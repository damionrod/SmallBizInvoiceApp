-- NZ GST basis activation: evidence-first, atomic and source-linked.
-- No business data is changed by this migration.
alter table public.gst_basis_change_requests drop constraint gst_basis_change_requests_status_check;
alter table public.gst_basis_change_requests add constraint gst_basis_change_requests_status_check check(status in ('pending_verification','applied','cancelled'));
alter table public.gst_basis_change_requests add column previous_settings jsonb, add column applied_evidence jsonb, add column applied_at timestamptz, add column applied_by uuid references auth.users(id), add column adjustment_id uuid references public.gst_adjustments(id), add column verification_history jsonb not null default '[]';
create unique index gst_basis_applied_boundary_once on public.gst_basis_change_requests(business_id,effective_from) where status='applied';
create unique index gst_basis_adjustment_once on public.gst_adjustments(business_id,source_id) where source_type='gst_basis_transition' and status='active';

create function frindly_cash.gst_transition_evidence(d date,old_basis text,new_basis text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); r record; x record; rows jsonb:='[]'; issues jsonb:='[]'; items jsonb;
 paid numeric; all_paid numeric; credited numeric; credit_tax numeric; refunded numeric; net_tax numeric; cash_tax numeric; expected numeric; reported numeric; outstanding numeric; delta numeric; net numeric:=0; debtor numeric:=0; creditor numeric:=0; prior_delta numeric; side_changed boolean; rate numeric;reported_map jsonb;delta_map jsonb;
