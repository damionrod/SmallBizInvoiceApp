-- Finlo V61.79A Phase A correction: Schedule + Dashboard database foundation
-- REVIEW-ONLY MIGRATION. This file was authored but NOT applied to any database.
-- Additive/idempotent where reasonably possible; destructive cascade removal is not used.

begin;

-- Fail closed if the baseline security/schema objects this migration depends on are absent.
do $v6179_preflight$
declare
  missing text[] := array[]::text[];
  bad text[] := array[]::text[];
  r record;
  found_udt text;
begin
  -- Required relations/functions.
  if to_regclass('public.businesses') is null then missing:=array_append(missing,'table public.businesses'); end if;
  if to_regclass('public.business_memberships') is null then missing:=array_append(missing,'table public.business_memberships'); end if;
  if to_regclass('public.modules') is null then missing:=array_append(missing,'table public.modules'); end if;
  if to_regclass('public.business_modules') is null then missing:=array_append(missing,'table public.business_modules'); end if;
  if to_regclass('public.plans') is null then missing:=array_append(missing,'table public.plans'); end if;
  if to_regclass('public.subscriptions') is null then missing:=array_append(missing,'table public.subscriptions'); end if;
  if to_regclass('public.customers') is null then missing:=array_append(missing,'table public.customers'); end if;
  if to_regclass('public.job_costings') is null then missing:=array_append(missing,'table public.job_costings'); end if;
  if to_regclass('public.quotes') is null then missing:=array_append(missing,'table public.quotes'); end if;
  if to_regclass('public.invoices') is null then missing:=array_append(missing,'table public.invoices'); end if;
  if to_regclass('public.payroll_employees') is null then missing:=array_append(missing,'table public.payroll_employees'); end if;
  if to_regprocedure('public.current_business_id()') is null then missing:=array_append(missing,'function public.current_business_id()'); end if;
  if to_regprocedure('public.v6147_current_business_role(uuid)') is null then missing:=array_append(missing,'function public.v6147_current_business_role(uuid)'); end if;

  -- Column/type compatibility required by this migration. udt_name is used for arrays.
  for r in
    select * from (values
      ('businesses','id','uuid'),
      ('business_memberships','business_id','uuid'),('business_memberships','user_id','uuid'),('business_memberships','role','text'),('business_memberships','status','text'),
      ('modules','id','uuid'),('modules','slug','text'),('modules','name','text'),('modules','description','text'),('modules','monthly_price','numeric'),('modules','is_active','bool'),('modules','created_at','timestamptz'),
      ('business_modules','business_id','uuid'),('business_modules','module_id','uuid'),('business_modules','status','text'),('business_modules','trial_ends_at','timestamptz'),
      ('plans','id','uuid'),('plans','included_modules','_text'),
      ('subscriptions','business_id','uuid'),('subscriptions','plan_id','uuid'),('subscriptions','status','text'),('subscriptions','created_at','timestamptz'),
      ('customers','id','uuid'),('customers','business_id','uuid'),('customers','name','text'),
      ('job_costings','id','uuid'),('job_costings','business_id','uuid'),
      ('quotes','id','uuid'),('quotes','business_id','uuid'),
      ('invoices','id','uuid'),('invoices','business_id','uuid'),
      ('payroll_employees','id','uuid'),('payroll_employees','business_id','uuid'),('payroll_employees','first_name','text'),('payroll_employees','last_name','text'),('payroll_employees','preferred_name','text'),('payroll_employees','archived','bool'),('payroll_employees','employment_status','text')
    ) as req(tbl,col,udt)
  loop
    if to_regclass('public.'||r.tbl) is not null then
      if not exists(select 1 from information_schema.columns c where c.table_schema='public' and c.table_name=r.tbl and c.column_name=r.col) then
        missing:=array_append(missing,format('column public.%s.%s',r.tbl,r.col));
      elsif not exists(select 1 from information_schema.columns c where c.table_schema='public' and c.table_name=r.tbl and c.column_name=r.col and c.udt_name=r.udt) then
        select c.udt_name into found_udt from information_schema.columns c
        where c.table_schema='public' and c.table_name=r.tbl and c.column_name=r.col;
        bad:=array_append(bad,format('public.%s.%s expected %s, found %s',r.tbl,r.col,r.udt,found_udt));
      end if;
    end if;
  end loop;

  if coalesce(array_length(missing,1),0)>0 or coalesce(array_length(bad,1),0)>0 then
    raise exception 'V61.79A preflight failed. Missing: [%]. Incompatible: [%]',
      coalesce(array_to_string(missing,', '),'none'), coalesce(array_to_string(bad,', '),'none');
  end if;
