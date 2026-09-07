-- V61 Payroll usability extensions
-- 1) Timesheet-linked employee reimbursements
-- 2) Permit explicitly confirmed deletion of finalised pay runs and their children

create table if not exists public.payroll_timesheet_expenses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  timesheet_id uuid not null references public.payroll_timesheets(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  job_costing_id uuid references public.job_costings(id) on delete set null,
  description text not null,
  amount numeric(14,2) not null check(amount > 0),
  taxable boolean not null default false check(taxable = false),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create index if not exists payroll_timesheet_expenses_timesheet_idx on public.payroll_timesheet_expenses(timesheet_id);
create index if not exists payroll_timesheet_expenses_business_idx on public.payroll_timesheet_expenses(business_id,employee_id);

alter table public.payroll_timesheet_expenses enable row level security;
drop policy if exists payroll_timesheet_expenses_business_access on public.payroll_timesheet_expenses;
create policy payroll_timesheet_expenses_business_access on public.payroll_timesheet_expenses
for all using (business_id = public.current_business_id())
with check (business_id = public.current_business_id());

-- Keep finalised runs locked against edits, but allow deletion when the user explicitly chooses Delete.
create or replace function public.v55_lock_finalised_pay_run()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.status='finalised' and tg_op='UPDATE' then
    raise exception 'Finalised pay runs are locked. Delete the pay run and recreate it if a full reversal is required.';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end$$;

create or replace function public.v55_lock_finalised_payroll_child()
returns trigger language plpgsql security definer set search_path=public as $$
declare rid uuid;
begin
  -- Cascading/dependent deletes are allowed so a finalised pay run can be permanently removed.
  if tg_op='DELETE' then return old; end if;
  if tg_table_name='payroll_pay_run_employees' then
    rid=new.pay_run_id;
  elsif tg_table_name='payroll_pay_run_lines' then
    select pay_run_id into rid from payroll_pay_run_employees where id=new.pay_run_employee_id;
  else
    rid=new.pay_run_id;
  end if;
  if exists(select 1 from payroll_pay_runs where id=rid and status='finalised') then
    if tg_table_name='payroll_payslips' and tg_op='UPDATE'
       and new.id=old.id and new.business_id=old.business_id and new.pay_run_id=old.pay_run_id
       and new.pay_run_employee_id=old.pay_run_employee_id and new.employee_id=old.employee_id
       and new.payslip_number=old.payslip_number and new.payslip_data is not distinct from old.payslip_data
       and new.generated_at=old.generated_at then
      return new;
    end if;
    raise exception 'Finalised payroll detail is locked. Delete the pay run and recreate it if a full reversal is required.';
  end if;
  return new;
end$$;
