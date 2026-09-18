-- V61.14 Duplicate Pay Protection
-- Purpose:
-- 1) Link payroll earning lines to the exact approved timesheet that produced them.
-- 2) Prevent the same timesheet being included in more than one payroll run.
-- 3) Prevent salary employees being finalised twice for the exact same pay period.
-- 4) Protect older/legacy finalised hourly runs that pre-date timesheet links.
--
-- This migration does not change tax calculations, pay rates, payslips, or financial reporting.

alter table public.payroll_pay_run_lines
  add column if not exists timesheet_id uuid references public.payroll_timesheets(id) on delete restrict;

create index if not exists payroll_pay_run_lines_timesheet_idx
  on public.payroll_pay_run_lines(timesheet_id)
  where timesheet_id is not null;

create or replace function public.v6114_prevent_duplicate_finalised_pay()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  duplicate_employee text;
  duplicate_run text;
begin
  if new.status = 'finalised' and old.status is distinct from 'finalised' then
    -- Timesheet-backed hourly earnings may only be finalised once. Draft pay
    -- runs may overlap while being prepared, but finalisation is blocked if an
    -- exact timesheet has already been paid in another finalised run.
    select coalesce(e.first_name || ' ' || e.last_name, e.employee_number, 'Employee'), r.pay_run_number
      into duplicate_employee, duplicate_run
    from payroll_pay_run_employees cur
    join payroll_employees e on e.id = cur.employee_id
    join payroll_pay_run_lines cl
      on cl.pay_run_employee_id = cur.id
     and cl.line_type in ('ordinary','overtime')
     and cl.timesheet_id is not null
    join payroll_pay_run_lines pl
      on pl.timesheet_id = cl.timesheet_id
     and pl.line_type in ('ordinary','overtime')
     and pl.id <> cl.id
    join payroll_pay_run_employees prior on prior.id = pl.pay_run_employee_id
    join payroll_pay_runs r
      on r.id = prior.pay_run_id
     and r.status = 'finalised'
     and r.id <> new.id
    where cur.pay_run_id = new.id
    limit 1;

    if duplicate_run is not null then
      raise exception '% has a timesheet that was already paid in finalised pay run %.', duplicate_employee, duplicate_run;
    end if;

    duplicate_employee := null;
    duplicate_run := null;

    -- Salary payroll is period based rather than timesheet based. A salary
    -- employee cannot be finalised twice for the exact same period.
    select coalesce(e.first_name || ' ' || e.last_name, e.employee_number, 'Employee'), r.pay_run_number
      into duplicate_employee, duplicate_run
    from payroll_pay_run_employees cur
    join payroll_employees e on e.id = cur.employee_id
    join payroll_pay_runs r
      on r.business_id = new.business_id
     and r.status = 'finalised'
     and r.id <> new.id
     and r.period_start = new.period_start
     and r.period_end = new.period_end
    join payroll_pay_run_employees prior
      on prior.pay_run_id = r.id
     and prior.employee_id = cur.employee_id
    where cur.pay_run_id = new.id
      and e.pay_type = 'salary'
    limit 1;

    if duplicate_run is not null then
      raise exception '% has already been included in finalised pay run % for this exact pay period.', duplicate_employee, duplicate_run;
    end if;

    -- Legacy safeguard: older finalised hourly runs did not store timesheet_id.
    -- If the exact same employee/period exists and the old earnings lines have
    -- no timesheet links, do not guess which hours are unpaid; require the old
    -- run to be removed/recreated before regular payroll can be repeated.
    duplicate_employee := null;
    duplicate_run := null;

    select coalesce(e.first_name || ' ' || e.last_name, e.employee_number, 'Employee'), r.pay_run_number
      into duplicate_employee, duplicate_run
    from payroll_pay_run_employees cur
    join payroll_employees e on e.id = cur.employee_id
    join payroll_pay_runs r
      on r.business_id = new.business_id
     and r.status = 'finalised'
     and r.id <> new.id
     and r.period_start = new.period_start
     and r.period_end = new.period_end
    join payroll_pay_run_employees prior
      on prior.pay_run_id = r.id
     and prior.employee_id = cur.employee_id
    where cur.pay_run_id = new.id
      and e.pay_type <> 'salary'
      and not exists (
        select 1
        from payroll_pay_run_lines pl
        where pl.pay_run_employee_id = prior.id
          and pl.line_type in ('ordinary','overtime')
          and pl.timesheet_id is not null
      )
    limit 1;

    if duplicate_run is not null then
      raise exception '% was already included in finalised pay run % for this pay period. The older run has no timesheet links, so it cannot safely be paid again.', duplicate_employee, duplicate_run;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists v6114_duplicate_finalised_pay_guard on public.payroll_pay_runs;
create trigger v6114_duplicate_finalised_pay_guard
before update on public.payroll_pay_runs
for each row execute function public.v6114_prevent_duplicate_finalised_pay();
