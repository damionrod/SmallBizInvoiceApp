-- Receipt posting repair: reuse existing journals, payments and reconciliation links.
CREATE OR REPLACE FUNCTION public.frindly_default_manual_receipt_bank()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $body$
begin
 if new.bank_account_id is null and coalesce(new.payment_source,'manual')='manual'
 and new.invoice_payment_transaction_id is null and not coalesce(new.is_legacy_estimate,false) then
  select b.id into new.bank_account_id from public.bank_accounts b
  join public.accounting_accounts a on a.id=b.accounting_account_id and a.business_id=b.business_id
  where b.business_id=new.business_id and b.is_default and not b.archived and not a.archived
  and (a.account_type='bank' or (a.account_type='asset' and a.account_subtype='bank'))
  and (select count(*) from public.bank_accounts x where x.business_id=new.business_id and x.is_default and not x.archived)=1;
  if new.bank_account_id is null then raise exception 'Select a receiving bank account before recording this receipt'; end if;
 end if;
 return new;
end $body$;
REVOKE ALL ON FUNCTION public.frindly_default_manual_receipt_bank() FROM public,anon,authenticated;
CREATE TRIGGER frindly_default_manual_receipt_bank BEFORE INSERT ON public.customer_payments
FOR EACH ROW EXECUTE FUNCTION public.frindly_default_manual_receipt_bank();
DROP TRIGGER v6216_post_selected_customer_receipt_trg ON public.customer_payments;
CREATE TRIGGER v6216_post_selected_customer_receipt_trg AFTER INSERT OR UPDATE OF bank_account_id ON public.customer_payments
FOR EACH ROW WHEN (new.bank_account_id IS NOT NULL) EXECUTE FUNCTION public.v6216_post_selected_customer_receipt();
CREATE OR REPLACE FUNCTION public.v6203_group_reconcile(p_bank_transaction_ids uuid[], p_allocations jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        if exists(select 1 from public.customer_payments where id=v_existing and business_id=v_bid and bank_account_id is not null and bank_account_id<>v_tx.bank_account_id) then
          raise exception 'Recorded receipt bank differs from the selected statement bank; review the payment first';
        end if;
        update public.customer_payments set bank_account_id=v_tx.bank_account_id
        where id=v_existing and business_id=v_bid and bank_account_id is null;
        perform public.v6170b_post_source('customer_payment',v_existing,'receipt_existing_match');
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
          business_id,invoice_id,payment_date,amount,currency,reference,notes,created_by,bank_account_id
        ) values(
          v_bid,v_target_id,v_tx.transaction_date,v_amount,v_bank_currency,
          coalesce(v_tx.reference,v_tx.description),'Created by Smart Match Set',v_uid,v_tx.bank_account_id
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
end$function$;
CREATE OR REPLACE FUNCTION public.v6219l_match_paid_migration(p_bank_transaction_id uuid, p_invoice_id uuid, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bid uuid:=public.current_business_id(); v_tx public.bank_transactions%rowtype;
 v_inv public.invoices%rowtype; v_payment uuid; v_paid numeric; v_prior numeric; v_currency text; v_bank_currency text;
begin
 if auth.uid() is null or v_bid is null or not public.v6147_can_write_area(v_bid,'bank') then
   raise exception 'Bank reconciliation access denied' using errcode='42501';
 end if;
 if p_bank_transaction_id is null or p_invoice_id is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then
   raise exception 'A valid bank transaction, invoice and cents amount are required';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_bank_transaction_id::text,6203));
 select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
 if not found or v_tx.status<>'unreconciled' or v_tx.amount<=0 then raise exception 'Bank deposit is no longer available for matching';end if;
 if abs(v_tx.amount-p_amount)>0.005 then raise exception 'Bank deposit must match the allocation amount';end if;
 select * into v_inv from public.invoices where id=p_invoice_id and business_id=v_bid for update;
 if not found or v_inv.lifecycle_state<>'issued' then raise exception 'Invoice is not an issued invoice';end if;
 select coalesce(sum(amount),0) into v_paid from public.customer_payments where business_id=v_bid and invoice_id=p_invoice_id;
 if v_paid+p_amount>least(v_inv.total,coalesce(v_inv.amount_paid,0))+0.005 then
   raise exception 'Bank evidence exceeds the historical paid amount; use the standard payment matching route';
 end if;
 select upper(coalesce(nullif(trim(b.settings->>'currency'),''),'NZD')) into v_currency
 from public.businesses b where b.id=v_bid;
 select upper(trim(a.currency)) into v_bank_currency from public.bank_accounts a where a.id=v_tx.bank_account_id and a.business_id=v_bid;
 if v_bank_currency is null or v_bank_currency<>coalesce(v_currency,'NZD') then raise exception 'Bank and invoice currencies do not match';end if;
 select coalesce(sum(amount),0) into v_prior from public.bank_reconciliation_allocations
 where business_id=v_bid and invoice_id=p_invoice_id;
 if v_prior+p_amount>least(v_inv.total,coalesce(v_inv.amount_paid,0))+0.005 then
   raise exception 'Matching would exceed the historical paid amount';end if;
 insert into public.customer_payments(business_id,invoice_id,payment_date,amount,currency,reference,notes,created_by,bank_account_id,is_legacy_estimate)
 values(v_bid,p_invoice_id,v_tx.transaction_date,p_amount,v_currency,v_tx.reference,
 'Historical paid invoice: precise receipt restored from bank evidence',auth.uid(),v_tx.bank_account_id,false) returning id into v_payment;
 -- Retain the previously imported paid marker until all of its bank evidence is linked.
 update public.invoices set amount_paid=v_inv.amount_paid,balance_due=v_inv.balance_due where business_id=v_bid and id=p_invoice_id;
 insert into public.bank_reconciliation_allocations
 (business_id,bank_transaction_id,allocation_type,amount,invoice_id,note,created_by,customer_payment_id)
 values(v_bid,v_tx.id,'invoice',p_amount,p_invoice_id,'Historical receipt linked to original bank evidence',auth.uid(),v_payment);
 update public.bank_transactions set status='reconciled',reconciliation_type='invoice',reconciled_at=now(),
 reconciled_by=auth.uid(),updated_by=auth.uid(),updated_at=now()
 where id=v_tx.id and business_id=v_bid and status='unreconciled';
 if not found then raise exception 'Bank transaction changed during reconciliation';end if;
 return jsonb_build_object('status','reconciled','invoice_id',p_invoice_id,'bank_transaction_id',v_tx.id,'amount',p_amount,'new_payment_created',true,'customer_payment_id',v_payment);
