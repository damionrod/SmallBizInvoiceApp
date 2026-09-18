-- V61.73-P4B.1 — NZ Statutory Leave Engine foundation + jurisdiction/effective-rule hardening
-- REVIEW ONLY. DO NOT APPLY IN THIS PHASE.
-- Prospective/additive only. No historical leave/payroll recalculation.
begin;

-- Controlled statutory identity on existing leave types.
alter table public.payroll_leave_types add column if not exists statutory_leave_code text null;
do $$ begin
  alter table public.payroll_leave_types add constraint payroll_leave_types_p4b_statutory_code_check
    check (statutory_leave_code is null or statutory_leave_code in ('sick_leave','bereavement_leave','family_violence_leave'));
exception when duplicate_object then null; end $$;
create unique index if not exists payroll_leave_types_p4b_statutory_unique
  on public.payroll_leave_types(business_id,statutory_leave_code) where statutory_leave_code is not null;

-- Map only exact existing Finlo defaults when no statutory identity exists. This does not reinterpret transactions/balances.
update public.payroll_leave_types l set statutory_leave_code='sick_leave'
where l.name='Sick Leave' and l.statutory_leave_code is null
  and exists(select 1 from public.payroll_settings ps where ps.business_id=l.business_id and upper(trim(ps.country_code))='NZ')
  and not exists(select 1 from public.payroll_leave_types x where x.business_id=l.business_id and x.statutory_leave_code='sick_leave');
update public.payroll_leave_types l set statutory_leave_code='bereavement_leave'
where l.name='Bereavement Leave' and l.statutory_leave_code is null
  and exists(select 1 from public.payroll_settings ps where ps.business_id=l.business_id and upper(trim(ps.country_code))='NZ')
  and not exists(select 1 from public.payroll_leave_types x where x.business_id=l.business_id and x.statutory_leave_code='bereavement_leave');

-- Prospective Family Violence Leave seed only where no statutory equivalent exists.
insert into public.payroll_leave_types(business_id,name,paid,archived,statutory_leave_code)
select ps.business_id,'Family Violence Leave',true,false,'family_violence_leave'
from public.payroll_settings ps
where upper(trim(ps.country_code))='NZ'
  and not exists(select 1 from public.payroll_leave_types l where l.business_id=ps.business_id and l.statutory_leave_code='family_violence_leave')
  and not exists(select 1 from public.payroll_leave_types l where l.business_id=ps.business_id and lower(trim(l.name))='family violence leave');
update public.payroll_leave_types l set statutory_leave_code='family_violence_leave'
where lower(trim(l.name))='family violence leave' and l.statutory_leave_code is null
  and exists(select 1 from public.payroll_settings ps where ps.business_id=l.business_id and upper(trim(ps.country_code))='NZ')
  and not exists(select 1 from public.payroll_leave_types x where x.business_id=l.business_id and x.statutory_leave_code='family_violence_leave');

-- Prospective statutory entitlement periods. Legacy balance_hours remains untouched.
create table if not exists public.payroll_statutory_leave_entitlements(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete cascade,
  statutory_leave_code text not null check(statutory_leave_code in ('sick_leave','family_violence_leave')),
  period_start date not null,
  period_end date not null,
  grant_days numeric(12,4) not null check(grant_days>=0),
  carry_forward_days numeric(12,4) not null default 0 check(carry_forward_days>=0),
  used_days numeric(12,4) not null default 0 check(used_days>=0),
  rule_version text not null,
  rules_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(), created_by uuid default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid default auth.uid(),
  check(period_end>=period_start), unique(business_id,employee_id,statutory_leave_code,period_start)
);

-- Event-based bereavement evidence; intentionally minimal narrative.
create table if not exists public.payroll_bereavement_events(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete cascade,
  event_date date not null,
  statutory_category text not null check(statutory_category in ('three_day','one_day')),
  employer_accepted boolean null,
  entitlement_days numeric(12,4) not null check(entitlement_days in (1,3)),
  used_days numeric(12,4) not null default 0 check(used_days>=0),
  evidence_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(), created_by uuid default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid default auth.uid()
);

-- Prospective RDP/ADP classification defaults for unclassified built-in items only. Taxable is never used as a proxy.
update public.payroll_pay_items set rdp_inclusion_mode='include' where name='Ordinary Hours' and statutory_earning_code='ordinary_earnings' and rdp_inclusion_mode is null and exists(select 1 from public.payroll_settings ps where ps.business_id=payroll_pay_items.business_id and upper(trim(ps.country_code))='NZ');
update public.payroll_pay_items set rdp_inclusion_mode='conditional' where name='Overtime' and statutory_earning_code='overtime' and rdp_inclusion_mode is null and exists(select 1 from public.payroll_settings ps where ps.business_id=payroll_pay_items.business_id and upper(trim(ps.country_code))='NZ');
update public.payroll_pay_items set rdp_inclusion_mode='needs_confirmation' where statutory_earning_code in ('bonus','commission','allowance','reimbursement') and rdp_inclusion_mode is null and exists(select 1 from public.payroll_settings ps where ps.business_id=payroll_pay_items.business_id and upper(trim(ps.country_code))='NZ');
update public.payroll_pay_items set adp_inclusion_mode=coalesce(holidays_gross_earnings_mode,'needs_confirmation') where adp_inclusion_mode is null and statutory_earning_code is not null and exists(select 1 from public.payroll_settings ps where ps.business_id=payroll_pay_items.business_id and upper(trim(ps.country_code))='NZ');

