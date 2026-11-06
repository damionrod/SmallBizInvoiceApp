-- Reference only. Do not execute without the guarded recovery procedure in docs/GST_BASIS_CHANGE_ACTIVATION.md.

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
end $function$;

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
end$function$;

CREATE OR REPLACE FUNCTION public.frindly_preview_gst_basis_change_v1(p_from date, p_to date, p_basis text, p_effective date, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION frindly_cash.gst_basis_review(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION frindly_cash.guard_gst_basis_finalisation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.status='finalised' and (tg_op='INSERT' or old.status is distinct from 'finalised') then
  if new.business_id is distinct from public.current_business_id() then raise exception 'GST business access denied' using errcode='42501';end if;
  perform pg_advisory_xact_lock(hashtextextended(new.business_id::text||':gst-basis',0));
  if jsonb_array_length(frindly_cash.gst_basis_review(new.period_start,new.period_end))>0 then
   raise exception 'GST accounting-basis reconciliation is pending verification. Save a draft instead.';
  end if;
 end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION frindly_settlement.record_payment(p_request_id uuid, p_date date, p_bank_id uuid, p_reference text, p_allocations jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id(); uid uuid:=auth.uid(); item record; o record; ba public.bank_accounts%rowtype;
 payment_id uuid:=gen_random_uuid(); journal_id uuid; existing public.liability_payments%rowtype;
 total_amount numeric:=0; lines jsonb:='[]'; dir text; gst public.gst_returns%rowtype; ledger_net numeric; acct_count int; rounding_amount numeric:=0; rounding_account uuid;
begin
 if uid is null or b is null then raise exception 'Authentication and active business required'; end if;
 -- Serialize settlements AND reconciliation for this tenant. Balance checks happen after the lock.
 perform pg_advisory_xact_lock(hashtextextended('frindly-settlement:'||b::text,0));
 if p_request_id is null or p_date is null or p_bank_id is null then raise exception 'Payment ID, date and bank required'; end if;
 if jsonb_typeof(p_allocations)<>'array' or jsonb_array_length(p_allocations)=0 then raise exception 'Choose settlement allocations'; end if;
 for item in select * from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric) loop
  if item.kind not in ('gst','wages','ird') then raise exception 'Invalid settlement kind'; end if;
  perform frindly_settlement.assert_access(case when item.kind='gst' then 'financials' else 'payroll' end,true);
  if item.amount is null or item.amount<=0 or item.amount<>round(item.amount,2) then raise exception 'Payment amount must be positive with at most two decimals'; end if;
  total_amount:=total_amount+item.amount;
 end loop;
 if exists(select 1 from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric) group by kind,source_id,account_id having count(*)>1) then raise exception 'Duplicate allocation'; end if;
 -- An explicitly confirmed one-cent GST refund excess is separate from the return allocation.
 if exists(
   select 1 from jsonb_array_elements(p_allocations) a where a ? 'gst_refund_rounding'
 ) then
  if jsonb_array_length(p_allocations)<>1 or p_allocations->0->>'kind' is distinct from 'gst'
    or p_allocations->0->'gst_refund_rounding' is distinct from '0.01'::jsonb then
   raise exception 'Only a confirmed one-cent GST refund rounding adjustment is supported';
  end if;
  rounding_amount:=0.01;
  total_amount:=total_amount+rounding_amount;
 end if;
 select * into existing from public.liability_payments where business_id=b and request_id=p_request_id;
 if found then
  if existing.payment_date<>p_date or existing.bank_account_id<>p_bank_id or existing.amount<>total_amount or coalesce(existing.reference,'')<>coalesce(nullif(btrim(p_reference),''),'') then raise exception 'Request ID already used for a different payment'; end if;
  if (select jsonb_agg(jsonb_build_object('kind',a.kind,'source_id',coalesce(a.gst_return_id,a.pay_run_id),'account_id',a.account_id,'amount',a.amount) order by a.kind,coalesce(a.gst_return_id,a.pay_run_id),a.account_id) from public.liability_payment_allocations a where a.business_id=b and a.payment_id=existing.id)
   is distinct from (select jsonb_agg(jsonb_build_object('kind',x.kind,'source_id',x.source_id,'account_id',x.account_id,'amount',x.amount) order by x.kind,x.source_id,x.account_id) from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric)) then raise exception 'Request allocations changed'; end if;
  return existing.id;
 end if;
 if exists(select 1 from public.accounting_periods where business_id=b and status<>'open' and p_date between period_start and period_end) then raise exception 'Payment accounting period is locked'; end if;
 select * into ba from public.bank_accounts where business_id=b and id=p_bank_id and not archived;
 if ba.id is null or ba.accounting_account_id is null or not exists(select 1 from public.accounting_accounts where business_id=b and id=ba.accounting_account_id and not archived and account_type='asset' and account_subtype='bank') then raise exception 'Select a bank linked to an active bank ledger account'; end if;
 for item in select * from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric) loop
  select * into o from frindly_settlement.obligations(b) where kind=item.kind and source_id=item.source_id and account_id=item.account_id;
  if not found or o.notice is not null or item.amount>o.outstanding then raise exception 'Allocation exceeds outstanding liability or source needs review'; end if;
  if rounding_amount>0 and (o.direction is distinct from 'refund' or item.amount<>o.outstanding) then
   raise exception 'GST refund rounding requires settling the full outstanding refund';
  end if;
  if not exists(select 1 from public.accounting_accounts where business_id=b and id=item.account_id and not archived) then raise exception 'The original liability account is archived; review its mapping before settlement'; end if;
  if dir is not null and dir<>o.direction then raise exception 'Payments and refunds must be recorded separately'; end if; dir:=o.direction;
  if item.kind='gst' then
   select * into gst from public.gst_returns where business_id=b and id=item.source_id;
   if gst.status<>'finalised' then raise exception 'Only finalised GST returns can be settled'; end if;
   -- Reconcile the saved return to source GST ledger movements; never create another accrual.
   select round(coalesce(sum(l.credit-l.debit),0),2) into ledger_net
   from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
   join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id
   where j.business_id=b and j.status in ('posted','reversed') and j.journal_date between gst.period_start and gst.period_end
   and j.source_type<>'liability_settlement'
   and (a.system_key in ('gst_payable','gst_receivable') or a.system_account_key in ('gst_payable','gst_receivable'));
   if abs(ledger_net-gst.gst_net)>0.01 then raise exception 'Saved GST return differs from posted GST ledger. Reconcile source postings and calculation basis before settlement'; end if;
   if exists(select 1 from public.gst_returns g where g.business_id=b and g.id<>gst.id and g.status='finalised' and g.period_start<=gst.period_end and g.period_end>=gst.period_start) then raise exception 'Overlapping finalised GST returns require review'; end if;
  elsif exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='payroll_ird_payment' and j.status='posted' and not exists(select 1 from public.bank_reconciliation_allocations a where a.business_id=b and a.accounting_journal_id=j.id and a.pay_run_id is not null)) and item.kind='ird' then
   raise exception 'Existing unallocated IRD settlements need allocation review before recording another payment';
  end if;
  -- Global liability balance is an additional guard against unallocated historical settlements.
  select coalesce(sum(l.credit-l.debit),0) into ledger_net from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=item.account_id and j.status in ('posted','reversed') and j.journal_date<=p_date;
  if (dir='payment' and ledger_net<item.amount) or (dir='refund' and -ledger_net<item.amount) then raise exception 'Payment exceeds the posted liability available on this date'; end if;
  lines:=lines||jsonb_build_array(jsonb_build_object('account_id',item.account_id,'description',o.label||' settlement','debit',case when dir='payment' then item.amount else 0 end,'credit',case when dir='refund' then item.amount else 0 end,'tax_code','NO_GST','tax_amount',0));
 end loop;
 -- Ensure allocations sharing an account cannot jointly exceed its balance.
 for item in select account_id,sum(amount) amount from jsonb_to_recordset(p_allocations) as x(account_id uuid,amount numeric) group by account_id loop
  select coalesce(sum(l.credit-l.debit),0) into ledger_net from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=item.account_id and j.status in ('posted','reversed') and j.journal_date<=p_date;
  if (dir='payment' and ledger_net<item.amount) or (dir='refund' and -ledger_net<item.amount) then raise exception 'Combined allocations exceed posted liability'; end if;
 end loop;
 if rounding_amount>0 then
  rounding_account:=frindly_cash.account(b,'gst_refund_rounding','GST Refund Rounding','other_income');
  lines:=lines||jsonb_build_array(jsonb_build_object('account_id',rounding_account,'description','Confirmed IRD GST refund rounding','debit',0,'credit',rounding_amount,'tax_code','NO_GST','tax_amount',0));
 end if;
 lines:=lines||jsonb_build_array(jsonb_build_object('account_id',ba.accounting_account_id,'description','GST / payroll settlement','debit',case when dir='refund' then total_amount else 0 end,'credit',case when dir='payment' then total_amount else 0 end,'tax_code','NO_GST','tax_amount',0));
 journal_id:=public.v6192_create_posted_journal(b,p_date,'bank','liability_settlement',payment_id,nullif(btrim(p_reference),''),'GST / payroll settlement',lines);
 insert into public.liability_payments(id,business_id,request_id,payment_date,bank_account_id,amount,direction,reference,accounting_journal_id,created_by) values(payment_id,b,p_request_id,p_date,p_bank_id,total_amount,dir,nullif(btrim(p_reference),''),journal_id,uid);
 insert into public.liability_payment_allocations(business_id,payment_id,kind,gst_return_id,pay_run_id,account_id,amount)
 select b,payment_id,x.kind,case when x.kind='gst' then x.source_id end,case when x.kind<>'gst' then x.source_id end,x.account_id,x.amount from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric);
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'liability_payment',payment_id,'record_payment',jsonb_build_object('allocations',p_allocations,'journal_id',journal_id,'date',p_date,'bank_id',p_bank_id),uid);
 return payment_id;
