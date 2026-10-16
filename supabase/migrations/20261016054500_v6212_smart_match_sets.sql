-- Frindly v62.12
-- Atomic Smart Match Sets hardening.
-- Additive/idempotent: does not rewrite or delete business records.

begin;

-- Main and Dev historically carried different versions of the allocation-type
-- check. Normalise the accepted union without changing any existing rows.
alter table public.bank_reconciliation_allocations
  drop constraint if exists bank_alloc_type_c45;
alter table public.bank_reconciliation_allocations
  drop constraint if exists bank_reconciliation_allocations_allocation_type_check;
alter table public.bank_reconciliation_allocations
  drop constraint if exists bank_reconciliation_allocations_allocation_type_ck;
alter table public.bank_reconciliation_allocations
  drop constraint if exists bank_reconciliation_allocations_allocation_type_v6212_ck;
alter table public.bank_reconciliation_allocations
  add constraint bank_reconciliation_allocations_allocation_type_v6212_ck
  check (allocation_type in (
    'invoice','expense','transfer','exclude','customer_refund','supplier_refund',
    'payroll_pay_run','payroll_ird','owner_equity','expense_deposit_refund','stripe_payout'
  ));

-- Earlier databases retained two equivalent type checks which pre-dated
-- grouped matching. Keep their accepted values and add the isolated `group`
-- value used by both the original grouped RPC and Smart Match Sets.
alter table public.bank_transactions
  drop constraint if exists bank_recon_type_c45;
alter table public.bank_transactions
  drop constraint if exists bank_transactions_reconciliation_type_c45;
alter table public.bank_transactions
  drop constraint if exists bank_transactions_reconciliation_type_ck;
alter table public.bank_transactions
  drop constraint if exists bank_transactions_reconciliation_type_v6212_ck;
alter table public.bank_transactions
  add constraint bank_transactions_reconciliation_type_v6212_ck
  check (reconciliation_type is null or reconciliation_type in (
    'invoice','expense','created_expense','split','group','transfer','excluded',
    'customer_refund','supplier_refund','payroll_pay_run','owner_funds_introduced',
    'director_loan_received','capital_contribution','owner_drawings','repay_owner_loan',
    'director_payment','dividend_distribution','expense_deposit_refund'
  ));

