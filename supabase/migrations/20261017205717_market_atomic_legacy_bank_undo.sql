-- Market reliability: one transaction for the remaining legacy invoice/transfer/exclusion undo.
-- This operation runs with the caller's existing RLS permissions. Specialized undo RPCs retain ownership.
create or replace function public.v6222_undo_legacy_bank_transaction(
 p_business_id uuid,p_bank_transaction_id uuid,p_reason text,
 p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 v_uid uuid:=auth.uid();v_tx public.bank_transactions%rowtype;
 v_a public.bank_reconciliation_allocations%rowtype;v_p public.customer_payments%rowtype;
 v_remove uuid[]:=array[]::uuid[];v_count integer:=0;v_removed integer:=0;v_audit jsonb;
begin
 if v_uid is null or p_business_id is distinct from public.current_business_id()
    or not coalesce(public.v6147_can_write_area(p_business_id,'bank'),false) then
  raise exception 'Bank reconciliation write access denied' using errcode='42501';
 end if;
 if length(btrim(coalesce(p_reason,'')))<3 or length(p_reason)>1000 then
  raise exception 'Enter an undo reason between 3 and 1,000 characters' using errcode='22023';
 end if;
 select * into v_tx from public.bank_transactions
 where business_id=p_business_id and id=p_bank_transaction_id for update;
 if not found then raise exception 'Bank transaction not found for this business' using errcode='42501';end if;
 if v_tx.status='unreconciled' and not exists(select 1 from public.bank_reconciliation_allocations where business_id=p_business_id and bank_transaction_id=v_tx.id) then
  return jsonb_build_object('ok',true,'replayed',true,'removed_payment_count',0);
 end if;
 if not coalesce(public.v6169a_accountant_centre_access(p_business_id,false),false) then
  raise exception 'Accounting review access is required to verify this legacy bank undo' using errcode='42501';
 end if;
 if exists(select 1 from public.accounting_journals where business_id=p_business_id and source_id=v_tx.id and status in ('posted','reversed')) then
  raise exception 'This bank transaction has posted accounting entries. Use its journal reversal workflow. No records were changed.';
 end if;
 if v_tx.status not in ('reconciled','excluded') then raise exception 'This bank transaction cannot be undone from its current status';end if;
 if p_expected_updated_at is not null and v_tx.updated_at is distinct from p_expected_updated_at then
  raise exception 'The bank transaction changed. Refresh its history before undoing it.' using errcode='40001';
 end if;
 for v_a in select * from public.bank_reconciliation_allocations
  where business_id=p_business_id and bank_transaction_id=v_tx.id order by id for update
 loop
  v_count:=v_count+1;
  if v_a.allocation_type not in ('invoice','transfer','exclude') or v_a.reconciliation_group_id is not null
     or v_a.accounting_journal_id is not null or v_a.expense_id is not null or v_a.expense_payment_id is not null
     or coalesce(v_a.created_expense,false) or v_a.related_bank_transaction_id is not null
     or v_a.invoice_payment_transaction_id is not null then
   raise exception 'This bank match requires its specialized undo workflow. No records were changed.';
  end if;
  if v_a.customer_payment_id is not null then
   if v_a.allocation_type<>'invoice' or v_a.invoice_id is null or v_a.existing_customer_payment_id is not null then
    raise exception 'The payment origin is ambiguous. No records were changed.';
   end if;
   select * into v_p from public.customer_payments
   where id=v_a.customer_payment_id and business_id=p_business_id and invoice_id=v_a.invoice_id for update;
   if not found then raise exception 'The linked payment could not be verified. No records were changed.';end if;
   select details into v_audit from public.bank_reconciliation_audit
   where business_id=p_business_id and bank_transaction_id=v_tx.id and action='reconciled'
   order by created_at desc,id desc limit 1;
   if v_p.notes is distinct from 'Created by bank reconciliation' or v_audit->>'existing_payment' is distinct from 'false'
      or v_audit->>'target_id' is distinct from v_a.invoice_id::text
      or v_p.invoice_payment_transaction_id is not null or v_p.stripe_payment_intent_id is not null
      or v_p.stripe_checkout_session_id is not null then
    raise exception 'The payment origin could not be verified. No records were changed.';
   end if;
   if exists(select 1 from public.bank_reconciliation_allocations where business_id=p_business_id and id<>v_a.id
    and (customer_payment_id=v_p.id or existing_customer_payment_id=v_p.id)) then
    raise exception 'The payment is used by another bank match. No records were changed.';
   end if;
   if not exists(select 1 from public.accounting_periods where business_id=p_business_id and v_p.payment_date between period_start and period_end and status='open') then raise exception 'The payment is in a closed or unavailable accounting period. No records were changed.';end if;
   if exists(select 1 from public.accounting_journals where business_id=p_business_id and source_id=v_p.id and status in ('posted','reversed')) then
    raise exception 'This payment has posted accounting entries. Review its journal reversal before undoing the bank match. No records were changed.';
   end if;
   if not coalesce(public.v6147_can_write_area(p_business_id,'core'),false) then
    raise exception 'Payment write access is required to undo this match' using errcode='42501';
   end if;
   v_remove:=array_append(v_remove,v_p.id);
  end if;
 end loop;
 if v_tx.reconciliation_type='invoice' and v_count=0 then raise exception 'Invoice match evidence is missing. No records were changed.';end if;
 delete from public.bank_reconciliation_allocations where business_id=p_business_id and bank_transaction_id=v_tx.id;
 get diagnostics v_removed=row_count;
 if v_removed<>v_count then raise exception 'The allocation changed or access was denied. No records were changed.' using errcode='42501';end if;
 delete from public.customer_payments where business_id=p_business_id and id=any(v_remove);
 get diagnostics v_removed=row_count;
 if v_removed<>cardinality(v_remove) then raise exception 'Payment removal was denied. No records were changed.' using errcode='42501';end if;
 update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,
  excluded_reason=null,transfer_bank_account_id=null,updated_at=now(),updated_by=v_uid
 where id=v_tx.id and business_id=p_business_id;
 if not found then raise exception 'Bank transaction update was denied. No records were changed.' using errcode='42501';end if;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
 values(p_business_id,v_tx.id,'legacy_undo_atomic',jsonb_build_object('reason',btrim(p_reason),'removed_payment_ids',v_remove,'allocation_count',v_count),v_uid);
 return jsonb_build_object('ok',true,'replayed',false,'removed_payment_count',cardinality(v_remove));
end$$;
revoke all on function public.v6222_undo_legacy_bank_transaction(uuid,uuid,text,timestamptz) from public,anon;
grant execute on function public.v6222_undo_legacy_bank_transaction(uuid,uuid,text,timestamptz) to authenticated;
