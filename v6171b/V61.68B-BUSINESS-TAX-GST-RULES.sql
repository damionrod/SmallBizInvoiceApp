-- V61.68B — NZ Business Tax/GST statutory rules and GST return period experience.
-- Additive only. Tenant circumstances remain in financial_settings. Finalised GST returns are never rewritten.

create table if not exists public.country_business_tax_rules (
  id uuid primary key default gen_random_uuid(), country_code char(2) not null check(country_code ~ '^[A-Z]{2}$'),
  rule_type text not null, rule_key text not null, numeric_value numeric, text_value text, json_value jsonb,
  effective_from date not null, effective_to date, active boolean not null default true, source_note text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check(num_nonnulls(numeric_value,text_value,json_value)=1), check(effective_to is null or effective_to>=effective_from),
  unique(country_code,rule_type,rule_key,effective_from)
);
alter table public.country_business_tax_rules enable row level security;
drop policy if exists country_business_tax_rules_read on public.country_business_tax_rules;
create policy country_business_tax_rules_read on public.country_business_tax_rules for select to authenticated using (true);

-- Production statutory values. These are centrally controlled and date-effective; tenants cannot edit them.
insert into public.country_business_tax_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,source_note) values
('NZ','gst','standard_rate_percent',15,null,null,'1989-07-01','IRD GST'),
('NZ','gst','registration_threshold_12m',60000,null,null,'2009-04-01','IRD GST registration'),
('NZ','gst','payments_basis_threshold_12m',2000000,null,null,'2000-10-10','IRD GST accounting basis'),
('NZ','gst','six_monthly_threshold_12m',500000,null,null,'2000-10-10','IRD GST filing frequency'),
('NZ','gst','monthly_mandatory_threshold_12m',24000000,null,null,'2000-10-10','IRD GST filing frequency'),
('NZ','gst','standard_due_day',28,null,null,'1986-10-01','IRD GST filing'),
('NZ','gst','march_period_due',null,'05-07',null,'1986-10-01','Period ending 31 March: 7 May'),
('NZ','gst','november_period_due',null,'01-15',null,'1986-10-01','Period ending 30 November: 15 January'),
('NZ','income_tax','company_rate_percent',28,null,null,'2011-04-01','IRD company tax rate'),
('NZ','income_tax','trust_rate_percent',39,null,null,'2024-04-01','NZ trustee income rate; tenant circumstances may vary'),
('NZ','income_tax','individual_brackets',null,null,'[{"up_to":15600,"rate":0.105},{"up_to":53500,"rate":0.175},{"up_to":78100,"rate":0.30},{"up_to":180000,"rate":0.33},{"up_to":null,"rate":0.39}]'::jsonb,'2024-07-31','IRD individual income tax rates')
on conflict(country_code,rule_type,rule_key,effective_from) do nothing;

-- Preserve historical GST return facts. New returns snapshot the statutory/tenant basis used.
alter table public.gst_returns add column if not exists statutory_due_date date;
alter table public.gst_returns add column if not exists accounting_basis text;
alter table public.gst_returns add column if not exists filing_frequency text;
alter table public.gst_returns add column if not exists statutory_rule_snapshot jsonb not null default '{}'::jsonb;

-- Official-source monitoring is additive and separate from Payroll monitoring.
create table if not exists public.business_tax_compliance_sources (
 id uuid primary key default gen_random_uuid(), country_code char(2) not null, source_name text not null, source_url text not null,
 source_identifier text not null, purpose text, active boolean not null default true, last_checked_at timestamptz,
 last_successful_check_at timestamptz,last_changed_at timestamptz,last_known_fingerprint text,last_check_status text not null default 'never_checked'
 check(last_check_status in('never_checked','no_change','change_detected','check_error')),last_error text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(country_code,source_identifier));
