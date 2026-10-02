-- Phase 13N: Schedule jobs can create draft Payroll timesheets.
-- Guardrails: only draft timesheets linked to a schedule are auto-created/updated/removed.
-- Submitted, approved, finalised payroll records and accounting journals are not changed.

alter table public.job_schedules
  add column if not exists payroll_create_timesheets boolean not null default true,
  add column if not exists payroll_break_minutes integer not null default 0;

alter table public.payroll_timesheets
  add column if not exists source_type text,
  add column if not exists source_schedule_id uuid references public.job_schedules(id) on delete set null,
  add column if not exists source_schedule_assignment_id uuid references public.job_schedule_assignments(id) on delete set null;

alter table public.payroll_timesheets
  drop constraint if exists payroll_timesheets_source_type_ck;

alter table public.payroll_timesheets
  add constraint payroll_timesheets_source_type_ck
  check (source_type is null or source_type in ('schedule'));

create index if not exists payroll_timesheets_source_schedule_idx
  on public.payroll_timesheets(business_id,source_schedule_id,status);

create unique index if not exists payroll_timesheets_schedule_assignment_uidx
  on public.payroll_timesheets(source_schedule_assignment_id)
  where source_type='schedule' and source_schedule_assignment_id is not null;

create or replace function public.v61105_phase13n_sync_schedule_timesheets(
  p_schedule_id uuid,
  p_create_timesheets boolean default true,
  p_break_minutes integer default 0
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  b uuid:=public.current_business_id();
  u uuid:=auth.uid();
  s public.job_schedules%rowtype;
  a record;
  jc_id uuid;
  business_settings jsonb:='{}'::jsonb;
  prefix text:='JC';
  next_seq integer:=1;
  jc_no text;
  cust_name text:='';
  tz text;
  local_start timestamp;
  local_end timestamp;
  duration_mins integer;
  break_mins integer:=greatest(0,coalesce(p_break_minutes,0));
  total_hours_val numeric;
  created_count integer:=0;
  updated_count integer:=0;
  skipped_locked_count integer:=0;
  deleted_draft_count integer:=0;
  active_assignment_count integer:=0;
begin
  if u is null or b is null then
    raise exception 'Choose a business and sign in';
  end if;

  select * into s
  from public.job_schedules
  where id=p_schedule_id and business_id=b;

  if s.id is null then
    raise exception 'Schedule job not found in current business';
  end if;

  update public.job_schedules
  set payroll_create_timesheets=coalesce(p_create_timesheets,false),
      payroll_break_minutes=break_mins,
      updated_at=now(),
      updated_by=u
  where id=s.id and business_id=b
  returning * into s;

  if coalesce(p_create_timesheets,false)=false
     or s.start_at is null
     or s.end_at is null
     or s.status in ('unscheduled','cancelled') then
    delete from public.payroll_timesheets t
    where t.business_id=b
      and t.source_type='schedule'
      and t.source_schedule_id=s.id
      and t.status='draft';
    get diagnostics deleted_draft_count = row_count;
    return jsonb_build_object(
      'synced',true,
      'created',0,
      'updated',0,
      'deleted_draft',deleted_draft_count,
      'skipped_non_draft',0,
      'job_costing_created',false
    );
  end if;

  duration_mins:=greatest(0,floor(extract(epoch from (s.end_at-s.start_at))/60)::integer);
  if break_mins>=duration_mins then
    raise exception 'Break must be shorter than the scheduled duration';
  end if;
  select count(*) into active_assignment_count
  from public.job_schedule_assignments ax
  where ax.business_id=b
    and ax.schedule_id=s.id
    and ax.employee_id is not null
    and coalesce(ax.assignment_status,'assigned')<>'cancelled';
  if active_assignment_count=0 then
    delete from public.payroll_timesheets t
    where t.business_id=b
      and t.source_type='schedule'
      and t.source_schedule_id=s.id
      and t.status='draft';
    get diagnostics deleted_draft_count = row_count;
    return jsonb_build_object(
      'synced',true,
      'created',0,
      'updated',0,
      'deleted_draft',deleted_draft_count,
      'skipped_non_draft',0,
      'job_costing_created',false,
      'reason','no_assigned_employees'
    );
  end if;
  total_hours_val:=round((duration_mins-break_mins)::numeric/60,2);
  tz:=coalesce(nullif(s.timezone,''),'Pacific/Auckland');
  local_start:=s.start_at at time zone tz;
  local_end:=s.end_at at time zone tz;
  jc_id:=s.job_costing_id;
  select coalesce((
    select c.name
    from public.customers c
    where c.business_id=b and c.id=s.customer_id
  ), '') into cust_name;

  if jc_id is null then
    select coalesce(bs.settings,'{}'::jsonb) into business_settings
    from public.businesses bs
    where bs.id=b;

    prefix:=upper(regexp_replace(coalesce(business_settings#>>'{jobCostingSettings,costingPrefix}','JC'),'[^A-Za-z0-9]+','','g'));
    if prefix='' then prefix:='JC'; end if;

    select coalesce(max((m[1])::integer),0)+1 into next_seq
    from (
      select regexp_match(jc.costing_number,'^'||prefix||'-(\d+)$','i') m
      from public.job_costings jc
      where jc.business_id=b
    ) n
    where m is not null;

    jc_no:=prefix||'-'||lpad(next_seq::text,4,'0');

    insert into public.job_costings(
      business_id,costing_number,costing_date,customer_id,customer_name,job_description,notes,
      labour_items,variable_costs,direct_costs,custom_fields,job_address,job_duration_hours,
      total_labour,total_variable,total_direct,allocated_overhead,contingency_percent,contingency_amount,
      subtotal_job_cost,total_cost_ex_gst,margin_percent,recommended_price_ex_gst,proposed_quote_price_ex_gst,
      expected_profit,expected_margin_percent,costing_snapshot,current_estimate_snapshot,estimate_status,status,updated_at
    ) values (
      b,jc_no,(local_start::date),s.customer_id,cust_name,coalesce(s.title,s.service_type,'Scheduled job'),
      'Created automatically from Schedule so payroll time can be linked to a job number.',
      '[]'::jsonb,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,coalesce(s.service_address,''),round(duration_mins::numeric/60,2),
      0,0,0,0,0,0,0,0,0,0,0,0,0,
      jsonb_build_object('source','schedule','schedule_id',s.id,'created_for','draft_timesheets'),
      jsonb_build_object('source','schedule','schedule_id',s.id,'created_for','draft_timesheets'),
      'not_estimated','draft',now()
    )
    returning id into jc_id;

    update public.job_schedules
    set job_costing_id=jc_id,
        updated_at=now(),
        updated_by=u
    where id=s.id and business_id=b;
  end if;

  delete from public.payroll_timesheets t
  where t.business_id=b
    and t.source_type='schedule'
    and t.source_schedule_id=s.id
    and t.status='draft'
    and not exists (
      select 1
      from public.job_schedule_assignments ax
      where ax.id=t.source_schedule_assignment_id
        and ax.business_id=b
        and ax.schedule_id=s.id
        and coalesce(ax.assignment_status,'assigned')<>'cancelled'
    );
  get diagnostics deleted_draft_count = row_count;

  for a in
    select jsa.*
    from public.job_schedule_assignments jsa
    where jsa.business_id=b
      and jsa.schedule_id=s.id
      and jsa.employee_id is not null
      and coalesce(jsa.assignment_status,'assigned')<>'cancelled'
  loop
    if exists (
      select 1
      from public.payroll_timesheets t
      where t.business_id=b
        and t.source_type='schedule'
        and t.source_schedule_assignment_id=a.id
        and t.status<>'draft'
    ) then
      skipped_locked_count:=skipped_locked_count+1;
      continue;
    end if;

    if exists (
      select 1
      from public.payroll_timesheets t
      where t.business_id=b
        and t.source_type='schedule'
        and t.source_schedule_assignment_id=a.id
        and t.status='draft'
    ) then
      update public.payroll_timesheets
      set employee_id=a.employee_id,
          work_date=local_start::date,
          job_costing_id=jc_id,
          customer_id=s.customer_id,
          start_time=local_start::time,
          finish_time=local_end::time,
          break_minutes=break_mins,
          total_hours=total_hours_val,
          pay_type='ordinary',
          notes='Draft time created from Schedule: '||coalesce(s.title,s.service_type,'Scheduled job'),
          updated_at=now(),
          updated_by=u
      where business_id=b
        and payroll_timesheets.source_type='schedule'
        and payroll_timesheets.source_schedule_assignment_id=a.id
        and payroll_timesheets.status='draft';
      updated_count:=updated_count+1;
    else
      insert into public.payroll_timesheets(
        business_id,employee_id,work_date,job_costing_id,customer_id,start_time,finish_time,
        break_minutes,total_hours,pay_type,notes,status,source_type,source_schedule_id,
        source_schedule_assignment_id,created_by,updated_at,updated_by
      ) values (
        b,a.employee_id,local_start::date,jc_id,s.customer_id,local_start::time,local_end::time,
        break_mins,total_hours_val,'ordinary',
        'Draft time created from Schedule: '||coalesce(s.title,s.service_type,'Scheduled job'),
        'draft','schedule',s.id,a.id,u,now(),u
      );
      created_count:=created_count+1;
    end if;
  end loop;

  return jsonb_build_object(
    'synced',true,
    'created',created_count,
    'updated',updated_count,
    'deleted_draft',deleted_draft_count,
    'skipped_non_draft',skipped_locked_count,
    'job_costing_created',s.job_costing_id is null,
    'job_costing_id',jc_id
  );
end$$;

revoke execute on function public.v61105_phase13n_sync_schedule_timesheets(uuid,boolean,integer) from public,anon;
grant execute on function public.v61105_phase13n_sync_schedule_timesheets(uuid,boolean,integer) to authenticated;

-- Make the new RPC visible to Supabase/PostgREST immediately after running this SQL.
notify pgrst, 'reload schema';
