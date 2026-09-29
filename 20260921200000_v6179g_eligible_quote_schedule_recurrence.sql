-- V61.79G Schedule quote eligibility, virtual unscheduled quotes and safe recurrence.
-- Schedule-only additive migration. Existing one-time saves keep the V61.79F contract.
begin;

alter table public.job_recurrence_series
  add column if not exists quote_id uuid null references public.quotes(id) on delete set null,
  add column if not exists invoice_id uuid null references public.invoices(id) on delete set null,
  add column if not exists title text null,
  add column if not exists service_type text null,
  add column if not exists service_address text null,
  add column if not exists scheduled_value numeric null,
  add column if not exists notes text null,
  add column if not exists customer_instructions text null,
  add column if not exists selected_dates date[] null;

alter table public.job_recurrence_series
  drop constraint if exists job_recurrence_series_frequency_check,
  drop constraint if exists job_recurrence_series_days_check;

alter table public.job_recurrence_series
  add constraint job_recurrence_series_frequency_check check
    (frequency in ('daily','every_other_day','weekly','fortnightly','monthly','selected_dates')),
  add constraint job_recurrence_series_days_check check (
    (frequency in ('weekly','fortnightly')
      and days_of_week is not null
      and cardinality(days_of_week) between 1 and 7
      and days_of_week <@ array[0,1,2,3,4,5,6]::smallint[]
      and public.v6179_smallint_array_is_unique(days_of_week))
    or
    (frequency in ('daily','every_other_day','monthly','selected_dates') and days_of_week is null)
  );

alter table public.job_recurrence_series
  add constraint job_recurrence_series_selected_dates_check check (
    frequency <> 'selected_dates' or (selected_dates is not null and cardinality(selected_dates) > 0)
  );

create index if not exists job_recurrence_series_business_quote_idx
  on public.job_recurrence_series(business_id,quote_id);

-- One non-recurring schedule per quote. Recurring occurrences are intentionally
-- exempt because each occurrence links to the same source quote.
create unique index if not exists job_schedules_business_quote_one_time_uidx
  on public.job_schedules(business_id,quote_id)
  where quote_id is not null and recurrence_series_id is null;

create or replace function public.v6179_schedule_eligible_quotes()
returns table(
  id uuid,
  quote_number text,
  customer_id uuid,
  customer_name text,
  customer_address text,
  description text,
  total_incl_gst numeric,
  status text
)
language plpgsql
stable
security invoker
set search_path = 'pg_catalog', 'public', 'auth'
as $$
declare
  v_business uuid;
begin
  v_business := public.current_business_id();
  if v_business is null then raise exception 'Active business is required'; end if;
  if not public.v6179_schedule_role_allowed(v_business,false) then
    raise exception 'Schedule access not authorised';
  end if;
  return query
  select q.id,q.quote_number,q.customer_id,q.customer_name,q.customer_address,
         q.description,q.total_incl_gst,q.status
  from public.quotes q
  where q.business_id=v_business
    -- These are the active statuses present in the current quote schema.
    -- accepted is accepted for forward-compatible tenants; unknown statuses fail closed.
    and q.status in ('sent','accepted','approved','won')
    and not exists (
      select 1 from public.job_schedules s
      where s.business_id=v_business and s.quote_id=q.id
    )
  order by q.created_at desc;
end;
$$;

revoke all on function public.v6179_schedule_eligible_quotes() from public;
revoke execute on function public.v6179_schedule_eligible_quotes() from anon;
grant execute on function public.v6179_schedule_eligible_quotes() to authenticated;

-- Keep direct table writes fail-closed as well as RPC writes. A rejected/draft/
-- expired quote can never become a Schedule row by manipulating the browser.
create or replace function public.v6179_validate_schedule_refs()
returns trigger
language plpgsql
security invoker
set search_path = 'public'
as $v6179_refs$
declare
  v_quote_status text;
