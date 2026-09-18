-- V61.68A — platform payroll rulesets + official compliance monitoring
-- Additive only. Detection/review NEVER changes active production payroll rules.

create table if not exists public.payroll_rulesets (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null check (country_code ~ '^[A-Z]{2}$'),
  name text not null,
  version text not null,
  effective_from date not null,
  effective_to date,
  status text not null default 'draft' check (status in ('draft','validated','approved','active','retired')),
  source_update_id uuid,
  created_by uuid references auth.users(id) on delete set null,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  activated_by uuid references auth.users(id) on delete set null,
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  unique(country_code,name,version)
);

create table if not exists public.payroll_ruleset_rules (
  id uuid primary key default gen_random_uuid(),
  ruleset_id uuid not null references public.payroll_rulesets(id) on delete cascade,
  rule_type text not null,
  rule_key text not null,
  numeric_value numeric,
  text_value text,
  json_value jsonb,
  source_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (num_nonnulls(numeric_value,text_value,json_value)=1),
  unique(ruleset_id,rule_type,rule_key)
);

create table if not exists public.payroll_compliance_sources (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null check (country_code ~ '^[A-Z]{2}$'),
  source_name text not null,
  source_type text not null default 'official_specification',
  source_url text not null,
  source_identifier text not null,
  purpose text,
  active boolean not null default true,
  check_frequency text not null default 'daily',
  last_checked_at timestamptz,
  last_successful_check_at timestamptz,
  last_changed_at timestamptz,
  last_known_version text,
  last_known_fingerprint text,
  last_source_reference text,
  last_check_status text not null default 'never_checked' check (last_check_status in ('never_checked','no_change','change_detected','check_error')),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(country_code,source_identifier)
);

create table if not exists public.payroll_compliance_updates (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references public.payroll_compliance_sources(id) on delete restrict,
  country_code char(2) not null,
  detected_at timestamptz not null default now(),
  source_version text,
  source_fingerprint text not null,
  previous_fingerprint text,
  status text not null default 'review_required' check (status in ('review_required','draft_prepared','validated','approved','activated','dismissed_no_payroll_impact')),
  summary text,
  source_reference text,
  proposed_ruleset_id uuid references public.payroll_rulesets(id) on delete set null,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_notes text,
  dismissed_at timestamptz,
  dismissed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(source_id,source_fingerprint)
);

alter table public.payroll_rulesets drop constraint if exists payroll_rulesets_source_update_id_fkey;
alter table public.payroll_rulesets add constraint payroll_rulesets_source_update_id_fkey foreign key(source_update_id) references public.payroll_compliance_updates(id) on delete set null;