create or replace function public.v6203_group_reconcile(
  p_bank_transaction_ids uuid[],
  p_allocations jsonb,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_bid uuid:=public.current_business_id();
  v_uid uuid:=auth.uid();
  v_group public.bank_reconciliation_groups%rowtype;
  v_tx public.bank_transactions%rowtype;
  v_invoice public.invoices%rowtype;
  v_expense public.expenses%rowtype;
  v_item jsonb;
  v_tx_id uuid;
  v_target_id uuid;
  v_payment_id uuid;
  v_existing uuid;
  v_amount numeric;
  v_raw_amount numeric;
  v_tx_total numeric;
  v_bank_total numeric:=0;
  v_alloc_total numeric:=0;
  v_payment_amount numeric;
  v_prior numeric;
  v_remaining numeric;
  v_type text;
  v_note text;
  v_direction integer:=null;
  v_current_direction integer;
  v_count integer:=0;
  v_locked_count integer:=0;
  v_bank_currency text;
  v_record_currency text;
  v_business_currency text;
  v_reconciliation_type text;
begin
  if v_uid is null or v_bid is null
     or not coalesce(public.v6147_can_write_area(v_bid,'bank'),false) then
    raise exception 'Bank reconciliation write access denied' using errcode='42501';
  end if;

  if p_request_id is null
     or coalesce(array_length(p_bank_transaction_ids,1),0)=0
     or array_position(p_bank_transaction_ids,null) is not null
     or p_allocations is null
     or jsonb_typeof(p_allocations)<>'array'
     or jsonb_array_length(p_allocations)=0 then
    raise exception 'Transactions, allocations and request ID are required';
  end if;

  -- Serialise retries before checking the idempotency record. A repeated network
  -- request returns its original result instead of raising a unique-key error.
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,6212));
  select * into v_group
  from public.bank_reconciliation_groups
  where business_id=v_bid and request_id=p_request_id;
  if found then
    return jsonb_build_object(
      'status',v_group.status,'group_id',v_group.id,
      'bank_total',v_group.bank_total,'allocation_total',v_group.allocation_total,
      'transaction_count',v_group.transaction_count,'allocation_count',v_group.allocation_count,
      'replayed',true
    );
  end if;

  if (select count(*) from unnest(p_bank_transaction_ids) x)
     <>(select count(distinct x) from unnest(p_bank_transaction_ids) x) then
    raise exception 'A bank transaction was selected more than once';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_allocations) x
    where jsonb_typeof(x)<>'object'
       or nullif(x->>'bank_transaction_id','') is null
       or nullif(x->>'type','') is null
       or nullif(x->>'amount','') is null
       or (x->>'amount') !~ '^[0-9]+([.][0-9]{1,2})?$'
  ) then
    raise exception 'Every allocation requires a transaction, type and positive amount with no more than two decimals';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_allocations) x
    where not ((x->>'bank_transaction_id')::uuid=any(p_bank_transaction_ids))
  ) then
    raise exception 'An allocation references an unselected bank transaction';
  end if;

  select upper(coalesce(nullif(trim(settings->>'currency'),''),'NZD'))
    into v_business_currency
  from public.businesses where id=v_bid;
  v_business_currency:=coalesce(v_business_currency,'NZD');

  -- Lock all bank rows in a deterministic order and validate each bank line.
  for v_tx in
    select * from public.bank_transactions
    where business_id=v_bid and id=any(p_bank_transaction_ids)
    order by id for update
  loop
    v_locked_count:=v_locked_count+1;
    perform pg_advisory_xact_lock(hashtextextended(v_tx.id::text,6203));
    if coalesce(v_tx.status,'unreconciled')<>'unreconciled' then
      raise exception 'A selected bank transaction is already reconciled';
    end if;
    if round(v_tx.amount,2)=0 then
      raise exception 'Zero-value bank transactions cannot be grouped';
    end if;
    v_current_direction:=case when v_tx.amount>0 then 1 else -1 end;
    if v_direction is null then v_direction:=v_current_direction;
    elsif v_direction<>v_current_direction then
      raise exception 'A match set cannot mix money in and money out';
    end if;

    select upper(trim(currency)) into v_bank_currency
    from public.bank_accounts
    where id=v_tx.bank_account_id and business_id=v_bid;
    if v_bank_currency is null then
      raise exception 'The bank account for a selected transaction was not found';
    end if;

    v_tx_total:=round(abs(v_tx.amount),2);
    select round(coalesce(sum((x->>'amount')::numeric),0),2)
      into v_alloc_total
    from jsonb_array_elements(p_allocations) x
    where (x->>'bank_transaction_id')::uuid=v_tx.id;
    if abs(v_tx_total-v_alloc_total)>0.005 then
      raise exception 'Allocations for bank transaction % must equal %',v_tx.id,v_tx_total;
    end if;
    v_bank_total:=v_bank_total+v_tx_total;
  end loop;

  if v_locked_count<>array_length(p_bank_transaction_ids,1) then
    raise exception 'A selected bank transaction was not found in this business';
  end if;

  -- Lock every target in deterministic order. This closes simultaneous-user
  -- races before payment guards recalculate outstanding balances.
  perform 1 from public.invoices
  where business_id=v_bid and id in (
    select distinct nullif(x->>'invoice_id','')::uuid
    from jsonb_array_elements(p_allocations) x where x->>'type'='invoice'
  ) order by id for update;
  perform 1 from public.expenses
  where business_id=v_bid and id in (
    select distinct nullif(x->>'expense_id','')::uuid
    from jsonb_array_elements(p_allocations) x where x->>'type'='expense'
  ) order by id for update;
  perform 1 from public.customer_payments
  where business_id=v_bid and id in (
    select distinct nullif(x->>'existing_customer_payment_id','')::uuid
    from jsonb_array_elements(p_allocations) x where x->>'type'='invoice'
  ) order by id for update;
  perform 1 from public.expense_payments
  where business_id=v_bid and id in (
    select distinct nullif(x->>'existing_expense_payment_id','')::uuid
    from jsonb_array_elements(p_allocations) x where x->>'type'='expense'
  ) order by id for update;

  insert into public.bank_reconciliation_groups(business_id,request_id,status,created_by)
  values(v_bid,p_request_id,'pending',v_uid)
  returning * into v_group;

  v_alloc_total:=0;
  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_payment_id:=null; v_existing:=null; v_note:=null;
    v_tx_id:=(v_item->>'bank_transaction_id')::uuid;
    select * into v_tx from public.bank_transactions
    where id=v_tx_id and business_id=v_bid;
    if not found then raise exception 'A selected bank transaction was not found'; end if;

    v_type:=v_item->>'type';
    v_raw_amount:=(v_item->>'amount')::numeric;
    v_amount:=round(v_raw_amount,2);
    if v_amount<=0 or abs(v_raw_amount-v_amount)>0.0001 then
      raise exception 'Allocation amounts must be positive and rounded to cents';
    end if;
    select upper(trim(currency)) into v_bank_currency
    from public.bank_accounts where id=v_tx.bank_account_id and business_id=v_bid;

    if v_type='invoice' then
      if v_tx.amount<=0 then raise exception 'Invoices require money-in transactions'; end if;
      v_target_id:=nullif(v_item->>'invoice_id','')::uuid;
      if v_target_id is null then raise exception 'Invoice allocation is missing its invoice'; end if;
      select * into v_invoice from public.invoices
      where id=v_target_id and business_id=v_bid;
      if not found then raise exception 'Invoice was not found in this business'; end if;
      if coalesce(v_invoice.lifecycle_state,'issued')<>'issued' then
        raise exception 'Only issued invoices can be reconciled';
      end if;
      v_record_currency:=v_business_currency;
      if v_bank_currency<>v_record_currency then
        raise exception 'Bank and invoice currencies do not match';
      end if;

      v_existing:=nullif(v_item->>'existing_customer_payment_id','')::uuid;
      if v_existing is not null then
        select amount into v_payment_amount from public.customer_payments
        where id=v_existing and invoice_id=v_target_id and business_id=v_bid;
        if not found then raise exception 'Existing customer payment was not found for the selected invoice'; end if;
        select coalesce(sum(amount),0) into v_prior
        from public.bank_reconciliation_allocations
        where business_id=v_bid
          and (existing_customer_payment_id=v_existing or customer_payment_id=v_existing);
        v_remaining:=greatest(v_payment_amount-v_prior,0);
        if v_amount>v_remaining+0.005 then
          raise exception 'Allocations exceed the remaining unmatched customer payment';
        end if;
        v_note:='v6212:existing_payment';
      else
        if exists (
          select 1 from public.accounting_periods p
          where p.business_id=v_bid and v_tx.transaction_date between p.period_start and p.period_end
            and p.status<>'open'
        ) then raise exception 'A new payment cannot be created inside a closed accounting period'; end if;
        v_remaining:=greatest(coalesce(v_invoice.balance_due,v_invoice.total-coalesce(v_invoice.amount_paid,0)),0);
        if v_amount>v_remaining+0.005 then
          raise exception 'Allocation exceeds the invoice outstanding balance';
        end if;
        insert into public.customer_payments(
          business_id,invoice_id,payment_date,amount,currency,reference,notes,created_by
        ) values(
          v_bid,v_target_id,v_tx.transaction_date,v_amount,v_bank_currency,
          coalesce(v_tx.reference,v_tx.description),'Created by Smart Match Set',v_uid
        ) returning id into v_payment_id;
        v_note:='v6212:created_payment';
      end if;

      insert into public.bank_reconciliation_allocations(
        business_id,bank_transaction_id,allocation_type,amount,invoice_id,
        customer_payment_id,existing_customer_payment_id,reconciliation_group_id,note,created_by
      ) values(
        v_bid,v_tx.id,'invoice',v_amount,v_target_id,
        v_payment_id,v_existing,v_group.id,v_note,v_uid
      );

    elsif v_type='expense' then
      if v_tx.amount>=0 then raise exception 'Expenses require money-out transactions'; end if;
      v_target_id:=nullif(v_item->>'expense_id','')::uuid;
      if v_target_id is null then raise exception 'Expense allocation is missing its expense'; end if;
      select * into v_expense from public.expenses
      where id=v_target_id and business_id=v_bid;
      if not found or coalesce(v_expense.archived,false)
         or v_expense.payment_status='draft'
         or coalesce(v_expense.lifecycle_state,'recorded')<>'recorded' then
        raise exception 'Only active recorded expenses can be reconciled';
      end if;
      v_record_currency:=upper(trim(coalesce(v_expense.currency,v_business_currency)));
      if v_bank_currency<>v_record_currency then
        raise exception 'Bank and expense currencies do not match';
      end if;

      v_existing:=nullif(v_item->>'existing_expense_payment_id','')::uuid;
      if v_existing is not null then
        select amount into v_payment_amount from public.expense_payments
        where id=v_existing and expense_id=v_target_id and business_id=v_bid;
        if not found then raise exception 'Existing expense payment was not found for the selected expense'; end if;
        select coalesce(sum(amount),0) into v_prior
        from public.bank_reconciliation_allocations
        where business_id=v_bid and expense_payment_id=v_existing;
        v_remaining:=greatest(v_payment_amount-v_prior,0);
        if v_amount>v_remaining+0.005 then
          raise exception 'Allocations exceed the remaining unmatched expense payment';
        end if;
        v_payment_id:=v_existing;
        v_note:='v6212:existing_payment';
      else
        if exists (
          select 1 from public.accounting_periods p
          where p.business_id=v_bid and v_tx.transaction_date between p.period_start and p.period_end
            and p.status<>'open'
        ) then raise exception 'A new payment cannot be created inside a closed accounting period'; end if;
        v_remaining:=greatest(coalesce(v_expense.outstanding_balance,0),0);
        if v_amount>v_remaining+0.005 then
          raise exception 'Allocation exceeds the expense outstanding balance';
        end if;
        insert into public.expense_payments(
          business_id,expense_id,payment_date,amount,payment_method,reference,notes,
          reconciled,reconciled_at,reconciled_by,reconciliation_requirement,created_by
        ) values(
          v_bid,v_target_id,v_tx.transaction_date,v_amount,'Bank reconciliation',v_tx.reference,
          'Created by Smart Match Set',true,now(),v_uid,'bank_match',v_uid
        ) returning id into v_payment_id;
        v_note:='v6212:created_payment';
      end if;

      insert into public.bank_reconciliation_allocations(
        business_id,bank_transaction_id,allocation_type,amount,expense_id,
        expense_payment_id,reconciliation_group_id,note,created_by
      ) values(
        v_bid,v_tx.id,'expense',v_amount,v_target_id,
        v_payment_id,v_group.id,v_note,v_uid
      );
    else
      raise exception 'Smart Match Sets only support invoice and expense allocations';
    end if;

    v_alloc_total:=v_alloc_total+v_amount;
    v_count:=v_count+1;
  end loop;

  if abs(v_bank_total-v_alloc_total)>0.005 then
    raise exception 'Match Set allocations do not equal the selected bank total';
  end if;

  -- Preserve the familiar history label for an ordinary one-to-one match.
  -- Combined matches use `group`, while their allocation rows retain the
  -- exact invoice/expense targets used by reporting and undo.
  v_reconciliation_type:=case
    when array_length(p_bank_transaction_ids,1)=1 and v_count=1 then v_type
    else 'group'
  end;

  update public.bank_transactions
  set status='reconciled',reconciliation_type=v_reconciliation_type,reconciled_at=now(),
      reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
  where business_id=v_bid and id=any(p_bank_transaction_ids) and status='unreconciled';
  if not found then raise exception 'A selected bank transaction changed during reconciliation'; end if;

  update public.bank_reconciliation_groups
  set status='completed',bank_total=v_bank_total,allocation_total=v_alloc_total,
      transaction_count=array_length(p_bank_transaction_ids,1),allocation_count=v_count,
      completed_at=now()
  where id=v_group.id;

  insert into public.bank_reconciliation_audit(
    business_id,bank_transaction_id,action,details,created_by
  )
  select v_bid,x,'smart_match_set_reconciled',jsonb_build_object(
    'group_id',v_group.id,'request_id',p_request_id,'bank_total',v_bank_total,
    'allocation_total',v_alloc_total,'allocation_count',v_count
  ),v_uid
  from unnest(p_bank_transaction_ids) x;

  return jsonb_build_object(
    'status','completed','group_id',v_group.id,'bank_total',v_bank_total,
    'allocation_total',v_alloc_total,'transaction_count',array_length(p_bank_transaction_ids,1),
    'allocation_count',v_count,'replayed',false
  );
