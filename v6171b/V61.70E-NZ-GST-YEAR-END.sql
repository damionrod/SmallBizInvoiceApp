-- V61.70E NZ GST, tax periods & year-end foundation
-- Forward-only. No historical bootstrap or financial fixtures.

alter table public.financial_settings add column if not exists gst_number text;
alter table public.financial_settings add column if not exists balance_date_month smallint not null default 3;
alter table public.financial_settings add column if not exists balance_date_day smallint not null default 31;

create table if not exists public.gst_settings_history(
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 effective_from date not null, gst_registered boolean not null, gst_number text,
 accounting_basis text not null check(accounting_basis in('payments','invoice','hybrid')),
 filing_frequency text not null check(filing_frequency in('monthly','two_monthly','six_monthly')),
 balance_date_month smallint not null check(balance_date_month between 1 and 12),
 balance_date_day smallint not null check(balance_date_day between 1 and 31),
 created_at timestamptz not null default now(), created_by uuid default auth.uid(),
 unique(business_id,effective_from)
);
create table if not exists public.gst_adjustments(
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 adjustment_date date not null, adjustment_type text not null check(adjustment_type in('supply_correction','business_private','manual','bad_debt','other_debit','other_credit')),
 direction text not null check(direction in('debit','credit')), gst_amount numeric(14,2) not null check(gst_amount>=0),
 reason text not null check(length(btrim(reason))>0), reference text, evidence text,
 source_type text, source_id uuid, status text not null default 'active' check(status in('active','reversed')),
 reversal_of uuid references public.gst_adjustments(id), included_return_id uuid references public.gst_returns(id),
 created_at timestamptz not null default now(), created_by uuid default auth.uid(), updated_at timestamptz not null default now(), updated_by uuid default auth.uid()
);
create table if not exists public.gst_correction_items(
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 affected_return_id uuid not null references public.gst_returns(id), source_type text not null, source_id uuid,
 discovered_date date not null default current_date, original_amount numeric(14,2), corrected_amount numeric(14,2), gst_difference numeric(14,2) not null,
 reason text not null check(length(btrim(reason))>0), resolution_status text not null default 'review_required' check(resolution_status in('review_required','resolved','not_required')),
 resolution_notes text, created_at timestamptz not null default now(), created_by uuid default auth.uid(), resolved_at timestamptz, resolved_by uuid
);
alter table public.gst_returns add column if not exists debit_adjustments numeric(14,2) not null default 0;
alter table public.gst_returns add column if not exists credit_adjustments numeric(14,2) not null default 0;
alter table public.gst_returns add column if not exists review_items jsonb not null default '[]'::jsonb;
alter table public.gst_returns add column if not exists calculation_version text;
alter table public.gst_returns add column if not exists registration_snapshot jsonb not null default '{}'::jsonb;

alter table public.gst_settings_history enable row level security;
alter table public.gst_adjustments enable row level security;
alter table public.gst_correction_items enable row level security;
drop policy if exists gst_settings_history_read on public.gst_settings_history;
create policy gst_settings_history_read on public.gst_settings_history for select to authenticated using(public.v6147_can_read_area(business_id,'financials'));
drop policy if exists gst_adjustments_read on public.gst_adjustments;
create policy gst_adjustments_read on public.gst_adjustments for select to authenticated using(public.v6147_can_read_area(business_id,'financials'));
drop policy if exists gst_correction_items_read on public.gst_correction_items;
create policy gst_correction_items_read on public.gst_correction_items for select to authenticated using(public.v6147_can_read_area(business_id,'financials'));
revoke insert,update,delete,truncate on public.gst_settings_history,public.gst_adjustments,public.gst_correction_items from anon,authenticated;
revoke insert,update,delete,truncate on public.gst_returns from anon,authenticated;