end
$v6179_preflight$;

-- Schedule catalogue entry only. Do NOT add it to existing plans/businesses.
-- gen_random_uuid() is used explicitly because the supplied package does not contain
-- the historical CREATE TABLE for modules, so its UUID default cannot be verified.
insert into public.modules(id,slug,name,description,monthly_price,is_active,created_at)
select gen_random_uuid(),'schedule','Schedule',
       'Plan jobs, allocate staff and manage scheduled work.',
       0,true,now()
where not exists (select 1 from public.modules where slug='schedule');


-- IANA timezone validation uses PostgreSQL's pg_timezone_names catalogue.
-- SECURITY INVOKER: no elevation is required to validate a name.
create or replace function public.v6179_is_iana_timezone(p_timezone text)
returns boolean
language sql
stable
security invoker
set search_path = 'pg_catalog'
as $v6179_tz$
  select p_timezone is not null
     and p_timezone <> ''
     and exists (select 1 from pg_catalog.pg_timezone_names where name=p_timezone);
$v6179_tz$;

revoke all on function public.v6179_is_iana_timezone(text) from public;
revoke execute on function public.v6179_is_iana_timezone(text) from anon;
grant execute on function public.v6179_is_iana_timezone(text) to authenticated;


create or replace function public.v6179_smallint_array_is_unique(p_values smallint[])
returns boolean
language sql
immutable
security invoker
set search_path = 'pg_catalog'
as $v6179_unique$
  select p_values is null or cardinality(p_values) =
    (select count(distinct v) from unnest(p_values) as u(v));
$v6179_unique$;

revoke all on function public.v6179_smallint_array_is_unique(smallint[]) from public;
revoke execute on function public.v6179_smallint_array_is_unique(smallint[]) from anon;
grant execute on function public.v6179_smallint_array_is_unique(smallint[]) to authenticated;

create table if not exists public.job_recurrence_series (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  job_costing_id uuid null references public.job_costings(id) on delete set null,
  customer_id uuid null references public.customers(id) on delete set null,
  frequency text not null,
  interval_count integer not null default 1,
  days_of_week smallint[] null,
  start_date date not null,
  end_date date null,
  default_start_time time without time zone null,
  default_duration_minutes integer not null,
  timezone text not null,
  active boolean not null default true,
  created_by uuid null references auth.users(id),
  updated_by uuid null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_recurrence_series_frequency_check check (frequency in ('daily','weekly','monthly')),
  constraint job_recurrence_series_interval_check check (interval_count > 0),
  constraint job_recurrence_series_duration_check check (default_duration_minutes > 0),
  constraint job_recurrence_series_dates_check check (end_date is null or end_date >= start_date),
  constraint job_recurrence_series_timezone_check check (public.v6179_is_iana_timezone(timezone)),
  constraint job_recurrence_series_days_check check (
    (frequency='weekly'
      and days_of_week is not null
      and cardinality(days_of_week) between 1 and 7
      and days_of_week <@ array[0,1,2,3,4,5,6]::smallint[]
      and public.v6179_smallint_array_is_unique(days_of_week))
    or
    (frequency in ('daily','monthly') and days_of_week is null)
  ),
  -- Weekday convention: 0=Sunday, 1=Monday, ... 6=Saturday.
  -- All recurrence frequencies require a positive duration. A default start time is
  -- required because Phase A recurrence represents schedulable job occurrences.
  constraint job_recurrence_series_start_time_check check (default_start_time is not null)
);

