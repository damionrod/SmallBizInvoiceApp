-- v60.2 — Country-based Super Admin payroll tax rules
-- Targeted change only: adds central country/effective-dated payroll rules.

create table if not exists public.country_payroll_rules (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null,
  rule_type text not null,
  rule_key text not null,
  numeric_value numeric null,
  text_value text null,
  json_value jsonb null,
  effective_from date not null,
  effective_to date null,
  active boolean not null default true,
  source_note text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint country_payroll_rules_country_check check (country_code ~ '^[A-Z]{2}$'),
  constraint country_payroll_rules_dates_check check (effective_to is null or effective_to >= effective_from),
  constraint country_payroll_rules_one_value_check check (num_nonnulls(numeric_value,text_value,json_value)=1),
  constraint country_payroll_rules_version_unique unique(country_code,rule_type,rule_key,effective_from)
);

create index if not exists country_payroll_rules_lookup_idx on public.country_payroll_rules(country_code,rule_type,rule_key,effective_from,effective_to) where active=true;

alter table public.country_payroll_rules enable row level security;
drop policy if exists country_payroll_rules_read on public.country_payroll_rules;
create policy country_payroll_rules_read on public.country_payroll_rules for select to authenticated using (true);
drop policy if exists country_payroll_rules_admin_insert on public.country_payroll_rules;
create policy country_payroll_rules_admin_insert on public.country_payroll_rules for insert to authenticated with check (public.is_super_admin());
drop policy if exists country_payroll_rules_admin_update on public.country_payroll_rules;
create policy country_payroll_rules_admin_update on public.country_payroll_rules for update to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
drop policy if exists country_payroll_rules_admin_delete on public.country_payroll_rules;
create policy country_payroll_rules_admin_delete on public.country_payroll_rules for delete to authenticated using (public.is_super_admin());

-- Seed the central NZ rule versions from the existing tenant rule table.
-- This copies rule definitions only; it does not alter any tenant payroll records.
insert into public.country_payroll_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,effective_to,active,source_note)
select distinct on (upper(trim(country_code::text)),rule_type,rule_key,effective_from)
  upper(trim(country_code::text))::char(2),rule_type,rule_key,numeric_value,text_value,json_value,effective_from,effective_to,active,source_note
from public.payroll_country_rules
where active=true and country_code is not null
order by upper(trim(country_code::text)),rule_type,rule_key,effective_from,created_at desc
on conflict (country_code,rule_type,rule_key,effective_from) do nothing;

-- Tax-code behaviour is also country data, not application code.
insert into public.country_payroll_rules(country_code,rule_type,rule_key,json_value,effective_from,effective_to,active,source_note)
values ('NZ','paye','tax_codes','[
 {"code":"M","label":"M","mode":"primary","ietc":false,"student_loan":false,"student_loan_threshold":true},
 {"code":"ME","label":"ME","mode":"primary","ietc":true,"student_loan":false,"student_loan_threshold":true},
 {"code":"M SL","label":"M SL","mode":"primary","ietc":false,"student_loan":true,"student_loan_threshold":true},
 {"code":"ME SL","label":"ME SL","mode":"primary","ietc":true,"student_loan":true,"student_loan_threshold":true},
 {"code":"SB","label":"SB","mode":"secondary","secondary_key":"SB","student_loan":false,"student_loan_threshold":false},
 {"code":"S","label":"S","mode":"secondary","secondary_key":"S","student_loan":false,"student_loan_threshold":false},
 {"code":"SH","label":"SH","mode":"secondary","secondary_key":"SH","student_loan":false,"student_loan_threshold":false},
 {"code":"ST","label":"ST","mode":"secondary","secondary_key":"ST","student_loan":false,"student_loan_threshold":false},
 {"code":"SA","label":"SA","mode":"secondary","secondary_key":"SA","student_loan":false,"student_loan_threshold":false},
 {"code":"SB SL","label":"SB SL","mode":"secondary","secondary_key":"SB","student_loan":true,"student_loan_threshold":false},
 {"code":"S SL","label":"S SL","mode":"secondary","secondary_key":"S","student_loan":true,"student_loan_threshold":false},
 {"code":"SH SL","label":"SH SL","mode":"secondary","secondary_key":"SH","student_loan":true,"student_loan_threshold":false},
 {"code":"ST SL","label":"ST SL","mode":"secondary","secondary_key":"ST","student_loan":true,"student_loan_threshold":false},
 {"code":"SA SL","label":"SA SL","mode":"secondary","secondary_key":"SA","student_loan":true,"student_loan_threshold":false},
 {"code":"CAE","label":"CAE","mode":"secondary","secondary_key":"CAE","student_loan":false,"student_loan_threshold":false},
 {"code":"EDW","label":"EDW","mode":"secondary","secondary_key":"EDW","student_loan":false,"student_loan_threshold":false},
 {"code":"ND","label":"ND","mode":"secondary","secondary_key":"ND","student_loan":false,"student_loan_threshold":false},
 {"code":"NSW","label":"NSW","mode":"secondary","secondary_key":"NSW","student_loan":false,"student_loan_threshold":false}
]'::jsonb,'2026-04-01','2027-03-31',true,'Migrated NZ employee tax-code behaviour for v60.2')
on conflict (country_code,rule_type,rule_key,effective_from) do nothing;
