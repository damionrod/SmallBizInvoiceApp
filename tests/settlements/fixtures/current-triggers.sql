set check_function_bodies=false;
CREATE OR REPLACE FUNCTION public.v6187_guard_subscription_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is not null and not public.is_super_admin() then
    if tg_op<>'INSERT' and public.v6187_subscription_read_only(old.business_id) then
      raise exception 'This subscription has ended. Existing records are read-only. Open Settings -> Subscription & Billing.' using errcode='42501';
    end if;
    if tg_op<>'DELETE' and public.v6187_subscription_read_only(new.business_id) then
      raise exception 'This subscription has ended. Existing records are read-only. Open Settings -> Subscription & Billing.' using errcode='42501';
    end if;
  end if;
  if tg_op='DELETE' then return old;end if;
  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.v61107w_owner_allocation_business_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.owner_id is not null then
    if new.allocation_type <> 'owner_equity' then
      raise exception 'Owner/shareholder can only be attached to an owner_equity allocation';
    end if;
    if not exists(
      select 1 from public.business_owners o
      where o.id=new.owner_id and o.business_id=new.business_id
    ) then
      raise exception 'Owner/shareholder does not belong to this business';
    end if;
  end if;
  return new;
end
$function$
;
CREATE OR REPLACE FUNCTION public.v6135_validate_bank_allocation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare tx_business uuid;
begin
  select business_id into tx_business
  from public.bank_transactions where id=new.bank_transaction_id;
  if tx_business is null or tx_business<>new.business_id then
    raise exception 'Bank allocation must belong to the same business as the bank transaction';
  end if;
  if new.invoice_id is not null and not exists(select 1 from public.invoices where id=new.invoice_id and business_id=new.business_id) then
    raise exception 'Invoice does not belong to this business';
  end if;
  if new.expense_id is not null and not exists(select 1 from public.expenses where id=new.expense_id and business_id=new.business_id) then
    raise exception 'Expense does not belong to this business';
  end if;
  if new.customer_payment_id is not null and not exists(select 1 from public.customer_payments where id=new.customer_payment_id and business_id=new.business_id) then
    raise exception 'Customer payment does not belong to this business';
  end if;
  if new.existing_customer_payment_id is not null and not exists(select 1 from public.customer_payments where id=new.existing_customer_payment_id and business_id=new.business_id) then
    raise exception 'Existing customer payment does not belong to this business';
  end if;
  if new.expense_payment_id is not null and not exists(select 1 from public.expense_payments where id=new.expense_payment_id and business_id=new.business_id) then
    raise exception 'Expense payment does not belong to this business';
  end if;
  if new.reconciliation_group_id is not null and not exists(select 1 from public.bank_reconciliation_groups where id=new.reconciliation_group_id and business_id=new.business_id) then
    raise exception 'Reconciliation group does not belong to this business';
  end if;
  return new;