create table if not exists public.job_schedules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  job_costing_id uuid null references public.job_costings(id) on delete set null,
  quote_id uuid null references public.quotes(id) on delete set null,
  customer_id uuid null references public.customers(id) on delete set null,
  invoice_id uuid null references public.invoices(id) on delete set null,
  recurrence_series_id uuid null references public.job_recurrence_series(id) on delete set null,
  recurrence_occurrence_date date null,
  title text not null,
  service_type text null,
  service_address text null,
  start_at timestamptz null,
  end_at timestamptz null,
  timezone text not null,
  status text not null default 'unscheduled',
  scheduled_value numeric null,
  actual_start_at timestamptz null,
  actual_end_at timestamptz null,
  notes text null,
  customer_instructions text null,
  created_by uuid null references auth.users(id),
  updated_by uuid null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_schedules_status_check check (status in ('unscheduled','scheduled','confirmed','in_progress','completed','cancelled')),
  constraint job_schedules_timezone_check check (public.v6179_is_iana_timezone(timezone)),
  constraint job_schedules_value_check check (scheduled_value is null or scheduled_value >= 0),
  constraint job_schedules_time_pair_check check (
    (start_at is null and end_at is null)
    or
    (start_at is not null and end_at is not null and end_at > start_at)
  ),
  constraint job_schedules_status_time_check check (
    status='unscheduled' or (start_at is not null and end_at is not null)
  ),
  constraint job_schedules_actual_time_pair_check check (
    (actual_start_at is null and actual_end_at is null)
    or
    (actual_start_at is not null and actual_end_at is not null and actual_end_at > actual_start_at)
  )
);

create unique index if not exists job_schedules_recurrence_occurrence_uidx
  on public.job_schedules(business_id,recurrence_series_id,recurrence_occurrence_date)
  where recurrence_series_id is not null and recurrence_occurrence_date is not null;

create table if not exists public.job_schedule_assignments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  schedule_id uuid not null references public.job_schedules(id) on delete cascade,
  employee_id uuid null references public.payroll_employees(id) on delete set null,
  role text null,
  assignment_status text not null default 'assigned',
  planned_hours numeric null,
  actual_hours numeric null,
  created_by uuid null references auth.users(id),
  updated_by uuid null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_schedule_assignments_status_check check (assignment_status in ('assigned','confirmed','declined','completed','cancelled')),
  constraint job_schedule_assignments_planned_hours_check check (planned_hours is null or planned_hours >= 0),
  constraint job_schedule_assignments_actual_hours_check check (actual_hours is null or actual_hours >= 0),
  constraint job_schedule_assignments_unique_employee unique(schedule_id,employee_id)
);

-- Google metadata only. No access/refresh token or client-secret column exists here.
create table if not exists public.google_calendar_connections (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  user_id uuid not null references auth.users(id),
  google_account_id text null,
  google_account_email text null,
  calendar_id text null,
  connection_status text not null default 'disconnected',
  granted_scopes text[] not null default array[]::text[],
  token_expires_at timestamptz null,
  last_sync_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint google_calendar_connections_status_check check (connection_status in ('connected','disconnected','needs_reconnection','error')),
  constraint google_calendar_connections_business_user_unique unique(business_id,user_id)
);

create table if not exists public.google_calendar_event_links (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  schedule_id uuid not null references public.job_schedules(id) on delete cascade,
  employee_id uuid null references public.payroll_employees(id) on delete cascade,
  user_id uuid null references auth.users(id),
  calendar_id text not null,
  google_event_id text not null,
  provider_updated_at timestamptz null,
  last_synced_at timestamptz null,
  sync_status text not null default 'pending',
  last_error text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint google_calendar_event_links_actor_check check ((employee_id is not null)::integer + (user_id is not null)::integer = 1),
  constraint google_calendar_event_links_status_check check (sync_status in ('pending','synced','needs_reconnection','failed'))
);

create unique index if not exists google_calendar_event_links_employee_uidx
  on public.google_calendar_event_links(schedule_id,employee_id,calendar_id)
  where employee_id is not null;

create unique index if not exists google_calendar_event_links_user_uidx
  on public.google_calendar_event_links(schedule_id,user_id,calendar_id)
  where user_id is not null;

create table if not exists public.google_calendar_sync_log (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  connection_id uuid not null references public.google_calendar_connections(id) on delete cascade,
  schedule_id uuid null references public.job_schedules(id) on delete set null,
  operation text not null,
  status text not null,
  attempt_count integer not null default 0,
  error_message text null,
  created_at timestamptz not null default now(),
  completed_at timestamptz null,
  constraint google_calendar_sync_log_operation_check check (operation in ('create','update','cancel','delete','retry','disconnect')),
  constraint google_calendar_sync_log_status_check check (status in ('pending','running','succeeded','failed','needs_reconnection')),
  constraint google_calendar_sync_log_attempt_check check (attempt_count >= 0)
);

