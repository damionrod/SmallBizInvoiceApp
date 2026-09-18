-- Invoice Manager v55 — Payroll module
-- Run this entire file in Supabase SQL Editor BEFORE deploying v55.
-- Adds a business-scoped Payroll module with employees, timesheets, pay runs,
-- payslips, leave/configuration, audit history, private employee documents and
-- module-level access enforcement.

create extension if not exists pgcrypto;

insert into public.modules(slug,name,description,monthly_price,is_active)
values ('payroll','Payroll','Manage employees, timesheets, pay runs, payslips and payroll reporting',0,true)
on conflict (slug) do update set name=excluded.name,description=excluded.description,is_active=true;

-- Module access is enforced in the database, not just by hiding the navigation.
create or replace function public.v55_payroll_access(p_business_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else exists(select 1 from public.profiles p where p.id=auth.uid() and p.business_id=p_business_id)
      and exists(select 1 from public.modules m where m.slug='payroll' and m.is_active=true)
      and (
        exists(
          select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
          where bm.business_id=p_business_id and m.slug='payroll' and bm.status in ('active','trialing')
        )
        or (
          not exists(
            select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
            where bm.business_id=p_business_id and m.slug='payroll'
          )
          and exists(
            select 1 from public.subscriptions s join public.plans pl on pl.id=s.plan_id
            where s.business_id=p_business_id and coalesce(s.status,'') not in ('suspended','canceled')
              and 'payroll'=any(coalesce(pl.included_modules,'{}'::text[]))
          )
        )
      )
  end;
$$;
revoke all on function public.v55_payroll_access(uuid) from public;
grant execute on function public.v55_payroll_access(uuid) to authenticated;

create table if not exists public.payroll_settings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique default public.current_business_id() references public.businesses(id) on delete cascade,
  country_code char(2) not null default 'NZ',
  currency char(3) not null default 'NZD',
  default_pay_frequency text not null default 'fortnightly',
  default_pay_day smallint not null default 5 check(default_pay_day between 0 and 6),
  week_start_day smallint not null default 1 check(week_start_day between 0 and 6),
  default_weekly_hours numeric(7,2) not null default 40,
  default_working_days numeric(4,2) not null default 5,
  employee_prefix text not null default 'EMP',
  payslip_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create table if not exists public.payroll_country_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  country_code char(2) not null default 'NZ',
  rule_type text not null,
  rule_key text not null,
  numeric_value numeric(16,6),
  text_value text,
  json_value jsonb,
  effective_from date not null,
  effective_to date,
  active boolean not null default true,
  source_note text,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  unique(business_id,country_code,rule_type,rule_key,effective_from)
);

create table if not exists public.payroll_employees (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_number text not null,
  first_name text not null,
  middle_name text,
  last_name text not null,
  preferred_name text,
  date_of_birth date,
  email text,
  mobile text,
  phone text,
  address text,
  emergency_contact_name text,
  emergency_contact_phone text,
  notes text,
  employment_type text not null default 'casual',
  job_title text,
  department text,
  manager_name text,
  start_date date not null default current_date,
  end_date date,
  standard_weekly_hours numeric(7,2) not null default 40,
  standard_working_days numeric(4,2) not null default 5,
  pay_frequency text not null default 'fortnightly',
  employment_status text not null default 'active' check(employment_status in ('active','on_leave','terminated','inactive')),
  pay_type text not null default 'hourly' check(pay_type in ('hourly','salary')),
  hourly_rate numeric(14,2) not null default 0 check(hourly_rate>=0),
  annual_salary numeric(14,2) not null default 0 check(annual_salary>=0),
  overtime_multiplier numeric(7,3) not null default 1.5 check(overtime_multiplier>=0),
  ird_number text,
  tax_code text not null default 'M',
  student_loan boolean not null default false,
  kiwisaver_status text not null default 'not_enrolled' check(kiwisaver_status in ('not_enrolled','enrolled','suspended')),
  kiwisaver_employee_rate numeric(7,3) not null default 3.5,
  kiwisaver_employer_rate numeric(7,3) not null default 3.5,
  annual_holiday_method text not null default 'standard' check(annual_holiday_method in ('standard','payg')),
  holiday_pay_rate numeric(7,3) not null default 8,
  bank_account_name text,
  bank_account_number text,
  bank_payment_reference text,
  termination_reason text,
  final_pay_required boolean not null default false,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,employee_number)
);

