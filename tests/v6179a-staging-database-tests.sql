\set ON_ERROR_STOP on
-- V61.79A executable STAGING-ONLY database tests.
-- Prerequisites:
--   1) Apply the V61.79A migration to a disposable Supabase clone.
--   2) Supply EXISTING disposable fixture UUIDs with psql -v:
--      business_a, business_b, owner_a, admin_a, staff_a, owner_b,
--      customer_a, customer_b, job_a, quote_a, invoice_a, employee_a
-- The script wraps all test mutations in a transaction and ROLLBACKs them.
-- It deliberately does not manufacture fixtures because baseline required columns
-- not present in the supplied migration history are unknown.

begin;

-- V61.79B: copy psql fixture variables into transaction-local settings so
-- PL/pgSQL dollar-quoted DO blocks can safely access them via current_setting().
select set_config('v6179a.business_a', :'business_a', true);
select set_config('v6179a.business_b', :'business_b', true);
select set_config('v6179a.owner_a', :'owner_a', true);
select set_config('v6179a.admin_a', :'admin_a', true);
select set_config('v6179a.staff_a', :'staff_a', true);
select set_config('v6179a.owner_b', :'owner_b', true);
select set_config('v6179a.customer_a', :'customer_a', true);
select set_config('v6179a.customer_b', :'customer_b', true);
select set_config('v6179a.job_a', :'job_a', true);
select set_config('v6179a.quote_a', :'quote_a', true);
select set_config('v6179a.invoice_a', :'invoice_a', true);
select set_config('v6179a.employee_a', :'employee_a', true);

create temporary table v6179a_results(test_name text primary key, passed boolean, detail text);
grant select, insert on v6179a_results to authenticated;

create or replace function pg_temp.assert_true(p_name text,p_ok boolean,p_detail text default null)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok,false) then raise exception 'TEST FAILED: % — %',p_name,coalesce(p_detail,''); end if;
  insert into v6179a_results values(p_name,true,p_detail);
end $$;

create or replace function pg_temp.as_user(p_user uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  set local role authenticated;
end $$;

-- Migration execution/object/RLS smoke checks.
select pg_temp.assert_true('six tables exist',
  (select count(*)=6 from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname in
   ('job_recurrence_series','job_schedules','job_schedule_assignments','google_calendar_connections','google_calendar_event_links','google_calendar_sync_log')));
select pg_temp.assert_true('all six tables RLS enabled',
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname in
   ('job_recurrence_series','job_schedules','job_schedule_assignments','google_calendar_connections','google_calendar_event_links','google_calendar_sync_log')));

select pg_temp.assert_true('complete expected V61.79D RLS policy list present',
  (select array_agg(tablename||'.'||policyname order by tablename,policyname)
   from pg_policies
   where schemaname='public'
     and (tablename,policyname) in (
       ('job_recurrence_series','v6179_schedule_series_read'),
       ('job_recurrence_series','v6179_schedule_series_insert'),
       ('job_recurrence_series','v6179_schedule_series_update'),
       ('job_recurrence_series','v6179_schedule_series_delete'),
       ('job_schedules','v6179_schedules_read'),
       ('job_schedules','v6179_schedules_insert'),
       ('job_schedules','v6179_schedules_update'),
       ('job_schedules','v6179_schedules_delete'),
       ('job_schedule_assignments','v6179_schedule_assignments_read'),
       ('job_schedule_assignments','v6179_schedule_assignments_insert'),
       ('job_schedule_assignments','v6179_schedule_assignments_update'),
       ('job_schedule_assignments','v6179_schedule_assignments_delete'),
       ('google_calendar_connections','v6179_google_connections_own_read'),
       ('google_calendar_event_links','v6179_google_event_links_read'),
       ('google_calendar_sync_log','v6179_google_sync_log_read')
     )) =
  array[
    'google_calendar_connections.v6179_google_connections_own_read',
    'google_calendar_event_links.v6179_google_event_links_read',
    'google_calendar_sync_log.v6179_google_sync_log_read',
    'job_recurrence_series.v6179_schedule_series_delete',
    'job_recurrence_series.v6179_schedule_series_insert',
    'job_recurrence_series.v6179_schedule_series_read',
    'job_recurrence_series.v6179_schedule_series_update',
    'job_schedule_assignments.v6179_schedule_assignments_delete',
    'job_schedule_assignments.v6179_schedule_assignments_insert',
    'job_schedule_assignments.v6179_schedule_assignments_read',
    'job_schedule_assignments.v6179_schedule_assignments_update',
    'job_schedules.v6179_schedules_delete',
    'job_schedules.v6179_schedules_insert',
    'job_schedules.v6179_schedules_read',
    'job_schedules.v6179_schedules_update'
  ]::text[]);