begin
 if auth.uid() is null or b is null or not coalesce(public.v6147_can_read_area(b,'financials'),false) then raise exception 'Financial access denied' using errcode='42501';end if;
 if d is null or old_basis not in ('invoice','payments','hybrid') or new_basis not in ('invoice','payments','hybrid') then raise exception 'Invalid transition';end if;
 if exists(select 1 from public.gst_returns g where g.business_id=b and g.status='finalised' and g.period_end<d and (
  coalesce(g.accounting_basis,g.snapshot->>'basis') not in ('invoice','payments','hybrid') or coalesce(g.accounting_basis,g.snapshot->>'basis') is null
  or abs(round(coalesce((select sum((it->>'gst')::numeric) from jsonb_array_elements(coalesce(g.snapshot->'sales_items','[]')) it),0),2)-coalesce(g.gst_collected,0))>0.011
  or abs(round(coalesce((select sum((it->>'gst')::numeric) from jsonb_array_elements(coalesce(g.snapshot->'purchase_items','[]')) it),0),2)-coalesce(g.gst_paid,0))>0.011
  or abs(coalesce(g.gst_net,0)-(coalesce(g.gst_collected,0)+coalesce(g.debit_adjustments,0)-coalesce(g.gst_paid,0)-coalesce(g.credit_adjustments,0)))>0.011
  or abs(coalesce((g.snapshot->>'gst_net')::numeric,g.gst_net)-coalesce(g.gst_net,0))>0.011
 )) then issues:=issues||jsonb_build_array(jsonb_build_object('code','prior_snapshot_reconciliation','message','A prior filed GST basis, itemised tax or total does not reconcile with its saved snapshot. Review the original filing evidence before applying this change.'));end if;
 -- Attribute immutable filed evidence once, rather than rescanning all snapshots
 -- separately for every historical invoice and bill.
 with items as (
  select 'invoice'::text side,it from public.gst_returns g cross join lateral jsonb_array_elements(coalesce(g.snapshot->'sales_items','[]')) it where g.business_id=b and g.status='finalised' and g.period_end<d
  union all select 'expense',it from public.gst_returns g cross join lateral jsonb_array_elements(coalesce(g.snapshot->'purchase_items','[]')) it where g.business_id=b and g.status='finalised' and g.period_end<d
 ), refs as (
  select side,case it->>'source_type' when 'invoice' then it->>'source_id' when 'expense' then it->>'source_id' when 'customer_payment' then cp.invoice_id::text when 'expense_payment' then ep.expense_id::text when 'customer_credit_note' then cn.original_invoice_id::text when 'supplier_credit' then sc.original_expense_id::text end source_id,(it->>'gst')::numeric tax
  from items left join public.customer_payments cp on cp.business_id=b and it->>'source_type'='customer_payment' and cp.id::text=it->>'source_id'
  left join public.expense_payments ep on ep.business_id=b and it->>'source_type'='expense_payment' and ep.id::text=it->>'source_id'
  left join public.customer_credit_notes cn on cn.business_id=b and it->>'source_type'='customer_credit_note' and cn.id::text=it->>'source_id'
  left join public.supplier_credits sc on sc.business_id=b and it->>'source_type'='supplier_credit' and sc.id::text=it->>'source_id'
 ) select coalesce(jsonb_object_agg(side||':'||source_id,tax),'{}') into reported_map from (select side,source_id,sum(tax) tax from refs where source_id is not null group by side,source_id) z;
 select coalesce(jsonb_object_agg(k,tax),'{}') into delta_map from (select (it->>'source_type')||':'||(it->>'source_id') k,sum((it->>'tax_delta')::numeric) tax from public.gst_basis_change_requests q cross join lateral jsonb_array_elements(coalesce(q.applied_evidence->'transactions','[]')) it where q.business_id=b and q.status='applied' and q.change_kind='ird_change' and q.effective_from<d and (q.adjustment_id is null or exists(select 1 from public.gst_adjustments a join public.gst_returns g on g.id=a.included_return_id and g.business_id=a.business_id where a.business_id=b and a.id=q.adjustment_id and a.status='active' and g.status='finalised' and g.period_end<d)) group by 1) z;
 if exists(select 1 from public.customer_payments p join public.invoices i on i.id=p.invoice_id and i.business_id=p.business_id where p.business_id=b and p.payment_date<d and i.invoice_date>=d and coalesce(i.gst,0)>0)
 or exists(select 1 from public.expense_payments p join public.expenses e on e.id=p.expense_id and e.business_id=p.business_id where p.business_id=b and p.payment_date<d and e.invoice_date>=d and coalesce(e.gst_amount,0)>0) then
 issues:=issues||jsonb_build_array(jsonb_build_object('code','advance_payment','message','Payments before the invoice date cross this change. Review the time-of-supply treatment before applying it.'));end if;
 if exists(select 1 from public.gst_adjustments a where a.business_id=b and a.status='active' and a.adjustment_date<d and a.gst_amount>0 and a.source_id is null and a.included_return_id is not null) then
 issues:=issues||jsonb_build_array(jsonb_build_object('code','unattributed_prior_adjustment','message','A previous filed GST adjustment has no transaction allocation. Its effect on this transition needs review.'));end if;
 if exists(select 1 from public.invoices where business_id=b and coalesce(lifecycle_state,'issued')='issued' and invoice_date is null) or exists(select 1 from public.expenses where business_id=b and coalesce(lifecycle_state,'recorded')='recorded' and invoice_date is null) then
 issues:=issues||jsonb_build_array(jsonb_build_object('code','missing_source_date','message','Recorded transactions are missing invoice dates. Review them before changing basis.'));end if;
 if exists(select 1 from public.customer_credit_notes where business_id=b and lifecycle_state='issued' and credit_date is null) or exists(select 1 from public.supplier_credits where business_id=b and lifecycle_state='recorded' and credit_date is null) then issues:=issues||jsonb_build_array(jsonb_build_object('code','missing_credit_date','message','A recorded credit is missing its tax date. Review it before applying this change.'));end if;
 if exists(select 1 from public.customer_refunds where business_id=b and lifecycle_state='recorded' and refund_date<d and customer_id is null) then issues:=issues||jsonb_build_array(jsonb_build_object('code','refund_allocation','message','A customer refund has no customer/source allocation. Review it before applying this change.'));end if;
 if exists(select 1 from public.invoices i where i.business_id=b and i.invoice_date<d and coalesce(i.lifecycle_state,'issued')='issued' and coalesce(to_jsonb(i)->>'currency',i.company_snapshot->>'currency') is not null and upper(btrim(coalesce(to_jsonb(i)->>'currency',i.company_snapshot->>'currency')))<>'NZD') or exists(select 1 from public.expenses where business_id=b and invoice_date<d and coalesce(lifecycle_state,'recorded')='recorded' and currency is not null and upper(btrim(currency))<>'NZD') then issues:=issues||jsonb_build_array(jsonb_build_object('code','currency_review','message','Foreign-currency source amounts need verified NZD GST conversion before automatic transition reconciliation.'));end if;
 for r in
 select i.id,'invoice'::text source_type,i.invoice_number reference,i.invoice_date date,i.total,i.gst tax,i.amount_paid,i.customer_id party_id,i.lifecycle_state,i.voided_at,1::numeric business_fraction from public.invoices i where i.business_id=b and i.invoice_date<d and coalesce(i.lifecycle_state,'issued')<>'draft'
 union all select e.id,'expense',e.expense_number,e.invoice_date,e.total_amount,e.gst_amount*coalesce(e.business_use_percent,100)/100,e.amount_paid,e.supplier_id,e.lifecycle_state,e.voided_at,coalesce(e.business_use_percent,100)/100 from public.expenses e where e.business_id=b and e.invoice_date<d and coalesce(e.lifecycle_state,'recorded')<>'draft'
 order by date,id
 loop
 side_changed:=case r.source_type when 'invoice' then (old_basis='payments')<>(new_basis='payments') else (old_basis='invoice')<>(new_basis='invoice') end;
 if not side_changed then continue;end if;
 if r.lifecycle_state='voided' then
  -- A void is not assumed to be a tax reversal or to erase previously filed evidence.
  if coalesce(r.tax,0)>0 then issues:=issues||jsonb_build_array(jsonb_build_object('code','void_timing','source_id',r.id,'message','Review the void/reversal timing for '||coalesce(r.reference,r.id::text)));end if;
  continue;
 end if;
 if r.total is null or r.total<0 or r.tax is null or r.tax<0 or r.tax>r.total or r.business_fraction not between 0 and 1 then
 issues:=issues||jsonb_build_array(jsonb_build_object('code','source_tax','source_id',r.id,'message','Missing or invalid tax evidence for '||coalesce(r.reference,r.id::text)));continue;end if;
 if r.total=0 then continue;end if;
 if not exists(select 1 from public.gst_returns g where g.business_id=b and g.status='finalised' and r.date between g.period_start and g.period_end) then issues:=issues||jsonb_build_array(jsonb_build_object('code','prior_period_missing','source_id',r.id,'message','The original GST period has no filed snapshot for '||coalesce(r.reference,r.id::text)||'. Record the earlier filing evidence before applying this change.'));end if;
 if (not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_id=r.id and j.source_type=r.source_type and j.status='posted' and j.journal_date<d) or abs(r.tax-coalesce((select sum(case when r.source_type='invoice' then l.credit-l.debit else l.debit-l.credit end) from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id where j.business_id=b and j.source_id=r.id and j.source_type=r.source_type and j.status='posted' and j.journal_date<d and (a.system_key in ('gst_payable','gst_receivable') or a.system_account_key in ('gst_payable','gst_receivable'))),0))>0.011) then
 issues:=issues||jsonb_build_array(jsonb_build_object('code','source_posting','source_id',r.id,'message','The source GST does not reconcile with its posted journal: '||coalesce(r.reference,r.id::text)));end if;
 rate:=r.tax/r.total;
 if r.total>225000 and r.tax>0 then issues:=issues||jsonb_build_array(jsonb_build_object('code','special_supply','source_id',r.id,'message','A supply over $225,000 needs its special GST time-of-supply treatment reviewed.'));end if;
 credited:=0;credit_tax:=0;refunded:=0;reported:=0;prior_delta:=0;
 if r.source_type='invoice' then
  select coalesce(sum(p.amount) filter(where p.payment_date<d and not coalesce(p.is_legacy_estimate,false)),0),coalesce(sum(p.amount) filter(where not coalesce(p.is_legacy_estimate,false)),0),coalesce(jsonb_agg(jsonb_build_object('id',p.id,'date',p.payment_date,'amount',p.amount,'estimated',p.is_legacy_estimate) order by p.payment_date,p.id) filter(where p.payment_date<d),'[]') into paid,all_paid,items from public.customer_payments p where p.business_id=b and p.invoice_id=r.id;
  if exists(select 1 from public.customer_payments p where p.business_id=b and p.invoice_id=r.id and (p.payment_date is null or p.amount is null or p.amount<0 or (p.payment_date<d and coalesce(p.is_legacy_estimate,false)))) then issues:=issues||jsonb_build_array(jsonb_build_object('code','payment_evidence','source_id',r.id,'message','Review missing, negative or estimated customer payment evidence for '||coalesce(r.reference,r.id::text)));end if;
  if exists(select 1 from public.customer_payments p where p.business_id=b and p.invoice_id=r.id and p.payment_date<d and not coalesce(p.is_legacy_estimate,false) and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_payment' and (j.source_id=p.id or j.source_id=p.invoice_payment_transaction_id) and j.status='posted' and j.journal_date<d)) then issues:=issues||jsonb_build_array(jsonb_build_object('code','payment_posting','source_id',r.id,'message','A customer payment is not backed by its posted receipt. Review the existing payment workflow.'));end if;
  select coalesce(sum(c.total_amount),0),coalesce(sum(c.gst_amount),0) into credited,credit_tax from public.customer_credit_notes c where c.business_id=b and c.original_invoice_id=r.id and c.lifecycle_state='issued' and c.credit_date<d;
  if exists(select 1 from public.customer_credit_notes c where c.business_id=b and c.original_invoice_id=r.id and c.lifecycle_state='issued' and c.credit_date<d and (c.gst_amount is null or c.total_amount is null or c.gst_amount<0 or c.total_amount<0 or abs(c.gst_amount-rate*c.total_amount)>0.011)) then issues:=issues||jsonb_build_array(jsonb_build_object('code','mixed_credit','source_id',r.id,'message','The credit uses a different GST mix. Verify payment allocation for '||coalesce(r.reference,r.id::text)));end if;
  if exists(select 1 from public.customer_credit_notes c where c.business_id=b and c.original_invoice_id=r.id and c.lifecycle_state='issued' and c.credit_date<d and (not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_credit_note' and j.source_id=c.id and j.status='posted' and j.journal_date<d) or abs(c.gst_amount-coalesce((select sum(l.debit-l.credit) from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id where j.business_id=b and j.source_type='customer_credit_note' and j.source_id=c.id and j.status='posted' and j.journal_date<d and (a.system_key='gst_payable' or a.system_account_key='gst_payable')),0))>0.011)) then issues:=issues||jsonb_build_array(jsonb_build_object('code','credit_posting','source_id',r.id,'message','The customer credit does not reconcile with its posted GST journal.'));end if;
  if exists(select 1 from public.customer_refunds f where f.business_id=b and f.customer_id=r.party_id and f.lifecycle_state='recorded' and f.refund_date<d and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_refund' and j.source_id=f.id and j.status='posted' and j.journal_date<d)) then issues:=issues||jsonb_build_array(jsonb_build_object('code','refund_posting','source_id',r.id,'message','The customer refund is not backed by its posted refund.'));end if;
  select coalesce(sum(f.amount),0) into refunded from public.customer_refunds f where f.business_id=b and f.customer_id=r.party_id and f.lifecycle_state='recorded' and f.refund_date<d;
  if refunded>0 and (select count(*) from public.invoices i where i.business_id=b and i.customer_id=r.party_id and i.invoice_date<d and coalesce(i.lifecycle_state,'issued')='issued')<>1 then issues:=issues||jsonb_build_array(jsonb_build_object('code','refund_allocation','source_id',r.id,'message','Customer refunds span more than one invoice. The source allocation needs review.'));end if;
  reported:=coalesce((reported_map->>(r.source_type||':'||r.id::text))::numeric,0);
 else
  select coalesce(sum(p.amount) filter(where p.payment_date<d),0),coalesce(sum(p.amount),0),coalesce(jsonb_agg(jsonb_build_object('id',p.id,'date',p.payment_date,'amount',p.amount) order by p.payment_date,p.id) filter(where p.payment_date<d),'[]') into paid,all_paid,items from public.expense_payments p where p.business_id=b and p.expense_id=r.id;
  if exists(select 1 from public.expense_payments p where p.business_id=b and p.expense_id=r.id and (p.payment_date is null or p.amount is null or p.amount<0)) then issues:=issues||jsonb_build_array(jsonb_build_object('code','payment_evidence','source_id',r.id,'message','Review supplier payment evidence for '||coalesce(r.reference,r.id::text)));end if;
  if exists(select 1 from public.expense_payments p where p.business_id=b and p.expense_id=r.id and p.payment_date<d and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='supplier_payment' and j.source_id=p.id and j.status='posted' and j.journal_date<d)) then issues:=issues||jsonb_build_array(jsonb_build_object('code','payment_posting','source_id',r.id,'message','A supplier payment is not backed by its posted payment. Review the existing payment workflow.'));end if;
  select coalesce(sum(c.total_amount),0),coalesce(sum(c.gst_amount*r.business_fraction),0) into credited,credit_tax from public.supplier_credits c where c.business_id=b and c.original_expense_id=r.id and c.lifecycle_state='recorded' and c.credit_date<d;
  if exists(select 1 from public.supplier_credits c where c.business_id=b and c.original_expense_id=r.id and c.lifecycle_state='recorded' and c.credit_date<d and (c.gst_amount is null or c.total_amount is null or c.gst_amount<0 or c.total_amount<0 or abs(c.gst_amount*r.business_fraction-rate*c.total_amount)>0.011 or (c.applied_expense_id is not null and c.applied_expense_id<>r.id))) then issues:=issues||jsonb_build_array(jsonb_build_object('code','mixed_credit','source_id',r.id,'message','Supplier credit tax or allocation needs review for '||coalesce(r.reference,r.id::text)));end if;
  if exists(select 1 from public.supplier_credits c where c.business_id=b and c.original_expense_id=r.id and c.lifecycle_state='recorded' and c.credit_date<d and (not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='supplier_credit' and j.source_id=c.id and j.status='posted' and j.journal_date<d) or abs(c.gst_amount*r.business_fraction-coalesce((select sum(l.credit-l.debit) from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id where j.business_id=b and j.source_type='supplier_credit' and j.source_id=c.id and j.status='posted' and j.journal_date<d and (a.system_key='gst_receivable' or a.system_account_key='gst_receivable')),0))>0.011)) then issues:=issues||jsonb_build_array(jsonb_build_object('code','credit_posting','source_id',r.id,'message','The supplier credit does not reconcile with its posted GST journal.'));end if;
  if exists(select 1 from public.supplier_refund_allocations a join public.supplier_refunds f on f.id=a.supplier_refund_id and f.business_id=a.business_id join public.supplier_credits c on c.id=a.supplier_credit_id and c.business_id=a.business_id where a.business_id=b and c.original_expense_id=r.id and f.lifecycle_state='recorded' and f.refund_date<d and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='supplier_refund' and j.source_id=f.id and j.status='posted' and j.journal_date<d)) then issues:=issues||jsonb_build_array(jsonb_build_object('code','refund_posting','source_id',r.id,'message','The supplier refund is not backed by its posted refund.'));end if;
  select coalesce(sum(a.amount),0) into refunded from public.supplier_refund_allocations a join public.supplier_refunds f on f.id=a.supplier_refund_id and f.business_id=a.business_id join public.supplier_credits c on c.id=a.supplier_credit_id and c.business_id=a.business_id where a.business_id=b and c.original_expense_id=r.id and f.lifecycle_state='recorded' and f.refund_date<d;
  if exists(select 1 from public.supplier_refunds f where f.business_id=b and f.supplier_id=r.party_id and f.lifecycle_state='recorded' and f.refund_date<d and abs(f.amount-coalesce((select sum(a.amount) from public.supplier_refund_allocations a where a.business_id=b and a.supplier_refund_id=f.id),0))>0.011) then issues:=issues||jsonb_build_array(jsonb_build_object('code','refund_allocation','source_id',r.id,'message','A supplier refund has incomplete credit allocation.'));end if;
  reported:=coalesce((reported_map->>(r.source_type||':'||r.id::text))::numeric,0);
 end if;
 if coalesce(r.amount_paid,0)>all_paid+0.011 then issues:=issues||jsonb_build_array(jsonb_build_object('code','missing_payment_evidence','source_id',r.id,'message','The paid total is not backed by dated payment records for '||coalesce(r.reference,r.id::text)));end if;
 if credited>r.total+0.011 or paid-refunded<0 or paid-refunded>r.total-credited+0.011 then issues:=issues||jsonb_build_array(jsonb_build_object('code','credit_balance','source_id',r.id,'message','An overpayment, pending refund or credit balance needs review for '||coalesce(r.reference,r.id::text)));end if;
 net_tax:=r.tax-credit_tax;cash_tax:=rate*(paid-refunded);outstanding:=greatest(r.total-credited-paid+refunded,0);
 expected:=case when (r.source_type='invoice' and old_basis<>'payments') or (r.source_type='expense' and old_basis='invoice') then net_tax else cash_tax end;
 -- Previous applied wash-ups count only once their return is filed. Section 19C(9).
 prior_delta:=coalesce((delta_map->>(r.source_type||':'||r.id::text))::numeric,0);
 reported:=reported+prior_delta;
 if r.tax>0 and abs(round(expected,2)-round(reported,2))>0.011 then issues:=issues||jsonb_build_array(jsonb_build_object('code','prior_reported_gst','source_id',r.id,'message','Previous filed GST does not reconcile for '||coalesce(r.reference,r.id::text)||'. Expected '||round(expected,2)::text||', evidenced '||round(reported,2)::text||'. Review prior returns or import the original filing evidence.'));end if;
 if exists(select 1 from public.gst_adjustments a where a.business_id=b and a.status='active' and a.adjustment_date<d and a.source_id=r.id and coalesce(a.source_type,'')<>'gst_basis_transition') then issues:=issues||jsonb_build_array(jsonb_build_object('code','source_adjustment','source_id',r.id,'message','A previous GST adjustment affects this source and requires reconciliation.'));end if;
 delta:=case when (r.source_type='invoice' and new_basis<>'payments') or (r.source_type='expense' and new_basis='invoice') then net_tax-reported else cash_tax-reported end;
 if r.source_type='invoice' then debtor:=debtor+greatest(net_tax-cash_tax,0);net:=net+delta;else creditor:=creditor+greatest(net_tax-cash_tax,0);net:=net-delta;end if;
 rows:=rows||jsonb_build_array(jsonb_build_object('source_type',r.source_type,'source_id',r.id,'reference',r.reference,'date',r.date,'total',r.total,'source_gst',r.tax,'business_fraction',r.business_fraction,'paid_before_change',paid,'credit_total',credited,'credit_gst',credit_tax,'refund_total',refunded,'outstanding',round(outstanding,2),'outstanding_gst',round(greatest(net_tax-cash_tax,0),2),'previously_reported_gst',round(reported,2),'expected_prior_gst',round(expected,2),'tax_delta',delta,'payments',items));
 end loop;
 if exists(select 1 from public.gst_adjustments a where a.business_id=b and a.status='active' and a.adjustment_date=d and coalesce(a.source_type,'')<>'gst_basis_transition' and lower(coalesce(a.reason,'')||' '||coalesce(a.reference,''))~'(basis|transition|wash.?up)') then issues:=issues||jsonb_build_array(jsonb_build_object('code','existing_transition_adjustment','message','An existing adjustment may already cover this basis change. Reconcile it before creating another.'));end if;
 return jsonb_build_object('business_id',b,'effective_from',d,'previous_basis',old_basis,'requested_basis',new_basis,'transactions',rows,'review_items',issues,'outstanding_customer_gst',round(debtor,2),'outstanding_supplier_gst',round(creditor,2),'net_adjustment',round(net,2),'debit',greatest(round(net,2),0),'credit',greatest(-round(net,2),0),'version','nz-gst-transition-v2');
end $$;
revoke all on function frindly_cash.gst_transition_evidence(date,text,text) from public,anon,authenticated;

create or replace function public.frindly_preview_gst_basis_change_v1(p_from date,p_to date,p_basis text,p_effective date,p_kind text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); old_basis text; cfg jsonb; ev jsonb; reviews jsonb:='[]'; locked boolean; normal jsonb; proposed jsonb; result jsonb;
begin
 if auth.uid() is null or b is null or not coalesce(public.v6147_can_read_area(b,'financials'),false) then raise exception 'Financial access denied' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from>p_to or p_effective is distinct from p_from or p_basis is null or p_basis not in ('invoice','payments','hybrid') or p_kind is null or p_kind not in ('correction','ird_change') then raise exception 'Choose a valid period and basis. The effective date must be the first day of the selected period.';end if;
 cfg:=public.v6170e_gst_settings(case when p_kind='ird_change' then p_effective-1 else p_effective end);old_basis:=cfg->>'accounting_basis';
 if old_basis is null or old_basis not in ('invoice','payments','hybrid') or not coalesce((cfg->>'gst_registered')::boolean,false) then raise exception 'Verify the previous GST registration and NZ accounting basis first.';end if;
 if exists(select 1 from public.gst_settings_history where business_id=b and jurisdiction<>'NZ') then raise exception 'This workflow supports New Zealand GST only.';end if;
 -- Settings changes may affect later reporting, not just the selected period.
 select exists(select 1 from public.gst_returns where business_id=b and status='finalised' and period_end>=p_effective)
 or exists(select 1 from public.ird_filing_batches where business_id=b and filing_type='gst_return' and status in ('filed_in_myir','submitted','accepted') and period_end>=p_effective) into locked;
 if locked then reviews:=reviews||jsonb_build_array(jsonb_build_object('code','filed_period_conflict','message','An affected or later return is already filed. Use an amendment review rather than changing these settings.'));end if;
 if p_basis='payments' and (select coalesce(sum(total-coalesce(gst,0)),0) from public.invoices where business_id=b and invoice_date>=p_effective-365 and invoice_date<p_effective and coalesce(lifecycle_state,'issued')='issued')>2000000 then reviews:=reviews||jsonb_build_array(jsonb_build_object('code','payments_eligibility','message','Recorded annual sales exceed the standard $2 million payments-basis threshold. Eligibility or an IRD exception needs review before applying.'));end if;
 if p_kind='ird_change' then
  if old_basis=p_basis then reviews:=reviews||jsonb_build_array(jsonb_build_object('code','same_basis','message','This is already the previous GST basis. Choose a correction if the historical configuration is wrong.'));end if;
  ev:=frindly_cash.gst_transition_evidence(p_effective,old_basis,p_basis);reviews:=reviews||coalesce(ev->'review_items','[]');
 else
  ev:=jsonb_build_object('transactions','[]'::jsonb,'net_adjustment',0,'debit',0,'credit',0,'outstanding_customer_gst',0,'outstanding_supplier_gst',0);
  if (select coalesce(g.accounting_basis,g.snapshot->>'basis') from public.gst_returns g where g.business_id=b and g.status='finalised' and g.period_end<p_effective order by g.period_end desc limit 1) is not null and (select coalesce(g.accounting_basis,g.snapshot->>'basis') from public.gst_returns g where g.business_id=b and g.status='finalised' and g.period_end<p_effective order by g.period_end desc limit 1)<>p_basis then
   reviews:=reviews||jsonb_build_array(jsonb_build_object('code','correction_prior_filing','message','Earlier filed returns use another basis. This requires an authorised transition or amendment, not a configuration correction.'));
  end if;
  if not exists(select 1 from public.gst_returns where business_id=b and status='finalised' and period_end<p_effective and accounting_basis=p_basis)
   and (exists(select 1 from public.invoices where business_id=b and invoice_date<p_effective and coalesce(lifecycle_state,'issued')='issued') or exists(select 1 from public.expenses where business_id=b and invoice_date<p_effective and coalesce(lifecycle_state,'recorded')='recorded')) then
   reviews:=reviews||jsonb_build_array(jsonb_build_object('code','correction_start','message','Earlier transactions have no confirmed filing evidence for this basis. Start the correction at the earliest affected unfiled period or review the earlier filings.'));
  end if;
  if exists(select 1 from public.gst_basis_change_requests where business_id=b and status='applied' and effective_from>=p_effective) then reviews:=reviews||jsonb_build_array(jsonb_build_object('code','applied_change_conflict','message','A confirmed basis change already exists in this correction window. Review it rather than overwriting its evidence.'));end if;
 end if;
 if p_kind='ird_change' and exists(select 1 from public.gst_settings_history where business_id=b and effective_from>p_effective and accounting_basis<>old_basis and accounting_basis<>p_basis) then reviews:=reviews||jsonb_build_array(jsonb_build_object('code','later_settings_change','message','A later basis change is already recorded. Reconcile that boundary before applying this one.'));end if;
 if exists(select 1 from public.gst_basis_change_requests where business_id=b and status='applied' and effective_from=p_effective) then reviews:=reviews||jsonb_build_array(jsonb_build_object('code','already_applied','message','A confirmed change already exists at this date. Use its View / refresh action instead of applying it twice.'));end if;
 normal:=public.frindly_gst_boundary_basis_v1(p_from,p_to,null);proposed:=public.frindly_gst_boundary_basis_v1(p_from,p_to,p_basis);
 result:=jsonb_build_object('business_id',b,'period_start',p_from,'period_end',p_to,'effective_from',p_effective,'previous_basis',old_basis,'requested_basis',p_basis,'change_kind',p_kind,'status','ready_for_review','can_apply',not locked and jsonb_array_length(reviews)=0,'filed_conflict',locked,'current_calculation',normal,'proposed_calculation',proposed,'outstanding_customer_gst',ev->'outstanding_customer_gst','outstanding_supplier_gst',ev->'outstanding_supplier_gst','provisional_net_adjustment',ev->'net_adjustment','provisional_debit',ev->'debit','provisional_credit',ev->'credit','transactions',ev->'transactions','review_items',reviews,'transition_evidence',ev,'version','nz-gst-activation-v2');
 return result||jsonb_build_object('fingerprint',md5(result::text));
end $$;

create function public.frindly_apply_gst_basis_change_v1(p_id uuid,p_fingerprint text,p_confirm boolean)
returns public.gst_basis_change_requests language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id();r public.gst_basis_change_requests; p jsonb; ev jsonb; cfg jsonb; a public.gst_adjustments; prev_a uuid; net numeric; existing_file boolean; fs public.financial_settings;
begin
 if auth.uid() is null or b is null or not coalesce(public.v6147_can_write_area(b,'financials'),false) then raise exception 'Financial write access denied' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(b::text||':gst-basis',0));
 select * into r from public.gst_basis_change_requests where business_id=b and id=p_id for update;
 if not found or r.status='cancelled' then raise exception 'Active basis-change request not found';end if;
 if not coalesce(p_confirm,false) then raise exception 'Confirm the authorised basis and complete transaction and filing evidence.';end if;
 -- GST-relevant journal postings share this lock; avoid taking source row locks
 -- in the opposite order to invoice/payment writers.
 if r.status='applied' then
  if r.change_kind='correction' then return r;end if;
  ev:=frindly_cash.gst_transition_evidence(r.effective_from,r.previous_basis,r.requested_basis);
  if ev=r.applied_evidence then return r;end if;
  if exists(select 1 from public.gst_returns where business_id=b and status='finalised' and period_end>=r.effective_from) or exists(select 1 from public.ird_filing_batches where business_id=b and filing_type='gst_return' and status in ('filed_in_myir','submitted','accepted') and period_end>=r.effective_from) then raise exception 'Evidence changed after a filed return. Use the amendment workflow.';end if;
  if jsonb_array_length(ev->'review_items')>0 then raise exception 'Resolve the transaction and prior-filing review items before refreshing reconciliation.';end if;
  if md5(ev::text) is distinct from p_fingerprint then raise exception 'The evidence changed. Review the latest reconciliation before confirming.';end if;
 else
  p:=public.frindly_preview_gst_basis_change_v1(r.period_start,r.period_end,r.requested_basis,r.effective_from,r.change_kind);
  if p->>'previous_basis' is distinct from r.previous_basis then raise exception 'The previous basis changed after this request. Cancel it and create a fresh request.';end if;
  if not (p->>'can_apply')::boolean then raise exception 'Resolve all basis-change review items before applying.';end if;
  if p->>'fingerprint' is distinct from p_fingerprint then raise exception 'The evidence changed. Refresh the comparison before applying.';end if;
  if btrim(r.evidence_reference)='' then raise exception 'A correction reason or IRD approval reference is required';end if;
  ev:=p->'transition_evidence';
 end if;
 select * into fs from public.financial_settings where business_id=b;
 perform frindly_cash.check_date(b,r.effective_from,false);
 cfg:=public.v6170e_gst_settings(r.effective_from);
 prev_a:=r.adjustment_id;
 if prev_a is not null then
  if exists(select 1 from public.gst_adjustments where business_id=b and id=prev_a and included_return_id is not null) then raise exception 'A filed adjustment cannot be replaced';end if;
  update public.gst_adjustments set status='reversed',updated_at=now(),updated_by=auth.uid() where business_id=b and id=prev_a and status='active';
 end if;
 -- Authorisation marker and settings/adjustment changes commit together.
 update public.gst_basis_change_requests set status='applied',previous_settings=coalesce(previous_settings,public.v6170e_gst_settings('-infinity'::date)),applied_evidence=ev,applied_at=now(),applied_by=auth.uid(),verification_history=verification_history||case when applied_evidence is not null then jsonb_build_array(jsonb_build_object('evidence',applied_evidence,'adjustment_id',adjustment_id,'replaced_at',now(),'by',auth.uid())) else '[]'::jsonb end where id=r.id returning * into r;
 if r.change_kind='correction' then
  update public.gst_settings_history set accounting_basis=r.requested_basis where business_id=b and effective_from>=r.effective_from;
 else
  -- Duplicate settings rows with the old basis are configuration snapshots,
  -- not additional authorised changes. Keep their other tax settings intact.
  update public.gst_settings_history set accounting_basis=r.requested_basis where business_id=b and effective_from>r.effective_from and accounting_basis=r.previous_basis;
 end if;
 perform public.v6170e_set_gst_settings((cfg->>'gst_registered')::boolean,cfg->>'gst_number',r.requested_basis,cfg->>'filing_frequency',coalesce((cfg->>'balance_date_month')::smallint,3::smallint),coalesce((cfg->>'balance_date_day')::smallint,31::smallint),r.effective_from);
 update public.financial_settings set gst_registered=fs.gst_registered,gst_number=fs.gst_number,gst_filing_frequency=fs.gst_filing_frequency,balance_date_month=fs.balance_date_month,balance_date_day=fs.balance_date_day,gst_accounting_basis=coalesce((public.v6170e_gst_settings((now() at time zone 'Pacific/Auckland')::date)->>'accounting_basis'),fs.gst_accounting_basis) where business_id=b;
 net:=coalesce((ev->>'net_adjustment')::numeric,0);
 if r.change_kind='ird_change' and net<>0 then
  a:=public.v6170e_create_gst_adjustment(r.effective_from,'supply_correction',case when net>0 then 'debit' else 'credit' end,abs(net),'NZ GST accounting basis change: '||r.previous_basis||' to '||r.requested_basis,r.evidence_reference,ev::text,'gst_basis_transition',r.id);
  if prev_a is not null then update public.gst_adjustments set reversal_of=prev_a where id=a.id and business_id=b;end if;
 end if;
 update public.gst_basis_change_requests set adjustment_id=a.id where id=r.id returning * into r;
 return r;