-- No token-vault table is created in Phase A. Refresh-token encryption/storage must be
-- implemented server-side in Phase E after a staging-verified secret-management design.

create index if not exists job_schedules_business_start_idx on public.job_schedules(business_id,start_at);
create index if not exists job_schedules_business_status_start_idx on public.job_schedules(business_id,status,start_at);
create index if not exists job_schedules_business_customer_idx on public.job_schedules(business_id,customer_id);
create index if not exists job_schedules_business_job_idx on public.job_schedules(business_id,job_costing_id);
create index if not exists job_schedules_business_recurrence_idx on public.job_schedules(business_id,recurrence_series_id);
create index if not exists job_schedule_assignments_schedule_employee_idx on public.job_schedule_assignments(schedule_id,employee_id);
create index if not exists job_schedule_assignments_employee_schedule_idx on public.job_schedule_assignments(employee_id,schedule_id);
create index if not exists job_recurrence_series_business_active_start_idx on public.job_recurrence_series(business_id,active,start_date);
create index if not exists google_calendar_connections_business_user_idx on public.google_calendar_connections(business_id,user_id);
create index if not exists google_calendar_event_links_business_schedule_idx on public.google_calendar_event_links(business_id,schedule_id);
create index if not exists google_calendar_sync_log_business_created_idx on public.google_calendar_sync_log(business_id,created_at);

