-- Staged NZ GST basis-change workflow. Requests never change official settings,
-- create adjustments or post journals. Affected filing stays blocked until verified.
create table public.gst_basis_change_requests (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 period_start date not null, period_end date not null, effective_from date not null,
 previous_basis text not null check(previous_basis in ('invoice','payments','hybrid')),
 requested_basis text not null check(requested_basis in ('invoice','payments','hybrid')),
 change_kind text not null check(change_kind in ('correction','ird_change')),
 evidence_reference text not null check(length(btrim(evidence_reference)) between 1 and 2000),
 preview jsonb not null,
 status text not null default 'pending_verification' check(status in ('pending_verification','cancelled')),
 created_at timestamptz not null default now(), created_by uuid not null references auth.users(id),
 cancelled_at timestamptz, cancelled_by uuid references auth.users(id),
 check(period_start<=period_end), check(effective_from<=period_end)
);
create unique index gst_basis_request_pending_once on public.gst_basis_change_requests
 (business_id,period_start,period_end,effective_from,requested_basis,change_kind) where status='pending_verification';
alter table public.gst_basis_change_requests enable row level security;
revoke all on public.gst_basis_change_requests from public,anon,authenticated;
grant select on public.gst_basis_change_requests to authenticated;
create policy gst_basis_request_read on public.gst_basis_change_requests for select to authenticated
 using(business_id=public.current_business_id() and public.v6147_can_read_area(business_id,'financials'));

create function frindly_cash.gst_basis_review(p_from date,p_to date) returns jsonb
 language plpgsql stable security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); issues jsonb:='[]';
begin
 if auth.uid() is null or b is null or not public.v6147_can_read_area(b,'financials') then raise exception 'Financial access denied' using errcode='42501';end if;
 if exists(select 1 from public.gst_basis_change_requests r where r.business_id=b and r.status='pending_verification'
   and case when r.change_kind='ird_change' then r.effective_from<=p_to else r.period_start<=p_to and r.period_end>=p_from end) then
  issues:=issues||jsonb_build_array(jsonb_build_object('severity','blocking','code','basis_change_pending_verification','message','A GST basis-change request affects this period. It is pending verification. You can review and save a draft, but cannot finalise it yet.'));
 end if;
 if exists(select 1 from (select effective_from,accounting_basis,gst_registered,
 lag(accounting_basis) over(order by effective_from) prior_basis,
 lag(gst_registered) over(order by effective_from) prior_registered
 from public.gst_settings_history where business_id=b and coalesce(jurisdiction,'NZ')='NZ') h
 where h.effective_from<=p_to and h.gst_registered and h.prior_registered and h.accounting_basis<>h.prior_basis) then
  issues:=issues||jsonb_build_array(jsonb_build_object('severity','blocking','code','historical_basis_transition_unverified','message','GST settings include an accounting-basis change. Its outstanding invoice and bill reconciliation must be verified before filing. No transition adjustment has been automatically posted.'));
 end if;
 return issues;
end $$;
revoke all on function frindly_cash.gst_basis_review(date,date) from public,anon,authenticated;

create function public.frindly_preview_gst_basis_change_v1(p_from date,p_to date,p_basis text,p_effective date,p_kind text)
 returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); cfg jsonb; old_basis text; proposed jsonb; normal jsonb;
 rows jsonb:='[]'; reviews jsonb:='[]'; r record; paid numeric; outstanding numeric; tax numeric;
 debtor numeric:=0; creditor numeric:=0; net numeric:=0; locked boolean; sources jsonb; calculated jsonb;