end $$;
revoke all on function public.frindly_apply_gst_basis_change_v1(uuid,text,boolean) from public,anon;
grant execute on function public.frindly_apply_gst_basis_change_v1(uuid,text,boolean) to authenticated;

create function public.frindly_gst_basis_request_review_v1(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r public.gst_basis_change_requests;ev jsonb;b uuid:=public.current_business_id();
begin
 if auth.uid() is null or b is null or not coalesce(public.v6147_can_read_area(b,'financials'),false) then raise exception 'Financial access denied' using errcode='42501';end if;
 select * into r from public.gst_basis_change_requests where business_id=b and id=p_id;
 if not found then raise exception 'Request not found';end if;
 if r.status='applied' and r.change_kind='ird_change' then
  ev:=frindly_cash.gst_transition_evidence(r.effective_from,r.previous_basis,r.requested_basis);
  return jsonb_build_object('request',to_jsonb(r),'evidence',ev,'fingerprint',md5(ev::text),'unchanged',ev=r.applied_evidence,'can_apply',ev is distinct from r.applied_evidence and jsonb_array_length(ev->'review_items')=0 and not exists(select 1 from public.gst_returns where business_id=b and status='finalised' and period_end>=r.effective_from));
 end if;
 if r.status='applied' then return jsonb_build_object('request',to_jsonb(r),'evidence',r.applied_evidence,'unchanged',true,'can_apply',false);end if;
 return jsonb_build_object('request',to_jsonb(r),'preview',public.frindly_preview_gst_basis_change_v1(r.period_start,r.period_end,r.requested_basis,r.effective_from,r.change_kind));
end $$;
revoke all on function public.frindly_gst_basis_request_review_v1(uuid) from public,anon;
grant execute on function public.frindly_gst_basis_request_review_v1(uuid) to authenticated;

create or replace function frindly_cash.gst_basis_review(p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare b uuid:=public.current_business_id();issues jsonb:='[]';r record;ev jsonb;net numeric;
begin
 if auth.uid() is null or b is null or not coalesce(public.v6147_can_read_area(b,'financials'),false) then raise exception 'Financial access denied' using errcode='42501';end if;
 if exists(select 1 from public.gst_basis_change_requests q where q.business_id=b and q.status='pending_verification' and q.effective_from<=p_to) then issues:=issues||jsonb_build_array(jsonb_build_object('severity','blocking','code','basis_change_pending_verification','message','Review or cancel the pending GST basis-change request before finalising.'));end if;
 for r in select * from (select effective_from,accounting_basis,gst_registered,lag(accounting_basis) over(order by effective_from) prior_basis,lag(gst_registered) over(order by effective_from) prior_registered from public.gst_settings_history where business_id=b and coalesce(jurisdiction,'NZ')='NZ') h where h.effective_from<=p_to and h.gst_registered and h.prior_registered and h.accounting_basis<>h.prior_basis loop
  if not exists(select 1 from public.gst_basis_change_requests q where q.business_id=b and q.status='applied' and q.effective_from=r.effective_from and q.requested_basis=r.accounting_basis and (q.change_kind='correction' or q.previous_basis=r.prior_basis)) then issues:=issues||jsonb_build_array(jsonb_build_object('severity','blocking','code','historical_basis_transition_unverified','date',r.effective_from,'message','A historical accounting-basis change has no confirmed reconciliation. Review that boundary before filing.'));end if;
 end loop;
 for r in select * from public.gst_basis_change_requests where business_id=b and status='applied' and change_kind='ird_change' and effective_from<=p_to order by effective_from loop
  ev:=frindly_cash.gst_transition_evidence(r.effective_from,r.previous_basis,r.requested_basis);net:=(r.applied_evidence->>'net_adjustment')::numeric;
  if ev is distinct from r.applied_evidence then issues:=issues||jsonb_build_array(jsonb_build_object('severity','blocking','code','basis_evidence_changed','request_id',r.id,'message','Transaction or prior-filing evidence changed after the basis change. Refresh its reconciliation before filing; filed periods need amendment review.'));end if;
  if (net<>0 and not exists(select 1 from public.gst_adjustments a where a.business_id=b and a.id=r.adjustment_id and a.status='active' and a.source_type='gst_basis_transition' and a.source_id=r.id and a.adjustment_date=r.effective_from and a.gst_amount=abs(net) and a.direction=case when net>0 then 'debit' else 'credit' end)) or (net=0 and r.adjustment_id is not null) then issues:=issues||jsonb_build_array(jsonb_build_object('severity','blocking','code','basis_adjustment_changed','request_id',r.id,'message','The confirmed transition adjustment no longer matches its evidence. Review it before filing.'));end if;
 end loop;
 return issues;
end $$;

create function frindly_cash.guard_gst_basis_history() returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;d date; oldvalues jsonb;newvalues jsonb;prior record;
begin
 b:=case when tg_op='DELETE' then old.business_id else new.business_id end;
 if tg_op='DELETE' and not exists(select 1 from public.businesses where id=b) then return old;end if;
 d:=case when tg_op='DELETE' then old.effective_from when tg_op='UPDATE' then least(old.effective_from,new.effective_from) else new.effective_from end;
 if tg_op='UPDATE' then
  if new.business_id is distinct from old.business_id then raise exception 'GST history cannot be moved between businesses';end if;
  oldvalues:=jsonb_build_array(old.effective_from,old.accounting_basis,old.gst_registered,old.gst_number,old.filing_frequency,old.balance_date_month,old.balance_date_day);
  newvalues:=jsonb_build_array(new.effective_from,new.accounting_basis,new.gst_registered,new.gst_number,new.filing_frequency,new.balance_date_month,new.balance_date_day);
  if oldvalues=newvalues then return new;end if;
 elsif tg_op='INSERT' then
  select * into prior from public.gst_settings_history where business_id=b and effective_from<=d order by effective_from desc limit 1;
  if found and jsonb_build_array(new.accounting_basis,new.gst_registered,new.gst_number,new.filing_frequency,new.balance_date_month,new.balance_date_day)=jsonb_build_array(prior.accounting_basis,prior.gst_registered,prior.gst_number,prior.filing_frequency,prior.balance_date_month,prior.balance_date_day) then return new;end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(b::text||':gst-basis',0));
 if exists(select 1 from public.gst_returns where business_id=b and status='finalised' and period_end>=d) or exists(select 1 from public.ird_filing_batches where business_id=b and filing_type='gst_return' and status in ('filed_in_myir','submitted','accepted') and period_end>=d) then raise exception 'These GST settings affect a filed return and cannot be changed. Use amendment review.';end if;
 if tg_op='DELETE' and exists(select 1 from public.gst_basis_change_requests where business_id=b and status='applied' and effective_from=d) then raise exception 'Confirmed GST basis history cannot be deleted';end if;
 if tg_op<>'DELETE' and exists(select 1 from public.gst_basis_change_requests q where q.business_id=b and q.status='applied' and q.effective_from<=new.effective_from and q.requested_basis<>new.accounting_basis and not exists(select 1 from public.gst_basis_change_requests later where later.business_id=b and later.status='applied' and later.effective_from>q.effective_from and later.effective_from<=new.effective_from)) then raise exception 'Use the authorised basis-change workflow instead of overwriting confirmed history';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function frindly_cash.guard_gst_basis_history() from public,anon,authenticated;
create trigger frindly_guard_gst_basis_history before insert or update or delete on public.gst_settings_history for each row execute function frindly_cash.guard_gst_basis_history();

-- Reuse the posted-journal engine to separate IRD amounts from GST that is
-- still awaiting cash recognition. These are balance-sheet transfers only.
create function frindly_cash.post_gst_basis_return(p_id uuid,p_calc jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id();g public.gst_returns;r record;balance numeric;reserved numeric;available numeric;source_net numeric:=0;old_timing numeric:=0;target numeric;net numeric;lines jsonb:='[]';payable uuid;receivable uuid;timing_liability uuid;timing_asset uuid;settlement uuid;journal uuid;
begin
 if auth.uid() is null or b is null or not coalesce(public.v6147_can_write_area(b,'financials'),false) then raise exception 'Financial write access denied' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('frindly-settlement:'||b::text,0));
 select * into g from public.gst_returns where business_id=b and id=p_id for update;if not found or g.status='finalised' then raise exception 'An editable GST return is required';end if;
 perform frindly_cash.check_date(b,g.period_end,false);
 if exists(select 1 from public.gst_returns where business_id=b and status='finalised' and period_start>g.period_end) then raise exception 'A later GST return is filed. Review amendments instead of backdating this finalisation.';end if;
 if exists(select 1 from generate_series((select min(effective_from) from public.gst_basis_change_requests where business_id=b and status='applied'),g.period_start-1,interval '1 day') d where coalesce((public.v6170e_gst_settings(d::date)->>'gst_registered')::boolean,false) and not exists(select 1 from public.gst_returns x where x.business_id=b and x.status='finalised' and d::date between x.period_start and x.period_end)) then raise exception 'Finalise or record the earlier GST periods first so reporting remains continuous.';end if;
 if exists(select 1 from public.gst_adjustments where business_id=b and status='active' and adjustment_date between g.period_start and g.period_end and coalesce(source_type,'')<>'gst_basis_transition' and gst_amount<>0) then raise exception 'Other GST adjustments in this period need their accounting treatment reviewed before this basis-transition return can be finalised.';end if;
 net:=(p_calc->>'gst_net')::numeric;
 payable:=frindly_cash.account(b,'gst_return_payable','GST returns payable to IRD','liability');
 receivable:=frindly_cash.account(b,'gst_return_receivable','GST refunds due from IRD','asset');
 timing_liability:=frindly_cash.account(b,'gst_timing_liability','GST awaiting cash recognition','liability');
 timing_asset:=frindly_cash.account(b,'gst_timing_asset','GST deductions awaiting payment','asset');
 for r in select id,system_key,system_account_key,account_subtype from public.accounting_accounts where id in (payable,receivable,timing_liability,timing_asset) and business_id=b loop
  if r.account_subtype='bank' or exists(select 1 from public.bank_accounts where business_id=b and accounting_account_id=r.id) or coalesce(r.system_key,r.system_account_key) not in ('gst_return_payable','gst_return_receivable','gst_timing_liability','gst_timing_asset') then raise exception 'A GST control account name is already in use. Review the mapping; no duplicate was created.';end if;
 end loop;
 update public.accounting_accounts set is_control=true,allow_manual_posting=false where business_id=b and id in (payable,receivable,timing_liability,timing_asset);
 for r in select a.id,coalesce(a.system_key,a.system_account_key) key,a.archived,a.account_type,a.account_subtype from public.accounting_accounts a where a.business_id=b and (a.system_key in ('gst_payable','gst_receivable') or a.system_account_key in ('gst_payable','gst_receivable')) loop
  if r.account_subtype='bank' or exists(select 1 from public.bank_accounts where business_id=b and accounting_account_id=r.id) or r.account_type not in ('asset','liability','current_liability','non_current_liability','tax') then raise exception 'GST controls must be balance-sheet accounts';end if;
  select coalesce(sum(l.credit-l.debit),0)*case when r.key='gst_receivable' then -1 else 1 end into balance from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=r.id and j.status in ('posted','reversed') and j.journal_date<=g.period_end;
  select coalesce(sum(greatest(abs(x.gst_net)-coalesce((select sum(a.amount) from public.liability_payment_allocations a join public.liability_payments p on p.id=a.payment_id and p.business_id=a.business_id join public.accounting_journals j on j.id=p.accounting_journal_id and j.business_id=p.business_id where a.business_id=b and a.gst_return_id=x.id and a.account_id=r.id and p.payment_date<=g.period_end and j.status='posted'),0),0)),0) into reserved from public.gst_returns x where x.business_id=b and x.status='finalised' and x.period_end<=g.period_end and x.snapshot->>'basis_activation_version' is null and ((r.key='gst_payable' and x.gst_net>0) or (r.key='gst_receivable' and x.gst_net<0));
  available:=round(balance-reserved,2);
  if available< -0.011 or (coalesce(r.archived,false) and abs(balance)>0.011) then raise exception 'Original GST control balances or earlier settlements need review before the return transfer can be posted';end if;
  if available>0 then
   lines:=lines||jsonb_build_array(jsonb_build_object('account_id',r.id,'debit',case when r.key='gst_payable' then available else 0 end,'credit',case when r.key='gst_receivable' then available else 0 end,'description','Transfer unallocated source GST to timing control','tax_code','NO_GST','tax_amount',0));
   source_net:=source_net+case when r.key='gst_payable' then available else -available end;
  end if;
 end loop;
 for r in select id from public.accounting_accounts where business_id=b and id in (timing_liability,timing_asset) loop
  select coalesce(sum(l.credit-l.debit),0) into balance from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=r.id and j.status in ('posted','reversed') and j.journal_date<=g.period_end;
  old_timing:=old_timing+balance;
  if balance<>0 then lines:=lines||jsonb_build_array(jsonb_build_object('account_id',r.id,'debit',greatest(balance,0),'credit',greatest(-balance,0),'description','Reclassify GST timing balance','tax_code','NO_GST','tax_amount',0));end if;
 end loop;
 target:=round(old_timing+source_net-net,2);
 if target<>0 then lines:=lines||jsonb_build_array(jsonb_build_object('account_id',case when target>0 then timing_liability else timing_asset end,'debit',greatest(-target,0),'credit',greatest(target,0),'description','GST pending recognition after this return','tax_code','NO_GST','tax_amount',0));end if;
 settlement:=case when net<0 then receivable else payable end;
 if net<>0 then lines:=lines||jsonb_build_array(jsonb_build_object('account_id',settlement,'debit',greatest(-net,0),'credit',greatest(net,0),'description','GST return due to or from IRD','tax_code','NO_GST','tax_amount',0));end if;
 select coalesce(jsonb_agg(jsonb_build_object('account_id',z.account_id,'debit',greatest(z.amount,0),'credit',greatest(-z.amount,0),'description','GST return timing and settlement transfer','tax_code','NO_GST','tax_amount',0) order by z.account_id),'[]') into lines from (select account_id,round(sum(debit-credit),2) amount from jsonb_to_recordset(lines) x(account_id uuid,debit numeric,credit numeric) group by account_id having abs(round(sum(debit-credit),2))>0.004) z;
 if jsonb_array_length(lines)>0 then journal:=public.v6192_create_posted_journal(b,g.period_end,'tax_adjustment','gst_return_transfer',g.id,g.period_start::text||' to '||g.period_end::text,'GST return and basis timing reconciliation',lines);end if;
 return p_calc||jsonb_build_object('basis_activation_version','nz-gst-activation-v2','settlement_account_id',settlement,'settlement_journal_id',journal,'basis_change_ids',(select coalesce(jsonb_agg(id order by effective_from),'[]') from public.gst_basis_change_requests where business_id=b and status='applied' and effective_from<=g.period_end));
end $$;
revoke all on function frindly_cash.post_gst_basis_return(uuid,jsonb) from public,anon,authenticated;

create or replace function frindly_cash.guard_gst_basis_finalisation() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='finalised' and (tg_op='INSERT' or old.status is distinct from 'finalised') then
  if new.business_id is distinct from public.current_business_id() then raise exception 'GST business access denied' using errcode='42501';end if;
  perform pg_advisory_xact_lock(hashtextextended(new.business_id::text||':gst-basis',0));
  if jsonb_array_length(frindly_cash.gst_basis_review(new.period_start,new.period_end))>0 then raise exception 'GST accounting-basis reconciliation needs review. Save a draft instead.';end if;
  if exists(select 1 from public.gst_basis_change_requests where business_id=new.business_id and status='applied' and effective_from<=new.period_end) and (new.snapshot->>'basis_activation_version' is distinct from 'nz-gst-activation-v2' or (new.gst_net<>0 and not exists(select 1 from public.accounting_journals j where j.business_id=new.business_id and j.id=(new.snapshot->>'settlement_journal_id')::uuid and j.source_type='gst_return_transfer' and j.source_id=new.id and j.status='posted'))) then raise exception 'Use the verified GST return save workflow so its ledger transfer is posted exactly once.';end if;
 end if;
 return new;
end $$;

create function frindly_cash.assert_gst_source_postings(c jsonb) returns void language plpgsql stable security definer set search_path='' as $$
declare b uuid:=public.current_business_id();it jsonb;source uuid;kind text;tax numeric;posted numeric;sgn int;through date:=(c->>'period_end')::date;
begin
 if auth.uid() is null or b is null or not coalesce(public.v6147_can_read_area(b,'financials'),false) then raise exception 'Financial access denied' using errcode='42501';end if;
 for it in select value from jsonb_array_elements(coalesce(c->'sales_items','[]')||coalesce(c->'purchase_items','[]')) loop
  kind:=it->>'source_type';source:=(it->>'source_id')::uuid;tax:=null;sgn:=1;
  if kind='customer_payment' then select i.id,i.gst into source,tax from public.customer_payments p join public.invoices i on i.id=p.invoice_id and i.business_id=p.business_id where p.business_id=b and p.id=source;kind:='invoice';
  elsif kind='expense_payment' then select e.id,e.gst_amount*coalesce(e.business_use_percent,100)/100 into source,tax from public.expense_payments p join public.expenses e on e.id=p.expense_id and e.business_id=p.business_id where p.business_id=b and p.id=source;kind:='expense';sgn:=-1;
  elsif kind='invoice' then select i.gst into tax from public.invoices i where i.business_id=b and i.id=source;
  elsif kind='expense' then select e.gst_amount*coalesce(e.business_use_percent,100)/100 into tax from public.expenses e where e.business_id=b and e.id=source;sgn:=-1;
  else tax:=(it->>'gst')::numeric;sgn:=case when kind='supplier_credit' then -1 else 1 end;
  end if;
  select coalesce(sum((l.credit-l.debit)*sgn),0) into posted from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id where j.business_id=b and j.source_type=kind and j.source_id=source and j.status='posted' and j.journal_date<=through and (a.system_key in ('gst_payable','gst_receivable') or a.system_account_key in ('gst_payable','gst_receivable'));
  if source is null or tax is null or abs(posted-tax)>0.011 or not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type=kind and j.source_id=source and j.status='posted' and j.journal_date<=through) then raise exception 'GST source % does not reconcile with its posted ledger. Review the source before filing.',coalesce(it->>'reference',source::text,kind);end if;
 end loop;