create table if not exists public.payroll_compliance_audit (
  id uuid primary key default gen_random_uuid(),
  country_code char(2),
  source_id uuid references public.payroll_compliance_sources(id) on delete set null,
  update_id uuid references public.payroll_compliance_updates(id) on delete set null,
  ruleset_id uuid references public.payroll_rulesets(id) on delete set null,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists payroll_rulesets_country_status_idx on public.payroll_rulesets(country_code,status,effective_from);
create index if not exists payroll_ruleset_rules_ruleset_idx on public.payroll_ruleset_rules(ruleset_id,rule_type,rule_key);
create index if not exists payroll_compliance_updates_status_idx on public.payroll_compliance_updates(country_code,status,detected_at desc);
create index if not exists payroll_compliance_audit_created_idx on public.payroll_compliance_audit(created_at desc);

alter table public.payroll_rulesets enable row level security;
alter table public.payroll_ruleset_rules enable row level security;
alter table public.payroll_compliance_sources enable row level security;
alter table public.payroll_compliance_updates enable row level security;
alter table public.payroll_compliance_audit enable row level security;

do $$ declare t text; begin
  foreach t in array array['payroll_rulesets','payroll_ruleset_rules','payroll_compliance_sources','payroll_compliance_updates','payroll_compliance_audit'] loop
    execute format('drop policy if exists %I on public.%I',t||'_super_admin',t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin())',t||'_super_admin',t);
  end loop;
end $$;

-- Server/service-role monitor writes are intentionally separate from ordinary tenant access.
-- Seed the authoritative NZ IRD landing page. The server monitor resolves and fingerprints the actual specification document.
insert into public.payroll_compliance_sources(country_code,source_name,source_type,source_url,source_identifier,purpose,active,check_frequency)
values ('NZ','Inland Revenue New Zealand','official_specification','https://www.ird.govt.nz/digital-service-providers/services-catalogue/returns-and-information/payday-filing/payroll-calculations-and-business-rules','ird-nz-payroll-calculations-business-rules','Payroll Calculations & Business Rules',true,'daily')
on conflict(country_code,source_identifier) do update set source_name=excluded.source_name,source_type=excluded.source_type,source_url=excluded.source_url,purpose=excluded.purpose,active=true,updated_at=now();

create or replace function public.v6168a_create_draft_ruleset(p_update_id uuid, p_name text, p_version text, p_effective_from date, p_effective_to date default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare u public.payroll_compliance_updates; r_id uuid;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into u from public.payroll_compliance_updates where id=p_update_id;
  if u.id is null then raise exception 'Compliance update not found'; end if;
  if u.status not in ('review_required','draft_prepared') then raise exception 'This update is not available for draft preparation'; end if;
  insert into public.payroll_rulesets(country_code,name,version,effective_from,effective_to,status,source_update_id,created_by)
  values(u.country_code,trim(p_name),trim(p_version),p_effective_from,p_effective_to,'draft',u.id,auth.uid()) returning id into r_id;
  insert into public.payroll_ruleset_rules(ruleset_id,rule_type,rule_key,numeric_value,text_value,json_value,source_note)
  select r_id,rule_type,rule_key,numeric_value,text_value,json_value,source_note
  from public.country_payroll_rules
  where country_code=u.country_code and active=true
    and effective_from <= p_effective_from and (effective_to is null or effective_to >= p_effective_from)
  on conflict do nothing;
  update public.payroll_compliance_updates set status='draft_prepared',proposed_ruleset_id=r_id,reviewed_at=coalesce(reviewed_at,now()),reviewed_by=coalesce(reviewed_by,auth.uid()),updated_at=now() where id=u.id;
  insert into public.payroll_compliance_audit(country_code,source_id,update_id,ruleset_id,action,actor_user_id) values(u.country_code,u.source_id,u.id,r_id,'draft_created',auth.uid());
  return r_id;
end $$;

create or replace function public.v6168a_mark_update_no_impact(p_update_id uuid,p_notes text default null)
returns void language plpgsql security definer set search_path=public as $$
declare u public.payroll_compliance_updates;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into u from public.payroll_compliance_updates where id=p_update_id;
  if u.id is null then raise exception 'Compliance update not found'; end if;
  update public.payroll_compliance_updates set status='dismissed_no_payroll_impact',reviewed_at=now(),reviewed_by=auth.uid(),review_notes=nullif(trim(coalesce(p_notes,'')),''),dismissed_at=now(),dismissed_by=auth.uid(),updated_at=now() where id=p_update_id;
  insert into public.payroll_compliance_audit(country_code,source_id,update_id,action,detail,actor_user_id) values(u.country_code,u.source_id,u.id,'update_dismissed',jsonb_build_object('notes',coalesce(p_notes,'')),auth.uid());
end $$;

create or replace function public.v6168a_set_ruleset_status(p_ruleset_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.payroll_rulesets; u public.payroll_compliance_updates;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  if p_status not in ('validated','approved') then raise exception 'Only validated or approved status may be set here'; end if;
  select * into r from public.payroll_rulesets where id=p_ruleset_id;
  if r.id is null then raise exception 'Ruleset not found'; end if;
  if p_status='validated' and r.status<>'draft' then raise exception 'Only Draft rulesets can be validated'; end if;
  if p_status='approved' and r.status<>'validated' then raise exception 'Ruleset must be validated before approval'; end if;
  update public.payroll_rulesets set status=p_status,approved_by=case when p_status='approved' then auth.uid() else approved_by end,approved_at=case when p_status='approved' then now() else approved_at end,updated_at=now() where id=r.id;
  if r.source_update_id is not null then update public.payroll_compliance_updates set status=p_status,updated_at=now() where id=r.source_update_id; end if;
  insert into public.payroll_compliance_audit(country_code,update_id,ruleset_id,action,actor_user_id) values(r.country_code,r.source_update_id,r.id,case when p_status='validated' then 'validation_run' else 'ruleset_approved' end,auth.uid());
end $$;

create or replace function public.v6168a_activate_ruleset(p_ruleset_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.payroll_rulesets; rr record;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into r from public.payroll_rulesets where id=p_ruleset_id for update;
  if r.id is null then raise exception 'Ruleset not found'; end if;
  if r.status<>'approved' then raise exception 'Ruleset must be explicitly approved before activation'; end if;
  if not exists(select 1 from public.payroll_ruleset_rules where ruleset_id=r.id) then raise exception 'Ruleset has no rules'; end if;
  -- This is the ONLY V61.68A path that writes production payroll rules, and it requires an approved ruleset + Super Admin.
  for rr in select * from public.payroll_ruleset_rules where ruleset_id=r.id loop
    insert into public.country_payroll_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,effective_to,active,source_note,created_at,updated_at)
    values(r.country_code,rr.rule_type,rr.rule_key,rr.numeric_value,rr.text_value,rr.json_value,r.effective_from,r.effective_to,true,coalesce(rr.source_note,'Approved Finlo payroll ruleset '||r.name||' '||r.version),now(),now())
    on conflict(country_code,rule_type,rule_key,effective_from) do update set numeric_value=excluded.numeric_value,text_value=excluded.text_value,json_value=excluded.json_value,effective_to=excluded.effective_to,active=true,source_note=excluded.source_note,updated_at=now();
  end loop;
  update public.payroll_rulesets set status='active',activated_by=auth.uid(),activated_at=now(),updated_at=now() where id=r.id;
  if r.source_update_id is not null then update public.payroll_compliance_updates set status='activated',updated_at=now() where id=r.source_update_id; end if;
  insert into public.payroll_compliance_audit(country_code,update_id,ruleset_id,action,actor_user_id) values(r.country_code,r.source_update_id,r.id,'ruleset_activated',auth.uid());
end $$;

revoke all on function public.v6168a_create_draft_ruleset(uuid,text,text,date,date) from public,anon;
revoke all on function public.v6168a_mark_update_no_impact(uuid,text) from public,anon;
revoke all on function public.v6168a_set_ruleset_status(uuid,text) from public,anon;
revoke all on function public.v6168a_activate_ruleset(uuid) from public,anon;
grant execute on function public.v6168a_create_draft_ruleset(uuid,text,text,date,date) to authenticated;
grant execute on function public.v6168a_mark_update_no_impact(uuid,text) to authenticated;
grant execute on function public.v6168a_set_ruleset_status(uuid,text) to authenticated;
grant execute on function public.v6168a_activate_ruleset(uuid) to authenticated;

-- Close the legacy direct-write path. Production rules are readable by tenants,
-- but V61.68A activation is the only supported write path and is SECURITY DEFINER.
drop policy if exists country_payroll_rules_admin_insert on public.country_payroll_rules;
drop policy if exists country_payroll_rules_admin_update on public.country_payroll_rules;
drop policy if exists country_payroll_rules_admin_delete on public.country_payroll_rules;