begin
 if auth.uid() is null or b is null or not public.v6147_can_read_area(b,'financials') then raise exception 'Financial access denied' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from>p_to or p_effective is null or p_effective>p_to or p_basis is null or p_basis not in ('invoice','payments','hybrid') or p_kind is null or p_kind not in ('correction','ird_change') then raise exception 'Choose a valid GST period, basis, effective date and reason for the change.';end if;
 if p_kind='ird_change' and p_effective<>p_from then raise exception 'Use the first day of the IRD-approved GST period as the effective date.';end if;
 if p_kind='correction' and p_effective<>p_from then raise exception 'A historical correction must start at the beginning of the selected GST period.';end if;
 cfg:=public.v6170e_gst_settings(case when p_kind='ird_change' then p_effective-1 else p_effective end);
 old_basis:=cfg->>'accounting_basis';
 if old_basis not in ('invoice','payments','hybrid') or old_basis is null then raise exception 'The previous GST basis could not be established. Review the historical settings first.';end if;
 if not coalesce((cfg->>'gst_registered')::boolean,false) then raise exception 'This workflow is for a GST-registered NZ business.';end if;
 if exists(select 1 from public.gst_settings_history where business_id=b and jurisdiction<>'NZ') then raise exception 'This workflow supports New Zealand GST only.';end if;
 select exists(select 1 from public.gst_returns g where g.business_id=b and g.status='finalised' and
 case when p_kind='ird_change' then g.period_end>=p_effective else g.period_start<=p_to and g.period_end>=p_from end)
 or exists(select 1 from public.ird_filing_batches f where f.business_id=b and f.filing_type='gst_return' and f.status in ('filed_in_myir','submitted','accepted') and
 case when p_kind='ird_change' then f.period_end>=p_effective else f.period_start<=p_to and f.period_end>=p_from end) into locked;
 if locked then reviews:=reviews||jsonb_build_array(jsonb_build_object('code','filed_period_conflict','message','An affected GST period is already filed or finalised. Use the amendment workflow; it cannot be changed here.'));end if;
 -- Reuse existing authoritative calculation. Outstanding amounts below are a
 -- separate transition worksheet, not another GST return calculation engine.
 normal:=public.frindly_gst_boundary_basis_v1(p_from,p_to,null);
 proposed:=public.frindly_gst_boundary_basis_v1(p_from,p_to,p_basis);
 if p_kind='ird_change' and old_basis<>p_basis then
  for r in select i.id,i.invoice_number reference,i.invoice_date date,i.total,i.gst tax,i.amount_paid,'invoice'::text source_type
   from public.invoices i where i.business_id=b and i.invoice_date<p_effective and coalesce(i.lifecycle_state,'issued')='issued'
   union all select e.id,e.expense_number,e.invoice_date,e.total_amount,e.gst_amount*coalesce(e.business_use_percent,100)/100,e.amount_paid,'expense'
   from public.expenses e where e.business_id=b and e.invoice_date<p_effective and coalesce(e.lifecycle_state,'recorded')='recorded'
   order by date,id
  loop
   if r.source_type='invoice' then
    select coalesce(sum(amount) filter(where payment_date<p_effective and not coalesce(is_legacy_estimate,false)),0) into paid from public.customer_payments where business_id=b and invoice_id=r.id;
    if exists(select 1 from public.customer_payments where business_id=b and invoice_id=r.id and (coalesce(is_legacy_estimate,false) or payment_date is null or amount<0)) then
     reviews:=reviews||jsonb_build_array(jsonb_build_object('code','payment_evidence','source_id',r.id,'message','Customer payment evidence needs review: '||coalesce(r.reference,r.id::text)));end if;
    if exists(select 1 from public.customer_credit_notes where business_id=b and original_invoice_id=r.id and lifecycle_state='issued' and credit_date<p_effective) then
     reviews:=reviews||jsonb_build_array(jsonb_build_object('code','credit_evidence','source_id',r.id,'message','Credits or refunds affect the outstanding balance: '||coalesce(r.reference,r.id::text)));end if;
    select coalesce(jsonb_agg(jsonb_build_object('id',id,'date',payment_date,'amount',amount,'estimated',is_legacy_estimate) order by payment_date,id),'[]') into sources from public.customer_payments where business_id=b and invoice_id=r.id and payment_date<p_effective;
    if coalesce(r.amount_paid,0)>(select coalesce(sum(amount),0) from public.customer_payments where business_id=b and invoice_id=r.id)+0.01 then
     reviews:=reviews||jsonb_build_array(jsonb_build_object('code','missing_payment_evidence','source_id',r.id,'message','Recorded paid amount has no matching payment evidence: '||coalesce(r.reference,r.id::text)));end if;
   else
    select coalesce(sum(amount) filter(where payment_date<p_effective),0) into paid from public.expense_payments where business_id=b and expense_id=r.id;
    if exists(select 1 from public.expense_payments where business_id=b and expense_id=r.id and (payment_date is null or amount<0)) then
     reviews:=reviews||jsonb_build_array(jsonb_build_object('code','payment_evidence','source_id',r.id,'message','Supplier payment evidence needs review: '||coalesce(r.reference,r.id::text)));end if;
    if exists(select 1 from public.supplier_credits where business_id=b and original_expense_id=r.id and lifecycle_state='recorded' and credit_date<p_effective) then
     reviews:=reviews||jsonb_build_array(jsonb_build_object('code','credit_evidence','source_id',r.id,'message','Supplier credits or refunds need review: '||coalesce(r.reference,r.id::text)));end if;
    select coalesce(jsonb_agg(jsonb_build_object('id',id,'date',payment_date,'amount',amount) order by payment_date,id),'[]') into sources from public.expense_payments where business_id=b and expense_id=r.id and payment_date<p_effective;
    if coalesce(r.amount_paid,0)>(select coalesce(sum(amount),0) from public.expense_payments where business_id=b and expense_id=r.id)+0.01 then
     reviews:=reviews||jsonb_build_array(jsonb_build_object('code','missing_payment_evidence','source_id',r.id,'message','Recorded paid amount has no matching payment evidence: '||coalesce(r.reference,r.id::text)));end if;
   end if;
   if r.total is null or r.total<0 or r.tax is null or r.tax<0 or paid>coalesce(r.total,0)+0.01 then
    reviews:=reviews||jsonb_build_array(jsonb_build_object('code','source_amount_review','source_id',r.id,'message','Transaction amounts need review: '||coalesce(r.reference,r.id::text)));continue;end if;
   if r.total=0 then continue;end if;
   outstanding:=greatest(r.total-paid,0);tax:=r.tax*outstanding/r.total;
   if outstanding>0.004 then
    rows:=rows||jsonb_build_array(jsonb_build_object('source_type',r.source_type,'source_id',r.id,'reference',r.reference,'date',r.date,'total',r.total,'paid_before_change',paid,'outstanding',round(outstanding,2),'outstanding_gst',round(tax,2),'payments',sources));
    if r.source_type='invoice' then debtor:=debtor+tax;else creditor:=creditor+tax;end if;
   end if;
  end loop;
  -- IR546 March 2026 p4. Figures remain explicitly provisional until evidence
  -- attribution to filed returns, credits and prior transitions is verified.
  net:=case old_basis||'>'||p_basis when 'invoice>payments' then creditor-debtor when 'payments>invoice' then debtor-creditor
   when 'invoice>hybrid' then creditor when 'hybrid>invoice' then -creditor when 'payments>hybrid' then debtor when 'hybrid>payments' then -debtor else 0 end;
  if jsonb_array_length(rows)>0 then reviews:=reviews||jsonb_build_array(jsonb_build_object('code','prior_filing_evidence','message','Verify which GST was included in previous returns, including returns filed outside Frindly. The worksheet is not an approved adjustment.'));end if;
 end if;
 calculated:=jsonb_build_object('period_start',p_from,'period_end',p_to,'effective_from',p_effective,'previous_basis',old_basis,'requested_basis',p_basis,'change_kind',p_kind,
 'status','pending_verification','can_apply',false,'filed_conflict',locked,'current_calculation',normal,'proposed_calculation',proposed,
 'outstanding_customer_gst',round(debtor,2),'outstanding_supplier_gst',round(creditor,2),'provisional_net_adjustment',round(net,2),'provisional_debit',greatest(round(net,2),0),'provisional_credit',greatest(-round(net,2),0),'transactions',rows,'review_items',reviews);
 return calculated||jsonb_build_object('fingerprint',md5(calculated::text));