drop function if exists public.v6170e_gst_settings(date);
create function public.v6170e_gst_settings(p_on date default current_date) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare bid uuid:=current_business_id(); h record; f record;begin
 if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501'; end if;
 select * into h from gst_settings_history where business_id=bid and effective_from<=p_on order by effective_from desc limit 1;
 if found then return jsonb_build_object('effective_from',h.effective_from,'gst_registered',h.gst_registered,'gst_number',h.gst_number,'accounting_basis',h.accounting_basis,'filing_frequency',h.filing_frequency,'balance_date_month',h.balance_date_month,'balance_date_day',h.balance_date_day); end if;
 select * into f from financial_settings where business_id=bid limit 1;
 return jsonb_build_object('effective_from',null,'gst_registered',coalesce(f.gst_registered,true),'gst_number',f.gst_number,'accounting_basis',coalesce(f.gst_accounting_basis,'invoice'),'filing_frequency',coalesce(f.gst_filing_frequency,'two_monthly'),'balance_date_month',coalesce(f.balance_date_month,3),'balance_date_day',coalesce(f.balance_date_day,31));
end$$;

drop function if exists public.v6170e_set_gst_settings(boolean,text,text,text,smallint,smallint,date);
create function public.v6170e_set_gst_settings(p_registered boolean,p_gst_number text,p_basis text,p_frequency text,p_balance_month smallint,p_balance_day smallint,p_effective_from date default current_date) returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'Financial settings access denied' using errcode='42501';end if;
 if p_basis not in('payments','invoice','hybrid') or p_frequency not in('monthly','two_monthly','six_monthly') then raise exception 'Invalid NZ GST configuration';end if;
 if p_balance_month not between 1 and 12 or p_balance_day not between 1 and 31 then raise exception 'Invalid balance date';end if;
 insert into gst_settings_history(business_id,effective_from,gst_registered,gst_number,accounting_basis,filing_frequency,balance_date_month,balance_date_day)
 values(bid,p_effective_from,p_registered,nullif(btrim(p_gst_number),''),p_basis,p_frequency,p_balance_month,p_balance_day)
 on conflict(business_id,effective_from) do update set gst_registered=excluded.gst_registered,gst_number=excluded.gst_number,accounting_basis=excluded.accounting_basis,filing_frequency=excluded.filing_frequency,balance_date_month=excluded.balance_date_month,balance_date_day=excluded.balance_date_day;
 update financial_settings set gst_registered=p_registered,gst_number=nullif(btrim(p_gst_number),''),gst_accounting_basis=p_basis,gst_filing_frequency=p_frequency,balance_date_month=p_balance_month,balance_date_day=p_balance_day,updated_at=now(),updated_by=auth.uid() where business_id=bid;
 return v6170e_gst_settings(p_effective_from);
end$$;