end $$;
revoke all on function frindly_cash.assert_gst_source_postings(jsonb) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.frindly_save_gst_basis_v1(p_from date, p_to date, p_status text DEFAULT 'draft'::text, p_basis text DEFAULT NULL::text)
 RETURNS gst_returns
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare bid uuid:=current_business_id(); calc jsonb; r gst_returns; blockers int; cfg jsonb; v_existing boolean:=false; v_conflict gst_returns; activated boolean;
begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'GST return access denied' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(bid::text||':gst-basis',0));
 if exists(select 1 from public.ird_filing_batches where business_id=bid and filing_type='gst_return' and status in ('filed_in_myir','submitted','accepted') and period_start<=p_to and period_end>=p_from) then raise exception 'This period is already recorded as filed externally. Use the amendment workflow.';end if;
 activated:=exists(select 1 from public.gst_basis_change_requests where business_id=bid and status='applied' and effective_from<=p_to);
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
 if activated and p_status='finalised' then perform frindly_cash.assert_gst_source_postings(calc);end if;
 if v_existing then
  update gst_returns set status=case when activated and p_status='finalised' then 'reviewed' else p_status end,gst_rate=15,taxable_sales_ex_gst=(calc->>'sales_ex_gst')::numeric,gst_collected=(calc->>'gst_collected')::numeric,taxable_purchases_ex_gst=(calc->>'purchases_ex_gst')::numeric,gst_paid=(calc->>'gst_paid')::numeric,debit_adjustments=(calc->>'debit_adjustments')::numeric,credit_adjustments=(calc->>'credit_adjustments')::numeric,gst_net=(calc->>'gst_net')::numeric,snapshot=calc,accounting_basis=calc->>'basis',filing_frequency=cfg->>'filing_frequency',statutory_rule_snapshot=jsonb_build_object('country','NZ','standard_rate_percent',15),registration_snapshot=cfg,review_items=calc->'review_items',calculation_version='frindly-gst-boundary-v1',finalised_at=case when p_status='finalised' then now() else null end,finalised_by=case when p_status='finalised' then auth.uid() else null end,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 else
  insert into gst_returns(business_id,period_start,period_end,status,gst_rate,taxable_sales_ex_gst,gst_collected,taxable_purchases_ex_gst,gst_paid,debit_adjustments,credit_adjustments,gst_net,snapshot,accounting_basis,filing_frequency,statutory_rule_snapshot,registration_snapshot,review_items,calculation_version,finalised_at,finalised_by,created_by,updated_by)
  values(bid,p_from,p_to,case when activated and p_status='finalised' then 'reviewed' else p_status end,15,(calc->>'sales_ex_gst')::numeric,(calc->>'gst_collected')::numeric,(calc->>'purchases_ex_gst')::numeric,(calc->>'gst_paid')::numeric,(calc->>'debit_adjustments')::numeric,(calc->>'credit_adjustments')::numeric,(calc->>'gst_net')::numeric,calc,calc->>'basis',cfg->>'filing_frequency',jsonb_build_object('country','NZ','standard_rate_percent',15),cfg,calc->'review_items','frindly-gst-boundary-v1',case when p_status='finalised' then now() end,case when p_status='finalised' then auth.uid() end,auth.uid(),auth.uid()) returning * into r;
 end if;
 if activated and p_status='finalised' then
  calc:=frindly_cash.post_gst_basis_return(r.id,calc);
  update public.gst_returns set status='finalised',snapshot=calc,finalised_at=now(),finalised_by=auth.uid(),updated_at=now(),updated_by=auth.uid() where business_id=bid and id=r.id returning * into r;
 end if;
 if p_status='finalised' then update gst_adjustments set included_return_id=r.id,updated_at=now(),updated_by=auth.uid() where business_id=bid and status='active' and adjustment_date between p_from and p_to and included_return_id is null;end if;
 return r;
