-- V61.70F — Australian Accounting & BAS Foundation
-- Forward-only. Reuses Phase-E effective-dated tax settings and controlled source evidence.

alter table public.gst_settings_history add column if not exists jurisdiction text not null default 'NZ';
alter table public.gst_settings_history add column if not exists tax_identifier text;

do $$ begin
  alter table public.gst_settings_history drop constraint if exists gst_settings_history_accounting_basis_check;
  alter table public.gst_settings_history add constraint gst_settings_history_accounting_basis_check check (accounting_basis in ('payments','invoice','hybrid','cash','non_cash'));
  alter table public.gst_settings_history drop constraint if exists gst_settings_history_filing_frequency_check;
  alter table public.gst_settings_history add constraint gst_settings_history_filing_frequency_check check (filing_frequency in ('monthly','two_monthly','six_monthly','quarterly','annual'));
  alter table public.gst_settings_history drop constraint if exists gst_settings_history_jurisdiction_check;
  alter table public.gst_settings_history add constraint gst_settings_history_jurisdiction_check check (jurisdiction in ('NZ','AU'));
exception when duplicate_object then null; end $$;

alter table public.invoices add column if not exists au_tax_classification text;
alter table public.expenses add column if not exists au_tax_classification text;
do $$ begin if to_regclass('public.expense_lines') is not null then execute 'alter table public.expense_lines add column if not exists au_tax_classification text'; end if; end $$;
alter table public.customer_credit_notes add column if not exists au_tax_classification text;
alter table public.supplier_credits add column if not exists au_tax_classification text;

do $$ declare t text; begin
  foreach t in array array['invoices','expenses','expense_lines','customer_credit_notes','supplier_credits'] loop
    execute format('alter table public.%I drop constraint if exists %I',t,t||'_au_tax_classification_check');
    execute format('alter table public.%I add constraint %I check (au_tax_classification is null or au_tax_classification in (''gst_taxable'',''gst_free'',''input_taxed'',''out_of_scope''))',t,t||'_au_tax_classification_check');
  end loop;
end $$;

create table if not exists public.bas_returns(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  status text not null default 'draft' check(status in('draft','reviewed','finalised')),
  jurisdiction text not null default 'AU' check(jurisdiction='AU'),
  gst_registered boolean not null default false,
  abn text,
  accounting_basis text not null check(accounting_basis in('cash','non_cash')),
  filing_frequency text not null check(filing_frequency in('monthly','quarterly','annual')),
  statutory_due_date date,
  g1_total_sales numeric(14,2) not null default 0,
  gst_on_sales numeric(14,2) not null default 0,
  gst_on_purchases numeric(14,2) not null default 0,
  gst_net numeric(14,2) not null default 0,
  snapshot jsonb not null default '{}'::jsonb,
  review_items jsonb not null default '[]'::jsonb,
  calculation_version text,
  statutory_rule_snapshot jsonb not null default '{}'::jsonb,
  registration_snapshot jsonb not null default '{}'::jsonb,
  finalised_at timestamptz,
  finalised_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,period_start,period_end)
);
create index if not exists bas_returns_business_period_idx on public.bas_returns(business_id,period_start,period_end);
alter table public.bas_returns enable row level security;
drop policy if exists bas_returns_select on public.bas_returns;
create policy bas_returns_select on public.bas_returns for select to authenticated using (business_id=public.current_business_id() and public.v6147_can_read_area(business_id,'financials'));
revoke all on public.bas_returns from anon,authenticated;
grant select on public.bas_returns to authenticated;