drop function if exists public.v6170e_gst_calculate(date,date);
create function public.v6170e_gst_calculate(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare bid uuid:=current_business_id(); cfg jsonb; basis text; registered boolean; sales_ex numeric:=0; sales_gst numeric:=0; purch_ex numeric:=0; purch_gst numeric:=0; debit_adj numeric:=0; credit_adj numeric:=0; legacy_count int:=0; missing_count int:=0; sales_items jsonb:='[]'; purchase_items jsonb:='[]'; adjustment_items jsonb:='[]'; review jsonb:='[]';begin
 if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid GST period';end if;
 cfg:=v6170e_gst_settings(p_to); basis:=cfg->>'accounting_basis'; registered:=coalesce((cfg->>'gst_registered')::boolean,false);
 if not registered then return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'sales_ex_gst',0,'gst_collected',0,'purchases_ex_gst',0,'gst_paid',0,'debit_adjustments',0,'credit_adjustments',0,'gst_net',0,'sales_items','[]'::jsonb,'purchase_items','[]'::jsonb,'adjustment_items','[]'::jsonb,'review_items',jsonb_build_array(jsonb_build_object('severity','blocking','code','not_registered','message','Business is not GST registered for this period.')));end if;
 -- Sales: invoice basis for invoice/hybrid; actual payments for payments basis.
 if basis in('invoice','hybrid') then
  select coalesce(sum(greatest(i.total-i.gst,0)),0),coalesce(sum(i.gst),0),coalesce(jsonb_agg(jsonb_build_object('source_type','invoice','source_id',i.id,'date',i.invoice_date,'reference',i.invoice_number,'party',i.customer_id::text,'ex_gst',greatest(i.total-i.gst,0),'gst',i.gst,'total',i.total) order by i.invoice_date,i.invoice_number),'[]') into sales_ex,sales_gst,sales_items from invoices i where i.business_id=bid and i.invoice_date between p_from and p_to and coalesce(i.lifecycle_state,'issued') not in('draft','voided');
 else
  select coalesce(sum(greatest(cp.amount-coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),0)),0),coalesce(sum(coalesce(i.gst,0)*(cp.amount/nullif(i.total,0))),0),coalesce(jsonb_agg(jsonb_build_object('source_type','customer_payment','source_id',cp.id,'date',cp.payment_date,'reference',i.invoice_number,'party',i.customer_id::text,'ex_gst',greatest(cp.amount-coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),0),'gst',coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),'total',cp.amount) order by cp.payment_date),'[]') into sales_ex,sales_gst,sales_items from customer_payments cp join invoices i on i.id=cp.invoice_id and i.business_id=cp.business_id where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=false and i.total>0;
  select count(*) into legacy_count from customer_payments cp where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=true;
  if legacy_count>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','legacy_estimated_payments','count',legacy_count,'message','Legacy estimated customer payment dates cannot be used as precise payments-basis GST evidence. Review required.'));end if;
 end if;
 -- Purchases: invoice basis only for invoice; payments basis for payments/hybrid. Business-use allocation is preserved.
 if basis='invoice' then
  select coalesce(sum(e.ex_gst*coalesce(e.business_use_percent,100)/100),0),coalesce(sum(e.gst_amount*coalesce(e.business_use_percent,100)/100),0),coalesce(jsonb_agg(jsonb_build_object('source_type','expense','source_id',e.id,'date',e.invoice_date,'reference',e.expense_number,'party',e.supplier_id::text,'ex_gst',e.ex_gst*coalesce(e.business_use_percent,100)/100,'gst',e.gst_amount*coalesce(e.business_use_percent,100)/100,'total',e.total_amount*coalesce(e.business_use_percent,100)/100,'business_use_percent',coalesce(e.business_use_percent,100)) order by e.invoice_date,e.expense_number),'[]') into purch_ex,purch_gst,purchase_items from expenses e where e.business_id=bid and e.invoice_date between p_from and p_to and coalesce(e.lifecycle_state,'recorded')='recorded';
 else
  select coalesce(sum(greatest(ep.amount-(e.gst_amount*(ep.amount/nullif(e.total_amount,0))),0)*coalesce(e.business_use_percent,100)/100),0),coalesce(sum(e.gst_amount*(ep.amount/nullif(e.total_amount,0))*coalesce(e.business_use_percent,100)/100),0),coalesce(jsonb_agg(jsonb_build_object('source_type','expense_payment','source_id',ep.id,'date',ep.payment_date,'reference',e.expense_number,'party',e.supplier_id::text,'ex_gst',greatest(ep.amount-(e.gst_amount*(ep.amount/nullif(e.total_amount,0))),0)*coalesce(e.business_use_percent,100)/100,'gst',e.gst_amount*(ep.amount/nullif(e.total_amount,0))*coalesce(e.business_use_percent,100)/100,'total',ep.amount*coalesce(e.business_use_percent,100)/100,'business_use_percent',coalesce(e.business_use_percent,100)) order by ep.payment_date),'[]') into purch_ex,purch_gst,purchase_items from expense_payments ep join expenses e on e.id=ep.expense_id and e.business_id=ep.business_id where ep.business_id=bid and ep.payment_date between p_from and p_to and e.total_amount>0 and coalesce(e.lifecycle_state,'recorded')='recorded';
 end if;
 -- Supply correction information is recognised in the period it is provided/received; settlement refunds do not create GST again.
 select sales_ex-coalesce(sum(c.ex_gst),0),sales_gst-coalesce(sum(c.gst_amount),0) into sales_ex,sales_gst from customer_credit_notes c where c.business_id=bid and c.lifecycle_state='issued' and c.credit_date between p_from and p_to;
 select purch_ex-coalesce(sum(c.ex_gst*coalesce(e.business_use_percent,100)/100),0),purch_gst-coalesce(sum(c.gst_amount*coalesce(e.business_use_percent,100)/100),0) into purch_ex,purch_gst from supplier_credits c join expenses e on e.id=c.original_expense_id and e.business_id=c.business_id where c.business_id=bid and c.lifecycle_state='recorded' and c.credit_date between p_from and p_to;
 select coalesce(sum(case when direction='debit' then gst_amount else 0 end),0),coalesce(sum(case when direction='credit' then gst_amount else 0 end),0),coalesce(jsonb_agg(jsonb_build_object('id',id,'date',adjustment_date,'type',adjustment_type,'direction',direction,'gst_amount',gst_amount,'reason',reason,'reference',reference) order by adjustment_date),'[]') into debit_adj,credit_adj,adjustment_items from gst_adjustments where business_id=bid and status='active' and adjustment_date between p_from and p_to;
 select count(*) into missing_count from expenses e where e.business_id=bid and e.invoice_date between p_from and p_to and coalesce(e.lifecycle_state,'recorded')='recorded' and e.total_amount>0 and e.gst_amount is null;
 if missing_count>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','missing_gst','count',missing_count,'message','Recorded expenses are missing GST information.'));end if;
 return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',basis,'sales_ex_gst',round(sales_ex,2),'gst_collected',round(sales_gst,2),'purchases_ex_gst',round(purch_ex,2),'gst_paid',round(purch_gst,2),'debit_adjustments',round(debit_adj,2),'credit_adjustments',round(credit_adj,2),'gst_net',round(sales_gst+debit_adj-purch_gst-credit_adj,2),'sales_items',sales_items,'purchase_items',purchase_items,'adjustment_items',adjustment_items,'review_items',review,'calculation_version','v61.70e');