end $$;
revoke all on function public.frindly_preview_gst_basis_change_v1(date,date,text,date,text) from public,anon;
grant execute on function public.frindly_preview_gst_basis_change_v1(date,date,text,date,text) to authenticated;

create function public.frindly_request_gst_basis_change_v1(p_id uuid,p_from date,p_to date,p_basis text,p_effective date,p_kind text,p_evidence text,p_fingerprint text,p_confirm_unfiled boolean)
 returns public.gst_basis_change_requests language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); p jsonb; r public.gst_basis_change_requests;
begin
 if auth.uid() is null or b is null or not public.v6147_can_write_area(b,'financials') then raise exception 'Financial write access denied' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(b::text||':gst-basis',0));
 if p_id is null or not coalesce(p_confirm_unfiled,false) or coalesce(length(btrim(p_evidence)),0) not between 1 and 2000 then raise exception 'Confirm the period is unfiled and provide the correction reason or IRD approval reference.';end if;
 select * into r from public.gst_basis_change_requests where id=p_id and business_id=b;
 if found then
  if r.period_start=p_from and r.period_end=p_to and r.requested_basis=p_basis and r.effective_from=p_effective and r.change_kind=p_kind and r.evidence_reference=btrim(p_evidence) and r.preview->>'fingerprint'=p_fingerprint and r.status='pending_verification' then return r;end if;
  raise exception 'This request identifier has already been used. Refresh and review the request.';
 end if;
 p:=public.frindly_preview_gst_basis_change_v1(p_from,p_to,p_basis,p_effective,p_kind);
 if (p->>'filed_conflict')::boolean then raise exception 'An affected period is already filed. Use the amendment workflow.';end if;
 if p->>'fingerprint' is distinct from p_fingerprint then raise exception 'The evidence changed. Refresh the preview before saving.';end if;
 insert into public.gst_basis_change_requests(id,business_id,period_start,period_end,effective_from,previous_basis,requested_basis,change_kind,evidence_reference,preview,created_by)
 values(p_id,b,p_from,p_to,p_effective,p->>'previous_basis',p_basis,p_kind,btrim(p_evidence),p,auth.uid()) returning * into r;
 return r;
