-- v61.106F - Allow new bank reconciliation classifications introduced in v61.106E.
-- This is a forward-only companion migration so it still runs when v61.106E was
-- already applied before the check constraint issue was discovered.

do $$
declare
  v_constraint record;
begin
  if to_regclass('public.bank_transactions') is null then
    return;
  end if;

  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = to_regclass('public.bank_transactions')
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%reconciliation_type%'
  loop
    execute format('alter table public.bank_transactions drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table if exists public.bank_transactions
  add constraint bank_transactions_reconciliation_type_ck
  check (
    reconciliation_type is null
    or reconciliation_type in (
      'invoice',
      'expense',
      'created_expense',
      'split',
      'transfer',
      'excluded',
      'customer_refund',
      'supplier_refund',
      'payroll_pay_run',
      'owner_funds_introduced',
      'director_loan_received',
      'capital_contribution',
      'owner_drawings',
      'repay_owner_loan',
      'director_payment',
      'dividend_distribution'
    )
  );