end$$;

drop function if exists public.v6170e_save_gst_return(date,date,text);
create function public.v6170e_save_gst_return(p_from date,p_to date,p_status text default 'draft') returns gst_returns language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); calc jsonb; r gst_returns; blockers int; cfg jsonb; v_existing boolean:=false;begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'GST return access denied' using errcode='42501';end if;
 if p_status not in('draft','reviewed','finalised') then raise exception 'Invalid GST return status';end if;
 select * into r from gst_returns where business_id=bid and period_start=p_from and period_end=p_to for update; v_existing:=found;
 if v_existing and r.status='finalised' then raise exception 'This GST return is finalised and locked';end if;
 calc:=v6170e_gst_calculate(p_from,p_to); cfg:=calc->'settings'; select count(*) into blockers from jsonb_array_elements(calc->'review_items') x where x->>'severity'='blocking';
 if p_status='finalised' and blockers>0 then raise exception 'GST return has blocking review items and cannot be finalised';end if;
 if v_existing then
  update gst_returns set status=p_status,gst_rate=15,taxable_sales_ex_gst=(calc->>'sales_ex_gst')::numeric,gst_collected=(calc->>'gst_collected')::numeric,taxable_purchases_ex_gst=(calc->>'purchases_ex_gst')::numeric,gst_paid=(calc->>'gst_paid')::numeric,debit_adjustments=(calc->>'debit_adjustments')::numeric,credit_adjustments=(calc->>'credit_adjustments')::numeric,gst_net=(calc->>'gst_net')::numeric,snapshot=calc,accounting_basis=calc->>'basis',filing_frequency=cfg->>'filing_frequency',statutory_rule_snapshot=jsonb_build_object('country','NZ','standard_rate_percent',15),registration_snapshot=cfg,review_items=calc->'review_items',calculation_version='v61.70e',finalised_at=case when p_status='finalised' then now() else null end,finalised_by=case when p_status='finalised' then auth.uid() else null end,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 else
  insert into gst_returns(business_id,period_start,period_end,status,gst_rate,taxable_sales_ex_gst,gst_collected,taxable_purchases_ex_gst,gst_paid,debit_adjustments,credit_adjustments,gst_net,snapshot,accounting_basis,filing_frequency,statutory_rule_snapshot,registration_snapshot,review_items,calculation_version,finalised_at,finalised_by,created_by,updated_by)
  values(bid,p_from,p_to,p_status,15,(calc->>'sales_ex_gst')::numeric,(calc->>'gst_collected')::numeric,(calc->>'purchases_ex_gst')::numeric,(calc->>'gst_paid')::numeric,(calc->>'debit_adjustments')::numeric,(calc->>'credit_adjustments')::numeric,(calc->>'gst_net')::numeric,calc,calc->>'basis',cfg->>'filing_frequency',jsonb_build_object('country','NZ','standard_rate_percent',15),cfg,calc->'review_items','v61.70e',case when p_status='finalised' then now() end,case when p_status='finalised' then auth.uid() end,auth.uid(),auth.uid()) returning * into r;
 end if;
 if p_status='finalised' then update gst_adjustments set included_return_id=r.id,updated_at=now(),updated_by=auth.uid() where business_id=bid and status='active' and adjustment_date between p_from and p_to and included_return_id is null;end if;
 return r;