-- Australian statutory foundation. No tenant financial data is created.
insert into public.country_business_tax_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,active,source_note)
select * from (values
 ('AU','gst','standard_rate_percent',10::numeric,null::text,null::jsonb,'2000-07-01'::date,true,'ATO GST standard rate'),
 ('AU','gst','registration_threshold_12m',75000::numeric,null::text,null::jsonb,'2000-07-01'::date,true,'ATO GST registration threshold — general businesses'),
 ('AU','bas','g1_reporting_basis',null::numeric,'gst_inclusive'::text,null::jsonb,'2017-07-01'::date,true,'Finlo Simpler BAS foundation: G1 reported GST-inclusive'),
 ('AU','bas','simpler_bas_labels',null::numeric,null::text,'["G1","1A","1B"]'::jsonb,'2017-07-01'::date,true,'ATO Simpler BAS labels'),
 ('AU','bas','monthly_due_day',21::numeric,null::text,null::jsonb,'2000-07-01'::date,true,'ATO standard monthly BAS due day'),
 ('AU','bas','quarterly_due_dates',null::numeric,null::text,'{"09-30":"10-28","12-31":"02-28","03-31":"04-28","06-30":"07-28"}'::jsonb,'2000-07-01'::date,true,'ATO standard quarterly BAS due dates; agent/concession dates may differ')
) v(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,active,source_note)
where not exists(select 1 from public.country_business_tax_rules r where r.country_code=v.country_code and r.rule_type=v.rule_type and r.rule_key=v.rule_key and r.effective_from=v.effective_from);

create or replace function public.v6170f_business_country() returns text language sql stable security definer set search_path=public as $$
 select upper(coalesce((select settings->>'country' from public.businesses where id=public.current_business_id()),'NZ'))
$$;

create or replace function public.v6170f_bas_settings(p_on date default current_date) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare bid uuid:=current_business_id(); h gst_settings_history; f financial_settings; b businesses; basis text; freq text;begin
 if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501';end if;
 select * into b from businesses where id=bid;
 if upper(coalesce(b.settings->>'country','NZ'))<>'AU' then raise exception 'BAS is available only for Australian businesses' using errcode='22023';end if;
 select * into h from gst_settings_history where business_id=bid and jurisdiction='AU' and effective_from<=p_on order by effective_from desc limit 1;
 if found then return jsonb_build_object('jurisdiction','AU','gst_registered',h.gst_registered,'abn',coalesce(h.tax_identifier,h.gst_number),'accounting_basis',h.accounting_basis,'filing_frequency',h.filing_frequency,'balance_date_month',h.balance_date_month,'balance_date_day',h.balance_date_day,'effective_from',h.effective_from,'source','effective_history');end if;
 select * into f from financial_settings where business_id=bid;
 basis:=case when f.gst_accounting_basis='payments' then 'cash' else 'non_cash' end;
 freq:=case when f.gst_filing_frequency='monthly' then 'monthly' when f.gst_filing_frequency='annual' then 'annual' else 'quarterly' end;
 return jsonb_build_object('jurisdiction','AU','gst_registered',coalesce(f.gst_registered,false),'abn',coalesce(b.settings->>'abn',f.gst_number),'accounting_basis',basis,'filing_frequency',freq,'balance_date_month',coalesce(f.balance_date_month,6),'balance_date_day',coalesce(f.balance_date_day,30),'effective_from',null,'source','financial_settings_fallback');
end$$;

