-- V61.73-P5B — NZ Public Holiday & Alternative Holiday Engine
-- REVIEW ONLY. DO NOT APPLY IN THIS PHASE.
-- Prospective/additive only. Current Holidays Act regime only. No historical recalculation/backfill.
begin;

-- Minimum central-calendar metadata. Existing central table and Super Admin RLS remain authoritative.
alter table public.payroll_public_holidays add column if not exists holiday_scope text null;
alter table public.payroll_public_holidays add column if not exists holiday_family text null;
alter table public.payroll_public_holidays add column if not exists weekend_transfer_rule text null;
alter table public.payroll_public_holidays add column if not exists province_identifier text null;
alter table public.payroll_public_holidays add column if not exists source_retrieved_at timestamptz null;
do $$ begin alter table public.payroll_public_holidays add constraint payroll_public_holidays_p5b_scope_check check(holiday_scope is null or holiday_scope in ('national','regional')); exception when duplicate_object then null; end $$;
do $$ begin alter table public.payroll_public_holidays add constraint payroll_public_holidays_p5b_weekend_rule_check check(weekend_transfer_rule is null or weekend_transfer_rule in ('none','christmas_new_year','waitangi_anzac')); exception when duplicate_object then null; end $$;
create unique index if not exists payroll_public_holidays_p5b_identity_unique on public.payroll_public_holidays(jurisdiction,holiday_identifier,actual_date,coalesce(region_code,''),calendar_version);

-- Explicit employee-specific regional applicability evidence. Never derived from home/business address.
create table if not exists public.payroll_public_holiday_regions(
 id uuid primary key default gen_random_uuid(), business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
 employee_id uuid not null references public.payroll_employees(id) on delete cascade, region_code text not null,
 effective_from date not null, effective_to date null,
 determination_source text not null check(determination_source in ('employment_agreement','usual_place_of_work','employer_employee_agreement','custom_practice','employer_confirmation')),
 evidence_snapshot jsonb not null default '{}'::jsonb, confirmed boolean not null default false,
 confirmed_by uuid null, confirmed_at timestamptz null,
 created_at timestamptz not null default now(), created_by uuid default auth.uid(), updated_at timestamptz not null default now(), updated_by uuid default auth.uid(),
 check(effective_to is null or effective_to>=effective_from)
);

-- Written employee-specific transfer evidence. No transfer may be inferred from timesheets.
create table if not exists public.payroll_public_holiday_transfers(
 id uuid primary key default gen_random_uuid(), business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
 employee_id uuid not null references public.payroll_employees(id) on delete cascade,
 public_holiday_id uuid null references public.payroll_public_holidays(id), holiday_identifier text not null,
 transfer_type text not null check(transfer_type in ('whole_day','shift_part')),
 original_date date not null, original_start timestamptz null, original_end timestamptz null,
 destination_date date null, destination_start timestamptz null, destination_end timestamptz null,
 written_agreement_confirmed boolean not null default false, anti_avoidance_confirmed boolean not null default false,
 shift_part_criteria_met boolean null, evidence_snapshot jsonb not null default '{}'::jsonb,
 agreed_at timestamptz null, status text not null default 'active' check(status in ('active','superseded','cancelled')),
 created_at timestamptz not null default now(), created_by uuid default auth.uid(), updated_at timestamptz not null default now(), updated_by uuid default auth.uid(),
 check(destination_date is not null or (destination_start is not null and destination_end is not null)),
 check(destination_end is null or destination_start is null or destination_end>destination_start)
);

-- Whole-day alternative-holiday source-of-truth lifecycle. P6 termination amount deliberately absent.
create table if not exists public.payroll_alternative_holiday_entitlements(
 id uuid primary key default gen_random_uuid(), business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
 employee_id uuid not null references public.payroll_employees(id) on delete cascade,
 source_public_holiday_id uuid null references public.payroll_public_holidays(id), holiday_identifier text not null,
 source_observance_date date not null, source_owd_determination_id uuid null references public.payroll_owd_determinations(id),
 source_statutory_calculation_id uuid null references public.payroll_statutory_leave_calculations(id),
 earned_date date not null, statutory_quantity numeric(12,4) not null default 1 check(statutory_quantity=1), statutory_unit text not null default 'days' check(statutory_unit='days'),
 status text not null default 'available' check(status in ('available','taken','paid_exchange','termination_pending','termination_paid','voided')),
 taken_date date null, taken_leave_transaction_id uuid null references public.payroll_leave_transactions(id), taken_statutory_calculation_id uuid null references public.payroll_statutory_leave_calculations(id),
 cashout_requested_at timestamptz null, cashout_agreed_at timestamptz null, cashout_amount numeric(14,2) null,
 evidence_snapshot jsonb not null default '{}'::jsonb, rules_snapshot jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(), created_by uuid default auth.uid(), updated_at timestamptz not null default now(), updated_by uuid default auth.uid()
);
create unique index if not exists payroll_alt_holiday_p5b_source_unique on public.payroll_alternative_holiday_entitlements(business_id,employee_id,holiday_identifier,source_observance_date) where status<>'voided';

