-- Frindly v61.106L
-- Narrow fix: Undo an expense CREATED by Bank Reconciliation using the existing
-- controlled C1 expense void workflow. Existing accounting/lifecycle guards remain intact.

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
  v_voided_ids uuid[] := array[]::uuid[];
  v_deleted_ids uuid[] := array[]::uuid[];
  v_payment_ids uuid[] := array[]::uuid[];
  v_count integer := 0;
  v_reason text := coalesce(nullif(btrim(p_reason),''),'Undo bank reconciliation-created expense');
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
    select id,business_id,lifecycle_version,lifecycle_state into v_exp
      from public.expenses where id=v_alloc.expense_id and business_id=v_bid for update;
    if v_exp.id is null then raise exception 'The reconciliation-created expense % was not found. No records were changed.',v_alloc.expense_id; end if;

    -- The established void RPC requires all dependencies to be resolved first.
    -- Remove ONLY the payment/allocation created by this reconciliation. The whole
    -- function is transactional, so any later failure restores these rows automatically.
    if v_alloc.expense_payment_id is not null then
      delete from public.expense_payments
       where id=v_alloc.expense_payment_id and expense_id=v_alloc.expense_id and business_id=v_bid;
      if found then v_payment_ids:=array_append(v_payment_ids,v_alloc.expense_payment_id); end if;
    end if;

    delete from public.bank_reconciliation_allocations
     where id=v_alloc.id and business_id=v_bid and bank_transaction_id=p_bank_transaction_id
       and expense_id=v_alloc.expense_id and coalesce(created_expense,false)=true;
    if not found then raise exception 'The reconciliation allocation changed while Undo was running. No records were changed.'; end if;

    if v_exp.lifecycle_version is not null and lower(coalesce(v_exp.lifecycle_state,''))='recorded' then
      -- Canonical C1 path: this reverses the existing posted expense journal through
      -- v6170a_reverse_journal and performs the protected lifecycle transition itself.
      perform public.v6170c45_void_expense(v_alloc.expense_id,v_reason);
      v_voided_ids:=array_append(v_voided_ids,v_alloc.expense_id);
    elsif v_exp.lifecycle_version is not null and lower(coalesce(v_exp.lifecycle_state,''))='voided' then
      -- Already voided: keep the audit document and only finish detaching this bank match.
      v_voided_ids:=array_append(v_voided_ids,v_alloc.expense_id);
    elsif v_exp.lifecycle_version is null or lower(coalesce(v_exp.lifecycle_state,''))='draft' then
      -- Only a genuine draft/pre-C1 record that never became a protected financial
      -- document may retain the historical physical-delete behaviour.
      delete from public.expenses where id=v_alloc.expense_id and business_id=v_bid;
      if not found then raise exception 'Draft reconciliation-created expense could not be removed. No records were changed.'; end if;
      v_deleted_ids:=array_append(v_deleted_ids,v_alloc.expense_id);
    else
      raise exception 'This reconciliation-created expense is in lifecycle state % and was not changed.',coalesce(v_exp.lifecycle_state,'unknown');
    end if;
  end loop;

  update public.bank_transactions
     set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,
         excluded_reason=null,transfer_bank_account_id=null,updated_at=now(),updated_by=v_uid
   where id=p_bank_transaction_id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values(v_bid,p_bank_transaction_id,'created_expense_undo',jsonb_build_object(
    'reason',v_reason,'voided_expense_ids',to_jsonb(v_voided_ids),
    'deleted_unposted_expense_ids',to_jsonb(v_deleted_ids),
    'removed_reconciliation_payment_ids',to_jsonb(v_payment_ids),
    'accounting_safe',true,'void_path','v6170c45_void_expense'),v_uid);

  return jsonb_build_object('ok',true,'expense_count',v_count,
    'voided_expense_ids',to_jsonb(v_voided_ids),'deleted_unposted_expense_ids',to_jsonb(v_deleted_ids));
end;
$$;

