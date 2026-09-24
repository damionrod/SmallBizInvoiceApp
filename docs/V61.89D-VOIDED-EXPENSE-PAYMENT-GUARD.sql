-- V61.89D: Preserve recorded payment behavior and refuse payments on voided bills.
-- The existing trigger v6170c45_expense_payment_guard_trg calls this function.
create or replace function public.v6170c45_expense_payment_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  total numeric;
  expense_state text;
  credits numeric;
  other_paid numeric;
begin
  select e.total_amount, e.lifecycle_state
    into total, expense_state
    from public.expenses e
   where e.id = new.expense_id and e.business_id = new.business_id
   for update;
  if total is null then
    raise exception 'Expense not found';
  end if;
  if expense_state = 'voided' then
    raise exception 'Voided expenses cannot receive payments';
  end if;
  select coalesce(sum(c.total_amount), 0) into credits
    from public.supplier_credits c
   where c.business_id = new.business_id
     and c.original_expense_id = new.expense_id
     and c.lifecycle_state = 'recorded';
  select coalesce(sum(p.amount), 0) into other_paid
    from public.expense_payments p
   where p.business_id = new.business_id
     and p.expense_id = new.expense_id
     and p.id <> coalesce(new.id, gen_random_uuid());
  if other_paid + new.amount > greatest(total - credits, 0) + 0.005 then
    raise exception 'Payment exceeds supplier-credit-adjusted outstanding balance';
  end if;
  return new;
end
$function$;