-- Ensure Schedule entitlement for Business A only inside this rolled-back test.
reset role;
update public.plans p set included_modules =
  case when 'schedule'=any(coalesce(p.included_modules,array[]::text[])) then p.included_modules
       else array_append(coalesce(p.included_modules,array[]::text[]),'schedule') end
where p.id=(select s.plan_id from public.subscriptions s where s.business_id=:'business_a'::uuid order by s.created_at desc limit 1);

-- Owner A access.
select pg_temp.as_user(:'owner_a'::uuid);
select pg_temp.assert_true('owner A entitled',public.v6179_schedule_entitled(:'business_a'::uuid));
with created_schedule as (
  insert into public.job_schedules(business_id,customer_id,job_costing_id,quote_id,invoice_id,title,timezone,status,start_at,end_at)
  values(:'business_a'::uuid,:'customer_a'::uuid,:'job_a'::uuid,:'quote_a'::uuid,:'invoice_a'::uuid,'V6179B test','Pacific/Auckland','scheduled',now()+interval '1 hour',now()+interval '2 hours')
  returning id
)
select set_config('v6179a.schedule_id',(select id::text from created_schedule),true);

select pg_temp.assert_true('owner can read own schedule',
  exists(select 1 from public.job_schedules where id=current_setting('v6179a.schedule_id')::uuid));

-- Incomplete planned and actual times must fail.
do $$ begin
  begin
    insert into public.job_schedules(business_id,title,timezone,status,start_at,end_at)
    values(current_setting('v6179a.business_a')::uuid,'bad pair','Pacific/Auckland','unscheduled',now(),null);
    raise exception 'expected incomplete schedule time rejection';
  exception when check_violation then null; end;
  begin
    update public.job_schedules set actual_start_at=now(),actual_end_at=null where id=current_setting('v6179a.schedule_id')::uuid;
    raise exception 'expected incomplete actual time rejection';
  exception when check_violation then null; end;
end $$;
select pg_temp.assert_true('incomplete time pairs rejected',true);

-- Invalid timezone and duplicate weekly weekday fail.
do $$ begin
  begin
    insert into public.job_recurrence_series(business_id,frequency,interval_count,days_of_week,start_date,default_start_time,default_duration_minutes,timezone)
    values(current_setting('v6179a.business_a')::uuid,'weekly',1,array[1,1]::smallint[],current_date,'09:00',60,'Not/A_Real_Zone');
    raise exception 'expected timezone/weekday rejection';
  exception when check_violation then null; end;
end $$;
select pg_temp.assert_true('timezone and recurrence validation enforced',true);

-- Cross-business reference rejection.
do $$ begin
  begin
    update public.job_schedules set customer_id=current_setting('v6179a.customer_b')::uuid where id=current_setting('v6179a.schedule_id')::uuid;
    raise exception 'expected cross-business customer rejection';
  exception when others then
    if sqlerrm like 'expected cross-business%' then raise; end if;
  end;
end $$;
select pg_temp.assert_true('cross-business customer reference rejected',true);