create or replace function public.v6170f_set_bas_settings(p_registered boolean,p_abn text,p_basis text,p_frequency text,p_balance_month smallint,p_balance_day smallint,p_effective_from date default current_date) returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'Financial settings access denied' using errcode='42501';end if;
 if v6170f_business_country()<>'AU' then raise exception 'Australian BAS settings require an Australian business' using errcode='22023';end if;
 if p_basis not in('cash','non_cash') or p_frequency not in('monthly','quarterly','annual') then raise exception 'Invalid Australian BAS configuration';end if;
 if p_balance_month not between 1 and 12 or p_balance_day not between 1 and 31 then raise exception 'Invalid balance date';end if;
 insert into gst_settings_history(business_id,effective_from,gst_registered,gst_number,tax_identifier,accounting_basis,filing_frequency,balance_date_month,balance_date_day,jurisdiction)
 values(bid,p_effective_from,p_registered,nullif(btrim(p_abn),''),nullif(btrim(p_abn),''),p_basis,p_frequency,p_balance_month,p_balance_day,'AU')
 on conflict(business_id,effective_from) do update set gst_registered=excluded.gst_registered,gst_number=excluded.gst_number,tax_identifier=excluded.tax_identifier,accounting_basis=excluded.accounting_basis,filing_frequency=excluded.filing_frequency,balance_date_month=excluded.balance_date_month,balance_date_day=excluded.balance_date_day,jurisdiction='AU';
 update financial_settings set gst_registered=p_registered,gst_number=nullif(btrim(p_abn),''),gst_accounting_basis=case when p_basis='cash' then 'payments' else 'invoice' end,gst_filing_frequency=case when p_frequency='monthly' then 'monthly' else 'two_monthly' end,balance_date_month=p_balance_month,balance_date_day=p_balance_day,updated_at=now(),updated_by=auth.uid() where business_id=bid;
 insert into financial_audit_log(business_id,entity_type,action,after_data,created_by) values(bid,'bas_settings','effective_settings_changed',jsonb_build_object('effective_from',p_effective_from,'gst_registered',p_registered,'abn',nullif(btrim(p_abn),''),'accounting_basis',p_basis,'filing_frequency',p_frequency,'balance_date_month',p_balance_month,'balance_date_day',p_balance_day),auth.uid());
 return v6170f_bas_settings(p_effective_from);
end$$;

create or replace function public.v6170f_bas_due_date(p_period_end date,p_frequency text) returns date language plpgsql stable set search_path=public as $$
declare y int:=extract(year from p_period_end); m int:=extract(month from p_period_end);begin
 if p_frequency='monthly' then return (date_trunc('month',p_period_end)::date + interval '1 month' + interval '20 days')::date; end if;
 if p_frequency='quarterly' then
   if m=9 then return make_date(y,10,28); elsif m=12 then return make_date(y+1,2,28); elsif m=3 then return make_date(y,4,28); elsif m=6 then return make_date(y,7,28); end if;
 end if;
 return null;
end$$;