create table if not exists public.payroll_document_types (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  name text not null,
  required boolean not null default false,
  archived boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique(business_id,name)
);

create table if not exists public.payroll_employee_documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete cascade,
  document_type_id uuid references public.payroll_document_types(id) on delete set null,
  document_name text not null,
  storage_path text not null,
  original_filename text,
  mime_type text,
  file_size bigint,
  expiry_date date,
  notes text,
  status text,
  uploaded_at timestamptz not null default now(),
  uploaded_by uuid default auth.uid()
);

create table if not exists public.payroll_pay_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  item_type text not null check(item_type in ('earning','allowance','reimbursement','deduction','contribution')),
  name text not null,
  calculation_type text not null default 'fixed' check(calculation_type in ('fixed','per_hour','per_day','per_job','percent','custom')),
  default_rate numeric(14,4) not null default 0,
  taxable boolean not null default true,
  expense_category_id uuid references public.expense_categories(id) on delete set null,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,item_type,name)
);

create table if not exists public.payroll_leave_types (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  name text not null,
  paid boolean not null default true,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  unique(business_id,name)
);

create table if not exists public.payroll_employee_leave (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete cascade,
  leave_type_id uuid not null references public.payroll_leave_types(id) on delete restrict,
  balance_hours numeric(10,2) not null default 0,
  updated_at timestamptz not null default now(),
  unique(employee_id,leave_type_id)
);

create table if not exists public.payroll_timesheets (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  work_date date not null,
  job_costing_id uuid references public.job_costings(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  start_time time,
  finish_time time,
  break_minutes integer not null default 0 check(break_minutes>=0),
  total_hours numeric(8,2) not null default 0 check(total_hours>=0),
  pay_item_id uuid references public.payroll_pay_items(id) on delete set null,
  pay_type text not null default 'ordinary',
  notes text,
  status text not null default 'draft' check(status in ('draft','submitted','approved','rejected')),
  submitted_at timestamptz,
  approved_at timestamptz,
  approved_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid()
);

create table if not exists public.payroll_pay_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  pay_run_number text not null,
  pay_frequency text not null,
  period_start date not null,
  period_end date not null,
  pay_date date not null,
  status text not null default 'draft' check(status in ('draft','calculated','approved','finalised')),
  country_code char(2) not null default 'NZ',
  currency char(3) not null default 'NZD',
  rules_snapshot jsonb not null default '{}'::jsonb,
  gross_pay numeric(14,2) not null default 0,
  total_deductions numeric(14,2) not null default 0,
  net_pay numeric(14,2) not null default 0,
  employer_contributions numeric(14,2) not null default 0,
  total_employment_cost numeric(14,2) not null default 0,
  finalised_at timestamptz,
  finalised_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,pay_run_number),
  check(period_end>=period_start)
);

