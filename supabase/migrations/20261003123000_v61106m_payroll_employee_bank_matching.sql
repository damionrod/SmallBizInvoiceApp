-- V61.106M: identify individual employee net-pay bank matches without changing payroll accounting.
-- Existing whole-pay-run reconciliation remains supported. This migration adds evidence linkage only.

alter table if exists public.bank_reconciliation_allocations
  add column if not exists pay_run_employee_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='bank_reconciliation_allocations_pay_run_employee_fk'
      and conrelid='public.bank_reconciliation_allocations'::regclass
  ) then
    alter table public.bank_reconciliation_allocations
      add constraint bank_reconciliation_allocations_pay_run_employee_fk
      foreign key (pay_run_employee_id) references public.payroll_pay_run_employees(id) on delete set null;
  end if;
end$$;

create unique index if not exists bank_reconciliation_allocations_pay_run_employee_uq
  on public.bank_reconciliation_allocations(pay_run_employee_id)
  where pay_run_employee_id is not null;

comment on column public.bank_reconciliation_allocations.pay_run_employee_id is
  'Optional evidence link for an individual employee net-pay bank match. Does not create or change payroll journals.';
