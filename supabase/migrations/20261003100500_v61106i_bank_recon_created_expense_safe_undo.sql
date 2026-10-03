-- Frindly v61.106I
-- Accounting-safe undo for expenses CREATED by Bank Reconciliation.
-- Scope is deliberately narrow: no changes to ordinary invoice/expense/payroll/refund/owner-equity undo paths.
-- Posted expenses are voided through the existing accounting correction RPC so their journal/GST effect is reversed
-- and the source record remains for audit. Unposted created expenses may still be removed.

create or replace function public.v61106i_undo_created_expense_bank_reconciliation(
  p_bank_transaction_id uuid,
  p_reason text default 'Undo bank reconciliation-created expense'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_alloc record;
  v_exp record;
  v_has_posted_journal boolean;
  v_voided_ids uuid[] := array[]::uuid[];
  v_deleted_ids uuid[] := array[]::uuid[];
  v_payment_ids uuid[] := array[]::uuid[];
  v_count integer := 0;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx
  from public.bank_transactions
  where id=p_bank_transaction_id and business_id=v_bid
  for update;
  if v_tx.id is null then raise exception 'Bank transaction was not found for this business'; end if;

  if not exists (
    select 1 from public.bank_reconciliation_allocations
    where business_id=v_bid and bank_transaction_id=p_bank_transaction_id and coalesce(created_expense,false)=true and expense_id is not null
  ) then
    raise exception 'This reconciliation did not create an expense';
  end if;

  -- Refuse an unexpected mixed reconciliation rather than touching unrelated records.
  if exists (
    select 1 from public.bank_reconciliation_allocations
    where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
      and not (coalesce(created_expense,false)=true and expense_id is not null)
  ) then
    raise exception 'This bank transaction contains mixed allocations. No records were changed; review the reconciliation before undoing it.';
  end if;

  for v_alloc in
    select * from public.bank_reconciliation_allocations
    where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
      and coalesce(created_expense,false)=true and expense_id is not null
    order by created_at, id
  loop
    v_count := v_count + 1;

    select id,business_id,lifecycle_state,archived
      into v_exp
    from public.expenses
    where id=v_alloc.expense_id and business_id=v_bid
    for update;

    if v_exp.id is null then
      raise exception 'The reconciliation-created expense % was not found. No records were changed.', v_alloc.expense_id;
    end if;

    -- Remove only the payment explicitly created by this reconciliation. Existing/manual payments are untouched.
    if v_alloc.expense_payment_id is not null then
      delete from public.expense_payments
      where id=v_alloc.expense_payment_id
        and expense_id=v_alloc.expense_id
        and business_id=v_bid;
      if found then v_payment_ids := array_append(v_payment_ids,v_alloc.expense_payment_id); end if;
    end if;

    select exists(
      select 1 from public.accounting_journals j
      where j.business_id=v_bid
        and j.source_type='expense'
        and j.source_id=v_alloc.expense_id
        and j.status in ('posted','reversed')
    ) into v_has_posted_journal;

    if v_has_posted_journal then
      -- Never delete a source that has entered the ledger. Use the established expense-void correction path.
      if lower(coalesce(v_exp.lifecycle_state,'')) <> 'voided' then
        if to_regprocedure('public.v6170c45_void_expense(uuid,text)') is null then
          raise exception 'Accounting-safe expense reversal is not available. Nothing was undone.';
        end if;
        execute 'select public.v6170c45_void_expense($1,$2)'
          using v_alloc.expense_id, coalesce(nullif(btrim(p_reason),''),'Undo bank reconciliation-created expense');
      end if;
      v_voided_ids := array_append(v_voided_ids,v_alloc.expense_id);
    else
      -- No ledger/GST history exists, so the reconciliation-created source can be removed as before.
      delete from public.expenses
      where id=v_alloc.expense_id and business_id=v_bid;
      if not found then raise exception 'Unposted reconciliation-created expense could not be removed. Nothing was undone.'; end if;
      v_deleted_ids := array_append(v_deleted_ids,v_alloc.expense_id);
    end if;
  end loop;

  delete from public.bank_reconciliation_allocations
  where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
    and coalesce(created_expense,false)=true;

  update public.bank_transactions
  set status='unreconciled', reconciliation_type=null, reconciled_at=null, reconciled_by=null,
      excluded_reason=null, transfer_bank_account_id=null, updated_at=now(), updated_by=v_uid
  where id=p_bank_transaction_id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(
    business_id,bank_transaction_id,action,details,created_by
  ) values (
    v_bid,p_bank_transaction_id,'created_expense_undo',
    jsonb_build_object(
      'reason',coalesce(nullif(btrim(p_reason),''),'Undo bank reconciliation-created expense'),
      'voided_expense_ids',to_jsonb(v_voided_ids),
      'deleted_unposted_expense_ids',to_jsonb(v_deleted_ids),
      'removed_reconciliation_payment_ids',to_jsonb(v_payment_ids),
      'accounting_safe',true
    ),v_uid
  );

  return jsonb_build_object('ok',true,'expense_count',v_count,'voided_expense_ids',to_jsonb(v_voided_ids),'deleted_unposted_expense_ids',to_jsonb(v_deleted_ids));
end;
$$;

revoke execute on function public.v61106i_undo_created_expense_bank_reconciliation(uuid,text) from public, anon;
grant execute on function public.v61106i_undo_created_expense_bank_reconciliation(uuid,text) to authenticated;
