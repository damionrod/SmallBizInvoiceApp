-- V61.73-P6B NZ PAYG & FINAL PAY ENGINE — REVIEW ONLY — DO NOT APPLY
-- Keep outside supabase/migrations until separately approved.

create table if not exists public.payroll_payg_eligibility_determinations (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 employee_id uuid not null references public.payroll_employees(id) on delete cascade,
 effective_from date not null, effective_to date null, route text not null check(route in ('fixed_term','irregular_intermittent')),
 status text not null default 'draft' check(status in ('draft','needs_confirmation','eligible','ineligible','superseded')),
 agreement_confirmed boolean not null default false, separately_identifiable_confirmed boolean not null default false,
 fixed_term_start date null, fixed_term_end date null, fixed_term_reason text null, reasonable_grounds_confirmed boolean null,
 irregularity_evidence jsonb not null default '{}'::jsonb, impracticability_reason text null,
 statutory_minimum_rate numeric(8,4) null, contractual_rate numeric(8,4) null,
 rules_snapshot jsonb not null default '{}'::jsonb, evidence_snapshot jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(), created_by uuid null, updated_at timestamptz not null default now(), updated_by uuid null
);
create table if not exists public.payroll_annual_holiday_entitlement_periods (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 employee_id uuid not null references public.payroll_employees(id) on delete cascade,
 entitlement_date date not null, period_start date null, period_end date null,
 statutory_weeks numeric(10,4) not null default 0, contractual_extra_weeks numeric(10,4) not null default 0,
 taken_weeks numeric(10,4) not null default 0, cashed_up_weeks numeric(10,4) not null default 0, advance_weeks numeric(10,4) not null default 0,
 remaining_statutory_weeks numeric(10,4) not null default 0, week_evidence jsonb not null default '{}'::jsonb,
 status text not null default 'draft' check(status in ('draft','needs_confirmation','confirmed','superseded')),
 created_at timestamptz not null default now(), created_by uuid null, updated_at timestamptz not null default now(), updated_by uuid null,
 unique(business_id,employee_id,entitlement_date)
);
create table if not exists public.payroll_final_pay_calculations (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 employee_id uuid not null references public.payroll_employees(id) on delete cascade, pay_run_id uuid null references public.payroll_pay_runs(id) on delete set null,
 termination_date date not null, statutory_path text not null check(statutory_path in ('s23','s24_s25')),
 status text not null default 'draft' check(status in ('draft','needs_confirmation','ready','finalised','reversed','corrected')),
 completed_gross_basis numeric(14,2) null, final_percentage numeric(8,4) null, final_percentage_amount numeric(14,2) null,
 deductions_amount numeric(14,2) null, final_holiday_component numeric(14,2) null,
 rules_snapshot jsonb not null default '{}'::jsonb, calculation_snapshot jsonb not null default '{}'::jsonb, explanation_snapshot jsonb not null default '{}'::jsonb,
 finalised_at timestamptz null, finalised_by uuid null, reversed_calculation_id uuid null references public.payroll_final_pay_calculations(id),
 created_at timestamptz not null default now(), created_by uuid null, updated_at timestamptz not null default now(), updated_by uuid null
);
create table if not exists public.payroll_final_pay_components (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 final_pay_calculation_id uuid not null references public.payroll_final_pay_calculations(id) on delete cascade,
 employee_id uuid not null references public.payroll_employees(id) on delete cascade,
 component_code text not null, description text null, amount numeric(14,2) not null,
 holidays_gross_earnings_mode text not null check(holidays_gross_earnings_mode in ('include','exclude','needs_confirmation')),
 source_type text null, source_id uuid null, source_snapshot jsonb not null default '{}'::jsonb, sort_order integer not null default 0,
 created_at timestamptz not null default now()
);

alter table public.payroll_payg_eligibility_determinations enable row level security;
alter table public.payroll_annual_holiday_entitlement_periods enable row level security;
alter table public.payroll_final_pay_calculations enable row level security;
alter table public.payroll_final_pay_components enable row level security;