end$function$
;

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
 from gst g left join public.accounting_accounts a on a.business_id=p_bid and not a.archived and (case when g.snapshot->>'basis_activation_version'='nz-gst-activation-v2' then a.id=(g.snapshot->>'settlement_account_id')::uuid else a.system_key=g.account_key or a.system_account_key=g.account_key end)
 left join prior pr on pr.kind='gst' and pr.gst_return_id=g.id and pr.account_id=a.id
 $function$

;
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
   if gst.snapshot->>'basis_activation_version'='nz-gst-activation-v2' then
    if item.account_id is distinct from (gst.snapshot->>'settlement_account_id')::uuid then raise exception 'Select the original posted GST return control account';end if;
    select round(coalesce(sum(l.credit-l.debit),0),2) into ledger_net from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id
    where j.business_id=b and j.id=(gst.snapshot->>'settlement_journal_id')::uuid and j.source_id=gst.id and j.source_type='gst_return_transfer' and j.status='posted' and j.journal_date=gst.period_end and (a.system_key in ('gst_return_payable','gst_return_receivable') or a.system_account_key in ('gst_return_payable','gst_return_receivable'));
    if abs(ledger_net-gst.gst_net)>0.01 then raise exception 'Saved GST return differs from its posted return transfer. Review before settlement';end if;
   else
   select round(coalesce(sum(l.credit-l.debit),0),2) into ledger_net
   from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
   join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id
   where j.business_id=b and j.status in ('posted','reversed') and j.journal_date between gst.period_start and gst.period_end
   and j.source_type<>'liability_settlement'
   and (a.system_key in ('gst_payable','gst_receivable') or a.system_account_key in ('gst_payable','gst_receivable'));
   if abs(ledger_net-gst.gst_net)>0.01 then
    if coalesce(gst.accounting_basis,gst.snapshot->>'basis') in ('payments','hybrid') and exists(select 1 from public.gst_basis_change_requests q where q.business_id=b and q.status='applied' and q.effective_from>gst.period_end) and gst.snapshot is not null and abs(coalesce((gst.snapshot->>'gst_net')::numeric,1e99)-gst.gst_net)<=0.01 then
     perform frindly_cash.assert_gst_source_postings(gst.snapshot);
    else raise exception 'Saved GST return differs from posted GST ledger. Reconcile source postings and calculation basis before settlement';end if;
   end if;
   end if;
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
end $function$
;