create table if not exists public.payroll_leave_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  leave_type_id uuid not null references public.payroll_leave_types(id) on delete restrict,
  transaction_date date not null default current_date,
  transaction_type text not null check(transaction_type in ('accrual','taken','adjustment')),
  hours numeric(10,2) not null,
  notes text,
  pay_run_id uuid references public.payroll_pay_runs(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists public.payroll_pay_run_employees (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  pay_run_id uuid not null references public.payroll_pay_runs(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  employee_snapshot jsonb not null default '{}'::jsonb,
  hours numeric(9,2) not null default 0,
  rate numeric(14,4) not null default 0,
  ordinary_earnings numeric(14,2) not null default 0,
  holiday_pay numeric(14,2) not null default 0,
  allowances numeric(14,2) not null default 0,
  reimbursements numeric(14,2) not null default 0,
  gross_pay numeric(14,2) not null default 0,
  paye numeric(14,2) not null default 0,
  kiwisaver_employee numeric(14,2) not null default 0,
  student_loan numeric(14,2) not null default 0,
  other_deductions numeric(14,2) not null default 0,
  total_deductions numeric(14,2) not null default 0,
  net_pay numeric(14,2) not null default 0,
  kiwisaver_employer_gross numeric(14,2) not null default 0,
  esct numeric(14,2) not null default 0,
  employer_contributions numeric(14,2) not null default 0,
  total_employment_cost numeric(14,2) not null default 0,
  calculation_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(pay_run_id,employee_id)
);

create table if not exists public.payroll_pay_run_lines (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  pay_run_employee_id uuid not null references public.payroll_pay_run_employees(id) on delete cascade,
  pay_item_id uuid references public.payroll_pay_items(id) on delete set null,
  line_type text not null,
  description text not null,
  quantity numeric(12,4) not null default 1,
  rate numeric(14,4) not null default 0,
  amount numeric(14,2) not null default 0,
  job_costing_id uuid references public.job_costings(id) on delete set null,
  expense_category_id uuid references public.expense_categories(id) on delete set null,
  taxable boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.payroll_payslips (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  pay_run_id uuid not null references public.payroll_pay_runs(id) on delete cascade,
  pay_run_employee_id uuid not null references public.payroll_pay_run_employees(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  payslip_number text not null,
  payslip_data jsonb not null,
  generated_at timestamptz not null default now(),
  emailed_at timestamptz,
  emailed_to text,
  unique(business_id,payslip_number),
  unique(pay_run_employee_id)
);

create table if not exists public.payroll_financial_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  pay_run_id uuid not null references public.payroll_pay_runs(id) on delete cascade,
  transaction_type text not null,
  amount numeric(14,2) not null default 0,
  currency char(3) not null,
  reference text,
  expense_category_id uuid references public.expense_categories(id) on delete set null,
  source_record_id uuid,
  created_at timestamptz not null default now(),
  unique(pay_run_id,transaction_type,source_record_id)
);

create table if not exists public.payroll_audit_log (
  id bigserial primary key,
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  entity_type text not null,
  entity_id uuid,
  action text not null,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

-- Helpful indexes
create index if not exists payroll_employees_business_status_idx on public.payroll_employees(business_id,employment_status,archived);
create index if not exists payroll_timesheets_business_date_idx on public.payroll_timesheets(business_id,work_date,status);
create index if not exists payroll_leave_tx_employee_idx on public.payroll_leave_transactions(employee_id,transaction_date);
create index if not exists payroll_timesheets_employee_idx on public.payroll_timesheets(employee_id,work_date);
create index if not exists payroll_timesheets_job_idx on public.payroll_timesheets(job_costing_id) where job_costing_id is not null;
create index if not exists payroll_runs_business_paydate_idx on public.payroll_pay_runs(business_id,pay_date,status);
create index if not exists payroll_run_employees_run_idx on public.payroll_pay_run_employees(pay_run_id);
create index if not exists payroll_financial_business_idx on public.payroll_financial_transactions(business_id,created_at);

-- Validate every cross-table reference at database level. RLS alone is not enough for foreign-key tenant safety.
create or replace function public.v55_validate_payroll_refs()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_table_name in ('payroll_timesheets','payroll_employee_leave','payroll_leave_transactions','payroll_employee_documents','payroll_pay_run_employees','payroll_payslips') then
    if new.employee_id is not null and not exists(select 1 from payroll_employees e where e.id=new.employee_id and e.business_id=new.business_id) then raise exception 'Employee does not belong to this business'; end if;
  end if;
  if tg_table_name='payroll_timesheets' then
    if new.job_costing_id is not null and not exists(select 1 from job_costings j where j.id=new.job_costing_id and j.business_id=new.business_id) then raise exception 'Job does not belong to this business'; end if;
    if new.customer_id is not null and not exists(select 1 from customers c where c.id=new.customer_id and c.business_id=new.business_id) then raise exception 'Customer does not belong to this business'; end if;
    if new.pay_item_id is not null and not exists(select 1 from payroll_pay_items p where p.id=new.pay_item_id and p.business_id=new.business_id) then raise exception 'Pay item does not belong to this business'; end if;
  elsif tg_table_name in ('payroll_employee_leave','payroll_leave_transactions') then
    if not exists(select 1 from payroll_leave_types l where l.id=new.leave_type_id and l.business_id=new.business_id) then raise exception 'Leave type does not belong to this business'; end if;
    if tg_table_name='payroll_leave_transactions' and new.pay_run_id is not null and not exists(select 1 from payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
  elsif tg_table_name='payroll_employee_documents' then
    if new.document_type_id is not null and not exists(select 1 from payroll_document_types d where d.id=new.document_type_id and d.business_id=new.business_id) then raise exception 'Document type does not belong to this business'; end if;
  elsif tg_table_name='payroll_pay_run_employees' then
    if not exists(select 1 from payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
  elsif tg_table_name='payroll_pay_run_lines' then
    if not exists(select 1 from payroll_pay_run_employees e where e.id=new.pay_run_employee_id and e.business_id=new.business_id) then raise exception 'Pay run employee does not belong to this business'; end if;
    if new.pay_item_id is not null and not exists(select 1 from payroll_pay_items p where p.id=new.pay_item_id and p.business_id=new.business_id) then raise exception 'Pay item does not belong to this business'; end if;
    if new.job_costing_id is not null and not exists(select 1 from job_costings j where j.id=new.job_costing_id and j.business_id=new.business_id) then raise exception 'Job does not belong to this business'; end if;
    if new.expense_category_id is not null and not exists(select 1 from expense_categories c where c.id=new.expense_category_id and c.business_id=new.business_id) then raise exception 'Expense category does not belong to this business'; end if;
  elsif tg_table_name='payroll_payslips' then
    if not exists(select 1 from payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
    if not exists(select 1 from payroll_pay_run_employees e where e.id=new.pay_run_employee_id and e.business_id=new.business_id and e.pay_run_id=new.pay_run_id and e.employee_id=new.employee_id) then raise exception 'Payslip references do not belong together in this business'; end if;
  elsif tg_table_name='payroll_financial_transactions' then
    if not exists(select 1 from payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
    if new.expense_category_id is not null and not exists(select 1 from expense_categories c where c.id=new.expense_category_id and c.business_id=new.business_id) then raise exception 'Expense category does not belong to this business'; end if;
  end if;
  return new;
end$$;

do $$ declare t text; begin
  foreach t in array array['payroll_timesheets','payroll_employee_leave','payroll_leave_transactions','payroll_employee_documents','payroll_pay_run_employees','payroll_pay_run_lines','payroll_payslips','payroll_financial_transactions'] loop
    execute format('drop trigger if exists v55_validate_refs on public.%I',t);
    execute format('create trigger v55_validate_refs before insert or update on public.%I for each row execute function public.v55_validate_payroll_refs()',t);
  end loop;
end$$;

-- Finalised pay runs and their financial detail are immutable. Corrections must be new records.
create or replace function public.v55_lock_finalised_pay_run()
returns trigger language plpgsql as $$
begin
  if old.status='finalised' then raise exception 'Finalised pay runs are locked. Create a correction instead.'; end if;
  if tg_op='DELETE' then return old; end if;
  new.updated_at=now(); new.updated_by=auth.uid(); return new;
end$$;
drop trigger if exists v55_lock_finalised_pay_run on public.payroll_pay_runs;
create trigger v55_lock_finalised_pay_run before update or delete on public.payroll_pay_runs for each row execute function public.v55_lock_finalised_pay_run();

create or replace function public.v55_lock_finalised_payroll_child()
returns trigger language plpgsql security definer set search_path=public as $$
declare rid uuid;
begin
  if tg_table_name='payroll_pay_run_employees' then
    rid=case when tg_op='DELETE' then old.pay_run_id else new.pay_run_id end;
  elsif tg_table_name='payroll_pay_run_lines' then
    if tg_op='DELETE' then select pay_run_id into rid from payroll_pay_run_employees where id=old.pay_run_employee_id;
    else select pay_run_id into rid from payroll_pay_run_employees where id=new.pay_run_employee_id; end if;
  else
    rid=case when tg_op='DELETE' then old.pay_run_id else new.pay_run_id end;
  end if;
  if exists(select 1 from payroll_pay_runs where id=rid and status='finalised') then
    if tg_table_name='payroll_payslips' and tg_op='UPDATE'
       and new.id=old.id and new.business_id=old.business_id and new.pay_run_id=old.pay_run_id
       and new.pay_run_employee_id=old.pay_run_employee_id and new.employee_id=old.employee_id
       and new.payslip_number=old.payslip_number and new.payslip_data is not distinct from old.payslip_data
       and new.generated_at=old.generated_at then
      return new; -- email delivery metadata may be updated after finalisation
    end if;
    raise exception 'Finalised payroll detail is locked. Create a correction instead.';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end$$;
do $$ declare t text; begin
  foreach t in array array['payroll_pay_run_employees','payroll_pay_run_lines','payroll_payslips','payroll_financial_transactions'] loop
    execute format('drop trigger if exists v55_lock_finalised_child on public.%I',t);
    execute format('create trigger v55_lock_finalised_child before insert or update or delete on public.%I for each row execute function public.v55_lock_finalised_payroll_child()',t);
  end loop;
end$$;

-- RLS: all payroll data requires both same-business identity and an enabled Payroll module.
do $$
declare t text;
begin
  foreach t in array array[
    'payroll_settings','payroll_country_rules','payroll_employees','payroll_document_types','payroll_employee_documents',
    'payroll_pay_items','payroll_leave_types','payroll_employee_leave','payroll_leave_transactions','payroll_timesheets','payroll_pay_runs',
    'payroll_pay_run_employees','payroll_pay_run_lines','payroll_payslips','payroll_financial_transactions','payroll_audit_log'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists v55_payroll_tenant_all on public.%I',t);
    execute format('create policy v55_payroll_tenant_all on public.%I for all to authenticated using (public.v55_payroll_access(business_id)) with check (public.v55_payroll_access(business_id))',t);
  end loop;
end$$;

-- Private employee document storage.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('payroll-documents','payroll-documents',false,10485760,array[
  'application/pdf','image/jpeg','image/png','image/webp',
  'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'
]) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists v55_payroll_docs_select on storage.objects;
drop policy if exists v55_payroll_docs_insert on storage.objects;
drop policy if exists v55_payroll_docs_update on storage.objects;
drop policy if exists v55_payroll_docs_delete on storage.objects;
create policy v55_payroll_docs_select on storage.objects for select to authenticated using(
  bucket_id='payroll-documents' and public.v55_payroll_access(((storage.foldername(name))[1])::uuid)
);
create policy v55_payroll_docs_insert on storage.objects for insert to authenticated with check(
  bucket_id='payroll-documents' and public.v55_payroll_access(((storage.foldername(name))[1])::uuid)
);
create policy v55_payroll_docs_update on storage.objects for update to authenticated using(
  bucket_id='payroll-documents' and public.v55_payroll_access(((storage.foldername(name))[1])::uuid)
) with check(
  bucket_id='payroll-documents' and public.v55_payroll_access(((storage.foldername(name))[1])::uuid)
);
create policy v55_payroll_docs_delete on storage.objects for delete to authenticated using(
  bucket_id='payroll-documents' and public.v55_payroll_access(((storage.foldername(name))[1])::uuid)
);

-- Seed business-specific defaults only for businesses where Payroll is later enabled.
-- The frontend also safely creates these defaults on first Payroll use.
create or replace function public.v55_seed_payroll_defaults(p_business_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.v55_payroll_access(p_business_id) then raise exception 'Payroll access denied'; end if;
  insert into payroll_settings(business_id,country_code,currency)
  select p_business_id,'NZ',coalesce(nullif(b.settings->>'currency',''),'NZD') from businesses b where b.id=p_business_id
  on conflict(business_id) do nothing;
  insert into payroll_document_types(business_id,name,required,sort_order) values
    (p_business_id,'Employment Agreement',true,10),(p_business_id,'CV',false,20),(p_business_id,'Police Check',false,30),(p_business_id,'Driver Licence',false,40)
  on conflict(business_id,name) do nothing;
  insert into payroll_leave_types(business_id,name,paid) values
    (p_business_id,'Annual Leave',true),(p_business_id,'Sick Leave',true),(p_business_id,'Bereavement Leave',true),(p_business_id,'Alternative Holiday',true),(p_business_id,'Public Holiday',true),(p_business_id,'Other',true)
  on conflict(business_id,name) do nothing;
  insert into payroll_pay_items(business_id,item_type,name,calculation_type,default_rate,taxable) values
    (p_business_id,'earning','Ordinary Hours','per_hour',0,true),(p_business_id,'earning','Overtime','per_hour',0,true),
    (p_business_id,'earning','Bonus','fixed',0,true),(p_business_id,'earning','Commission','fixed',0,true),
    (p_business_id,'allowance','Travel Allowance','fixed',0,true),(p_business_id,'allowance','Tool Allowance','fixed',0,true),
    (p_business_id,'reimbursement','Mileage','fixed',0,false),(p_business_id,'reimbursement','Parking','fixed',0,false),
    (p_business_id,'reimbursement','Travel','fixed',0,false),(p_business_id,'reimbursement','Materials','fixed',0,false),
    (p_business_id,'deduction','Other Authorised Deduction','fixed',0,false)
  on conflict(business_id,item_type,name) do nothing;

  -- NZ rules effective for 1 Apr 2026–31 Mar 2027. Values are versioned so future rates can be added.
  insert into payroll_country_rules(business_id,country_code,rule_type,rule_key,numeric_value,effective_from,effective_to,source_note) values
    (p_business_id,'NZ','acc','earners_levy_rate',1.75,'2026-04-01','2027-03-31','IRD 2026/27 payroll rules'),
    (p_business_id,'NZ','acc','max_earnings',156641,'2026-04-01','2027-03-31','IRD 2026/27 payroll rules'),
    (p_business_id,'NZ','kiwisaver','default_employee_rate',3.5,'2026-04-01','2028-03-31','IRD KiwiSaver changes'),
    (p_business_id,'NZ','kiwisaver','default_employer_rate',3.5,'2026-04-01','2028-03-31','IRD KiwiSaver changes'),
    (p_business_id,'NZ','student_loan','annual_threshold',24128,'2026-04-01','2027-03-31','IRD 2026/27 payroll rules'),
    (p_business_id,'NZ','student_loan','standard_rate',12,'2026-04-01','2027-03-31','IRD 2026/27 payroll rules')
  on conflict(business_id,country_code,rule_type,rule_key,effective_from) do nothing;

  insert into payroll_country_rules(business_id,country_code,rule_type,rule_key,json_value,effective_from,effective_to,source_note) values
    (p_business_id,'NZ','paye','annual_brackets',
      '[{"max":15600,"rate":0.105,"offset":0},{"max":53500,"rate":0.175,"offset":1092},{"max":78100,"rate":0.30,"offset":7779.5},{"max":180000,"rate":0.33,"offset":10122.5},{"max":null,"rate":0.39,"offset":20922.5}]'::jsonb,
      '2026-04-01','2027-03-31','IRD 2026/27 payroll rules'),
    (p_business_id,'NZ','paye','secondary_rates',
      '{"SB":0.1225,"S":0.1925,"SH":0.3175,"ST":0.3475,"SA":0.4075,"ND":0.4675,"NSW":0.1225,"CAE":0.1925,"EDW":0.1925}'::jsonb,
      '2026-04-01','2027-03-31','IRD 2026/27 payroll rules'),
    (p_business_id,'NZ','paye','ietc',
      '{"min_income":24000,"full_to":66000,"max_income":70000,"credit":520,"abatement":0.13}'::jsonb,
      '2026-04-01','2027-03-31','IRD 2026/27 payroll rules'),
    (p_business_id,'NZ','esct','annual_rates',
      '[{"max":18720,"rate":0.105},{"max":64200,"rate":0.175},{"max":93720,"rate":0.30},{"max":216000,"rate":0.33},{"max":null,"rate":0.39}]'::jsonb,
      '2026-04-01','2027-03-31','IRD 2026/27 payroll rules')
  on conflict(business_id,country_code,rule_type,rule_key,effective_from) do nothing;
end$$;
grant execute on function public.v55_seed_payroll_defaults(uuid) to authenticated;

notify pgrst,'reload schema';