end$$;

-- Undo recognises both the original and Smart Match Set payment markers.
create or replace function public.v6203_undo_reconciliation_group(
  p_group_id uuid,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_bid uuid:=public.current_business_id();
  v_uid uuid:=auth.uid();
  v_group public.bank_reconciliation_groups%rowtype;
  v_row record;
  v_ids uuid[];
begin
  if v_uid is null or v_bid is null
     or not coalesce(public.v6147_can_write_area(v_bid,'bank'),false) then
    raise exception 'Bank reconciliation write access denied' using errcode='42501';
  end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'An undo reason is required'; end if;

  select * into v_group from public.bank_reconciliation_groups
  where id=p_group_id and business_id=v_bid for update;
  if not found then raise exception 'Reconciliation group not found'; end if;
  if v_group.status='undone' then
    return jsonb_build_object('status','undone','group_id',p_group_id,'replayed',true);
  end if;
  if v_group.status<>'completed' then raise exception 'Only completed reconciliation groups can be undone'; end if;

  select array_agg(distinct bank_transaction_id order by bank_transaction_id)
    into v_ids
  from public.bank_reconciliation_allocations
  where business_id=v_bid and reconciliation_group_id=p_group_id;
  if coalesce(array_length(v_ids,1),0)=0 then raise exception 'Reconciliation group has no allocations'; end if;

  perform 1 from public.bank_transactions
  where business_id=v_bid and id=any(v_ids) order by id for update;

  for v_row in
    delete from public.bank_reconciliation_allocations
    where business_id=v_bid and reconciliation_group_id=p_group_id
    returning customer_payment_id,expense_payment_id,note
  loop
    if v_row.note in ('v6203:created_payment','v6212:created_payment')
       and v_row.customer_payment_id is not null then
      delete from public.customer_payments
      where id=v_row.customer_payment_id and business_id=v_bid;
    end if;
    if v_row.note in ('v6203:created_payment','v6212:created_payment')
       and v_row.expense_payment_id is not null then
      delete from public.expense_payments
      where id=v_row.expense_payment_id and business_id=v_bid;
    end if;
  end loop;

  update public.bank_transactions
  set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,
      updated_at=now(),updated_by=v_uid
  where business_id=v_bid and id=any(v_ids);
  update public.bank_reconciliation_groups
  set status='undone',undone_at=now(),undone_by=v_uid,undo_reason=trim(p_reason)
  where id=p_group_id;
  insert into public.bank_reconciliation_audit(
    business_id,bank_transaction_id,action,details,created_by
  )
  select v_bid,x,'group_undo',jsonb_build_object('group_id',p_group_id,'reason',trim(p_reason)),v_uid
  from unnest(v_ids) x;

  return jsonb_build_object(
    'status','undone','group_id',p_group_id,
    'transaction_count',array_length(v_ids,1),'replayed',false
  );
end$$;

revoke execute on function public.v6203_group_reconcile(uuid[],jsonb,uuid) from public,anon;
revoke execute on function public.v6203_undo_reconciliation_group(uuid,text) from public,anon;
grant execute on function public.v6203_group_reconcile(uuid[],jsonb,uuid) to authenticated;
grant execute on function public.v6203_undo_reconciliation_group(uuid,text) to authenticated;

-- Consolidated from the earlier standalone v6203 index migration so this
-- complete GitHub replacement remains within the 100-file upload limit.
-- All statements are idempotent and the indexes already present in existing
-- databases are left unchanged.
create index if not exists bank_reconciliation_allocations_group_fk_v6203_idx
  on public.bank_reconciliation_allocations(reconciliation_group_id)
  where reconciliation_group_id is not null;

create index if not exists bank_reconciliation_allocations_existing_customer_payment_v6203_idx
  on public.bank_reconciliation_allocations(existing_customer_payment_id)
  where existing_customer_payment_id is not null;

create index if not exists bank_reconciliation_allocations_invoice_payment_transaction_v62_idx
  on public.bank_reconciliation_allocations(invoice_payment_transaction_id)
  where invoice_payment_transaction_id is not null;

commit;