end $$;
revoke all on function public.frindly_request_gst_basis_change_v1(uuid,date,date,text,date,text,text,text,boolean) from public,anon;
grant execute on function public.frindly_request_gst_basis_change_v1(uuid,date,date,text,date,text,text,text,boolean) to authenticated;

create function public.frindly_cancel_gst_basis_request_v1(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id();
begin
 if auth.uid() is null or b is null or not public.v6147_can_write_area(b,'financials') then raise exception 'Financial write access denied' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(b::text||':gst-basis',0));
 update public.gst_basis_change_requests set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid() where id=p_id and business_id=b and status='pending_verification';
end $$;
revoke all on function public.frindly_cancel_gst_basis_request_v1(uuid) from public,anon;
grant execute on function public.frindly_cancel_gst_basis_request_v1(uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.frindly_gst_boundary_basis_v1(p_from date, p_to date, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id();result jsonb;saved public.gst_returns;issues jsonb;items jsonb;ex numeric;gst numeric;
begin
 if auth.uid() is null or b is null or not public.v6147_can_read_area(b,'financials') then raise exception 'Financial access denied' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid GST period';end if;
 select * into saved from public.gst_returns where business_id=b and period_start=p_from and period_end=p_to and status='finalised';
 if found then
  if saved.snapshot is null or saved.snapshot='{}'::jsonb then raise exception 'The filed GST snapshot is missing. Review the original filing; it cannot be recalculated silently.';end if;
  return saved.snapshot||jsonb_build_object('locked_snapshot',true);
 end if;
 result:=frindly_cash.gst_base(p_from,p_to,p_basis);
 select coalesce(sum(c.amount-c.gst_amount),0),coalesce(sum(c.gst_amount),0),coalesce(jsonb_agg(jsonb_build_object('source_type','cash_transaction','source_id',c.id,'date',l.transaction_date,'reference',coalesce(c.reference,c.description),'party',c.party,'ex_gst',c.amount-c.gst_amount,'gst',c.gst_amount,'total',c.amount,'classification',case when c.gst_treatment='ZERO' then 'zero_rated' else 'standard' end)),'[]'::jsonb) into ex,gst,items
 from public.cash_transactions c join public.cash_transaction_legs l on l.transaction_id=c.id and l.business_id=c.business_id
 where c.business_id=b and c.status='recorded' and c.purpose='grant' and c.gst_treatment in ('GST','ZERO') and l.transaction_date between p_from and p_to;
 result:=result||jsonb_build_object('sales_ex_gst',coalesce((result->>'sales_ex_gst')::numeric,0)+ex,'gst_collected',coalesce((result->>'gst_collected')::numeric,0)+gst,'gst_net',coalesce((result->>'gst_net')::numeric,0)+gst,'sales_items',coalesce(result->'sales_items','[]'::jsonb)||items);
 issues:=frindly_cash.gst_basis_review(p_from,p_to);
 return result||jsonb_build_object('review_items',coalesce(result->'review_items','[]'::jsonb)||issues);
end $function$
;
CREATE OR REPLACE FUNCTION public.frindly_save_gst_basis_v1(p_from date, p_to date, p_status text DEFAULT 'draft'::text, p_basis text DEFAULT NULL::text)
 RETURNS gst_returns
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare bid uuid:=current_business_id(); calc jsonb; r gst_returns; blockers int; cfg jsonb; v_existing boolean:=false; v_conflict gst_returns;
begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'GST return access denied' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(bid::text||':gst-basis',0));
 if exists(select 1 from public.ird_filing_batches where business_id=bid and filing_type='gst_return' and status in ('filed_in_myir','submitted','accepted') and period_start<=p_to and period_end>=p_from) then raise exception 'This period is already recorded as filed externally. Use the amendment workflow.';end if;
 if p_status not in('draft','reviewed','finalised') then raise exception 'Invalid GST return status';end if;
 select * into r from gst_returns where business_id=bid and period_start=p_from and period_end=p_to for update; v_existing:=found;
 if v_existing and r.status='finalised' then raise exception 'This GST return is finalised and locked';end if;
 if p_status='finalised' then
  select * into v_conflict from gst_returns x where x.business_id=bid and x.status='finalised' and daterange(x.period_start,x.period_end,'[]') && daterange(p_from,p_to,'[]') and (not v_existing or x.id<>r.id) order by x.period_start limit 1 for update;
  if found then raise exception 'GST period conflict: existing finalised return % to % overlaps this period',v_conflict.period_start,v_conflict.period_end using errcode='23514';end if;
 end if;
 calc:=public.frindly_gst_boundary_basis_v1(p_from,p_to,p_basis);
 if p_status='finalised' and nullif(p_basis,'') is not null and p_basis<>(case (public.v6170e_gst_settings(p_to)->>'accounting_basis') when 'non_cash' then 'invoice' when 'cash' then 'payments' else (public.v6170e_gst_settings(p_to)->>'accounting_basis') end) then raise exception 'Selected GST basis differs from business settings. Confirm the authorised basis change in Settings before finalising.'; end if; cfg:=calc->'settings'; select count(*) into blockers from jsonb_array_elements(calc->'review_items') x where x->>'severity'='blocking';
 if p_status='finalised' and blockers>0 then raise exception 'GST return has blocking review items and cannot be finalised';end if;
 if v_existing then
  update gst_returns set status=p_status,gst_rate=15,taxable_sales_ex_gst=(calc->>'sales_ex_gst')::numeric,gst_collected=(calc->>'gst_collected')::numeric,taxable_purchases_ex_gst=(calc->>'purchases_ex_gst')::numeric,gst_paid=(calc->>'gst_paid')::numeric,debit_adjustments=(calc->>'debit_adjustments')::numeric,credit_adjustments=(calc->>'credit_adjustments')::numeric,gst_net=(calc->>'gst_net')::numeric,snapshot=calc,accounting_basis=calc->>'basis',filing_frequency=cfg->>'filing_frequency',statutory_rule_snapshot=jsonb_build_object('country','NZ','standard_rate_percent',15),registration_snapshot=cfg,review_items=calc->'review_items',calculation_version='frindly-gst-boundary-v1',finalised_at=case when p_status='finalised' then now() else null end,finalised_by=case when p_status='finalised' then auth.uid() else null end,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 else
  insert into gst_returns(business_id,period_start,period_end,status,gst_rate,taxable_sales_ex_gst,gst_collected,taxable_purchases_ex_gst,gst_paid,debit_adjustments,credit_adjustments,gst_net,snapshot,accounting_basis,filing_frequency,statutory_rule_snapshot,registration_snapshot,review_items,calculation_version,finalised_at,finalised_by,created_by,updated_by)
  values(bid,p_from,p_to,p_status,15,(calc->>'sales_ex_gst')::numeric,(calc->>'gst_collected')::numeric,(calc->>'purchases_ex_gst')::numeric,(calc->>'gst_paid')::numeric,(calc->>'debit_adjustments')::numeric,(calc->>'credit_adjustments')::numeric,(calc->>'gst_net')::numeric,calc,calc->>'basis',cfg->>'filing_frequency',jsonb_build_object('country','NZ','standard_rate_percent',15),cfg,calc->'review_items','frindly-gst-boundary-v1',case when p_status='finalised' then now() end,case when p_status='finalised' then auth.uid() end,auth.uid(),auth.uid()) returning * into r;
 end if;
 if p_status='finalised' then update gst_adjustments set included_return_id=r.id,updated_at=now(),updated_by=auth.uid() where business_id=bid and status='active' and adjustment_date between p_from and p_to and included_return_id is null;end if;
 return r;
end$function$
;

-- Cover alternate/legacy save callers and direct table finalisation as well.
create function frindly_cash.guard_gst_basis_finalisation() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='finalised' and (tg_op='INSERT' or old.status is distinct from 'finalised') then
  if new.business_id is distinct from public.current_business_id() then raise exception 'GST business access denied' using errcode='42501';end if;
  perform pg_advisory_xact_lock(hashtextextended(new.business_id::text||':gst-basis',0));
  if jsonb_array_length(frindly_cash.gst_basis_review(new.period_start,new.period_end))>0 then
   raise exception 'GST accounting-basis reconciliation is pending verification. Save a draft instead.';
  end if;
 end if;
 return new;
end $$;
revoke all on function frindly_cash.guard_gst_basis_finalisation() from public,anon,authenticated;
create trigger frindly_guard_gst_basis_finalisation before insert or update of status on public.gst_returns
 for each row execute function frindly_cash.guard_gst_basis_finalisation();
