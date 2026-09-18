-- V61.73-P2 — Effective-Dated NZ Payroll Rules Foundation
-- Additive/prospective only. Does not change payroll calculation formulas or historical payroll records.

begin;

-- 1) Current statutory defaults belong in the authoritative effective-dated country rule set.
-- PAYG annual holiday minimum: current Holidays Act / Employment NZ guidance.
insert into public.country_payroll_rules(
  country_code,rule_type,rule_key,numeric_value,effective_from,effective_to,active,source_note
)
values (
  'NZ','holidays','payg_minimum_rate',8,'2004-04-01',null,true,
  'Employment New Zealand — Pay-as-you-go annual holiday payments: minimum 8% of gross earnings. https://www.employment.govt.nz/pay-and-hours/pay-and-wages/leave-and-holiday-pay/pay-as-you-go-annual-holiday-payments'
)
on conflict (country_code,rule_type,rule_key,effective_from) do nothing;

-- KiwiSaver 2026 defaults are already seeded by the existing rules architecture in the audited baseline.
-- Do not overwrite an existing authoritative version here.

-- 2) Statutory earnings-classification foundation. Nullable means "not yet classified".
alter table public.payroll_pay_items
  add column if not exists statutory_earning_code text null,
  add column if not exists holidays_gross_earnings_mode text null,
  add column if not exists owp_inclusion_mode text null,
  add column if not exists rdp_inclusion_mode text null,
  add column if not exists adp_inclusion_mode text null,
  add column if not exists classification_notes text null;

do $$ begin
  alter table public.payroll_pay_items add constraint payroll_pay_items_statutory_earning_code_check
    check (statutory_earning_code is null or statutory_earning_code ~ '^[a-z][a-z0-9_]{1,63}$');
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.payroll_pay_items add constraint payroll_pay_items_holidays_gross_mode_check
    check (holidays_gross_earnings_mode is null or holidays_gross_earnings_mode in ('include','exclude','conditional','needs_confirmation'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.payroll_pay_items add constraint payroll_pay_items_owp_mode_check
    check (owp_inclusion_mode is null or owp_inclusion_mode in ('include','exclude','conditional','needs_confirmation'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.payroll_pay_items add constraint payroll_pay_items_rdp_mode_check
    check (rdp_inclusion_mode is null or rdp_inclusion_mode in ('include','exclude','conditional','needs_confirmation'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.payroll_pay_items add constraint payroll_pay_items_adp_mode_check
    check (adp_inclusion_mode is null or adp_inclusion_mode in ('include','exclude','conditional','needs_confirmation'));
exception when duplicate_object then null; end $$;

create index if not exists payroll_pay_items_statutory_code_idx
  on public.payroll_pay_items(business_id,statutory_earning_code)
  where statutory_earning_code is not null;

-- 3) Effective-dated employee work patterns. No OWD inference is performed in P2.
create table if not exists public.payroll_employee_work_patterns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete cascade,
  effective_from date not null,
  effective_to date null,
  pattern_type text not null check(pattern_type in ('fixed_weekly','rotating','roster','variable','other')),
  pattern_json jsonb not null default '{}'::jsonb,
  expected_weekly_hours numeric(10,2) null check(expected_weekly_hours is null or expected_weekly_hours>=0),
  source text null,
  notes text null,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  constraint payroll_employee_work_patterns_dates_check check(effective_to is null or effective_to>=effective_from)
);
create index if not exists payroll_employee_work_patterns_lookup_idx
  on public.payroll_employee_work_patterns(business_id,employee_id,effective_from,effective_to);

-- 4) Employer/system-supported OWD determination evidence store. P4 supplies decision logic.
create table if not exists public.payroll_owd_determinations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete cascade,
  relevant_date date not null,
  determination text not null check(determination in ('yes','no','needs_confirmation')),
  method text not null check(method in ('system_supported','employer_determined')),
  evidence_snapshot jsonb not null default '{}'::jsonb,
  employer_reason text null,
  determined_by uuid default auth.uid(),
  determined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,employee_id,relevant_date)
);
create index if not exists payroll_owd_determinations_lookup_idx
  on public.payroll_owd_determinations(business_id,employee_id,relevant_date);

-- 5) Auditable statutory leave calculation record foundation. No formulas are implemented in P2.
create table if not exists public.payroll_statutory_leave_calculations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  leave_type_id uuid null references public.payroll_leave_types(id) on delete set null,
  leave_transaction_id uuid null references public.payroll_leave_transactions(id) on delete set null,
  pay_run_id uuid null references public.payroll_pay_runs(id) on delete set null,
  owd_determination_id uuid null references public.payroll_owd_determinations(id) on delete set null,
  statutory_leave_code text null,
  calculation_type text not null check(calculation_type in ('annual_holiday','sick_leave','bereavement_leave','family_violence_leave','public_holiday','alternative_holiday','final_pay','other')),
  relevant_from date not null,
  relevant_to date null,
  rule_version text null,
  rules_snapshot jsonb not null default '{}'::jsonb,
  input_snapshot jsonb not null default '{}'::jsonb,
  owd_evidence_snapshot jsonb not null default '{}'::jsonb,
  owp_amount numeric(14,2) null,
  awe_amount numeric(14,2) null,
  rdp_amount numeric(14,2) null,
  adp_amount numeric(14,2) null,
  selected_method text null,
  selected_amount numeric(14,2) null,
  confirmation_state text not null default 'needs_confirmation' check(confirmation_state in ('needs_confirmation','confirmed','not_required')),
  explanation_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  constraint payroll_statutory_leave_calculations_dates_check check(relevant_to is null or relevant_to>=relevant_from)
);
create index if not exists payroll_statutory_leave_calc_employee_idx
  on public.payroll_statutory_leave_calculations(business_id,employee_id,relevant_from);
