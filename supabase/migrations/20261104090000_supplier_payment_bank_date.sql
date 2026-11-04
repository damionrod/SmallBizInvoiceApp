CREATE OR REPLACE FUNCTION public.v61107r_match_expense_bank_transaction(p_bank_transaction_id uuid, p_expense_id uuid, p_existing_payment_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid(); v_tx public.bank_transactions%rowtype; v_exp public.expenses%rowtype; v_pay public.expense_payments%rowtype; v_alloc public.bank_reconciliation_allocations%rowtype; v_amt numeric(14,2); v_journal public.accounting_journals%rowtype; v_lines jsonb; v_reversal uuid; v_replacement uuid; v_bank_gl uuid;
begin
 if v_uid is null then raise exception 'Authentication required'; end if;
 if v_bid is null then raise exception 'No active authorised business'; end if;
 if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;
 select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
 if v_tx.id is null or v_tx.amount>=0 then raise exception 'Expense bank transaction is not available'; end if;
 v_amt:=abs(v_tx.amount);
 if v_tx.status='reconciled' then return jsonb_build_object('ok',true,'result','already_reconciled'); end if;
 if v_tx.status<>'unreconciled' then raise exception 'Bank transaction is not unreconciled'; end if;
 select * into v_exp from public.expenses where id=p_expense_id and business_id=v_bid and coalesce(archived,false)=false and coalesce(lifecycle_state,'recorded')='recorded' for update;
 if v_exp.id is null then raise exception 'Active expense was not found'; end if;

 select * into v_alloc from public.bank_reconciliation_allocations where business_id=v_bid and bank_transaction_id=v_tx.id and expense_id=v_exp.id order by created_at desc limit 1;
 if v_alloc.id is not null then
   update public.bank_transactions set status='reconciled',reconciliation_type='expense',reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid where id=v_tx.id and business_id=v_bid;
   return jsonb_build_object('ok',true,'result','finished_existing_allocation','expense_number',v_exp.expense_number);
 end if;

 if p_existing_payment_id is not null then
   select * into v_pay from public.expense_payments where id=p_existing_payment_id and business_id=v_bid and expense_id=v_exp.id for update;
   if v_pay.id is null or abs(coalesce(v_pay.amount,0)-v_amt)>0.01 then raise exception 'Existing expense payment does not match the bank amount'; end if;
   if exists(select 1 from public.bank_reconciliation_allocations where business_id=v_bid and expense_payment_id=v_pay.id) then raise exception 'Existing expense payment is already linked to another bank transaction'; end if;
   if v_pay.payment_date is distinct from v_tx.transaction_date then
     if v_pay.amount<>v_amt or v_pay.funding_source='owner_personal' then
       raise exception 'Only an exact business-bank payment can be date-corrected when matched';
     end if;
     select * into v_journal from public.accounting_journals where business_id=v_bid
       and source_type='supplier_payment' and source_id=v_pay.id and status='posted' for update;
     if not found or (select count(*) from public.accounting_journals where business_id=v_bid and source_type='supplier_payment' and source_id=v_pay.id and status='posted')<>1 then
       raise exception 'One active supplier payment journal is required before correcting its date';
     end if;
     select accounting_account_id into v_bank_gl from public.bank_accounts
       where business_id=v_bid and id=v_tx.bank_account_id and not archived;
     if v_bank_gl is null or not exists(select 1 from public.accounting_journal_lines
       where business_id=v_bid and journal_id=v_journal.id and account_id=v_bank_gl and credit=v_amt) then
       raise exception 'The posted payment uses a different bank account; review its posting before matching';
     end if;
     perform frindly_cash.check_date(v_bid,v_pay.payment_date);
     perform frindly_cash.check_date(v_bid,v_tx.transaction_date);
     if v_journal.journal_date<>v_tx.transaction_date then
       select jsonb_agg(to_jsonb(l) order by l.id) into v_lines from public.accounting_journal_lines l
         where l.business_id=v_bid and l.journal_id=v_journal.id;
       v_reversal:=frindly_cash.reverse_at(v_bid,v_journal.id,'Supplier payment bank statement date correction');
       v_replacement:=public.v6170a_post_journal(v_tx.transaction_date,'supplier_payment',v_pay.id,
         v_journal.source_reference,v_journal.description,v_journal.journal_type,v_lines,
         (select max(posting_version)+1 from public.accounting_journals where business_id=v_bid and source_type='supplier_payment' and source_id=v_pay.id),
         'supplier_payment_bank_date_correction');
     end if;
     update public.expense_payments set payment_date=v_tx.transaction_date where business_id=v_bid and id=v_pay.id;
     insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by)
     values(v_bid,'expense_payment',v_pay.id,'bank_date_corrected',
       jsonb_build_object('old_date',v_pay.payment_date,'new_date',v_tx.transaction_date,'bank_transaction_id',v_tx.id,
         'original_journal_id',v_journal.id,'reversal_journal_id',v_reversal,'replacement_journal_id',v_replacement),v_uid);
   end if;
 else
   if coalesce(v_exp.outstanding_balance,0)+0.01 < v_amt then raise exception 'Bank amount exceeds the expense outstanding balance'; end if;
   insert into public.expense_payments(business_id,expense_id,payment_date,amount,payment_method,bank_account,reference,notes,reconciled,reconciled_at,reconciled_by,bank_transaction_reference,created_by)
   values(v_bid,v_exp.id,v_tx.transaction_date,v_amt,'Bank reconciliation',null,v_tx.reference,'Created by atomic bank reconciliation',true,now(),v_uid,coalesce(v_tx.bank_transaction_id,v_tx.reference),v_uid) returning * into v_pay;
 end if;

 insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,expense_id,expense_payment_id,created_expense,created_by)
 values(v_bid,v_tx.id,'expense',v_amt,v_exp.id,v_pay.id,false,v_uid);
 update public.expense_payments set reconciled=true,reconciled_at=now(),reconciled_by=v_uid,bank_transaction_reference=coalesce(v_tx.bank_transaction_id,v_tx.reference,v_tx.id::text) where id=v_pay.id and business_id=v_bid and expense_id=v_exp.id;

 update public.bank_transactions set status='reconciled',reconciliation_type='expense',reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid where id=v_tx.id and business_id=v_bid;

 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
 values(v_bid,v_tx.id,'expense_reconciled_atomic',jsonb_build_object('expense_id',v_exp.id,'payment_id',v_pay.id,'amount',v_amt,'existing_payment',p_existing_payment_id is not null,'atomic',true),v_uid);
 return jsonb_build_object('ok',true,'result','reconciled','expense_number',v_exp.expense_number);
end $function$;
