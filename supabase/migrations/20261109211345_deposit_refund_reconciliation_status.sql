CREATE OR REPLACE FUNCTION public.v6203_reconciliation_statuses()
 RETURNS TABLE(record_type text, record_id uuid, reconciliation_status text, matched_amount numeric, required_amount numeric, legacy_manual boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with bid as (select public.current_business_id() id),
  deposit_refund_values as (
    select a.expense_id, max(a.amount-r.amount) as matched
    from public.bank_reconciliation_allocations a
    join public.bank_reconciliation_allocations r
      on r.business_id=a.business_id and r.expense_id=a.expense_id
      and r.bank_transaction_id=a.related_bank_transaction_id
      and r.related_bank_transaction_id=a.bank_transaction_id
      and r.allocation_type='expense_deposit_refund'
    join public.bank_transactions debit on debit.id=a.bank_transaction_id and debit.business_id=a.business_id
    join public.bank_transactions refund on refund.id=r.bank_transaction_id and refund.business_id=r.business_id
    join public.expenses e on e.id=a.expense_id and e.business_id=a.business_id
    where a.business_id=(select id from bid)
      and a.allocation_type='expense_deposit_refund'
      and debit.status='reconciled' and refund.status='reconciled'
      and debit.amount=-a.amount and refund.amount=r.amount
      and r.amount>0 and a.amount>r.amount
      and round(a.amount-r.amount,2)=round(e.total_amount,2)
    group by a.expense_id
  ), expense_values as (
    select e.id,
      coalesce(sum(case when p.reconciliation_requirement='bank_match' then p.amount else 0 end),0) required,
      coalesce(sum(case when p.reconciliation_requirement='bank_match' then least(p.amount,coalesce(a.matched,0)) else 0 end),0) matched,
      coalesce(sum(case when p.reconciliation_requirement='not_required' then p.amount else 0 end),0) no_match,
      coalesce(e.reconciled,false) manual_flag
    from public.expenses e
    left join public.expense_payments p on p.expense_id=e.id and p.business_id=e.business_id
    left join lateral (
      select sum(bra.amount) matched
      from public.bank_reconciliation_allocations bra
      where bra.business_id=e.business_id and bra.expense_payment_id=p.id
    ) a on true
    where e.business_id=(select id from bid) and not coalesce(e.archived,false)
    group by e.id,e.reconciled
  ), expense_status_values as (
    select e.id, e.required, greatest(e.matched, least(e.required,coalesce(d.matched,0))) matched,
      e.no_match,e.manual_flag
    from expense_values e left join deposit_refund_values d on d.expense_id=e.id
  ), invoice_values as (
    select i.id,
      coalesce(sum(p.amount),0) required,
      coalesce(sum(least(p.amount,coalesce(a.matched,0))),0) matched
    from public.invoices i
    left join public.customer_payments p on p.invoice_id=i.id and p.business_id=i.business_id
    left join lateral (
      select sum(bra.amount) matched
      from public.bank_reconciliation_allocations bra
      where bra.business_id=i.business_id and (
        bra.customer_payment_id=p.id
        or bra.existing_customer_payment_id=p.id
        or exists (
          select 1 from public.invoice_payment_transactions ipt
          where ipt.id=bra.invoice_payment_transaction_id
            and ipt.business_id=i.business_id
            and ipt.customer_payment_id=p.id
        )
      )
    ) a on true
    where i.business_id=(select id from bid)
    group by i.id
  )
  select 'expense',e.id,
    case
      when e.required<=0.005 and e.no_match>0.005 then 'not_required'
      when e.required<=0.005 and e.manual_flag then 'legacy_manual_review'
      when e.required<=0.005 then 'awaiting_payment'
      when e.matched<=0.005 and e.manual_flag then 'legacy_manual_review'
      when e.matched<=0.005 then 'awaiting_bank_match'
      when e.matched+0.005<e.required then 'part_reconciled'
      else 'reconciled'
    end,e.matched,e.required,(e.manual_flag and e.matched<=0.005)
  from expense_status_values e
  union all
  select 'invoice',i.id,
    case when i.required<=0.005 then 'awaiting_payment'
         when i.matched<=0.005 then 'awaiting_bank_match'
         when i.matched+0.005<i.required then 'part_reconciled'
         else 'reconciled' end,
    i.matched,i.required,false
  from invoice_values i
$function$
;