create or replace function public.v6170f_bas_calculate(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare bid uuid:=current_business_id(); cfg jsonb; basis text; registered boolean; g1 numeric:=0; one_a numeric:=0; one_b numeric:=0; sales_items jsonb:='[]'; purchase_items jsonb:='[]'; review jsonb:='[]'; conflict_items jsonb:='[]'; missing_sales int:=0; missing_purchases int:=0; legacy_count int:=0; due date;
begin
 if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501';end if;
 if v6170f_business_country()<>'AU' then raise exception 'BAS calculation requires an Australian business' using errcode='22023';end if;
 if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid BAS period';end if;
 cfg:=v6170f_bas_settings(p_to); basis:=cfg->>'accounting_basis'; registered:=coalesce((cfg->>'gst_registered')::boolean,false); due:=v6170f_bas_due_date(p_to,cfg->>'filing_frequency');
 if not registered then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','not_registered','message','Business is not GST registered for this BAS period.'));end if;
 if basis='non_cash' then
   select coalesce(sum(case when i.au_tax_classification in('gst_taxable','gst_free','input_taxed') then i.total else 0 end),0),coalesce(sum(case when i.au_tax_classification='gst_taxable' then i.gst else 0 end),0),coalesce(jsonb_agg(jsonb_build_object('source_type','invoice','source_id',i.id,'date',i.invoice_date,'reference',i.invoice_number,'party',c.name,'party_id',i.customer_id,'classification',i.au_tax_classification,'g1',case when i.au_tax_classification in('gst_taxable','gst_free','input_taxed') then i.total else 0 end,'gst',case when i.au_tax_classification='gst_taxable' then i.gst else 0 end,'total',i.total) order by i.invoice_date,i.invoice_number),'[]') into g1,one_a,sales_items from invoices i left join customers c on c.id=i.customer_id and c.business_id=i.business_id where i.business_id=bid and i.invoice_date between p_from and p_to and coalesce(i.lifecycle_state,'issued') not in('draft','voided');
   select count(*) into missing_sales from invoices i where i.business_id=bid and i.invoice_date between p_from and p_to and coalesce(i.lifecycle_state,'issued') not in('draft','voided') and i.au_tax_classification is null;
   select coalesce(sum(case when e.au_tax_classification='gst_taxable' then e.gst_amount*coalesce(e.business_use_percent,100)/100 else 0 end),0),coalesce(jsonb_agg(jsonb_build_object('source_type','expense','source_id',e.id,'date',e.invoice_date,'reference',e.expense_number,'party',e.supplier_name,'party_id',e.supplier_id,'classification',e.au_tax_classification,'gst',case when e.au_tax_classification='gst_taxable' then e.gst_amount*coalesce(e.business_use_percent,100)/100 else 0 end,'total',e.total_amount*coalesce(e.business_use_percent,100)/100) order by e.invoice_date,e.expense_number),'[]') into one_b,purchase_items from expenses e where e.business_id=bid and e.invoice_date between p_from and p_to and coalesce(e.lifecycle_state,'recorded')='recorded';
   select count(*) into missing_purchases from expenses e where e.business_id=bid and e.invoice_date between p_from and p_to and coalesce(e.lifecycle_state,'recorded')='recorded' and e.au_tax_classification is null;
 else
   select coalesce(sum(case when i.au_tax_classification in('gst_taxable','gst_free','input_taxed') then cp.amount else 0 end),0),coalesce(sum(case when i.au_tax_classification='gst_taxable' then coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)) else 0 end),0),coalesce(jsonb_agg(jsonb_build_object('source_type','customer_payment','source_id',cp.id,'source_document_id',i.id,'date',cp.payment_date,'reference',i.invoice_number,'party',c.name,'party_id',i.customer_id,'classification',i.au_tax_classification,'g1',case when i.au_tax_classification in('gst_taxable','gst_free','input_taxed') then cp.amount else 0 end,'gst',case when i.au_tax_classification='gst_taxable' then coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)) else 0 end,'total',cp.amount) order by cp.payment_date,i.invoice_number),'[]') into g1,one_a,sales_items from customer_payments cp join invoices i on i.id=cp.invoice_id and i.business_id=cp.business_id left join customers c on c.id=i.customer_id and c.business_id=i.business_id where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=false and i.total>0 and coalesce(i.lifecycle_state,'issued') not in('draft','voided');
   select count(*) into legacy_count from customer_payments cp where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=true;
   select count(*) into missing_sales from customer_payments cp join invoices i on i.id=cp.invoice_id and i.business_id=cp.business_id where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=false and i.au_tax_classification is null;
   select coalesce(sum(case when e.au_tax_classification='gst_taxable' then e.gst_amount*(ep.amount/nullif(e.total_amount,0))*coalesce(e.business_use_percent,100)/100 else 0 end),0),coalesce(jsonb_agg(jsonb_build_object('source_type','expense_payment','source_id',ep.id,'source_document_id',e.id,'date',ep.payment_date,'reference',e.expense_number,'party',e.supplier_name,'party_id',e.supplier_id,'classification',e.au_tax_classification,'gst',case when e.au_tax_classification='gst_taxable' then e.gst_amount*(ep.amount/nullif(e.total_amount,0))*coalesce(e.business_use_percent,100)/100 else 0 end,'total',ep.amount*coalesce(e.business_use_percent,100)/100) order by ep.payment_date,e.expense_number),'[]') into one_b,purchase_items from expense_payments ep join expenses e on e.id=ep.expense_id and e.business_id=ep.business_id where ep.business_id=bid and ep.payment_date between p_from and p_to and e.total_amount>0 and coalesce(e.lifecycle_state,'recorded')='recorded';
   select count(*) into missing_purchases from expense_payments ep join expenses e on e.id=ep.expense_id and e.business_id=ep.business_id where ep.business_id=bid and ep.payment_date between p_from and p_to and e.au_tax_classification is null;
 end if;
 -- Controlled correction evidence. The correction source carries or inherits the original AU classification. Refund settlement does not create GST again.
 select g1-coalesce(sum(case when coalesce(cn.au_tax_classification,i.au_tax_classification) in('gst_taxable','gst_free','input_taxed') then cn.total_amount else 0 end),0),one_a-coalesce(sum(case when coalesce(cn.au_tax_classification,i.au_tax_classification)='gst_taxable' then cn.gst_amount else 0 end),0) into g1,one_a from customer_credit_notes cn join invoices i on i.id=cn.original_invoice_id and i.business_id=cn.business_id where cn.business_id=bid and cn.lifecycle_state='issued' and cn.credit_date between p_from and p_to;
 select sales_items||coalesce(jsonb_agg(jsonb_build_object('source_type','customer_credit_note','source_id',cn.id,'source_document_id',i.id,'date',cn.credit_date,'reference',cn.credit_note_number,'original_reference',i.invoice_number,'party',c.name,'party_id',cn.customer_id,'classification',coalesce(cn.au_tax_classification,i.au_tax_classification),'g1',case when coalesce(cn.au_tax_classification,i.au_tax_classification) in('gst_taxable','gst_free','input_taxed') then -cn.total_amount else 0 end,'gst',case when coalesce(cn.au_tax_classification,i.au_tax_classification)='gst_taxable' then -cn.gst_amount else 0 end,'total',-cn.total_amount) order by cn.credit_date,cn.credit_note_number),'[]'::jsonb) into sales_items from customer_credit_notes cn join invoices i on i.id=cn.original_invoice_id and i.business_id=cn.business_id left join customers c on c.id=cn.customer_id and c.business_id=cn.business_id where cn.business_id=bid and cn.lifecycle_state='issued' and cn.credit_date between p_from and p_to;
 select one_b-coalesce(sum(case when coalesce(sc.au_tax_classification,e.au_tax_classification)='gst_taxable' then sc.gst_amount*coalesce(e.business_use_percent,100)/100 else 0 end),0) into one_b from supplier_credits sc join expenses e on e.id=sc.original_expense_id and e.business_id=sc.business_id where sc.business_id=bid and sc.lifecycle_state='recorded' and sc.credit_date between p_from and p_to;
 select purchase_items||coalesce(jsonb_agg(jsonb_build_object('source_type','supplier_credit','source_id',sc.id,'source_document_id',e.id,'date',sc.credit_date,'reference',sc.credit_note_number,'original_reference',e.expense_number,'party',e.supplier_name,'party_id',sc.supplier_id,'classification',coalesce(sc.au_tax_classification,e.au_tax_classification),'gst',case when coalesce(sc.au_tax_classification,e.au_tax_classification)='gst_taxable' then -(sc.gst_amount*coalesce(e.business_use_percent,100)/100) else 0 end,'total',-(sc.total_amount*coalesce(e.business_use_percent,100)/100)) order by sc.credit_date,sc.credit_note_number),'[]'::jsonb) into purchase_items from supplier_credits sc join expenses e on e.id=sc.original_expense_id and e.business_id=sc.business_id where sc.business_id=bid and sc.lifecycle_state='recorded' and sc.credit_date between p_from and p_to;
 if missing_sales>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','missing_sales_tax_classification','count',missing_sales,'message','Australian sales evidence is missing a controlled GST classification. Review before finalising BAS.'));end if;
 if missing_purchases>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','missing_purchase_tax_classification','count',missing_purchases,'message','Australian purchase evidence is missing a controlled GST classification. Review before finalising BAS.'));end if;
 if legacy_count>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','legacy_estimated_payments','count',legacy_count,'message','Legacy estimated payment dates cannot be used as exact cash-basis BAS evidence.'));end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'period_start',r.period_start,'period_end',r.period_end,'status',r.status) order by r.period_start),'[]') into conflict_items from bas_returns r where r.business_id=bid and r.status='finalised' and daterange(r.period_start,r.period_end,'[]')&&daterange(p_from,p_to,'[]') and not(r.period_start=p_from and r.period_end=p_to);
 if jsonb_array_length(conflict_items)>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','finalised_period_overlap','message','BAS period conflict — an existing finalised BAS overlaps this period.','returns',conflict_items));end if;
 return jsonb_build_object('jurisdiction','AU','period_start',p_from,'period_end',p_to,'due_date',due,'settings',cfg,'basis',basis,'filing_frequency',cfg->>'filing_frequency','g1_total_sales',round(g1,2),'gst_on_sales',round(one_a,2),'gst_on_purchases',round(one_b,2),'gst_net',round(one_a-one_b,2),'sales_items',sales_items,'purchase_items',purchase_items,'review_items',review,'other_obligations',jsonb_build_object('payg_withholding',jsonb_build_object('status','unavailable','message','Requires authoritative finalised Australian payroll evidence.'),'payg_instalment',jsonb_build_object('status','unavailable','message','Not configured in this BAS foundation.')),'calculation_version','v61.70f','g1_reporting_basis','gst_inclusive');