-- Statutory leave rules: centrally controlled and effective dated.
-- Effective dates are part of each rule version; runtime must fail closed if an applicable rule is absent.
insert into public.country_payroll_rules(country_code,rule_type,rule_key,numeric_value,effective_from,active,source_note) values
('NZ','statutory_leave','statutory_leave_eligibility_months',6,'2003-04-01',true,'Holidays Act 2003 / Employment New Zealand — qualifying period.'),
('NZ','statutory_leave','statutory_leave_work_test_average_hours_per_week',10,'2003-04-01',true,'Holidays Act 2003 — average 10 hours/week work test.'),
('NZ','statutory_leave','statutory_leave_work_test_min_hours_each_week',1,'2003-04-01',true,'Holidays Act 2003 — at least 1 hour every week alternative limb.'),
('NZ','statutory_leave','statutory_leave_work_test_min_hours_each_month',40,'2003-04-01',true,'Holidays Act 2003 — at least 40 hours every month alternative limb.'),
('NZ','statutory_leave','sick_leave_grant_days',10,'2021-07-24',true,'Holidays Act sick leave minimum increased to 10 days.'),
('NZ','statutory_leave','sick_leave_current_entitlement_cap_days',20,'2021-07-24',true,'Current statutory sick leave current-entitlement cap.'),
('NZ','statutory_leave','sick_leave_carry_forward_enabled',1,'2003-04-01',true,'Effective-dated statutory switch: unused sick leave may carry forward subject to the statutory cap.'),
('NZ','statutory_leave','bereavement_immediate_days',3,'2003-04-01',true,'Holidays Act bereavement qualifying category.'),
('NZ','statutory_leave','bereavement_other_days',1,'2003-04-01',true,'Holidays Act other accepted bereavement.'),
('NZ','statutory_leave','family_violence_eligibility_months',6,'2019-04-01',true,'Domestic Violence — Victims Protection Act changes: family violence leave qualifying period.'),
('NZ','statutory_leave','family_violence_grant_days',10,'2019-04-01',true,'Holidays Act family violence leave entitlement.'),
('NZ','statutory_leave','family_violence_carry_forward_enabled',0,'2019-04-01',true,'Effective-dated statutory switch: family violence leave does not carry forward.'),
('NZ','statutory_leave','adp_lookback_weeks',52,'2011-04-01',true,'Holidays Act s9A ADP lookback.')
on conflict(country_code,rule_type,rule_key,effective_from) do nothing;

insert into public.country_payroll_rules(country_code,rule_type,rule_key,json_value,effective_from,active,source_note) values
('NZ','statutory_leave','adp_permitted_triggers','["rdp_not_possible_or_practicable","daily_pay_varies_in_pay_period"]'::jsonb,'2011-04-01',true,'Holidays Act s9A — effective-dated identifiers for the circumstances in which ADP may be used.')
on conflict(country_code,rule_type,rule_key,effective_from) do nothing;

-- Canonical P4B work-pattern contract marker; data remains in P2 pattern_json.
alter table public.payroll_employee_work_patterns add column if not exists pattern_schema_version text null;

-- Same-business validation for additive P4B tables. SECURITY INVOKER: RLS remains authoritative.
create or replace function public.v6173p4b_validate_refs() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if not exists(select 1 from public.payroll_employees e where e.id=new.employee_id and e.business_id=new.business_id) then raise exception 'Employee does not belong to this business'; end if;
 return new;
end $$;
revoke execute on function public.v6173p4b_validate_refs() from public,anon;
grant execute on function public.v6173p4b_validate_refs() to authenticated;

do $$ declare t text; begin
 foreach t in array array['payroll_statutory_leave_entitlements','payroll_bereavement_events'] loop
  execute format('drop trigger if exists v6173p4b_validate_refs on public.%I',t);
  execute format('create trigger v6173p4b_validate_refs before insert or update on public.%I for each row execute function public.v6173p4b_validate_refs()',t);
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists v6173p4b_payroll_tenant_all on public.%I',t);
  execute format('create policy v6173p4b_payroll_tenant_all on public.%I for all to authenticated using (public.v55_payroll_access(business_id)) with check (public.v55_payroll_access(business_id))',t);
 end loop;
end $$;

commit;