end$$;

drop function if exists public.v6170e_create_gst_adjustment(date,text,text,numeric,text,text,text,text,uuid);
create function public.v6170e_create_gst_adjustment(p_date date,p_type text,p_direction text,p_gst_amount numeric,p_reason text,p_reference text default null,p_evidence text default null,p_source_type text default null,p_source_id uuid default null) returns gst_adjustments language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r gst_adjustments;begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'GST adjustment access denied' using errcode='42501';end if;
 if coalesce(btrim(p_reason),'')='' or p_gst_amount<0 then raise exception 'Adjustment reason and valid amount are required';end if;
 if exists(select 1 from gst_returns where business_id=bid and status='finalised' and p_date between period_start and period_end) then raise exception 'This GST period is finalised. Create a correction/amendment review item instead.';end if;
 insert into gst_adjustments(business_id,adjustment_date,adjustment_type,direction,gst_amount,reason,reference,evidence,source_type,source_id) values(bid,p_date,p_type,p_direction,p_gst_amount,p_reason,p_reference,p_evidence,p_source_type,p_source_id) returning * into r;return r;
end$$;

drop function if exists public.v6170e_create_gst_correction(uuid,text,uuid,numeric,numeric,numeric,text);
create function public.v6170e_create_gst_correction(p_return_id uuid,p_source_type text,p_source_id uuid,p_original numeric,p_corrected numeric,p_gst_difference numeric,p_reason text) returns gst_correction_items language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r gst_correction_items;begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'GST correction access denied' using errcode='42501';end if;
 if not exists(select 1 from gst_returns where id=p_return_id and business_id=bid and status='finalised') then raise exception 'Finalised GST return not found';end if;
 insert into gst_correction_items(business_id,affected_return_id,source_type,source_id,original_amount,corrected_amount,gst_difference,reason) values(bid,p_return_id,p_source_type,p_source_id,p_original,p_corrected,p_gst_difference,p_reason) returning * into r;return r;
end$$;