create table if not exists public.business_tax_compliance_updates (
 id uuid primary key default gen_random_uuid(),source_id uuid not null references public.business_tax_compliance_sources(id) on delete restrict,country_code char(2) not null,
 detected_at timestamptz not null default now(),source_fingerprint text not null,previous_fingerprint text,status text not null default 'review_required'
 check(status in('review_required','reviewed_no_impact')),summary text,source_reference text,reviewed_at timestamptz,reviewed_by uuid references auth.users(id) on delete set null,review_notes text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(source_id,source_fingerprint));
alter table public.business_tax_compliance_sources enable row level security;alter table public.business_tax_compliance_updates enable row level security;
drop policy if exists business_tax_compliance_sources_super_admin on public.business_tax_compliance_sources;
create policy business_tax_compliance_sources_super_admin on public.business_tax_compliance_sources for all to authenticated using(public.is_super_admin()) with check(public.is_super_admin());
drop policy if exists business_tax_compliance_updates_super_admin on public.business_tax_compliance_updates;
create policy business_tax_compliance_updates_super_admin on public.business_tax_compliance_updates for all to authenticated using(public.is_super_admin()) with check(public.is_super_admin());
insert into public.business_tax_compliance_sources(country_code,source_name,source_url,source_identifier,purpose) values
('NZ','Inland Revenue New Zealand','https://www.ird.govt.nz/gst/filing-and-paying-gst-and-refunds/filing-gst','ird-nz-gst-filing','GST filing and statutory due dates'),
('NZ','Inland Revenue New Zealand','https://www.ird.govt.nz/gst/registering-for-gst/which-gst-accounting-basis-and-filing-frequency-should-i-use','ird-nz-gst-basis-frequency','GST accounting basis and filing-frequency eligibility')
on conflict(country_code,source_identifier) do update set source_url=excluded.source_url,purpose=excluded.purpose,active=true,updated_at=now();

-- Human-controlled Business Tax/GST ruleset workflow. Detection cannot write production rules.
create table if not exists public.business_tax_rulesets (
 id uuid primary key default gen_random_uuid(),country_code char(2) not null,name text not null,version text not null,effective_from date not null,effective_to date,
 status text not null default 'draft' check(status in('draft','validated','approved','active','retired')),source_update_id uuid references public.business_tax_compliance_updates(id) on delete set null,
 created_by uuid references auth.users(id) on delete set null,approved_by uuid references auth.users(id) on delete set null,approved_at timestamptz,activated_by uuid references auth.users(id) on delete set null,activated_at timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),check(effective_to is null or effective_to>=effective_from),unique(country_code,name,version));
create table if not exists public.business_tax_ruleset_rules (
 id uuid primary key default gen_random_uuid(),ruleset_id uuid not null references public.business_tax_rulesets(id) on delete cascade,rule_type text not null,rule_key text not null,numeric_value numeric,text_value text,json_value jsonb,source_note text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),check(num_nonnulls(numeric_value,text_value,json_value)=1),unique(ruleset_id,rule_type,rule_key));
alter table public.business_tax_rulesets enable row level security;alter table public.business_tax_ruleset_rules enable row level security;
drop policy if exists business_tax_rulesets_super_admin on public.business_tax_rulesets;create policy business_tax_rulesets_super_admin on public.business_tax_rulesets for all to authenticated using(public.is_super_admin()) with check(public.is_super_admin());
drop policy if exists business_tax_ruleset_rules_super_admin on public.business_tax_ruleset_rules;create policy business_tax_ruleset_rules_super_admin on public.business_tax_ruleset_rules for all to authenticated using(public.is_super_admin()) with check(public.is_super_admin());