create unique index gst_return_transfer_once on public.accounting_journals(business_id,source_id) where source_type='gst_return_transfer' and status='posted';
create function frindly_cash.guard_filed_gst_transfer() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.source_type='gst_return_transfer' and old.status='posted' and (tg_op='DELETE' or new.status is distinct from old.status or new.journal_date is distinct from old.journal_date or new.source_id is distinct from old.source_id) and exists(select 1 from public.gst_returns g where g.business_id=old.business_id and g.id=old.source_id and g.status='finalised') then raise exception 'A filed GST return transfer is immutable. Use amendment review.';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function frindly_cash.guard_filed_gst_transfer() from public,anon,authenticated;
create trigger frindly_guard_filed_gst_transfer before update or delete on public.accounting_journals for each row execute function frindly_cash.guard_filed_gst_transfer();
create function frindly_cash.guard_filed_gst_adjustment() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.included_return_id is not null and exists(select 1 from public.gst_returns g where g.business_id=old.business_id and g.id=old.included_return_id and g.status='finalised') then raise exception 'A filed GST adjustment is immutable. Use amendment review.';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function frindly_cash.guard_filed_gst_adjustment() from public,anon,authenticated;
create trigger frindly_guard_filed_gst_adjustment before update or delete on public.gst_adjustments for each row execute function frindly_cash.guard_filed_gst_adjustment();

