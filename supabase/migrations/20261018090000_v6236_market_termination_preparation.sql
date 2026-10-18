-- V62.36 (Market only) — guarded employee termination and final-pay preparation.
-- This does not calculate or finalise statutory final pay. It records the employment
-- end atomically and creates an evidence-backed review item for the existing P6 engine.

begin;

create table if not exists public.payroll_termination_preparations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  request_id uuid not null,
  termination_date date not null,
  termination_reason text null,
  status text not null default 'needs_review'
    check (status in ('needs_review','ready','completed','cancelled')),
  checklist_snapshot jsonb not null default '{}'::jsonb,
  employee_revision_at_request timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid(),
  updated_at timestamptz not null default now(),
  updated_by uuid not null default auth.uid(),
  unique (business_id, request_id)
);

create unique index if not exists payroll_termination_one_open_idx
  on public.payroll_termination_preparations(employee_id)
  where status in ('needs_review','ready');

create index if not exists payroll_termination_business_status_idx
  on public.payroll_termination_preparations(business_id,status,termination_date desc);

alter table public.payroll_termination_preparations enable row level security;

drop policy if exists v6236_termination_select on public.payroll_termination_preparations;
create policy v6236_termination_select
  on public.payroll_termination_preparations for select to authenticated
  using (public.v6147_can_read_area(business_id,'payroll'));

revoke all on table public.payroll_termination_preparations from public, anon;
revoke insert,update,delete on table public.payroll_termination_preparations from authenticated;
grant select on table public.payroll_termination_preparations to authenticated;

create or replace function public.v6236_validate_termination_preparation_refs()
returns trigger
language plpgsql
security invoker
set search_path=public
as $$
begin
  if not exists (
    select 1 from public.payroll_employees e
    where e.id=new.employee_id and e.business_id=new.business_id
  ) then
    raise exception 'Employee does not belong to this business';
  end if;
  new.updated_at=now();
  new.updated_by=auth.uid();
  return new;
end;
$$;

drop trigger if exists v6236_validate_refs on public.payroll_termination_preparations;
create trigger v6236_validate_refs
before insert or update on public.payroll_termination_preparations
for each row execute function public.v6236_validate_termination_preparation_refs();

create or replace function public.v6236_guard_employee_termination()
returns trigger
language plpgsql
security invoker
set search_path=public
as $$
begin
  if old.employment_status<>'terminated' and new.employment_status='terminated'
     and current_setting('v6236.termination_command',true) is distinct from 'true' then
    raise exception 'Use Prepare final pay to terminate an employee';
  end if;
  return new;
end;
$$;

drop trigger if exists v6236_guard_employee_termination on public.payroll_employees;
create trigger v6236_guard_employee_termination
before update of employment_status on public.payroll_employees
for each row execute function public.v6236_guard_employee_termination();

create or replace function public.v6236_prepare_employee_termination(
  p_employee_id uuid,
  p_expected_updated_at timestamptz,
  p_termination_date date,
  p_reason text,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_business_id uuid := public.current_business_id();
  v_employee public.payroll_employees%rowtype;
  v_preparation public.payroll_termination_preparations%rowtype;
  v_existing public.payroll_termination_preparations%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if v_business_id is null or not public.v55_payroll_access(v_business_id)
     or not public.v6147_can_write_area(v_business_id,'payroll') then
    raise exception 'Payroll write access required';
  end if;
  if p_employee_id is null or p_expected_updated_at is null or p_termination_date is null or p_request_id is null then
    raise exception 'Employee, record version, termination date and request ID are required';
  end if;

  select * into v_existing
  from public.payroll_termination_preparations
  where business_id=v_business_id and request_id=p_request_id;
  if found then
    return jsonb_build_object('ok',true,'id',v_existing.id,'status',v_existing.status,'replayed',true);
  end if;

  select * into v_employee
  from public.payroll_employees
  where id=p_employee_id and business_id=v_business_id
  for update;
  if not found then raise exception 'Employee not found'; end if;
  if v_employee.archived then raise exception 'Archived employees cannot be terminated'; end if;
  if v_employee.updated_at is distinct from p_expected_updated_at then
    raise exception 'This employee changed since you opened the form. Refresh and try again.';
  end if;
  if p_termination_date < v_employee.start_date then
    raise exception 'Termination date cannot be before the employee start date';
  end if;

  select * into v_existing
  from public.payroll_termination_preparations
  where employee_id=p_employee_id and status in ('needs_review','ready')
  for update;
  if found then
    if v_existing.termination_date<>p_termination_date
       or coalesce(v_existing.termination_reason,'')<>coalesce(nullif(btrim(p_reason),''),'') then
      raise exception 'An open final-pay review already exists for this employee';
    end if;
    return jsonb_build_object('ok',true,'id',v_existing.id,'status',v_existing.status,'replayed',true);
  end if;

  insert into public.payroll_termination_preparations(
    business_id,employee_id,request_id,termination_date,termination_reason,
    checklist_snapshot,employee_revision_at_request,created_by,updated_by
  ) values (
    v_business_id,p_employee_id,p_request_id,p_termination_date,nullif(btrim(p_reason),''),
    jsonb_build_object(
      'version','v62.36',
      'items',jsonb_build_array(
        'Confirm ordinary earnings through the final day',
        'Confirm annual-holiday entitlement evidence',
        'Confirm alternative holidays and other leave owing',
        'Review gross-earnings classifications and deductions',
        'Calculate and approve final pay before marking the review complete'
      ),
      'automatic_calculation',false
    ),
    v_employee.updated_at,auth.uid(),auth.uid()
  ) returning * into v_preparation;

  perform set_config('v6236.termination_command','true',true);
  update public.payroll_employees
  set employment_status='terminated', end_date=p_termination_date,
      termination_reason=nullif(btrim(p_reason),''), final_pay_required=true,
      updated_at=now(), updated_by=auth.uid()
  where id=p_employee_id and business_id=v_business_id;

  return jsonb_build_object('ok',true,'id',v_preparation.id,'status',v_preparation.status,'replayed',false);
end;
$$;

revoke all on function public.v6236_prepare_employee_termination(uuid,timestamptz,date,text,uuid) from public, anon;
grant execute on function public.v6236_prepare_employee_termination(uuid,timestamptz,date,text,uuid) to authenticated;

commit;