begin
  if new.business_id is null or new.business_id<>public.current_business_id() then
    raise exception 'Schedule business context is not authorised';
  end if;
  if new.customer_id is not null and not exists(select 1 from public.customers x where x.id=new.customer_id and x.business_id=new.business_id) then raise exception 'Customer belongs to another business or is unavailable'; end if;
  if new.job_costing_id is not null and not exists(select 1 from public.job_costings x where x.id=new.job_costing_id and x.business_id=new.business_id) then raise exception 'Job costing belongs to another business or is unavailable'; end if;
  if tg_table_name in ('job_schedules','job_recurrence_series') and new.quote_id is not null then
    select q.status into v_quote_status from public.quotes q where q.id=new.quote_id and q.business_id=new.business_id;
    if v_quote_status is null or v_quote_status not in ('sent','accepted','approved','won') then
      raise exception 'Quote is not eligible for scheduling';
    end if;
  end if;
  if tg_table_name='job_schedules' then
    if new.invoice_id is not null and not exists(select 1 from public.invoices x where x.id=new.invoice_id and x.business_id=new.business_id) then raise exception 'Invoice belongs to another business or is unavailable'; end if;
    if new.recurrence_series_id is not null and not exists(select 1 from public.job_recurrence_series x where x.id=new.recurrence_series_id and x.business_id=new.business_id) then raise exception 'Recurrence series belongs to another business or is unavailable'; end if;
  elsif tg_table_name='job_recurrence_series' then
    if new.invoice_id is not null and not exists(select 1 from public.invoices x where x.id=new.invoice_id and x.business_id=new.business_id) then raise exception 'Invoice belongs to another business or is unavailable'; end if;
  end if;
  return new;