-- Hardened entitlement helper for use by RLS/RPCs.
create or replace function public.v6179_schedule_entitled(p_business_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = 'public'
as $v6179_entitled$
declare
  v_current uuid;
  v_override text;
  v_in_plan boolean := false;
begin
  if auth.uid() is null then return false; end if;
  v_current := public.current_business_id();
  if v_current is null or v_current <> p_business_id then return false; end if;

  select bm.status into v_override
  from public.business_modules bm
  join public.modules m on m.id=bm.module_id
  where bm.business_id=p_business_id and m.slug='schedule'
  limit 1;

  if v_override='suspended' then return false; end if;
  if v_override='active' then return true; end if;
  if v_override='trialing' then
    return exists (
      select 1 from public.business_modules bm
      join public.modules m on m.id=bm.module_id
      where bm.business_id=p_business_id and m.slug='schedule'
        and bm.status='trialing'
        and (bm.trial_ends_at is null or bm.trial_ends_at >= now())
    );
  end if;

  select coalesce('schedule'=any(p.included_modules),false) into v_in_plan
  from public.subscriptions s
  join public.plans p on p.id=s.plan_id
  where s.business_id=p_business_id
    and s.status in ('trialing','active')
  order by s.created_at desc
  limit 1;

  return coalesce(v_in_plan,false);
end
$v6179_entitled$;

revoke all on function public.v6179_schedule_entitled(uuid) from public;
revoke execute on function public.v6179_schedule_entitled(uuid) from anon;
grant execute on function public.v6179_schedule_entitled(uuid) to authenticated;

create or replace function public.v6179_schedule_role_allowed(p_business_id uuid, p_write boolean default false)
returns boolean
language plpgsql
stable
security definer
set search_path = 'public'
as $v6179_role$
declare
  v_current uuid;
  v_role text;
begin
  if auth.uid() is null then return false; end if;
  v_current:=public.current_business_id();
  if v_current is null or v_current<>p_business_id then return false; end if;
  if not public.v6179_schedule_entitled(p_business_id) then return false; end if;
  v_role:=public.v6147_current_business_role(p_business_id);
  -- Phase A intentionally grants Schedule DB access only to owner/admin.
  -- The supplied project has no verified auth-user -> payroll-employee mapping,
  -- so "staff can see only their assignments" cannot yet be enforced safely.
  return v_role in ('owner','admin');
end
$v6179_role$;

revoke all on function public.v6179_schedule_role_allowed(uuid,boolean) from public;
revoke execute on function public.v6179_schedule_role_allowed(uuid,boolean) from anon;
grant execute on function public.v6179_schedule_role_allowed(uuid,boolean) to authenticated;

-- Fail-closed cross-business validation. SECURITY INVOKER is deliberate.
create or replace function public.v6179_validate_schedule_refs()
returns trigger
language plpgsql
security invoker
set search_path = 'public'
as $v6179_refs$
begin
  if new.business_id is null or new.business_id<>public.current_business_id() then
    raise exception 'Schedule business context is not authorised';
  end if;
  if new.customer_id is not null and not exists(select 1 from public.customers x where x.id=new.customer_id and x.business_id=new.business_id) then raise exception 'Customer belongs to another business or is unavailable'; end if;
  if new.job_costing_id is not null and not exists(select 1 from public.job_costings x where x.id=new.job_costing_id and x.business_id=new.business_id) then raise exception 'Job costing belongs to another business or is unavailable'; end if;
  if tg_table_name='job_schedules' then
    if new.quote_id is not null and not exists(select 1 from public.quotes x where x.id=new.quote_id and x.business_id=new.business_id) then raise exception 'Quote belongs to another business or is unavailable'; end if;
    if new.invoice_id is not null and not exists(select 1 from public.invoices x where x.id=new.invoice_id and x.business_id=new.business_id) then raise exception 'Invoice belongs to another business or is unavailable'; end if;
    if new.recurrence_series_id is not null and not exists(select 1 from public.job_recurrence_series x where x.id=new.recurrence_series_id and x.business_id=new.business_id) then raise exception 'Recurrence series belongs to another business or is unavailable'; end if;
  end if;
  return new;
end
$v6179_refs$;

revoke all on function public.v6179_validate_schedule_refs() from public;
revoke execute on function public.v6179_validate_schedule_refs() from anon;
grant execute on function public.v6179_validate_schedule_refs() to authenticated;

create or replace function public.v6179_validate_schedule_assignment_refs()
returns trigger
language plpgsql
security invoker
set search_path = 'public'
as $v6179_assign_refs$
begin
  if new.business_id is null or new.business_id<>public.current_business_id() then raise exception 'Schedule assignment business context is not authorised'; end if;
  if not exists(select 1 from public.job_schedules x where x.id=new.schedule_id and x.business_id=new.business_id) then raise exception 'Schedule belongs to another business or is unavailable'; end if;
  if new.employee_id is not null and not exists(select 1 from public.payroll_employees x where x.id=new.employee_id and x.business_id=new.business_id and coalesce(x.archived,false)=false and coalesce(x.employment_status,'active') not in ('terminated','inactive')) then raise exception 'Employee is inactive, archived, belongs to another business or is unavailable'; end if;
  return new;
end
$v6179_assign_refs$;

revoke all on function public.v6179_validate_schedule_assignment_refs() from public;
revoke execute on function public.v6179_validate_schedule_assignment_refs() from anon;
grant execute on function public.v6179_validate_schedule_assignment_refs() to authenticated;

create or replace function public.v6179_validate_google_refs()
returns trigger
language plpgsql
security invoker
set search_path = 'public'
as $v6179_google_refs$
begin
  if new.business_id is null or new.business_id<>public.current_business_id() then raise exception 'Google Calendar business context is not authorised'; end if;
  if tg_table_name='google_calendar_event_links' then
    if not exists(select 1 from public.job_schedules x where x.id=new.schedule_id and x.business_id=new.business_id) then raise exception 'Schedule belongs to another business or is unavailable'; end if;
    if new.employee_id is not null and not exists(select 1 from public.payroll_employees x where x.id=new.employee_id and x.business_id=new.business_id) then raise exception 'Employee belongs to another business or is unavailable'; end if;
  elsif tg_table_name='google_calendar_sync_log' then
    if not exists(select 1 from public.google_calendar_connections x where x.id=new.connection_id and x.business_id=new.business_id) then raise exception 'Calendar connection belongs to another business or is unavailable'; end if;
    if new.schedule_id is not null and not exists(select 1 from public.job_schedules x where x.id=new.schedule_id and x.business_id=new.business_id) then raise exception 'Schedule belongs to another business or is unavailable'; end if;
  end if;
  return new;
end
$v6179_google_refs$;

revoke all on function public.v6179_validate_google_refs() from public;
revoke execute on function public.v6179_validate_google_refs() from anon;
grant execute on function public.v6179_validate_google_refs() to authenticated;

-- Idempotent trigger creation.
do $v6179_triggers$
begin
  if not exists(select 1 from pg_trigger where tgname='v6179_recurrence_refs' and tgrelid='public.job_recurrence_series'::regclass) then
    create trigger v6179_recurrence_refs before insert or update on public.job_recurrence_series for each row execute function public.v6179_validate_schedule_refs();
  end if;
  if not exists(select 1 from pg_trigger where tgname='v6179_schedule_refs' and tgrelid='public.job_schedules'::regclass) then
    create trigger v6179_schedule_refs before insert or update on public.job_schedules for each row execute function public.v6179_validate_schedule_refs();
  end if;
  if not exists(select 1 from pg_trigger where tgname='v6179_assignment_refs' and tgrelid='public.job_schedule_assignments'::regclass) then
    create trigger v6179_assignment_refs before insert or update on public.job_schedule_assignments for each row execute function public.v6179_validate_schedule_assignment_refs();
  end if;
  if not exists(select 1 from pg_trigger where tgname='v6179_google_event_refs' and tgrelid='public.google_calendar_event_links'::regclass) then
    create trigger v6179_google_event_refs before insert or update on public.google_calendar_event_links for each row execute function public.v6179_validate_google_refs();
  end if;
  if not exists(select 1 from pg_trigger where tgname='v6179_google_log_refs' and tgrelid='public.google_calendar_sync_log'::regclass) then
    create trigger v6179_google_log_refs before insert or update on public.google_calendar_sync_log for each row execute function public.v6179_validate_google_refs();
  end if;
end
$v6179_triggers$;

alter table public.job_recurrence_series enable row level security;
alter table public.job_schedules enable row level security;
alter table public.job_schedule_assignments enable row level security;
alter table public.google_calendar_connections enable row level security;
alter table public.google_calendar_event_links enable row level security;
alter table public.google_calendar_sync_log enable row level security;

-- Schedule policies: owner/admin only in Phase A until a verified user<->employee link exists.
do $v6179_policies$
begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='job_recurrence_series' and policyname='v6179_schedule_series_read') then
    create policy v6179_schedule_series_read on public.job_recurrence_series for select to authenticated using (public.v6179_schedule_role_allowed(business_id,false));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='job_recurrence_series' and policyname='v6179_schedule_series_write') then
    create policy v6179_schedule_series_write on public.job_recurrence_series for all to authenticated using (public.v6179_schedule_role_allowed(business_id,true)) with check (public.v6179_schedule_role_allowed(business_id,true));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='job_schedules' and policyname='v6179_schedules_read') then
    create policy v6179_schedules_read on public.job_schedules for select to authenticated using (public.v6179_schedule_role_allowed(business_id,false));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='job_schedules' and policyname='v6179_schedules_write') then
    create policy v6179_schedules_write on public.job_schedules for all to authenticated using (public.v6179_schedule_role_allowed(business_id,true)) with check (public.v6179_schedule_role_allowed(business_id,true));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='job_schedule_assignments' and policyname='v6179_schedule_assignments_read') then
    create policy v6179_schedule_assignments_read on public.job_schedule_assignments for select to authenticated using (public.v6179_schedule_role_allowed(business_id,false));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='job_schedule_assignments' and policyname='v6179_schedule_assignments_write') then
    create policy v6179_schedule_assignments_write on public.job_schedule_assignments for all to authenticated using (public.v6179_schedule_role_allowed(business_id,true)) with check (public.v6179_schedule_role_allowed(business_id,true));
  end if;

  -- Users can see/manage only their own Google connection metadata in the active business.
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='google_calendar_connections' and policyname='v6179_google_connections_own_read') then
    create policy v6179_google_connections_own_read on public.google_calendar_connections for select to authenticated
      using (business_id=public.current_business_id() and user_id=auth.uid());
  end if;
  -- Event-link and sync-log rows are intentionally not client-writable. Owner/admin may read safe metadata.
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='google_calendar_event_links' and policyname='v6179_google_event_links_read') then
    create policy v6179_google_event_links_read on public.google_calendar_event_links for select to authenticated using (public.v6179_schedule_role_allowed(business_id,false));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='google_calendar_sync_log' and policyname='v6179_google_sync_log_read') then
    create policy v6179_google_sync_log_read on public.google_calendar_sync_log for select to authenticated using (public.v6179_schedule_role_allowed(business_id,false));
  end if;