create or replace function public.v6168b_create_draft_ruleset(p_update_id uuid,p_name text,p_version text,p_effective_from date,p_effective_to date default null) returns uuid language plpgsql security definer set search_path=public as $$
declare u public.business_tax_compliance_updates;r_id uuid;begin if not public.is_super_admin() then raise exception 'Super Admin access required';end if;select * into u from public.business_tax_compliance_updates where id=p_update_id;if u.id is null then raise exception 'Compliance update not found';end if;insert into public.business_tax_rulesets(country_code,name,version,effective_from,effective_to,status,source_update_id,created_by) values(u.country_code,trim(p_name),trim(p_version),p_effective_from,p_effective_to,'draft',u.id,auth.uid()) returning id into r_id;insert into public.business_tax_ruleset_rules(ruleset_id,rule_type,rule_key,numeric_value,text_value,json_value,source_note) select r_id,rule_type,rule_key,numeric_value,text_value,json_value,source_note from public.country_business_tax_rules where country_code=u.country_code and active=true and effective_from<=p_effective_from and(effective_to is null or effective_to>=p_effective_from) on conflict do nothing;return r_id;end$$;
create or replace function public.v6168b_set_ruleset_status(p_ruleset_id uuid,p_status text) returns void language plpgsql security definer set search_path=public as $$
declare r public.business_tax_rulesets;begin if not public.is_super_admin() then raise exception 'Super Admin access required';end if;if p_status not in('validated','approved') then raise exception 'Only validated or approved status may be set here';end if;select * into r from public.business_tax_rulesets where id=p_ruleset_id;if r.id is null then raise exception 'Ruleset not found';end if;if p_status='validated' and r.status<>'draft' then raise exception 'Only Draft rulesets can be validated';end if;if p_status='approved' and r.status<>'validated' then raise exception 'Ruleset must be validated before approval';end if;update public.business_tax_rulesets set status=p_status,approved_by=case when p_status='approved' then auth.uid() else approved_by end,approved_at=case when p_status='approved' then now() else approved_at end,updated_at=now() where id=r.id;end$$;
create or replace function public.v6168b_activate_ruleset(p_ruleset_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare r public.business_tax_rulesets;rr record;begin if not public.is_super_admin() then raise exception 'Super Admin access required';end if;select * into r from public.business_tax_rulesets where id=p_ruleset_id for update;if r.id is null then raise exception 'Ruleset not found';end if;if r.status<>'approved' then raise exception 'Ruleset must be explicitly approved before activation';end if;if not exists(select 1 from public.business_tax_ruleset_rules where ruleset_id=r.id) then raise exception 'Ruleset has no rules';end if;for rr in select * from public.business_tax_ruleset_rules where ruleset_id=r.id loop update public.country_business_tax_rules set active=false,effective_to=case when effective_from<r.effective_from then r.effective_from-1 else effective_to end,updated_at=now() where country_code=r.country_code and rule_type=rr.rule_type and rule_key=rr.rule_key and active=true and effective_from<r.effective_from;insert into public.country_business_tax_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,effective_to,active,source_note) values(r.country_code,rr.rule_type,rr.rule_key,rr.numeric_value,rr.text_value,rr.json_value,r.effective_from,r.effective_to,true,rr.source_note) on conflict(country_code,rule_type,rule_key,effective_from) do update set numeric_value=excluded.numeric_value,text_value=excluded.text_value,json_value=excluded.json_value,effective_to=excluded.effective_to,active=true,source_note=excluded.source_note,updated_at=now();end loop;update public.business_tax_rulesets set status='active',activated_by=auth.uid(),activated_at=now(),updated_at=now() where id=r.id;end$$;
revoke all on function public.v6168b_create_draft_ruleset(uuid,text,text,date,date) from public;grant execute on function public.v6168b_create_draft_ruleset(uuid,text,text,date,date) to authenticated;
revoke all on function public.v6168b_set_ruleset_status(uuid,text) from public;grant execute on function public.v6168b_set_ruleset_status(uuid,text) to authenticated;
revoke all on function public.v6168b_activate_ruleset(uuid) from public;grant execute on function public.v6168b_activate_ruleset(uuid) to authenticated;