end;
$function$;
CREATE OR REPLACE FUNCTION public.v6219l_paid_migration_candidates()
 RETURNS TABLE(invoice_id uuid, unmatched_amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
 select i.id,round(greatest(0,least(i.total,coalesce(i.amount_paid,0))-coalesce(a.allocated,0)),2)
 from public.invoices i
 left join lateral (
   select sum(bra.amount) allocated from public.bank_reconciliation_allocations bra
   where bra.business_id=i.business_id and bra.invoice_id=i.id
 ) a on true
 where i.business_id=public.current_business_id()
   and public.v6147_can_read_area(i.business_id,'bank')
   and i.lifecycle_state='issued' and coalesce(i.amount_paid,0)>0
   and coalesce((select sum(cp.amount) from public.customer_payments cp where cp.business_id=i.business_id and cp.invoice_id=i.id),0)<least(i.total,coalesce(i.amount_paid,0))-0.005
   and least(i.total,coalesce(i.amount_paid,0))>coalesce(a.allocated,0)+0.005;
$function$;
CREATE OR REPLACE FUNCTION public.v6170b_payment_account(p_bid uuid, p_source_type text, p_source_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_account uuid;v_funding text;v_requested text;v_selected uuid;
begin
 if p_source_type='customer_payment' then
  select cp.bank_account_id into v_selected from public.customer_payments cp where cp.business_id=p_bid and cp.id=p_source_id;
  if v_selected is not null then
   select ba.accounting_account_id into v_account from public.bank_accounts ba
   join public.accounting_accounts aa on aa.id=ba.accounting_account_id and aa.business_id=ba.business_id
   where ba.business_id=p_bid and ba.id=v_selected and not coalesce(ba.archived,false)
   and not aa.archived and (aa.account_type='bank' or (aa.account_type='asset' and aa.account_subtype='bank'));
   if v_account is null then raise exception 'Selected receiving bank account is not linked to an active bank ledger'; end if;
   return v_account;
  end if;
  select ba.accounting_account_id into v_account from public.bank_reconciliation_allocations ra
  join public.bank_transactions bt on bt.id=ra.bank_transaction_id and bt.business_id=ra.business_id
  join public.bank_accounts ba on ba.id=bt.bank_account_id and ba.business_id=bt.business_id
  where ra.business_id=p_bid and (ra.customer_payment_id=p_source_id or ra.existing_customer_payment_id=p_source_id) limit 1;
 elsif p_source_type='supplier_payment' then
  select ep.funding_source,nullif(btrim(ep.bank_account),'') into v_funding,v_requested
  from public.expense_payments ep where ep.id=p_source_id and ep.business_id=p_bid;
  if v_funding='owner_personal' then return public.v6170b_account(p_bid,'owner_director_loan'); end if;
  select ba.accounting_account_id into v_account from public.bank_reconciliation_allocations ra
  join public.bank_transactions bt on bt.id=ra.bank_transaction_id and bt.business_id=ra.business_id
  join public.bank_accounts ba on ba.id=bt.bank_account_id and ba.business_id=bt.business_id
  where ra.business_id=p_bid and ra.expense_payment_id=p_source_id and ba.accounting_account_id is not null limit 1;
  if v_account is null and v_requested is not null then
   if v_requested ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select ba.accounting_account_id into v_account from public.bank_accounts ba
    join public.accounting_accounts aa on aa.id=ba.accounting_account_id and aa.business_id=ba.business_id
    where ba.business_id=p_bid and ba.id=v_requested::uuid and not coalesce(ba.archived,false)
    and not aa.archived and (aa.account_type='bank' or (aa.account_type='asset' and aa.account_subtype='bank'));
    if v_account is null then raise exception 'Selected bank account is not linked to an active bank ledger'; end if;
   else
    select ba.accounting_account_id into v_account from public.bank_accounts ba
    where ba.business_id=p_bid and not coalesce(ba.archived,false) and ba.accounting_account_id is not null
    and (ba.name=v_requested or ba.account_number=v_requested)
    and (select count(*) from public.bank_accounts bx where bx.business_id=p_bid
     and not coalesce(bx.archived,false) and bx.accounting_account_id is not null
     and (bx.name=v_requested or bx.account_number=v_requested))=1 limit 1;
   end if;
  end if;
  if v_account is null then
   select ba.accounting_account_id into v_account from public.bank_accounts ba
   where ba.business_id=p_bid and not coalesce(ba.archived,false) and ba.is_default
   and ba.accounting_account_id is not null
   and (select count(*) from public.bank_accounts bx where bx.business_id=p_bid
    and not coalesce(bx.archived,false) and bx.is_default and bx.accounting_account_id is not null)=1 limit 1;
  end if;
 end if;
 return coalesce(v_account,public.v6170b_account(p_bid,'payment_clearing'));
end $function$;

CREATE OR REPLACE FUNCTION public.v6203_undo_reconciliation_group(p_group_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
       and v_row.customer_payment_id is not null and not exists(select 1 from public.accounting_journals j where j.business_id=v_bid and j.source_type='customer_payment' and j.source_id=v_row.customer_payment_id and j.status in ('posted','reversed')) then
      delete from public.customer_payments
      where id=v_row.customer_payment_id and business_id=v_bid;
    end if;
    if v_row.note in ('v6203:created_payment','v6212:created_payment')
       and v_row.expense_payment_id is not null and not exists(select 1 from public.accounting_journals j where j.business_id=v_bid and j.source_type='supplier_payment' and j.source_id=v_row.expense_payment_id and j.status in ('posted','reversed')) then
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
end$function$;