-- Serialize tax source posting with activation/finalisation. This trigger does
-- not require Financials access from invoice/expense users and never reposts.
create function frindly_cash.guard_gst_source_posting() returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;k text;d date;prior_d date;basis text;is_relevant boolean;
begin
 b:=case when tg_op='DELETE' then old.business_id else new.business_id end;
 k:=case when tg_op='DELETE' then old.source_type else new.source_type end;
 if k in ('gst_return_transfer','liability_settlement') then if tg_op='DELETE' then return old;end if;return new;end if;
 if not exists(select 1 from public.gst_basis_change_requests where business_id=b and status='applied') then if tg_op='DELETE' then return old;end if;return new;end if;
 if k not in ('invoice','customer_payment','expense','supplier_payment','customer_credit_note','supplier_credit','customer_refund','supplier_refund','asset_disposal','cash_transaction') and not exists(select 1 from public.accounting_journal_lines l join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id where l.business_id=b and l.journal_id=case when tg_op='DELETE' then old.id else new.id end and (a.system_key in ('gst_payable','gst_receivable') or a.system_account_key in ('gst_payable','gst_receivable'))) then if tg_op='DELETE' then return old;end if;return new;end if;
 if tg_op<>'DELETE' and new.status<>'posted' and (tg_op='INSERT' or old.status<>'posted') then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended(b::text||':gst-basis',0));
 if tg_op<>'INSERT' and old.status='posted' and (tg_op='DELETE' or new.status is distinct from old.status or new.journal_date is distinct from old.journal_date) and old.source_type in ('invoice','expense') and exists(select 1 from public.gst_returns g cross join lateral jsonb_array_elements(coalesce(g.snapshot->'sales_items','[]')||coalesce(g.snapshot->'purchase_items','[]')) it where g.business_id=b and g.status='finalised' and ((it->>'source_id'=old.source_id::text and it->>'source_type'=old.source_type) or (it->>'source_type'='customer_payment' and exists(select 1 from public.customer_payments cp where cp.business_id=b and cp.id::text=it->>'source_id' and cp.invoice_id=old.source_id)) or (it->>'source_type'='expense_payment' and exists(select 1 from public.expense_payments ep where ep.business_id=b and ep.id::text=it->>'source_id' and ep.expense_id=old.source_id)))) then raise exception 'This source is included in a filed GST snapshot. Use amendment review before reversing or moving it.';end if;
 for d in select distinct x from unnest(array[case when tg_op='DELETE' then old.journal_date else new.journal_date end,case when tg_op='UPDATE' then old.journal_date else null end]) x where x is not null loop
  select h.accounting_basis into basis from public.gst_settings_history h where h.business_id=b and h.effective_from<=d order by h.effective_from desc limit 1;
  if basis is null then select q.previous_settings->>'accounting_basis' into basis from public.gst_basis_change_requests q where q.business_id=b and q.status='applied' and q.effective_from>d and q.previous_settings is not null order by q.effective_from limit 1;end if;
  if basis is null then select f.gst_accounting_basis into basis from public.financial_settings f where f.business_id=b;end if;
  is_relevant:=case when k in ('invoice','customer_payment','customer_refund') then case when k='invoice' then basis in ('invoice','hybrid') else basis='payments' end when k in ('expense','supplier_payment','supplier_refund') then case when k='expense' then basis='invoice' else basis in ('payments','hybrid') end else true end;
  if is_relevant and (exists(select 1 from public.gst_returns where business_id=b and status='finalised' and d between period_start and period_end) or exists(select 1 from public.ird_filing_batches where business_id=b and filing_type='gst_return' and status in ('filed_in_myir','submitted','accepted') and d between period_start and period_end)) then raise exception 'This posting affects a filed GST period. Use the existing late-transaction or amendment review workflow.';end if;
 end loop;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function frindly_cash.guard_gst_source_posting() from public,anon,authenticated;