end
$v6179_policies$;

-- Explicit Data API grants; RLS remains authoritative. No anon grants.
grant select,insert,update,delete on public.job_recurrence_series to authenticated;
grant select,insert,update,delete on public.job_schedules to authenticated;
grant select,insert,update,delete on public.job_schedule_assignments to authenticated;
grant select on public.google_calendar_connections to authenticated;
grant select on public.google_calendar_event_links to authenticated;
grant select on public.google_calendar_sync_log to authenticated;
revoke insert,update,delete on public.google_calendar_connections from authenticated;
revoke insert,update,delete on public.google_calendar_event_links from authenticated;
revoke insert,update,delete on public.google_calendar_sync_log from authenticated;

revoke all on public.job_recurrence_series from anon;
revoke all on public.job_schedules from anon;
revoke all on public.job_schedule_assignments from anon;
revoke all on public.google_calendar_connections from anon;
revoke all on public.google_calendar_event_links from anon;
revoke all on public.google_calendar_sync_log from anon;

-- Dashboard foundation: safe structured response only. Financial forecast fields are NULL
-- until existing credit/payment/financial RPC semantics are staging-verified.
create or replace function public.v6179_dashboard_summary(p_as_of_date date default current_date, p_timezone text default 'Pacific/Auckland')
returns jsonb
language plpgsql
stable
security invoker
set search_path = 'public'
as $v6179_dashboard$
declare
  v_business uuid;
  v_role text;
  v_schedule boolean;