create index if not exists payroll_statutory_leave_calc_payrun_idx
  on public.payroll_statutory_leave_calculations(business_id,pay_run_id)
  where pay_run_id is not null;

-- 6) Statutory leave representation is additive. Existing balance_hours/hours remain authoritative legacy data.
alter table public.payroll_employee_leave
  add column if not exists statutory_quantity numeric(12,4) null,
  add column if not exists statutory_unit text null,
  add column if not exists display_hours numeric(12,4) null,
  add column if not exists statutory_leave_code text null;

alter table public.payroll_leave_transactions
  add column if not exists statutory_quantity numeric(12,4) null,
  add column if not exists statutory_unit text null,
  add column if not exists display_hours numeric(12,4) null,
  add column if not exists statutory_leave_code text null;

do $$ declare t text; begin
  foreach t in array array['payroll_employee_leave','payroll_leave_transactions'] loop
    begin execute format('alter table public.%I add constraint %I check (statutory_quantity is null or statutory_quantity>=0)',t,t||'_statutory_quantity_check'); exception when duplicate_object then null; end;
    begin execute format('alter table public.%I add constraint %I check (statutory_unit is null or statutory_unit in (''hours'',''days'',''weeks''))',t,t||'_statutory_unit_check'); exception when duplicate_object then null; end;
    begin execute format('alter table public.%I add constraint %I check (display_hours is null or display_hours>=0)',t,t||'_display_hours_check'); exception when duplicate_object then null; end;
    begin execute format('alter table public.%I add constraint %I check (statutory_leave_code is null or statutory_leave_code ~ ''^[a-z][a-z0-9_]{1,63}$'')',t,t||'_statutory_leave_code_check'); exception when duplicate_object then null; end;
  end loop;
end $$;

