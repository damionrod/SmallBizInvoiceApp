-- V61.79I Keep the Dashboard unscheduled count aligned with Schedule quote eligibility.
begin;

create or replace function public.v6179_unscheduled_schedule_count()
returns bigint
language plpgsql
security invoker
set search_path = pg_catalog, public, auth
as $$
declare
  v_business uuid;
  v_count bigint;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  v_business := public.current_business_id();
  if v_business is null then raise exception 'Active business is required'; end if;
  if not public.v6179_schedule_role_allowed(v_business, false) then raise exception 'Schedule read access not authorised'; end if;

  select count(*) into v_count
  from public.job_schedules s
  left join public.quotes q on q.id=s.quote_id and q.business_id=v_business
  where s.business_id=v_business
    and (s.start_at is null or s.status='unscheduled')
    and (s.quote_id is null or q.status in ('sent','accepted','approved','won'));
  return coalesce(v_count,0);
end;
$$;

revoke all on function public.v6179_unscheduled_schedule_count() from public;
revoke execute on function public.v6179_unscheduled_schedule_count() from anon;
grant execute on function public.v6179_unscheduled_schedule_count() to authenticated;

commit;