-- Admin A access.
reset role; select pg_temp.as_user(:'admin_a'::uuid);
select pg_temp.assert_true('admin A can read schedule',
  exists(select 1 from public.job_schedules where id=current_setting('v6179a.schedule_id')::uuid));

-- Staff A denied under Phase A.
reset role; select pg_temp.as_user(:'staff_a'::uuid);
select pg_temp.assert_true('staff A denied schedule read',
  not exists(select 1 from public.job_schedules where id=current_setting('v6179a.schedule_id')::uuid));
do $$ begin
  begin
    insert into public.job_schedules(business_id,title,timezone,status)
    values(current_setting('v6179a.business_a')::uuid,'staff spoof','Pacific/Auckland','unscheduled');
    raise exception 'expected staff write denial';
  exception when insufficient_privilege then null; end;
end $$;
select pg_temp.assert_true('staff A denied schedule write',true);

-- Tenant isolation: owner B cannot see Business A schedule.
reset role; select pg_temp.as_user(:'owner_b'::uuid);
select pg_temp.assert_true('owner B cannot read Business A schedule',
  not exists(select 1 from public.job_schedules where id=current_setting('v6179a.schedule_id')::uuid));

-- Entitlement disabled state: temporarily remove Schedule from Business A plan and assert owner A loses access.
reset role;
update public.plans p set included_modules=array_remove(coalesce(p.included_modules,array[]::text[]),'schedule')
where p.id=(select s.plan_id from public.subscriptions s where s.business_id=:'business_a'::uuid order by s.created_at desc limit 1);
select pg_temp.as_user(:'owner_a'::uuid);
select pg_temp.assert_true('owner denied when Schedule not entitled',
  not public.v6179_schedule_entitled(:'business_a'::uuid));
select pg_temp.assert_true('RLS hides schedule when entitlement removed',
  not exists(select 1 from public.job_schedules where id=current_setting('v6179a.schedule_id')::uuid));

-- Re-enable for remaining tests.
reset role;
update public.plans p set included_modules =
  case when 'schedule'=any(coalesce(p.included_modules,array[]::text[])) then p.included_modules
       else array_append(coalesce(p.included_modules,array[]::text[]),'schedule') end
where p.id=(select s.plan_id from public.subscriptions s where s.business_id=:'business_a'::uuid order by s.created_at desc limit 1);

-- Browser Google connection spoofing: authenticated user has SELECT only, no INSERT/UPDATE.
select pg_temp.as_user(:'owner_a'::uuid);
do $$ begin
  begin
    insert into public.google_calendar_connections(business_id,user_id,google_account_email,connection_status,granted_scopes)
    values(current_setting('v6179a.business_a')::uuid,current_setting('v6179a.owner_a')::uuid,'spoof@example.invalid','connected',array['calendar']);
    raise exception 'expected Google metadata insert denial';
  exception when insufficient_privilege then null; end;
end $$;
select pg_temp.assert_true('authenticated client cannot manufacture Google connection state',true);

-- Existing quote/job compatibility: SET NULL rather than blocking deletion.
-- These checks use disposable fixture rows. Deleting them is safe because the entire transaction rolls back.
reset role; select pg_temp.as_user(:'owner_a'::uuid);
-- Schedule references fixture quote/job; perform deletion as an authorised owner.
delete from public.quotes where id=:'quote_a'::uuid;
select pg_temp.assert_true('quote deletion preserved schedule',
  exists(select 1 from public.job_schedules where id=current_setting('v6179a.schedule_id')::uuid and quote_id is null));
delete from public.job_costings where id=:'job_a'::uuid;
select pg_temp.assert_true('job-costing deletion preserved schedule',
  exists(select 1 from public.job_schedules where id=current_setting('v6179a.schedule_id')::uuid and job_costing_id is null));

reset role;
select * from v6179a_results order by test_name;
rollback;