drop function if exists public.v6170e_year_end_readiness(date);
create function public.v6170e_year_end_readiness(p_year_end date) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare bid uuid:=current_business_id(); ys date; gst_open int; bank_unrec int; ar numeric; ap numeric; drafts int; corr int; payroll_open int;begin
 if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501';end if; ys:=(p_year_end-interval '1 year'+interval '1 day')::date;
 select count(*) into gst_open from gst_returns where business_id=bid and period_end between ys and p_year_end and status<>'finalised';
 select count(*) into bank_unrec from bank_transactions where business_id=bid and transaction_date between ys and p_year_end and coalesce(status,'unmatched')<>'reconciled';
 select coalesce(sum(greatest(balance_due,0)),0) into ar from invoices where business_id=bid and invoice_date<=p_year_end;
 select coalesce(sum(greatest(e.total_amount-coalesce((select sum(p.amount) from expense_payments p where p.business_id=e.business_id and p.expense_id=e.id),0)-coalesce((select sum(c.total_amount) from supplier_credits c where c.business_id=e.business_id and c.original_expense_id=e.id and c.lifecycle_state='recorded'),0),0)),0) into ap from expenses e where e.business_id=bid and e.invoice_date<=p_year_end and coalesce(e.lifecycle_state,'recorded')='recorded';
 select (select count(*) from invoices where business_id=bid and coalesce(lifecycle_state,'issued')='draft')+(select count(*) from expenses where business_id=bid and coalesce(lifecycle_state,'recorded')='draft') into drafts;
 select count(*) into corr from gst_correction_items where business_id=bid and resolution_status='review_required';
 select count(*) into payroll_open from payroll_pay_runs p where p.business_id=bid and coalesce((to_jsonb(p)->>'period_end')::date,(to_jsonb(p)->>'pay_date')::date)<=p_year_end and coalesce(to_jsonb(p)->>'status','') not in('finalised','voided');
 return jsonb_build_object('year_start',ys,'year_end',p_year_end,'gst_unfinalised',gst_open,'unreconciled_bank',bank_unrec,'unpaid_customers',ar,'unpaid_suppliers_legacy',ap,'draft_transactions',drafts,'unresolved_gst_corrections',corr,'unfinalised_payroll',payroll_open,'ready',gst_open=0 and bank_unrec=0 and drafts=0 and corr=0 and payroll_open=0,'note','Readiness guide for accountant handoff; not an income-tax return.');
end$$;

-- Finalised GST evidence is immutable to direct table mutation; controlled RPCs own changes.
create or replace function public.v6170e_guard_gst_return_mutation() returns trigger language plpgsql set search_path=public as $$begin if old.status='finalised' then raise exception 'Finalised GST return is immutable';end if;return new;end$$;
drop trigger if exists trg_v6170e_guard_gst_return on public.gst_returns;
create trigger trg_v6170e_guard_gst_return before update or delete on public.gst_returns for each row execute function public.v6170e_guard_gst_return_mutation();

revoke all on function public.v6170e_gst_settings(date),public.v6170e_set_gst_settings(boolean,text,text,text,smallint,smallint,date),public.v6170e_gst_calculate(date,date),public.v6170e_save_gst_return(date,date,text),public.v6170e_create_gst_adjustment(date,text,text,numeric,text,text,text,text,uuid),public.v6170e_create_gst_correction(uuid,text,uuid,numeric,numeric,numeric,text),public.v6170e_year_end_readiness(date) from public,anon;
grant execute on function public.v6170e_gst_settings(date),public.v6170e_set_gst_settings(boolean,text,text,text,smallint,smallint,date),public.v6170e_gst_calculate(date,date),public.v6170e_save_gst_return(date,date,text),public.v6170e_create_gst_adjustment(date,text,text,numeric,text,text,text,text,uuid),public.v6170e_create_gst_correction(uuid,text,uuid,numeric,numeric,numeric,text),public.v6170e_year_end_readiness(date) to authenticated;