do $$ declare t text; begin
 foreach t in array array['payroll_payg_eligibility_determinations','payroll_annual_holiday_entitlement_periods','payroll_final_pay_calculations','payroll_final_pay_components'] loop
  execute format('create policy %I on public.%I for all to authenticated using (public.v55_payroll_access(business_id)) with check (public.v55_payroll_access(business_id))',t||'_tenant',t);
 end loop;
end $$;

create or replace function public.v6173p6b_validate_refs() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if not exists(select 1 from public.payroll_employees e where e.id=new.employee_id and e.business_id=new.business_id) then raise exception 'Employee does not belong to this business'; end if;
 if tg_table_name='payroll_final_pay_components' and not exists(select 1 from public.payroll_final_pay_calculations c where c.id=new.final_pay_calculation_id and c.business_id=new.business_id and c.employee_id=new.employee_id) then raise exception 'Final-pay calculation does not belong to this employee/business'; end if;
 return new;
end $$;
revoke all on function public.v6173p6b_validate_refs() from public,anon;
grant execute on function public.v6173p6b_validate_refs() to authenticated;

do $$ declare t text; begin foreach t in array array['payroll_payg_eligibility_determinations','payroll_annual_holiday_entitlement_periods','payroll_final_pay_calculations','payroll_final_pay_components'] loop execute format('create trigger %I before insert or update on public.%I for each row execute function public.v6173p6b_validate_refs()',t||'_validate_refs',t); end loop; end $$;

create or replace function public.v6173p6b_protect_finalised() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if old.status='finalised' then raise exception 'Finalised final-pay evidence is immutable; use correction/reversal'; end if; return new;
end $$;
revoke all on function public.v6173p6b_protect_finalised() from public,anon;
grant execute on function public.v6173p6b_protect_finalised() to authenticated;
create trigger payroll_final_pay_calculations_protect before update or delete on public.payroll_final_pay_calculations for each row execute function public.v6173p6b_protect_finalised();

-- Explicit NZ effective-dated P6 rules. No AU rows.
insert into public.country_payroll_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,active,source_note)
values
 ('NZ','final_pay','final_holiday_percentage',8,null,null,'2004-04-01',true,'Holidays Act current-regime final-pay percentage; review-only P6B'),
 ('NZ','final_pay','final_pay_regime',null,'holidays_act_2003',null,'2004-04-01',true,'P6 jurisdiction/regime guard')
on conflict do nothing;

-- No historical UPDATE/backfill. No P3/P4/P5 changes. No P7 tax changes.

-- P6B.1 authoritative entitlement/reconciliation evidence hardening (review-only).
-- Required because the same persisted entitlement evidence must reconstruct both s24 valuation
-- and the non-mutating notional annual-holiday projection; caller-supplied day counts are not authoritative.
alter table public.payroll_annual_holiday_entitlement_periods
 add column if not exists evidence_as_at date null,
 add column if not exists work_pattern_evidence jsonb not null default '{}'::jsonb,
 add column if not exists notional_sequence_snapshot jsonb not null default '[]'::jsonb,
 add column if not exists reconciliation_snapshot jsonb not null default '{}'::jsonb;

-- Protect component evidence belonging to a finalised final-pay calculation.
create or replace function public.v6173p6b_protect_finalised_component() returns trigger
language plpgsql security invoker set search_path=public as $$
declare calc_id uuid;
begin
 calc_id := case when tg_op='DELETE' then old.final_pay_calculation_id else new.final_pay_calculation_id end;
 if exists(select 1 from public.payroll_final_pay_calculations c where c.id=calc_id and c.status='finalised') then
   raise exception 'Finalised final-pay component evidence is immutable; use correction/reversal';
 end if;
 return case when tg_op='DELETE' then old else new end;
end $$;
revoke all on function public.v6173p6b_protect_finalised_component() from public,anon;
grant execute on function public.v6173p6b_protect_finalised_component() to authenticated;
drop trigger if exists payroll_final_pay_components_protect on public.payroll_final_pay_components;
create trigger payroll_final_pay_components_protect before update or delete on public.payroll_final_pay_components
for each row execute function public.v6173p6b_protect_finalised_component();