end$$;

create or replace function public.v6170f_save_bas_return(p_from date,p_to date,p_status text default 'draft') returns public.bas_returns language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); calc jsonb; cfg jsonb; r bas_returns; conflict bas_returns; blockers int; existing boolean:=false; before_row jsonb;begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'BAS access denied' using errcode='42501';end if;
 if v6170f_business_country()<>'AU' then raise exception 'BAS is available only for Australian businesses' using errcode='22023';end if;
 if p_status not in('draft','reviewed','finalised') then raise exception 'Invalid BAS status';end if;
 select * into r from bas_returns where business_id=bid and period_start=p_from and period_end=p_to for update;existing:=found;before_row:=case when existing then to_jsonb(r) else null end;
 if existing and r.status='finalised' then raise exception 'This BAS is finalised and locked';end if;
 if p_status='finalised' then select * into conflict from bas_returns x where x.business_id=bid and x.status='finalised' and daterange(x.period_start,x.period_end,'[]')&&daterange(p_from,p_to,'[]') and (not existing or x.id<>r.id) order by x.period_start limit 1 for update;if found then raise exception 'BAS period conflict: existing finalised BAS % to % overlaps this period',conflict.period_start,conflict.period_end using errcode='23514';end if;end if;
 calc:=v6170f_bas_calculate(p_from,p_to);cfg:=calc->'settings';select count(*) into blockers from jsonb_array_elements(calc->'review_items') x where x->>'severity'='blocking';if p_status='finalised' and blockers>0 then raise exception 'BAS has blocking review items and cannot be finalised';end if;
 if existing then update bas_returns set status=p_status,gst_registered=coalesce((cfg->>'gst_registered')::boolean,false),abn=cfg->>'abn',accounting_basis=calc->>'basis',filing_frequency=calc->>'filing_frequency',statutory_due_date=nullif(calc->>'due_date','')::date,g1_total_sales=(calc->>'g1_total_sales')::numeric,gst_on_sales=(calc->>'gst_on_sales')::numeric,gst_on_purchases=(calc->>'gst_on_purchases')::numeric,gst_net=(calc->>'gst_net')::numeric,snapshot=calc,review_items=calc->'review_items',calculation_version='v61.70f',statutory_rule_snapshot=jsonb_build_object('jurisdiction','AU','gst_rate_percent',10,'g1_reporting_basis','gst_inclusive','simpler_bas_labels',jsonb_build_array('G1','1A','1B')),registration_snapshot=cfg,finalised_at=case when p_status='finalised' then now() else null end,finalised_by=case when p_status='finalised' then auth.uid() else null end,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 else insert into bas_returns(business_id,period_start,period_end,status,gst_registered,abn,accounting_basis,filing_frequency,statutory_due_date,g1_total_sales,gst_on_sales,gst_on_purchases,gst_net,snapshot,review_items,calculation_version,statutory_rule_snapshot,registration_snapshot,finalised_at,finalised_by,created_by,updated_by) values(bid,p_from,p_to,p_status,coalesce((cfg->>'gst_registered')::boolean,false),cfg->>'abn',calc->>'basis',calc->>'filing_frequency',nullif(calc->>'due_date','')::date,(calc->>'g1_total_sales')::numeric,(calc->>'gst_on_sales')::numeric,(calc->>'gst_on_purchases')::numeric,(calc->>'gst_net')::numeric,calc,calc->'review_items','v61.70f',jsonb_build_object('jurisdiction','AU','gst_rate_percent',10,'g1_reporting_basis','gst_inclusive','simpler_bas_labels',jsonb_build_array('G1','1A','1B')),cfg,case when p_status='finalised' then now() end,case when p_status='finalised' then auth.uid() end,auth.uid(),auth.uid()) returning * into r;end if;
 insert into financial_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) values(bid,'bas_returns',r.id,case when existing then 'updated' else 'created' end,before_row,to_jsonb(r),auth.uid());
 return r;