-- Prospective exact shift-boundary evidence; existing historical time-only rows remain untouched.
alter table public.payroll_timesheets add column if not exists work_started_at timestamptz null;
alter table public.payroll_timesheets add column if not exists work_ended_at timestamptz null;
alter table public.payroll_timesheets add column if not exists work_interval_evidence jsonb null;
do $$ begin alter table public.payroll_timesheets add constraint payroll_timesheets_p5b_work_interval_check check(work_ended_at is null or work_started_at is null or work_ended_at>work_started_at); exception when duplicate_object then null; end $$;

-- Explicit section-50 classification; RDP mode is not a proxy for penal-rate status.
alter table public.payroll_pay_items add column if not exists section50_penal_rate_mode text null;
do $$ begin alter table public.payroll_pay_items add constraint payroll_pay_items_p5b_penal_mode_check check(section50_penal_rate_mode is null or section50_penal_rate_mode in ('penal','non_penal','needs_confirmation')); exception when duplicate_object then null; end $$;

-- Current-law effective-dated P5 policy. Text-like values use json_value; no runtime formula/eval engine.
insert into public.country_payroll_rules(country_code,rule_type,rule_key,json_value,effective_from,active,source_note) values
('NZ','public_holiday','public_holiday_regime','"holidays_act_2003"'::jsonb,'2003-04-01',true,'Current Holidays Act 2003 regime. Employment Leave Act 2026 future commencement is out of P5 scope.'),
('NZ','public_holiday','worked_public_holiday_comparator','"s50_greater_of"'::jsonb,'2003-04-01',true,'Holidays Act 2003 s50 greater-of worked-public-holiday comparator.'),
('NZ','public_holiday','public_holiday_day_boundary','"midnight_to_midnight"'::jsonb,'2003-04-01',true,'Current public-holiday day boundary unless lawfully transferred.'),
('NZ','public_holiday','public_holiday_only_worker_alt_holiday_exception','true'::jsonb,'2003-04-01',true,'Holidays Act s56 public-holiday-only worker exception.'),
('NZ','public_holiday','public_holiday_transfer_written_evidence_required','true'::jsonb,'2003-04-01',true,'Written transfer evidence required by current-law transfer path.')
on conflict(country_code,rule_type,rule_key,effective_from) do nothing;
insert into public.country_payroll_rules(country_code,rule_type,rule_key,numeric_value,effective_from,active,source_note) values
('NZ','public_holiday','alternative_holiday_cashout_wait_months',12,'2003-04-01',true,'Current-law voluntary alternative-holiday exchange waiting period.'),
('NZ','public_holiday','alternative_holiday_employer_notice_days',14,'2003-04-01',true,'Current-law employer-directed alternative-holiday notice period.')
on conflict(country_code,rule_type,rule_key,effective_from) do nothing;

