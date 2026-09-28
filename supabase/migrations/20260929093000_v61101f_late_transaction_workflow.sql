-- v61.101F: controlled late supplier-bill workflow for closed accounting / finalised GST periods.
-- Additive: preserves invoice date and finalised GST snapshots; no historical return is rewritten.
begin;

create table if not exists public.late_transaction_adjustments(
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 expense_id uuid not null references public.expenses(id) on delete cascade, original_invoice_date date not null, entered_at timestamptz not null default now(),
 original_gst_return_id uuid references public.gst_returns(id), original_gst_period_start date, original_gst_period_end date, original_return_status text,
 accounting_period_id uuid references public.accounting_periods(id), gst_basis text not null, gst_amount numeric(14,2) not null default 0,
 treatment text not null check(treatment in ('current_period','prior_return_action','accounting_only')), adjustment_date date, adjustment_gst_period_start date, adjustment_gst_period_end date,
 adjustment_reason text not null, rule_version text not null, status text not null check(status in ('approved_current_period','requires_prior_return_action','accounting_only','reversed')),
 gst_adjustment_id uuid references public.gst_adjustments(id), correction_item_id uuid references public.gst_correction_items(id),
 created_at timestamptz not null default now(), created_by uuid, updated_at timestamptz not null default now(), updated_by uuid,
 unique(business_id,expense_id)
);
alter table public.late_transaction_adjustments enable row level security;
drop policy if exists late_transaction_adjustments_select on public.late_transaction_adjustments;
create policy late_transaction_adjustments_select on public.late_transaction_adjustments for select to authenticated using (business_id=public.current_business_id() and public.v6147_can_read_area(business_id,'expenses'));

