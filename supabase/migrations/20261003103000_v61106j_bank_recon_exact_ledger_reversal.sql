-- Frindly v61.106J
-- Exact-ledger reversal for Undo of expenses CREATED by Bank Reconciliation.
-- Narrow scope: replaces only v61106i_undo_created_expense_bank_reconciliation.
-- It does not delete posted expenses or alter ordinary reconciliation paths.

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
  v_j record;
  v_lines jsonb;
  v_reversal_journal uuid;
  v_voided_ids uuid[] := array[]::uuid[];
  v_deleted_ids uuid[] := array[]::uuid[];
  v_payment_ids uuid[] := array[]::uuid[];
  v_reversal_ids uuid[] := array[]::uuid[];
  v_count integer := 0;
  v_has_posted boolean;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions
  where id=p_bank_transaction_id and business_id=v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction was not found for this business'; end if;

  if not exists (
    select 1 from public.bank_reconciliation_allocations
    where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
      and coalesce(created_expense,false)=true and expense_id is not null
  ) then raise exception 'This reconciliation did not create an expense'; end if;

  if exists (
    select 1 from public.bank_reconciliation_allocations
    where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
      and not (coalesce(created_expense,false)=true and expense_id is not null)
  ) then raise exception 'This bank transaction contains mixed allocations. No records were changed; review the reconciliation before undoing it.'; end if;

  for v_alloc in
    select * from public.bank_reconciliation_allocations
    where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
      and coalesce(created_expense,false)=true and expense_id is not null
    order by created_at,id
  loop
    v_count:=v_count+1;
    select id,business_id,lifecycle_state,archived into v_exp
    from public.expenses where id=v_alloc.expense_id and business_id=v_bid for update;
    if v_exp.id is null then raise exception 'The reconciliation-created expense % was not found. No records were changed.',v_alloc.expense_id; end if;

    select exists(select 1 from public.accounting_journals j
      where j.business_id=v_bid and j.source_type='expense' and j.source_id=v_alloc.expense_id and j.status in ('posted','reversed'))
      into v_has_posted;

    if v_has_posted and lower(coalesce(v_exp.lifecycle_state,'')) <> 'voided' then
      -- Reverse each original expense journal from its ACTUAL lines. No GST or account amounts are recalculated.
      for v_j in
        select j.* from public.accounting_journals j
        where j.business_id=v_bid and j.source_type='expense' and j.source_id=v_alloc.expense_id and j.status='posted'
        order by j.created_at,j.id
        for update
      loop
        -- Do not create a second reversal for the same original journal.
        if not exists(select 1 from public.accounting_journals r
          where r.business_id=v_bid and r.source_type='expense_reversal' and r.source_id=v_j.id and r.status in ('posted','reversed')) then
          select coalesce(jsonb_agg(jsonb_build_object(
            'account_id',l.account_id,
            'description','Reversal: '||coalesce(l.description,'Expense'),
            'debit',coalesce(l.credit,0),
            'credit',coalesce(l.debit,0),
            'tax_code',coalesce(l.tax_code,'NO_GST'),
            'tax_rate',coalesce(l.tax_rate,0),
            'tax_amount',-coalesce(l.tax_amount,0)
          ) order by l.created_at,l.id),'[]'::jsonb)
          into v_lines
          from public.accounting_journal_lines l
          where l.business_id=v_bid and l.journal_id=v_j.id;

          if jsonb_array_length(v_lines)=0 then raise exception 'Posted expense journal % has no journal lines. Nothing was undone.',v_j.id; end if;
          if round(coalesce((select sum((x->>'debit')::numeric-(x->>'credit')::numeric) from jsonb_array_elements(v_lines)x),0),2)<>0 then
            raise exception 'Expense reversal would not balance. Nothing was undone.';
          end if;

          v_reversal_journal:=public.v6192_create_posted_journal(
            v_bid,v_j.journal_date,'correction','expense_reversal',v_j.id,
            'REV-'||left(v_j.id::text,8),
            'Reversal of bank-created expense: '||coalesce(nullif(btrim(p_reason),''),'Incorrect bank reconciliation'),v_lines
          );
          v_reversal_ids:=array_append(v_reversal_ids,v_reversal_journal);
        end if;
        update public.accounting_journals set status='reversed',updated_at=now(),updated_by=v_uid
        where id=v_j.id and business_id=v_bid and status='posted';
      end loop;

      -- Preserve source document and audit history; only mark its protected lifecycle as voided.
      update public.expenses set lifecycle_state='voided',updated_at=now(),updated_by=v_uid
      where id=v_alloc.expense_id and business_id=v_bid;
      v_voided_ids:=array_append(v_voided_ids,v_alloc.expense_id);
    elsif not v_has_posted then
      -- Only a source that never entered the formal ledger may be removed.
      if v_alloc.expense_payment_id is not null then
        delete from public.expense_payments where id=v_alloc.expense_payment_id and expense_id=v_alloc.expense_id and business_id=v_bid;
        if found then v_payment_ids:=array_append(v_payment_ids,v_alloc.expense_payment_id); end if;
      end if;
      delete from public.expenses where id=v_alloc.expense_id and business_id=v_bid;
      if not found then raise exception 'Unposted reconciliation-created expense could not be removed. Nothing was undone.'; end if;
      v_deleted_ids:=array_append(v_deleted_ids,v_alloc.expense_id);
    end if;

    -- For posted expenses remove ONLY the payment created by this bank reconciliation, after reversal exists.
    if v_has_posted and v_alloc.expense_payment_id is not null then
      delete from public.expense_payments where id=v_alloc.expense_payment_id and expense_id=v_alloc.expense_id and business_id=v_bid;
      if found then v_payment_ids:=array_append(v_payment_ids,v_alloc.expense_payment_id); end if;
    end if;
  end loop;

  delete from public.bank_reconciliation_allocations
  where business_id=v_bid and bank_transaction_id=p_bank_transaction_id and coalesce(created_expense,false)=true;

  update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,
    excluded_reason=null,transfer_bank_account_id=null,updated_at=now(),updated_by=v_uid
  where id=p_bank_transaction_id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values(v_bid,p_bank_transaction_id,'created_expense_undo',jsonb_build_object(
    'reason',coalesce(nullif(btrim(p_reason),''),'Incorrect bank reconciliation'),
    'voided_expense_ids',to_jsonb(v_voided_ids),'deleted_unposted_expense_ids',to_jsonb(v_deleted_ids),
    'reversal_journal_ids',to_jsonb(v_reversal_ids),'removed_reconciliation_payment_ids',to_jsonb(v_payment_ids),
    'accounting_safe',true,'reversal_basis','exact_original_journal_lines'),v_uid);

  return jsonb_build_object('ok',true,'expense_count',v_count,'voided_expense_ids',to_jsonb(v_voided_ids),
    'deleted_unposted_expense_ids',to_jsonb(v_deleted_ids),'reversal_journal_ids',to_jsonb(v_reversal_ids));
end;
$$;

revoke execute on function public.v61106i_undo_created_expense_bank_reconciliation(uuid,text) from public,anon;
grant execute on function public.v61106i_undo_created_expense_bank_reconciliation(uuid,text) to authenticated;