create trigger frindly_guard_gst_source_posting before insert or update or delete on public.accounting_journals for each row execute function frindly_cash.guard_gst_source_posting();

create function frindly_cash.lock_gst_adjustment_write() returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;
begin
 b:=case when tg_op='DELETE' then old.business_id else new.business_id end;
 perform pg_advisory_xact_lock(hashtextextended(b::text||':gst-basis',0));
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function frindly_cash.lock_gst_adjustment_write() from public,anon,authenticated;
create trigger frindly_lock_gst_adjustment_write before insert or update or delete on public.gst_adjustments for each row execute function frindly_cash.lock_gst_adjustment_write();

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
 if exists(select 1 from public.gst_basis_change_requests where business_id=b and status='applied' and effective_from<=p_to) then
  if exists(select 1 from jsonb_array_elements(coalesce(result->'sales_items','[]')) x where abs(coalesce((x->>'gst')::numeric,0))<0.005 and abs(coalesce((x->>'total')::numeric,0))>0.005 and coalesce(x->>'classification','') not in ('zero_rated','exempt','out_of_scope')) then issues:=issues||jsonb_build_array(jsonb_build_object('severity','blocking','code','zero_gst_classification','message','A zero-GST sale has no verified zero-rated/exempt classification. Review the source treatment before filing; no classification has been guessed.'));end if;
  if abs(coalesce((result->>'debit_adjustments')::numeric,0)-coalesce((result->>'credit_adjustments')::numeric,0)-coalesce((select sum(case when direction='debit' then gst_amount else -gst_amount end) from public.gst_adjustments where business_id=b and status='active' and source_type='gst_basis_transition' and adjustment_date between p_from and p_to),0))>0.011 then issues:=issues||jsonb_build_array(jsonb_build_object('severity','blocking','code','other_gst_adjustment_posting','message','Other GST adjustments in this period need their source and ledger treatment reviewed before filing this basis-transition return.'));end if;
 end if;

 return result||jsonb_build_object('review_items',coalesce(result->'review_items','[]'::jsonb)||issues);
end $function$

;

-- Preserve the pre-history fallback instead of silently changing older GST bases.
CREATE OR REPLACE FUNCTION public.v6170e_gst_settings(p_on date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare bid uuid:=current_business_id(); h record; f record; prior_cfg jsonb;begin if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501'; end if; select * into h from gst_settings_history where business_id=bid and effective_from<=p_on order by effective_from desc limit 1; if found then return jsonb_build_object('effective_from',h.effective_from,'gst_registered',h.gst_registered,'gst_number',h.gst_number,'accounting_basis',h.accounting_basis,'filing_frequency',h.filing_frequency,'balance_date_month',h.balance_date_month,'balance_date_day',h.balance_date_day); end if; select previous_settings into prior_cfg from public.gst_basis_change_requests where business_id=bid and status='applied' and effective_from>p_on and previous_settings is not null order by effective_from limit 1; if found then return prior_cfg;end if; select * into f from financial_settings where business_id=bid limit 1; return jsonb_build_object('effective_from',null,'gst_registered',coalesce(f.gst_registered,true),'gst_number',f.gst_number,'accounting_basis',coalesce(f.gst_accounting_basis,'invoice'),'filing_frequency',coalesce(f.gst_filing_frequency,'two_monthly'),'balance_date_month',coalesce(f.balance_date_month,3),'balance_date_day',coalesce(f.balance_date_day,31)); end$function$
;