revoke execute on function public.v61106i_undo_created_expense_bank_reconciliation(uuid,text) from public,anon;
grant execute on function public.v61106i_undo_created_expense_bank_reconciliation(uuid,text) to authenticated;

-- User-facing brand correction only. Keep the legacy finlo.c1_controlled setting name:
-- it is an internal compatibility key used by the established lifecycle workflow.
create or replace function public.v6170c1_expense_lifecycle_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare controlled boolean := coalesce(current_setting('finlo.c1_controlled',true),'')='on';
begin
  if tg_op='INSERT' then
    new.lifecycle_version:=1;
    if new.payment_status='draft' then new.lifecycle_state:='draft'; new.recorded_at:=null; new.recorded_by:=null; new.financial_locked_at:=null;
    else new.lifecycle_state:='recorded'; new.recorded_at:=coalesce(new.created_at,now()); new.recorded_by:=auth.uid(); new.financial_locked_at:=now(); end if;
    new.voided_at:=null; new.voided_by:=null; new.void_reason:=null; return new;
  end if;
  if old.lifecycle_version is null then
    if not controlled and (new.lifecycle_version is distinct from old.lifecycle_version or new.lifecycle_state is distinct from old.lifecycle_state or new.financial_locked_at is distinct from old.financial_locked_at) then
      raise exception using errcode='P0001',message='This is a pre-C1 legacy expense. Its lifecycle cannot be manufactured from the browser.';
    end if; return new;
  end if;
  if old.lifecycle_state='draft' and new.payment_status<>'draft' and new.lifecycle_state='draft' then
    new.lifecycle_state:='recorded'; new.recorded_at:=now(); new.recorded_by:=auth.uid(); new.financial_locked_at:=now(); return new;
  end if;
  if not controlled and (new.lifecycle_version is distinct from old.lifecycle_version or new.lifecycle_state is distinct from old.lifecycle_state or new.recorded_at is distinct from old.recorded_at or new.recorded_by is distinct from old.recorded_by or new.financial_locked_at is distinct from old.financial_locked_at or new.voided_at is distinct from old.voided_at or new.voided_by is distinct from old.voided_by or new.void_reason is distinct from old.void_reason) then
    raise exception using errcode='P0001',message='Expense status changes are controlled by Frindly.';
  end if;
  if old.lifecycle_state in ('recorded','voided') and (new.business_id is distinct from old.business_id or new.expense_number is distinct from old.expense_number or new.supplier_id is distinct from old.supplier_id or new.supplier_name is distinct from old.supplier_name or new.supplier_reference is distinct from old.supplier_reference or new.invoice_date is distinct from old.invoice_date or new.due_date is distinct from old.due_date or new.category_id is distinct from old.category_id or new.job_costing_id is distinct from old.job_costing_id or new.amount_type is distinct from old.amount_type or new.gst_treatment is distinct from old.gst_treatment or new.gst_rate is distinct from old.gst_rate or new.gst_override is distinct from old.gst_override or new.ex_gst is distinct from old.ex_gst or new.gst_amount is distinct from old.gst_amount or new.total_amount is distinct from old.total_amount or new.currency is distinct from old.currency or new.is_split is distinct from old.is_split or new.business_use_percent is distinct from old.business_use_percent or new.business_use_amount is distinct from old.business_use_amount or new.private_use_amount is distinct from old.private_use_amount or new.business_ex_gst is distinct from old.business_ex_gst or new.business_gst_amount is distinct from old.business_gst_amount or new.allocation_method is distinct from old.allocation_method or new.allocation_basis is distinct from old.allocation_basis) then
    raise exception using errcode='P0001',message='This expense is already part of your financial records. Use a correction, supplier credit or void instead of changing financial details.';
  end if;
  if old.lifecycle_state in ('recorded','voided') and to_jsonb(new) is distinct from to_jsonb(old) then
    insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(old.business_id,'expense',old.id,'document_metadata_updated',jsonb_build_object('lifecycle_state',old.lifecycle_state),auth.uid());
  end if;
  return new;
end
$function$;