-- Controlled bounded 2026 NZ calendar seed. Regional rows are central reference data; employee applicability still requires confirmed employee-specific evidence.
insert into public.payroll_public_holidays(jurisdiction,region_code,holiday_identifier,holiday_name,actual_date,observed_date,calendar_version,effective_from,active,source_reference,holiday_scope,holiday_family,weekend_transfer_rule,province_identifier,source_retrieved_at) values
('NZ',null,'new_years_day','New Year''s Day','2026-01-01','2026-01-01','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','fixed_date','christmas_new_year',null,'2026-09-18T00:00:00Z'),
('NZ',null,'day_after_new_year','Day after New Year''s Day','2026-01-02','2026-01-02','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','fixed_date','christmas_new_year',null,'2026-09-18T00:00:00Z'),
('NZ',null,'waitangi_day','Waitangi Day','2026-02-06','2026-02-06','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','fixed_date','waitangi_anzac',null,'2026-09-18T00:00:00Z'),
('NZ',null,'good_friday','Good Friday','2026-04-03','2026-04-03','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','easter','none',null,'2026-09-18T00:00:00Z'),
('NZ',null,'easter_monday','Easter Monday','2026-04-06','2026-04-06','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','easter','none',null,'2026-09-18T00:00:00Z'),
('NZ',null,'anzac_day','Anzac Day','2026-04-25','2026-04-27','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','fixed_date','waitangi_anzac',null,'2026-09-18T00:00:00Z'),
('NZ',null,'kings_birthday','King''s Birthday','2026-06-01','2026-06-01','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','first_monday_june','none',null,'2026-09-18T00:00:00Z'),
('NZ',null,'matariki','Matariki','2026-07-10','2026-07-10','NZ-P5B-2026-v1','2026-01-01',true,'Te Kāhui o Matariki Public Holiday Act 2022 Schedule 1; Employment New Zealand, retrieved 2026-09-18','national','matariki_published','none',null,'2026-09-18T00:00:00Z'),
('NZ',null,'labour_day','Labour Day','2026-10-26','2026-10-26','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','fourth_monday_october','none',null,'2026-09-18T00:00:00Z'),
('NZ',null,'christmas_day','Christmas Day','2026-12-25','2026-12-25','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','fixed_date','christmas_new_year',null,'2026-09-18T00:00:00Z'),
('NZ',null,'boxing_day','Boxing Day','2026-12-26','2026-12-28','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand — Public holidays and anniversary dates, retrieved 2026-09-18','national','fixed_date','christmas_new_year',null,'2026-09-18T00:00:00Z'),
('NZ','AUK','auckland_anniversary','Auckland Anniversary Day','2026-01-29','2026-01-26','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','auckland','2026-09-18T00:00:00Z'),
('NZ','TAR','taranaki_anniversary','Taranaki Anniversary Day','2026-03-31','2026-03-09','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','taranaki','2026-09-18T00:00:00Z'),
('NZ','HKB','hawkes_bay_anniversary','Hawke''s Bay Anniversary Day','2026-11-01','2026-10-23','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','hawkes_bay','2026-09-18T00:00:00Z'),
('NZ','WGN','wellington_anniversary','Wellington Anniversary Day','2026-01-22','2026-01-19','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','wellington','2026-09-18T00:00:00Z'),
('NZ','MBH','marlborough_anniversary','Marlborough Anniversary Day','2026-11-01','2026-11-02','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','marlborough','2026-09-18T00:00:00Z'),
('NZ','NSN','nelson_anniversary','Nelson Anniversary Day','2026-02-01','2026-02-02','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','nelson','2026-09-18T00:00:00Z'),
('NZ','CAN','canterbury_anniversary','Canterbury Anniversary Day','2026-12-16','2026-11-13','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','canterbury','2026-09-18T00:00:00Z'),
('NZ','SCN','south_canterbury_anniversary','South Canterbury Anniversary Day','2026-12-16','2026-09-28','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','south_canterbury','2026-09-18T00:00:00Z'),
('NZ','WTC','westland_anniversary','Westland Anniversary Day','2026-12-01','2026-11-30','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','westland','2026-09-18T00:00:00Z'),
('NZ','OTA','otago_anniversary','Otago Anniversary Day','2026-03-23','2026-03-23','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; agreement/custom may be required','regional','provincial_anniversary','none','otago','2026-09-18T00:00:00Z'),
('NZ','STL','southland_anniversary','Southland Anniversary Day','2026-01-17','2026-04-07','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','southland','2026-09-18T00:00:00Z'),
('NZ','CIT','chatham_islands_anniversary','Chatham Islands Anniversary Day','2026-11-30','2026-11-30','NZ-P5B-2026-v1','2026-01-01',true,'Employment New Zealand 2026 anniversary reference; local council/custom confirmation remains employee evidence','regional','provincial_anniversary','none','chatham_islands','2026-09-18T00:00:00Z')
on conflict do nothing;

-- Same-business reference validation for P5 business-owned records.
create or replace function public.v6173p5b_validate_refs() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if not exists(select 1 from public.payroll_employees e where e.id=new.employee_id and e.business_id=new.business_id) then raise exception 'Employee does not belong to this business'; end if;
 return new;
end $$;
revoke execute on function public.v6173p5b_validate_refs() from public,anon;
grant execute on function public.v6173p5b_validate_refs() to authenticated;

do $$ declare t text; begin
 foreach t in array array['payroll_public_holiday_regions','payroll_public_holiday_transfers','payroll_alternative_holiday_entitlements'] loop
  execute format('drop trigger if exists v6173p5b_validate_refs on public.%I',t);
  execute format('create trigger v6173p5b_validate_refs before insert or update on public.%I for each row execute function public.v6173p5b_validate_refs()',t);
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists v6173p5b_payroll_tenant_all on public.%I',t);
  execute format('create policy v6173p5b_payroll_tenant_all on public.%I for all to authenticated using (public.v55_payroll_access(business_id)) with check (public.v55_payroll_access(business_id))',t);
 end loop;
end $$;

commit;
