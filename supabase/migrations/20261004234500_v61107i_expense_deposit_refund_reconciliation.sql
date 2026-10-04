-- v61.107I: pair a supplier deposit/payment and refund to one existing net expense.
-- Additive only: preserves both bank transactions and does not alter expense/GST values.

alter table if exists public.bank_reconciliation_allocations
  add column if not exists related_bank_transaction_id uuid null references public.bank_transactions(id) on delete restrict;
create index if not exists bank_recon_alloc_related_bank_tx_idx
  on public.bank_reconciliation_allocations(related_bank_transaction_id)
  where related_bank_transaction_id is not null;

alter table public.bank_reconciliation_allocations drop constraint if exists bank_reconciliation_allocations_allocation_type_ck;
alter table public.bank_reconciliation_allocations add constraint bank_reconciliation_allocations_allocation_type_ck
  check (allocation_type = any(array['invoice','expense','transfer','customer_refund','supplier_refund','payroll_pay_run','owner_equity','expense_deposit_refund']::text[]));

alter table public.bank_transactions drop constraint if exists bank_transactions_reconciliation_type_ck;
alter table public.bank_transactions add constraint bank_transactions_reconciliation_type_ck
  check (reconciliation_type is null or reconciliation_type = any(array['invoice','expense','created_expense','split','transfer','excluded','customer_refund','supplier_refund','payroll_pay_run','owner_funds_introduced','director_loan_received','capital_contribution','owner_drawings','repay_owner_loan','director_payment','dividend_distribution','expense_deposit_refund']::text[]));

create or replace function public.v61107i_reconcile_expense_deposit_refund(p_money_out_transaction_id uuid,p_refund_transaction_id uuid,p_expense_id uuid,p_note text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_bid uuid := public.current_business_id(); v_uid uuid := auth.uid();
  v_out public.bank_transactions%rowtype; v_ref public.bank_transactions%rowtype; v_exp public.expenses%rowtype;
  v_out_amt numeric; v_ref_amt numeric; v_net numeric;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;
  select * into v_out from public.bank_transactions where id=p_money_out_transaction_id and business_id=v_bid for update;
  select * into v_ref from public.bank_transactions where id=p_refund_transaction_id and business_id=v_bid for update;
  if v_out.id is null or v_ref.id is null then raise exception 'Related bank transaction was not found in the active business'; end if;
  if v_out.id=v_ref.id then raise exception 'Choose two different bank transactions'; end if;
  if coalesce(v_out.status,'unreconciled')<>'unreconciled' or coalesce(v_ref.status,'unreconciled')<>'unreconciled' then raise exception 'Both bank transactions must be unreconciled'; end if;
  if v_out.amount >= 0 then raise exception 'The deposit/payment transaction must be money out'; end if;
  if v_ref.amount <= 0 then raise exception 'The refund transaction must be money in'; end if;
  v_out_amt:=round(abs(v_out.amount),2); v_ref_amt:=round(v_ref.amount,2); v_net:=round(v_out_amt-v_ref_amt,2);
  if v_net<=0 then raise exception 'Refund must be less than the original deposit/payment'; end if;
  select * into v_exp from public.expenses where id=p_expense_id and business_id=v_bid and not coalesce(archived,false);
  if v_exp.id is null then raise exception 'Expense not found in the active business'; end if;
  if abs(round(coalesce(v_exp.total_amount,0),2)-v_net)>0.01 then raise exception 'Expense total (%) must equal the net bank cost (%)',round(coalesce(v_exp.total_amount,0),2),v_net; end if;
  insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,expense_id,related_bank_transaction_id,note,created_by) values
    (v_bid,v_out.id,'expense_deposit_refund',v_out_amt,v_exp.id,v_ref.id,nullif(btrim(coalesce(p_note,'')),''),v_uid),
    (v_bid,v_ref.id,'expense_deposit_refund',v_ref_amt,v_exp.id,v_out.id,nullif(btrim(coalesce(p_note,'')),''),v_uid);
  update public.bank_transactions set status='reconciled',reconciliation_type='expense_deposit_refund',reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid where business_id=v_bid and id in(v_out.id,v_ref.id);
  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values
    (v_bid,v_out.id,'expense_deposit_refund_reconciled',jsonb_build_object('expense_id',v_exp.id,'related_bank_transaction_id',v_ref.id,'money_out',v_out_amt,'refund',v_ref_amt,'net_expense',v_net),v_uid),
    (v_bid,v_ref.id,'expense_deposit_refund_reconciled',jsonb_build_object('expense_id',v_exp.id,'related_bank_transaction_id',v_out.id,'money_out',v_out_amt,'refund',v_ref_amt,'net_expense',v_net),v_uid);
  return jsonb_build_object('ok',true,'expense_id',v_exp.id,'money_out',v_out_amt,'refund',v_ref_amt,'net_expense',v_net);
end $$;
revoke execute on function public.v61107i_reconcile_expense_deposit_refund(uuid,uuid,uuid,text) from public,anon;
grant execute on function public.v61107i_reconcile_expense_deposit_refund(uuid,uuid,uuid,text) to authenticated,service_role;

create or replace function public.v61107i_undo_expense_deposit_refund(p_bank_transaction_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid(); v_related uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;
  select related_bank_transaction_id into v_related from public.bank_reconciliation_allocations where business_id=v_bid and bank_transaction_id=p_bank_transaction_id and allocation_type='expense_deposit_refund' limit 1;
  if v_related is null then raise exception 'Deposit/refund reconciliation was not found'; end if;
  delete from public.bank_reconciliation_allocations where business_id=v_bid and allocation_type='expense_deposit_refund' and bank_transaction_id in(p_bank_transaction_id,v_related);
  update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,updated_at=now(),updated_by=v_uid where business_id=v_bid and id in(p_bank_transaction_id,v_related);
  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values
    (v_bid,p_bank_transaction_id,'expense_deposit_refund_undone',jsonb_build_object('related_bank_transaction_id',v_related,'reason',coalesce(nullif(btrim(p_reason),''),'Undo deposit/refund reconciliation')),v_uid),
    (v_bid,v_related,'expense_deposit_refund_undone',jsonb_build_object('related_bank_transaction_id',p_bank_transaction_id,'reason',coalesce(nullif(btrim(p_reason),''),'Undo deposit/refund reconciliation')),v_uid);
  return jsonb_build_object('ok',true,'bank_transaction_id',p_bank_transaction_id,'related_bank_transaction_id',v_related);
end $$;
revoke execute on function public.v61107i_undo_expense_deposit_refund(uuid,text) from public,anon;
grant execute on function public.v61107i_undo_expense_deposit_refund(uuid,text) to authenticated,service_role;
