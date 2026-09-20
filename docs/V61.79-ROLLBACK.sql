-- V61.79A STAGING-ONLY rollback. Never run in production without separate approval.
-- Dependency-aware: refuses to remove the Schedule module while any plan/business still references it.
begin;

do $v6179a_rb$
declare
  v_plan_count integer;
  v_business_count integer;
begin
  select count(*) into v_plan_count from public.plans where 'schedule'=any(coalesce(included_modules,array[]::text[]));
  select count(*) into v_business_count
  from public.business_modules bm join public.modules m on m.id=bm.module_id
  where m.slug='schedule';

  if v_plan_count>0 or v_business_count>0 then
    raise exception 'V61.79A rollback stopped safely: Schedule is referenced by % plan(s) and % business override(s). Remove staging-only Schedule entitlements/overrides deliberately, then rerun rollback.',
      v_plan_count,v_business_count;
  end if;
end
$v6179a_rb$;

drop function if exists public.v6179_today_schedule(timestamptz,timestamptz);
drop function if exists public.v6179_dashboard_summary(date,text);
drop table if exists public.google_calendar_sync_log;
drop table if exists public.google_calendar_event_links;
drop table if exists public.google_calendar_connections;
drop table if exists public.job_schedule_assignments;
drop table if exists public.job_schedules;
drop table if exists public.job_recurrence_series;
drop function if exists public.v6179_validate_google_refs();
drop function if exists public.v6179_validate_schedule_assignment_refs();
drop function if exists public.v6179_validate_schedule_refs();
drop function if exists public.v6179_schedule_role_allowed(uuid,boolean);
drop function if exists public.v6179_schedule_entitled(uuid);
drop function if exists public.v6179_smallint_array_is_unique(smallint[]);
drop function if exists public.v6179_is_iana_timezone(text);
delete from public.modules where slug='schedule' and name='Schedule';
commit;