end$$;

create or replace function public.v6170f_guard_bas_immutability() returns trigger language plpgsql set search_path=public as $$begin
 if tg_op='DELETE' and old.status='finalised' then raise exception 'Finalised BAS is immutable';end if;
 if tg_op='UPDATE' and old.status='finalised' and new is distinct from old then raise exception 'Finalised BAS is immutable';end if;
 return case when tg_op='DELETE' then old else new end;
end$$;
drop trigger if exists v6170f_bas_immutable on public.bas_returns;
create trigger v6170f_bas_immutable before update or delete on public.bas_returns for each row execute function public.v6170f_guard_bas_immutability();

create or replace function public.v6170f_preserve_au_credit_tax_classification() returns trigger language plpgsql set search_path=public as $$begin
 if new.au_tax_classification is null then
  if tg_table_name='customer_credit_notes' then select au_tax_classification into new.au_tax_classification from invoices where id=new.original_invoice_id and business_id=new.business_id;
  elsif tg_table_name='supplier_credits' then select au_tax_classification into new.au_tax_classification from expenses where id=new.original_expense_id and business_id=new.business_id;end if;
 end if;return new;end$$;
drop trigger if exists v6170f_credit_tax_classification on public.customer_credit_notes;
create trigger v6170f_credit_tax_classification before insert or update of original_invoice_id,au_tax_classification on public.customer_credit_notes for each row execute function public.v6170f_preserve_au_credit_tax_classification();
drop trigger if exists v6170f_supplier_credit_tax_classification on public.supplier_credits;
create trigger v6170f_supplier_credit_tax_classification before insert or update of original_expense_id,au_tax_classification on public.supplier_credits for each row execute function public.v6170f_preserve_au_credit_tax_classification();

revoke all on function public.v6170f_business_country(),public.v6170f_bas_settings(date),public.v6170f_set_bas_settings(boolean,text,text,text,smallint,smallint,date),public.v6170f_bas_calculate(date,date),public.v6170f_save_bas_return(date,date,text) from public,anon;
grant execute on function public.v6170f_business_country(),public.v6170f_bas_settings(date),public.v6170f_set_bas_settings(boolean,text,text,text,smallint,smallint,date),public.v6170f_bas_calculate(date,date),public.v6170f_save_bas_return(date,date,text) to authenticated;