end
$v6179_refs$;

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
  v_employee_ids uuid[] := '{}'::uuid[];
  v_quote_id uuid;
  v_quote_status text;
  v_target_id uuid := p_schedule_id;
  v_recur jsonb := p_schedule->'recurrence';
  v_recur_enabled boolean := false;
  v_series_id uuid;
  v_frequency text;
  v_interval integer;
  v_days smallint[];
  v_selected date[];
  v_start_date date;
  v_end_date date;
  v_start_time time;
  v_duration integer;
  v_timezone text;
  v_date date;
  v_occ_start timestamptz;
  v_occ_end timestamptz;
  v_first boolean := true;
  v_count integer := 0;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  v_business := public.current_business_id();
  if v_business is null then raise exception 'Active business is required'; end if;
  if not public.v6179_schedule_role_allowed(v_business, true) then raise exception 'Schedule write access not authorised'; end if;
  if p_schedule is null or nullif(btrim(p_schedule->>'title'),'') is null then raise exception 'Schedule title is required'; end if;
  if p_schedule ? 'business_id' and (p_schedule->>'business_id')::uuid <> v_business then raise exception 'Schedule business does not match active business'; end if;

  v_quote_id := nullif(p_schedule->>'quote_id','')::uuid;
  if v_quote_id is not null then
    select q.status into v_quote_status from public.quotes q where q.id=v_quote_id and q.business_id=v_business;
    if v_quote_status is null or v_quote_status not in ('sent','accepted','approved','won') then raise exception 'Quote is not eligible for scheduling'; end if;
  end if;

  select coalesce(array_agg(distinct e.id), '{}'::uuid[])
  into v_employee_ids
  from unnest(coalesce(p_employee_ids, '{}'::uuid[])) requested(employee_id)
  join public.payroll_employees e on e.id=requested.employee_id
  where e.business_id=v_business and coalesce(e.archived,false)=false
    and coalesce(e.employment_status,'active') not in ('terminated','inactive');

  v_recur_enabled := jsonb_typeof(v_recur)='object' and coalesce((v_recur->>'enabled')::boolean,false);
  if v_recur_enabled and p_schedule_id is not null then
    raise exception 'Edit a recurring occurrence individually or create a new series';
  end if;

  if v_recur_enabled then
    v_frequency := coalesce(nullif(v_recur->>'frequency',''),'daily');
    v_interval := greatest(1,coalesce(nullif(v_recur->>'interval_count','')::integer,1));
    if v_frequency in ('every_other_day','fortnightly') then v_interval := 2; end if;
    if v_frequency not in ('daily','every_other_day','weekly','fortnightly','monthly','selected_dates') then raise exception 'Unsupported recurrence pattern'; end if;
    v_start_date := coalesce(nullif(v_recur->>'start_date','')::date,nullif(p_schedule->>'date','')::date,current_date);
    v_end_date := nullif(v_recur->>'end_date','')::date;
    if v_end_date is not null and v_end_date<v_start_date then raise exception 'Recurrence end date must be on or after the start date'; end if;
    v_start_time := coalesce(nullif(v_recur->>'start_time','')::time,nullif(p_schedule->>'start_time','')::time,time '09:00');
    v_duration := greatest(15,coalesce(nullif(v_recur->>'duration_minutes','')::integer,nullif(p_schedule->>'duration_minutes','')::integer,60));
    v_timezone := coalesce(nullif(v_recur->>'timezone',''),nullif(p_schedule->>'timezone',''),'Pacific/Auckland');
    v_days := case when v_frequency in ('weekly','fortnightly') then coalesce((select array_agg(value::smallint) from jsonb_array_elements_text(coalesce(v_recur->'days_of_week','[]'::jsonb)) x(value)),'{}'::smallint[]) else null end;
    v_selected := case when v_frequency='selected_dates' then coalesce((select array_agg(value::date) from jsonb_array_elements_text(coalesce(v_recur->'selected_dates','[]'::jsonb)) x(value)),'{}'::date[]) else null end;
    if v_frequency in ('weekly','fortnightly') and coalesce(cardinality(v_days),0)=0 then raise exception 'Select at least one weekday for this recurrence'; end if;
    if v_frequency='selected_dates' and coalesce(cardinality(v_selected),0)=0 then raise exception 'Select at least one recurrence date'; end if;
    if v_end_date is null and v_frequency<>'selected_dates' then v_end_date := v_start_date+365; end if;
    if v_selected is not null and v_end_date is null then select max(x) into v_end_date from unnest(v_selected) x; end if;

    insert into public.job_recurrence_series(
      business_id,job_costing_id,quote_id,invoice_id,customer_id,title,service_type,service_address,
      frequency,interval_count,days_of_week,selected_dates,start_date,end_date,default_start_time,
      default_duration_minutes,timezone,scheduled_value,notes,customer_instructions,active,created_by,updated_by
    ) values (
      v_business,nullif(p_schedule->>'job_costing_id','')::uuid,v_quote_id,nullif(p_schedule->>'invoice_id','')::uuid,
      nullif(p_schedule->>'customer_id','')::uuid,btrim(p_schedule->>'title'),nullif(p_schedule->>'service_type',''),
      nullif(p_schedule->>'service_address',''),v_frequency,v_interval,v_days,v_selected,v_start_date,v_end_date,
      v_start_time,v_duration,v_timezone,nullif(p_schedule->>'scheduled_value','')::numeric,
      nullif(p_schedule->>'notes',''),nullif(p_schedule->>'customer_instructions',''),true,(select auth.uid()),(select auth.uid())
    ) returning id into v_series_id;

    for v_date in
      select distinct d from (
        select x.value::date as d from jsonb_array_elements_text(coalesce(v_recur->'selected_dates','[]'::jsonb)) x(value) where v_frequency='selected_dates'
        union all
        select gs::date as d from generate_series(v_start_date,v_end_date,interval '1 day') gs where v_frequency<>'selected_dates'
          and ((v_frequency='daily' and mod((gs::date-v_start_date),v_interval)=0)
            or (v_frequency='every_other_day' and mod((gs::date-v_start_date),2)=0)
            or (v_frequency in ('weekly','fortnightly') and extract(dow from gs)::smallint=any(v_days) and mod(((gs::date-v_start_date)/7),v_interval)=0)
            or (v_frequency='monthly' and extract(day from gs)=extract(day from v_start_date) and mod(((extract(year from gs)::integer*12+extract(month from gs)::integer)-(extract(year from v_start_date)::integer*12+extract(month from v_start_date)::integer)),v_interval)=0))
      ) occurrences order by d
    loop
      v_count:=v_count+1;
      if v_count>500 then raise exception 'Recurrence is limited to 500 occurrences'; end if;
      v_occ_start := ((v_date + v_start_time) at time zone v_timezone);
      v_occ_end := v_occ_start + make_interval(mins=>v_duration);
      insert into public.job_schedules(
        business_id,job_costing_id,quote_id,customer_id,invoice_id,recurrence_series_id,recurrence_occurrence_date,
        title,service_type,service_address,start_at,end_at,timezone,status,scheduled_value,notes,customer_instructions,created_by,updated_by
      ) values (
        v_business,nullif(p_schedule->>'job_costing_id','')::uuid,v_quote_id,nullif(p_schedule->>'customer_id','')::uuid,
        nullif(p_schedule->>'invoice_id','')::uuid,v_series_id,v_date,btrim(p_schedule->>'title'),nullif(p_schedule->>'service_type',''),
        nullif(p_schedule->>'service_address',''),v_occ_start,v_occ_end,v_timezone,coalesce(nullif(p_schedule->>'status',''),'scheduled'),
        nullif(p_schedule->>'scheduled_value','')::numeric,nullif(p_schedule->>'notes',''),nullif(p_schedule->>'customer_instructions',''),(select auth.uid()),(select auth.uid())
      ) on conflict do nothing;
      if v_first then select * into v_schedule from public.job_schedules where business_id=v_business and recurrence_series_id=v_series_id and recurrence_occurrence_date=v_date; v_first:=false; end if;
      insert into public.job_schedule_assignments(business_id,schedule_id,employee_id,created_by,updated_by)
      select v_business,s.id,eid,(select auth.uid()),(select auth.uid()) from public.job_schedules s cross join unnest(v_employee_ids) ids(eid)
      where s.business_id=v_business and s.recurrence_series_id=v_series_id and s.recurrence_occurrence_date=v_date
      on conflict (schedule_id,employee_id) do nothing;
    end loop;
    if v_schedule.id is null then raise exception 'Recurrence did not produce any occurrences'; end if;
    return v_schedule;
  end if;

  -- A quote card has no schedule id. Reuse the one-time row if a concurrent
  -- request created it, otherwise insert exactly one row.
  if v_target_id is null and v_quote_id is not null then
    select s.id into v_target_id from public.job_schedules s
    where s.business_id=v_business and s.quote_id=v_quote_id and s.recurrence_series_id is null
    order by s.created_at limit 1 for update;
  end if;
  if v_target_id is null then
    insert into public.job_schedules(
      business_id,job_costing_id,quote_id,customer_id,invoice_id,title,service_type,service_address,start_at,end_at,timezone,status,scheduled_value,notes,customer_instructions,created_by,updated_by
    ) values (
      v_business,nullif(p_schedule->>'job_costing_id','')::uuid,v_quote_id,nullif(p_schedule->>'customer_id','')::uuid,nullif(p_schedule->>'invoice_id','')::uuid,
      btrim(p_schedule->>'title'),nullif(p_schedule->>'service_type',''),nullif(p_schedule->>'service_address',''),nullif(p_schedule->>'start_at','')::timestamptz,nullif(p_schedule->>'end_at','')::timestamptz,p_schedule->>'timezone',coalesce(nullif(p_schedule->>'status',''),'unscheduled'),nullif(p_schedule->>'scheduled_value','')::numeric,nullif(p_schedule->>'notes',''),nullif(p_schedule->>'customer_instructions',''),(select auth.uid()),(select auth.uid())
    ) returning * into v_schedule;
  else
    update public.job_schedules s set
      job_costing_id=nullif(p_schedule->>'job_costing_id','')::uuid,quote_id=v_quote_id,customer_id=nullif(p_schedule->>'customer_id','')::uuid,invoice_id=nullif(p_schedule->>'invoice_id','')::uuid,title=btrim(p_schedule->>'title'),service_type=nullif(p_schedule->>'service_type',''),service_address=nullif(p_schedule->>'service_address',''),start_at=nullif(p_schedule->>'start_at','')::timestamptz,end_at=nullif(p_schedule->>'end_at','')::timestamptz,timezone=p_schedule->>'timezone',status=coalesce(nullif(p_schedule->>'status',''),'unscheduled'),scheduled_value=nullif(p_schedule->>'scheduled_value','')::numeric,notes=nullif(p_schedule->>'notes',''),customer_instructions=nullif(p_schedule->>'customer_instructions',''),updated_by=(select auth.uid()),updated_at=now()
    where s.id=v_target_id and s.business_id=v_business returning * into v_schedule;
    if v_schedule.id is null then raise exception 'Schedule is unavailable in the active business'; end if;
  end if;
  delete from public.job_schedule_assignments a where a.schedule_id=v_schedule.id and a.business_id=v_business and not (a.employee_id=any(v_employee_ids));
  insert into public.job_schedule_assignments(business_id,schedule_id,employee_id,created_by,updated_by)
  select v_business,v_schedule.id,employee_id,(select auth.uid()),(select auth.uid()) from unnest(v_employee_ids) employee_ids(employee_id) on conflict (schedule_id,employee_id) do nothing;
  return v_schedule;
end;
$$;

revoke all on function public.v6179_save_schedule_with_assignments(uuid,jsonb,uuid[]) from public;
revoke execute on function public.v6179_save_schedule_with_assignments(uuid,jsonb,uuid[]) from anon;
grant execute on function public.v6179_save_schedule_with_assignments(uuid,jsonb,uuid[]) to authenticated;

commit;