create or replace function public.v61101f_late_expense_status(p_business_id uuid,p_expense_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare e public.expenses%rowtype; cfg jsonb; basis text; gr public.gst_returns%rowtype; ap public.accounting_periods%rowtype; pay_date date; tax_date date; existing public.late_transaction_adjustments%rowtype; eligible boolean:=false; why text;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id or not public.v6147_can_read_area(p_business_id,'expenses') then raise exception 'Expense access denied'; end if;
 select * into e from public.expenses where id=p_expense_id and business_id=p_business_id; if not found then raise exception 'Expense not found'; end if;
 cfg:=public.v6170e_gst_settings(e.invoice_date); basis:=coalesce(cfg->>'accounting_basis','invoice');
 select * into ap from public.accounting_periods where business_id=p_business_id and status='closed' and e.invoice_date between period_start and period_end order by period_end desc limit 1;
 if basis='invoice' then tax_date:=e.invoice_date; else select min(payment_date) into pay_date from public.expense_payments where business_id=p_business_id and expense_id=e.id; tax_date:=pay_date; end if;
 if tax_date is not null then select * into gr from public.gst_returns where business_id=p_business_id and status='finalised' and tax_date between period_start and period_end order by period_end desc limit 1; end if;
 select * into existing from public.late_transaction_adjustments where business_id=p_business_id and expense_id=e.id;
 if gr.id is not null and coalesce(e.gst_amount,0)<>0 and current_date-e.invoice_date<=730 then eligible:=true; why:='IRD permits unclaimed purchases or expenses to be claimed in a next return in specified cases, including a clear mistake or simple oversight, subject to the applicable time limit.';
 elsif gr.id is not null then why:='This GST amount relates to a finalised return and should be reviewed for amendment or other IRD correction treatment.';
 elsif basis in ('payments','hybrid') and tax_date is null then why:='No GST correction is currently required because purchase GST is attributed using payment information and no payment has been recorded yet.';
 else why:='No finalised GST return is affected by the currently available transaction/payment dates.'; end if;
 return jsonb_build_object('expense_id',e.id,'invoice_date',e.invoice_date,'entered_at',coalesce(e.upload_date,e.created_at),'gst_basis',basis,'gst_amount',coalesce(e.gst_amount,0),'tax_date',tax_date,'accounting_period_closed',ap.id is not null,'accounting_period_start',ap.period_start,'accounting_period_end',ap.period_end,'gst_return_finalised',gr.id is not null,'gst_return_id',gr.id,'gst_period_start',gr.period_start,'gst_period_end',gr.period_end,'eligible_current_period',eligible,'explanation',why,'existing_status',existing.status,'existing_treatment',existing.treatment);
end $$;
grant execute on function public.v61101f_late_expense_status(uuid,uuid) to authenticated;

create or replace function public.v61101f_record_late_expense(p_business_id uuid,p_expense_id uuid,p_treatment text,p_reason text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s jsonb; e public.expenses%rowtype; adj uuid; corr uuid; st text;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id or not public.v6147_can_write_area(p_business_id,'expenses') then raise exception 'Expense access denied'; end if;
 if p_treatment not in ('current_period','prior_return_action','accounting_only') then raise exception 'Choose a valid late-transaction treatment'; end if;
 if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Enter a reason for the late transaction'; end if;
 s:=public.v61101f_late_expense_status(p_business_id,p_expense_id); select * into e from public.expenses where id=p_expense_id and business_id=p_business_id;
 if p_treatment='current_period' and not coalesce((s->>'eligible_current_period')::boolean,false) then raise exception 'This transaction is not eligible for automatic current-period GST correction'; end if;
 if p_treatment='current_period' and coalesce(e.gst_amount,0)<>0 then
  insert into public.gst_adjustments(business_id,adjustment_date,adjustment_type,direction,gst_amount,reason,reference,evidence,source_type,source_id,status,created_by,updated_by)
  values(p_business_id,current_date,'late_purchase','credit',abs(e.gst_amount),trim(p_reason),e.expense_number,'Late supplier bill; original invoice date preserved.','expense',e.id,'active',auth.uid(),auth.uid()) returning id into adj;
  st:='approved_current_period';
 elsif p_treatment='prior_return_action' then st:='requires_prior_return_action'; else st:='accounting_only'; end if;
 if coalesce((s->>'gst_return_finalised')::boolean,false) then
  insert into public.gst_correction_items(business_id,affected_return_id,source_type,source_id,discovered_date,original_amount,corrected_amount,gst_difference,reason,resolution_status,resolution_notes,created_by)
  values(p_business_id,(s->>'gst_return_id')::uuid,'expense',e.id,current_date,0,e.gst_amount,e.gst_amount,trim(p_reason),case when p_treatment='current_period' then 'resolved_next_return' else 'requires_action' end,'Original finalised return snapshot is unchanged.',auth.uid()) returning id into corr;
 end if;
 insert into public.late_transaction_adjustments(business_id,expense_id,original_invoice_date,original_gst_return_id,original_gst_period_start,original_gst_period_end,original_return_status,accounting_period_id,gst_basis,gst_amount,treatment,adjustment_date,adjustment_reason,rule_version,status,gst_adjustment_id,correction_item_id,created_by,updated_by)
 values(p_business_id,e.id,e.invoice_date,nullif(s->>'gst_return_id','')::uuid,nullif(s->>'gst_period_start','')::date,nullif(s->>'gst_period_end','')::date,case when coalesce((s->>'gst_return_finalised')::boolean,false) then 'finalised' end,(select id from public.accounting_periods where business_id=p_business_id and status='closed' and e.invoice_date between period_start and period_end order by period_end desc limit 1),s->>'gst_basis',coalesce(e.gst_amount,0),p_treatment,case when p_treatment='current_period' then current_date end,trim(p_reason),'NZ-IRD-fixing-mistakes-2026-09-29',st,adj,corr,auth.uid(),auth.uid())
 on conflict(business_id,expense_id) do update set treatment=excluded.treatment,adjustment_date=excluded.adjustment_date,adjustment_reason=excluded.adjustment_reason,rule_version=excluded.rule_version,status=excluded.status,gst_adjustment_id=coalesce(excluded.gst_adjustment_id,late_transaction_adjustments.gst_adjustment_id),correction_item_id=coalesce(excluded.correction_item_id,late_transaction_adjustments.correction_item_id),updated_at=now(),updated_by=auth.uid();
 return jsonb_build_object('ok',true,'status',st,'gst_adjustment_id',adj,'correction_item_id',corr);
end $$;
grant execute on function public.v61101f_record_late_expense(uuid,uuid,text,text) to authenticated;

create or replace function public.v6190_review_purchase(p_business_id uuid,p_expense_id uuid,p_expected_revision integer,p_rows jsonb,p_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_bill public.expenses%rowtype; v_previous public.purchase_invoice_reviews%rowtype;
 v_line jsonb; v_category uuid; v_ex numeric; v_gst numeric; v_qty numeric;
 v_ex_total numeric:=0;v_gst_total numeric:=0;v_id uuid;v_date date;v_life integer;
 v_se_revision integer;v_stock_enabled boolean;v_target jsonb;v_index integer:=0;v_line_number integer:=0;v_net_rows jsonb; v_alloc jsonb; v_alloc_ex numeric; v_alloc_gst numeric; v_alloc_target integer; v_alloc_ex_total numeric; v_alloc_gst_total numeric;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id
    or not public.v6147_can_write_area(p_business_id,'expenses') then raise exception 'Expense access denied'; end if;
 select * into v_bill from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found or v_bill.payment_status='draft' or coalesce(v_bill.archived,false)
    or coalesce(v_bill.lifecycle_state,'recorded')<>'recorded' then raise exception 'Record an active bill before review'; end if;
 if exists(select 1 from public.accounting_journals where business_id=p_business_id and source_type='expense'
    and source_id=p_expense_id and status='posted') then raise exception 'A posted bill requires an accountant-approved reclassification'; end if;
 if (exists(select 1 from public.accounting_periods where business_id=p_business_id
    and status='closed' and v_bill.invoice_date between period_start and period_end)
    or exists(select 1 from public.gst_returns where business_id=p_business_id and status='finalised'
    and v_bill.invoice_date between period_start and period_end))
    and not exists(select 1 from public.late_transaction_adjustments a where a.business_id=p_business_id
      and a.expense_id=p_expense_id and a.status in ('approved_current_period','requires_prior_return_action','accounting_only'))
   then raise exception 'LATE_TRANSACTION_REVIEW_REQUIRED'; end if;
 select * into v_previous from public.purchase_invoice_reviews where business_id=p_business_id
   and expense_id=p_expense_id order by revision desc limit 1 for update;
 if coalesce(v_previous.revision,0)<>coalesce(p_expected_revision,-1) then raise exception 'The review changed; reload before saving'; end if;
 if v_previous.id is not null and nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Give a reason for correcting a confirmed review'; end if;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 150 then raise exception 'Review between 1 and 150 items'; end if;
 for v_line in select value from jsonb_array_elements(p_rows) loop
  if jsonb_typeof(v_line)<>'object' or coalesce(v_line->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment','discount')
     or length(trim(coalesce(v_line->>'description',''))) not between 1 and 500
     or nullif(v_line->>'category_id','') is null or nullif(v_line->>'ex_gst','') is null
     or nullif(v_line->>'gst','') is null or nullif(v_line->>'quantity','') is null then raise exception 'Complete every item, category, quantity and GST amount'; end if;
  begin
   v_category:=(v_line->>'category_id')::uuid;v_ex:=(v_line->>'ex_gst')::numeric;
   v_gst:=(v_line->>'gst')::numeric;v_qty:=(v_line->>'quantity')::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Invalid item category or amount'; end;
  if not exists(select 1 from public.expense_categories c where c.id=v_category and c.business_id=p_business_id and not c.archived)
     or v_qty<=0 or v_qty>1000000 or v_ex<>round(v_ex,2) or v_gst<>round(v_gst,2)
     then raise exception 'Check category, amount and quantity on every item'; end if;
  if v_line ? 'allocation' and jsonb_typeof(v_line->'allocation')='object' then
   if jsonb_typeof(v_line->'allocation'->'allocations')<>'array' or jsonb_array_length(v_line->'allocation'->'allocations')<1
      or coalesce(v_line->'allocation'->>'method','') not in ('proportional','equal','manual')
      or coalesce(v_line->'allocation'->>'type','') not in ('freight','delivery','handling','discount','other') then
     raise exception 'Check the allocation method and selected items'; end if;
   v_alloc_ex_total:=0;v_alloc_gst_total:=0;
   for v_alloc in select value from jsonb_array_elements(v_line->'allocation'->'allocations') loop
    begin v_alloc_target:=(v_alloc->>'target_index')::integer;v_alloc_ex:=(v_alloc->>'ex_gst')::numeric;v_alloc_gst:=(v_alloc->>'gst')::numeric;
    exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Invalid allocation amount or target'; end;
    if v_alloc_target<0 or v_alloc_target>=jsonb_array_length(p_rows) or v_alloc_target=v_line_number
       or v_alloc_ex<>round(v_alloc_ex,2) or v_alloc_gst<>round(v_alloc_gst,2) then raise exception 'Check every allocated amount'; end if;
    v_target:=p_rows->v_alloc_target;
    if coalesce(v_target->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment')
       or (v_target ? 'allocation' and jsonb_typeof(v_target->'allocation')='object') then raise exception 'Allocate only to purchased item lines'; end if;
    v_alloc_ex_total:=v_alloc_ex_total+v_alloc_ex;v_alloc_gst_total:=v_alloc_gst_total+v_alloc_gst;
   end loop;
   if v_alloc_ex_total<>v_ex or v_alloc_gst_total<>v_gst then raise exception 'Allocated amounts must equal the invoice adjustment exactly'; end if;
   if v_line->>'kind'='discount' and (v_ex>=0 or v_gst>0 or v_qty<>1) then raise exception 'Check the discount amount'; end if;
   if v_line->>'kind'<>'discount' and (v_ex<0 or v_gst<0) then raise exception 'Use a discount row for a negative amount'; end if;
  elsif v_line->>'kind'='discount' then
   -- Legacy single-target discounts remain valid for existing reviewed bills.
   if coalesce(v_line->>'discount_target_index','') !~ '^[0-9]+$' then raise exception 'Choose which invoice charge this discount reduces'; end if;
   v_index:=(v_line->>'discount_target_index')::integer;
   if v_index>=v_line_number or v_ex>=0 or v_gst>0 or v_qty<>1 then raise exception 'Check the discount amount and its earlier charge'; end if;
   v_target:=p_rows->v_index;
   if coalesce(v_target->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment')
      or v_target->>'category_id' is distinct from v_line->>'category_id'
      or v_line->>'discount_for' is distinct from v_target->>'kind' then raise exception 'Discount must reduce a charge in the same category and Use'; end if;
  elsif v_ex<0 or v_gst<0 then raise exception 'Use a discount row for a negative amount';
  end if;
  if v_line->>'kind'='equipment' then
   begin v_date:=(v_line->>'available_on')::date;v_life:=(v_line->>'life_months')::integer;
   exception when invalid_datetime_format or invalid_text_representation then raise exception 'Check the equipment ready date and life'; end;
   if v_date is null or v_date<v_bill.invoice_date or v_life not between 1 and 1200
      or coalesce(v_line->>'book_method','') not in ('SL','DV') then raise exception 'Equipment needs a ready date, useful life and method'; end if;
  end if;
  v_ex_total:=v_ex_total+v_ex;v_gst_total:=v_gst_total+v_gst;v_line_number:=v_line_number+1;
 end loop;
 if v_ex_total<>v_bill.ex_gst or v_gst_total<>v_bill.gst_amount then raise exception 'Item ex GST and GST totals must match the bill exactly'; end if;
 v_net_rows:=public.v6190_net_purchase_rows(p_rows);
 select exists(select 1 from public.modules m where m.slug='stock_equipment' and m.is_active)
   and coalesce((select case when bm.status='active' then true
                   when bm.status='trialing' then bm.trial_ends_at is null or bm.trial_ends_at>now()
                   else false end from public.business_modules bm join public.modules m on m.id=bm.module_id
                 where bm.business_id=p_business_id and m.slug='stock_equipment' and m.is_active),
                (select s.status in ('active','trialing') and 'stock_equipment'=any(pl.included_modules)
                   from public.subscriptions s join public.plans pl on pl.id=s.plan_id
                  where s.business_id=p_business_id limit 1),false) into v_stock_enabled;
 if v_stock_enabled then
   select coalesce(max(revision),0) into v_se_revision from public.se_invoice_reviews
    where business_id=p_business_id and expense_id=p_expense_id;
   perform public.se_review_invoice(p_business_id,p_expense_id,v_se_revision,v_net_rows,p_reason);
 end if;
 insert into public.purchase_invoice_reviews(business_id,expense_id,revision,rows,source_ex_gst,source_gst,reviewed_by,reason)
 values(p_business_id,p_expense_id,coalesce(v_previous.revision,0)+1,p_rows,v_bill.ex_gst,v_bill.gst_amount,auth.uid(),nullif(trim(p_reason),'')) returning id into v_id;
 return v_id;
end $$;

revoke all on function public.v6190_review_purchase(uuid,uuid,integer,jsonb,text) from public,anon;
grant execute on function public.v6190_review_purchase(uuid,uuid,integer,jsonb,text) to authenticated;
commit;
