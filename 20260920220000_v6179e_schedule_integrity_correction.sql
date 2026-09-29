-- V61.79E Schedule integrity correction.
-- Additive replacement only: preserves assignment progress during ordinary job edits
-- and uses preferred-name fallback consistently in the dashboard Schedule RPC.
begin;

create or replace function public.v6179_save_schedule_with_assignments(
  p_schedule_id uuid,
  p_schedule jsonb,
  p_employee_ids uuid[] default '{}'::uuid[]
)
returns public.job_schedules
language plpgsql
security invoker
set search_path = pg_catalog, public, auth
as $$
declare
  v_business uuid;
  v_schedule public.job_schedules;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required';
  end if;

  v_business := public.current_business_id();
  if v_business is null then
    raise exception 'Active business is required';
  end if;
  if not public.v6179_schedule_role_allowed(v_business, true) then
    raise exception 'Schedule write access not authorised';
  end if;
  if p_schedule is null or nullif(btrim(p_schedule->>'title'),'') is null then
    raise exception 'Schedule title is required';
  end if;
  if p_schedule ? 'business_id' and (p_schedule->>'business_id')::uuid <> v_business then
    raise exception 'Schedule business does not match active business';
  end if;

  if p_schedule_id is null then
    insert into public.job_schedules(
      business_id,job_costing_id,quote_id,customer_id,invoice_id,title,service_type,
      service_address,start_at,end_at,timezone,status,scheduled_value,notes,
      customer_instructions,created_by,updated_by
    ) values (
      v_business,nullif(p_schedule->>'job_costing_id','')::uuid,nullif(p_schedule->>'quote_id','')::uuid,
      nullif(p_schedule->>'customer_id','')::uuid,nullif(p_schedule->>'invoice_id','')::uuid,
      btrim(p_schedule->>'title'),nullif(p_schedule->>'service_type',''),nullif(p_schedule->>'service_address',''),
      nullif(p_schedule->>'start_at','')::timestamptz,nullif(p_schedule->>'end_at','')::timestamptz,
      p_schedule->>'timezone',coalesce(nullif(p_schedule->>'status',''),'unscheduled'),
      nullif(p_schedule->>'scheduled_value','')::numeric,nullif(p_schedule->>'notes',''),
      nullif(p_schedule->>'customer_instructions',''),(select auth.uid()),(select auth.uid())
    ) returning * into v_schedule;
  else
    update public.job_schedules s set
      job_costing_id=nullif(p_schedule->>'job_costing_id','')::uuid,
      quote_id=nullif(p_schedule->>'quote_id','')::uuid,
      customer_id=nullif(p_schedule->>'customer_id','')::uuid,
      invoice_id=nullif(p_schedule->>'invoice_id','')::uuid,
      title=btrim(p_schedule->>'title'),service_type=nullif(p_schedule->>'service_type',''),
      service_address=nullif(p_schedule->>'service_address',''),
      start_at=nullif(p_schedule->>'start_at','')::timestamptz,end_at=nullif(p_schedule->>'end_at','')::timestamptz,
      timezone=p_schedule->>'timezone',status=coalesce(nullif(p_schedule->>'status',''),'unscheduled'),
      scheduled_value=nullif(p_schedule->>'scheduled_value','')::numeric,notes=nullif(p_schedule->>'notes',''),
      customer_instructions=nullif(p_schedule->>'customer_instructions',''),updated_by=(select auth.uid()),updated_at=now()
    where s.id=p_schedule_id and s.business_id=v_business
    returning * into v_schedule;
    if v_schedule.id is null then
      raise exception 'Schedule is unavailable in the active business';
    end if;
  end if;

  -- Remove only employees explicitly removed from the assignment list.
  delete from public.job_schedule_assignments a
  where a.schedule_id=v_schedule.id
    and a.business_id=v_business
    and not (a.employee_id=any(coalesce(p_employee_ids,'{}'::uuid[])));

  -- Add only new employees. Existing rows retain assignment_status,
  -- planned_hours, actual_hours and their original audit metadata.
  insert into public.job_schedule_assignments(
    business_id,schedule_id,employee_id,created_by,updated_by
  )
  select v_business,v_schedule.id,x.employee_id,(select auth.uid()),(select auth.uid())
  from (
    select distinct employee_id
    from unnest(coalesce(p_employee_ids,'{}'::uuid[])) as employee_ids(employee_id)
    where employee_id is not null
  ) x
  on conflict (schedule_id,employee_id) do nothing;

  return v_schedule;
end;
$$;

revoke all on function public.v6179_save_schedule_with_assignments(uuid,jsonb,uuid[]) from public;
revoke execute on function public.v6179_save_schedule_with_assignments(uuid,jsonb,uuid[]) from anon;
grant execute on function public.v6179_save_schedule_with_assignments(uuid,jsonb,uuid[]) to authenticated;

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
         coalesce(array_agg(distinct nullif(btrim(concat_ws(' ',coalesce(nullif(btrim(e.preferred_name),''),e.first_name),e.last_name)),'')) filter (where e.id is not null),array[]::text[])
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