begin
  v_business:=public.current_business_id();
  if v_business is null then raise exception 'No active authorised business'; end if;
  if not public.v6179_is_iana_timezone(p_timezone) then raise exception 'Invalid IANA timezone'; end if;
  v_role:=public.v6147_current_business_role(v_business);
  v_schedule:=public.v6179_schedule_entitled(v_business) and v_role in ('owner','admin');
  return jsonb_build_object(
    'generated_at',now(),
    'as_of_date',p_as_of_date,
    'timezone',p_timezone,
    'schedule_entitled',v_schedule,
    'bank_position',null,
    'expected_receipts_30d',null,
    'known_commitments_30d',null,
    'estimated_balance_30d',null,
    'monthly_summary',null,
    'completeness',jsonb_build_object(
      'bank_position','unsupported_until_opening_or_current_balance_source_is_verified',
      'forecast','pending_authoritative_credit_payment_and_financial_rpc_staging_verification',
      'monthly_summary','pending_authoritative_financial_rpc_staging_verification'
    )
  );
end
$v6179_dashboard$;

revoke all on function public.v6179_dashboard_summary(date,text) from public;
revoke execute on function public.v6179_dashboard_summary(date,text) from anon;
grant execute on function public.v6179_dashboard_summary(date,text) to authenticated;

create or replace function public.v6179_today_schedule(p_from timestamptz, p_to timestamptz)
returns table(
  schedule_id uuid,
  start_at timestamptz,
  end_at timestamptz,
  title text,
  customer_name text,
  service_address text,
  status text,
  scheduled_value numeric,
  assigned_employee_names text[]
)
language plpgsql
stable
security invoker
set search_path = 'public'
as $v6179_today$
declare
  v_business uuid;
begin
  v_business:=public.current_business_id();
  if v_business is null then raise exception 'No active authorised business'; end if;
  if p_from is null or p_to is null or p_to<=p_from then raise exception 'Invalid schedule range'; end if;
  if not public.v6179_schedule_role_allowed(v_business,false) then raise exception 'Schedule access not authorised'; end if;

  return query
  select s.id,s.start_at,s.end_at,s.title,c.name,s.service_address,s.status,s.scheduled_value,
         coalesce(array_agg(distinct nullif(btrim(concat_ws(' ',e.preferred_name,e.first_name,e.last_name)),'')) filter (where e.id is not null),array[]::text[])
  from public.job_schedules s
  left join public.customers c on c.id=s.customer_id and c.business_id=s.business_id
  left join public.job_schedule_assignments a on a.schedule_id=s.id and a.business_id=s.business_id and a.assignment_status<>'cancelled'
  left join public.payroll_employees e on e.id=a.employee_id and e.business_id=s.business_id
  where s.business_id=v_business
    and s.status<>'cancelled'
    and s.start_at is not null and s.end_at is not null
    and s.start_at < p_to and s.end_at > p_from
  group by s.id,s.start_at,s.end_at,s.title,c.name,s.service_address,s.status,s.scheduled_value
  order by s.start_at,s.title;
end
$v6179_today$;

revoke all on function public.v6179_today_schedule(timestamptz,timestamptz) from public;
revoke execute on function public.v6179_today_schedule(timestamptz,timestamptz) from anon;
grant execute on function public.v6179_today_schedule(timestamptz,timestamptz) to authenticated;

commit;