end $function$;

CREATE OR REPLACE FUNCTION frindly_settlement.obligations(p_bid uuid)
 RETURNS TABLE(kind text, source_id uuid, account_id uuid, label text, source_date date, total numeric, paid numeric, outstanding numeric, direction text, notice text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with payroll as (
 select r.id,r.pay_run_number,r.pay_date,r.net_pay,j.id journal_id,a.id account_id,
 case when coalesce(a.system_account_key,a.system_key)='payroll_net_payable' then 'wages' else 'ird' end kind,
 sum(l.credit-l.debit) total
 from public.payroll_pay_runs r
 join public.accounting_journals j on j.business_id=r.business_id and j.source_id=r.id and j.source_type='payroll' and j.status='posted'
 join public.accounting_journal_lines l on l.business_id=j.business_id and l.journal_id=j.id
 join public.accounting_accounts a on a.business_id=l.business_id and a.id=l.account_id
 where r.business_id=p_bid and r.status='finalised' and a.account_type in ('liability','current_liability','non_current_liability')
 and (a.system_key in ('payroll_net_payable','payroll_liability') or a.system_account_key in ('payroll_net_payable','payroll_liability'))
 group by r.id,j.id,a.id
 ), prior as (
 select x.kind,x.pay_run_id,x.gst_return_id,x.account_id,sum(x.amount) amount
 from public.liability_payment_allocations x join public.liability_payments p on p.business_id=x.business_id and p.id=x.payment_id
 join public.accounting_journals j on j.id=p.accounting_journal_id and j.business_id=p.business_id and j.status='posted'
 where x.business_id=p_bid group by 1,2,3,4
 ), bank_prior as (
 select a.pay_run_id,sum(a.amount) amount from public.bank_reconciliation_allocations a
 join public.accounting_journals j on j.id=a.accounting_journal_id and j.business_id=a.business_id and j.status='posted'
 where a.business_id=p_bid and a.allocation_type='payroll_pay_run' and a.liability_payment_id is null group by 1
 ), gst as (
 select g.*,case when g.gst_net<0 then 'gst_receivable' else 'gst_payable' end account_key
 from public.gst_returns g where g.business_id=p_bid
 )
 select p.kind,p.id,p.account_id,p.pay_run_number,p.pay_date,p.total,
 coalesce(pr.amount,0)+case when p.kind='wages' then coalesce(bp.amount,0) else 0 end,
 greatest(0,p.total-coalesce(pr.amount,0)-case when p.kind='wages' then coalesce(bp.amount,0) else 0 end),
 'payment',null::text
 from payroll p left join prior pr on pr.kind=p.kind and pr.pay_run_id=p.id and pr.account_id=p.account_id
 left join bank_prior bp on bp.pay_run_id=p.id
 union all
 select 'wages',r.id,null::uuid,r.pay_run_number,r.pay_date,r.net_pay,r.net_pay,0,'payment',
 'Legacy payroll already credited bank; no further wages posting is permitted. Bank matches remain separate evidence.'
 from public.payroll_pay_runs r where r.business_id=p_bid and r.status='finalised'
 and not exists(select 1 from payroll p where p.id=r.id and p.kind='wages')
 and exists(select 1 from public.accounting_journals j join public.accounting_journal_lines l on l.business_id=j.business_id and l.journal_id=j.id
 join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id
 where j.business_id=p_bid and j.source_id=r.id and j.source_type='payroll' and j.status='posted'
 and (a.account_subtype='bank' or a.system_key in ('bank','bank_main'))
 group by j.id having sum(l.credit-l.debit)=r.net_pay)
 union all
 select 'gst',g.id,a.id,g.period_start::text||' to '||g.period_end::text,g.period_end,abs(g.gst_net),coalesce(pr.amount,0),
 greatest(0,abs(g.gst_net)-coalesce(pr.amount,0)),case when g.gst_net<0 then 'refund' else 'payment' end,
 case when g.status<>'finalised' then 'Finalise this saved return before settlement.' end
 from gst g left join public.accounting_accounts a on a.business_id=p_bid and not a.archived and (a.system_key=g.account_key or a.system_account_key=g.account_key)
 left join prior pr on pr.kind='gst' and pr.gst_return_id=g.id and pr.account_id=a.id
 $function$;

CREATE OR REPLACE FUNCTION public.v6170e_gst_settings(p_on date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare bid uuid:=current_business_id(); h record; f record;begin if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501'; end if; select * into h from gst_settings_history where business_id=bid and effective_from<=p_on order by effective_from desc limit 1; if found then return jsonb_build_object('effective_from',h.effective_from,'gst_registered',h.gst_registered,'gst_number',h.gst_number,'accounting_basis',h.accounting_basis,'filing_frequency',h.filing_frequency,'balance_date_month',h.balance_date_month,'balance_date_day',h.balance_date_day); end if; select * into f from financial_settings where business_id=bid limit 1; return jsonb_build_object('effective_from',null,'gst_registered',coalesce(f.gst_registered,true),'gst_number',f.gst_number,'accounting_basis',coalesce(f.gst_accounting_basis,'invoice'),'filing_frequency',coalesce(f.gst_filing_frequency,'two_monthly'),'balance_date_month',coalesce(f.balance_date_month,3),'balance_date_day',coalesce(f.balance_date_day,31)); end$function$;