end$function$
;
CREATE OR REPLACE FUNCTION public.v6170a_guard_journal_status_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$ begin if old.status='draft' and new.status in ('posted','reversed') then if current_user in ('authenticated','anon') then raise exception 'Journal finalisation must use the controlled accounting posting function'; end if; if not public.v6170a_period_is_open(new.business_id,new.journal_date) then raise exception 'Accounting period is not open'; end if; if (select count(*) from public.accounting_journal_lines l where l.business_id=new.business_id and l.journal_id=new.id)<2 then raise exception 'Posted journal requires at least two lines'; end if; if (select round(coalesce(sum(l.debit),0),2)<>round(coalesce(sum(l.credit),0),2) or coalesce(sum(l.debit),0)<=0 or coalesce(sum(l.credit),0)<=0 from public.accounting_journal_lines l where l.business_id=new.business_id and l.journal_id=new.id) then raise exception 'Posted journal must balance'; end if; end if; return new; end $function$
;
CREATE OR REPLACE FUNCTION public.v6170a_guard_posted_journal_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$ begin if tg_op='DELETE' and old.status in ('posted','reversed') then raise exception 'Posted accounting journals cannot be deleted'; end if; if tg_op='UPDATE' and old.status in ('posted','reversed') and (new.business_id,new.journal_date,new.source_type,new.source_id,new.posting_version,new.description,new.journal_type) is distinct from (old.business_id,old.journal_date,old.source_type,old.source_id,old.posting_version,old.description,old.journal_type) then raise exception 'Posted accounting journals are immutable'; end if; return case when tg_op='DELETE' then old else new end; end $function$
;
CREATE OR REPLACE FUNCTION public.v6170a_guard_journal_line_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$ declare v_status text; begin select status into v_status from public.accounting_journals where id=new.journal_id and business_id=new.business_id; if v_status is null then raise exception 'Journal not found in active tenant'; end if; if v_status<>'draft' then raise exception 'Lines may only be inserted into draft journals'; end if; return new; end $function$
;
CREATE OR REPLACE FUNCTION public.v6170a_guard_posted_line_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$ declare v_status text; begin select status into v_status from public.accounting_journals where id=coalesce(old.journal_id,new.journal_id) and business_id=coalesce(old.business_id,new.business_id); if v_status in ('posted','reversed') then raise exception 'Posted accounting journal lines are immutable'; end if; return case when tg_op='DELETE' then old else new end; end $function$
;
CREATE OR REPLACE FUNCTION public.v6170a_period_is_open(p_business_id uuid, p_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select exists(select 1 from public.accounting_periods p where p.business_id=p_business_id and p_date between p.period_start and p.period_end and p.status='open') $function$
;
CREATE TRIGGER v6187_subscription_write BEFORE INSERT OR DELETE OR UPDATE ON public.bank_transactions FOR EACH ROW EXECUTE FUNCTION v6187_guard_subscription_write();
CREATE TRIGGER trg_v61107w_owner_allocation_business_guard BEFORE INSERT OR UPDATE OF owner_id, business_id, allocation_type ON public.bank_reconciliation_allocations FOR EACH ROW EXECUTE FUNCTION v61107w_owner_allocation_business_guard();
CREATE TRIGGER v6135_validate_bank_allocation_trg BEFORE INSERT OR UPDATE ON public.bank_reconciliation_allocations FOR EACH ROW EXECUTE FUNCTION v6135_validate_bank_allocation();
CREATE TRIGGER v6187_subscription_write BEFORE INSERT OR DELETE OR UPDATE ON public.bank_reconciliation_allocations FOR EACH ROW EXECUTE FUNCTION v6187_guard_subscription_write();
CREATE TRIGGER v6170a_guard_journal_status_transition BEFORE UPDATE ON public.accounting_journals FOR EACH ROW EXECUTE FUNCTION v6170a_guard_journal_status_transition();
CREATE TRIGGER v6170a_guard_posted_journal_mutation BEFORE DELETE OR UPDATE ON public.accounting_journals FOR EACH ROW EXECUTE FUNCTION v6170a_guard_posted_journal_mutation();
CREATE TRIGGER v6187_subscription_write BEFORE INSERT OR DELETE OR UPDATE ON public.accounting_journals FOR EACH ROW EXECUTE FUNCTION v6187_guard_subscription_write();
CREATE TRIGGER v6170a_guard_journal_line_insert BEFORE INSERT ON public.accounting_journal_lines FOR EACH ROW EXECUTE FUNCTION v6170a_guard_journal_line_insert();
CREATE TRIGGER v6170a_guard_posted_line_mutation BEFORE DELETE OR UPDATE ON public.accounting_journal_lines FOR EACH ROW EXECUTE FUNCTION v6170a_guard_posted_line_mutation();
CREATE TRIGGER v6187_subscription_write BEFORE INSERT OR DELETE OR UPDATE ON public.accounting_journal_lines FOR EACH ROW EXECUTE FUNCTION v6187_guard_subscription_write();
set check_function_bodies=true;