-- 7) Centrally controlled/versionable public-holiday calendar. Ordinary tenants are read-only.
create table if not exists public.payroll_public_holidays (
  id uuid primary key default gen_random_uuid(),
  jurisdiction char(2) not null default 'NZ',
  region_code text null,
  holiday_identifier text not null,
  holiday_name text not null,
  actual_date date not null,
  observed_date date not null,
  calendar_version text not null,
  effective_from date not null,
  effective_to date null,
  active boolean not null default true,
  source_reference text not null,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  constraint payroll_public_holidays_jurisdiction_check check(jurisdiction ~ '^[A-Z]{2}$'),
  constraint payroll_public_holidays_identifier_check check(holiday_identifier ~ '^[a-z][a-z0-9_]{1,63}$'),
  constraint payroll_public_holidays_dates_check check(effective_to is null or effective_to>=effective_from)
);
create unique index if not exists payroll_public_holidays_version_unique_idx
  on public.payroll_public_holidays(jurisdiction,coalesce(region_code,''),holiday_identifier,observed_date,calendar_version);
create index if not exists payroll_public_holidays_lookup_idx
  on public.payroll_public_holidays(jurisdiction,region_code,observed_date,active);

-- 8) Same-business FK validation for all new business-owned foundations.
create or replace function public.v6173p2_validate_payroll_foundation_refs()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.employee_id is not null and not exists(
    select 1 from public.payroll_employees e where e.id=new.employee_id and e.business_id=new.business_id
  ) then raise exception 'Employee does not belong to this business'; end if;

  if tg_table_name='payroll_statutory_leave_calculations' then
    if new.leave_type_id is not null and not exists(select 1 from public.payroll_leave_types l where l.id=new.leave_type_id and l.business_id=new.business_id) then raise exception 'Leave type does not belong to this business'; end if;
    if new.leave_transaction_id is not null and not exists(select 1 from public.payroll_leave_transactions l where l.id=new.leave_transaction_id and l.business_id=new.business_id and l.employee_id=new.employee_id) then raise exception 'Leave transaction does not belong to this employee/business'; end if;
    if new.pay_run_id is not null and not exists(select 1 from public.payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
    if new.owd_determination_id is not null and not exists(select 1 from public.payroll_owd_determinations o where o.id=new.owd_determination_id and o.business_id=new.business_id and o.employee_id=new.employee_id) then raise exception 'OWD determination does not belong to this employee/business'; end if;
  end if;
  return new;
end $$;

do $$ declare t text; begin
  foreach t in array array['payroll_employee_work_patterns','payroll_owd_determinations','payroll_statutory_leave_calculations'] loop
    execute format('drop trigger if exists v6173p2_validate_refs on public.%I',t);
    execute format('create trigger v6173p2_validate_refs before insert or update on public.%I for each row execute function public.v6173p2_validate_payroll_foundation_refs()',t);
  end loop;
end $$;

-- 9) RLS. Reuse the established payroll access gate for business-owned data.
do $$ declare t text; begin
  foreach t in array array['payroll_employee_work_patterns','payroll_owd_determinations','payroll_statutory_leave_calculations'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists v6173p2_payroll_tenant_all on public.%I',t);
    execute format('create policy v6173p2_payroll_tenant_all on public.%I for all to authenticated using (public.v55_payroll_access(business_id)) with check (public.v55_payroll_access(business_id))',t);
  end loop;
end $$;

alter table public.payroll_public_holidays enable row level security;
drop policy if exists payroll_public_holidays_read on public.payroll_public_holidays;
create policy payroll_public_holidays_read on public.payroll_public_holidays for select to authenticated using (true);
drop policy if exists payroll_public_holidays_admin_insert on public.payroll_public_holidays;
create policy payroll_public_holidays_admin_insert on public.payroll_public_holidays for insert to authenticated with check (public.is_super_admin());
drop policy if exists payroll_public_holidays_admin_update on public.payroll_public_holidays;
create policy payroll_public_holidays_admin_update on public.payroll_public_holidays for update to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
drop policy if exists payroll_public_holidays_admin_delete on public.payroll_public_holidays;
create policy payroll_public_holidays_admin_delete on public.payroll_public_holidays for delete to authenticated using (public.is_super_admin());

commit;
