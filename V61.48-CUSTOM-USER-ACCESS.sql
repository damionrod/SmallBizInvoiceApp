-- Finlo V61.48 — Custom per-user operational access overrides
-- Defaults remain role-driven. Overrides are optional and apply only to one membership.

create table if not exists public.business_member_access_overrides (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  membership_id uuid not null references public.business_memberships(id) on delete cascade,
  area text not null check (area in ('core','expenses','bank','financials','payroll','reports')),
  can_read boolean not null,
  can_write boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (membership_id,area),
  check (not can_write or can_read)
);

create index if not exists business_member_access_overrides_business_idx
  on public.business_member_access_overrides(business_id,membership_id);

alter table public.business_member_access_overrides enable row level security;
revoke all on public.business_member_access_overrides from anon,authenticated;

create or replace function public.v6148_role_default_read(p_role text,p_area text)
returns boolean
language sql immutable
as $$
  select case
    when p_role in ('owner','admin') then true
    when p_area='core' then p_role in ('accountant','bookkeeper','staff','viewer')
    when p_area in ('expenses','bank') then p_role in ('accountant','bookkeeper')
    when p_area='financials' then p_role in ('accountant','bookkeeper')
    when p_area='payroll' then false
    when p_area='reports' then p_role in ('accountant','bookkeeper','viewer')
    else false
  end
$$;

create or replace function public.v6148_role_default_write(p_role text,p_area text)
returns boolean
language sql immutable
as $$
  select case
    when p_role='owner' then true
    when p_role='admin' then p_area in ('core','expenses','bank','financials','payroll','reports')
    when p_area='core' then p_role in ('accountant','bookkeeper','staff')
    when p_area in ('expenses','bank') then p_role in ('accountant','bookkeeper')
    when p_area='financials' then p_role='accountant'
    else false
  end
$$;

-- Existing V61.47 policy entry points now layer an optional per-member override
-- over the unchanged role defaults. Protected account areas remain role-only.
create or replace function public.v6147_can_read_area(p_business_id uuid, p_area text)
returns boolean
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  r text;
  m_id uuid;
  o_read boolean;
begin
  if auth.uid() is null then return false; end if;
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;

  select bm.id,bm.role into m_id,r
  from public.business_memberships bm
  where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active'
  limit 1;
  if m_id is null then return false; end if;

  -- Never make account-control permissions customisable.
  if p_area in ('team','business_settings','billing') then
    if r in ('owner','admin') then return p_area <> 'billing' or r='owner'; end if;
    return false;
  end if;

  select o.can_read into o_read
  from public.business_member_access_overrides o
  where o.membership_id=m_id and o.business_id=p_business_id and o.area=p_area;

  if found then return o_read; end if;
  return public.v6148_role_default_read(r,p_area);
end;
$$;

create or replace function public.v6147_can_write_area(p_business_id uuid, p_area text)
returns boolean
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  r text;
  m_id uuid;
  o_write boolean;
begin
  if auth.uid() is null then return false; end if;
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;

  select bm.id,bm.role into m_id,r
  from public.business_memberships bm
  where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active'
  limit 1;
  if m_id is null then return false; end if;

  if p_area='billing' then return r='owner'; end if;
  if p_area in ('team','business_settings') then return r in ('owner','admin'); end if;

  select o.can_write into o_write
  from public.business_member_access_overrides o
  where o.membership_id=m_id and o.business_id=p_business_id and o.area=p_area;

  if found then return o_write; end if;
  return public.v6148_role_default_write(r,p_area);
end;
$$;

create or replace function public.v6148_my_effective_access(p_business_id uuid default public.current_business_id())
returns table(area text,can_read boolean,can_write boolean)
language sql
stable
security definer
set search_path=public
as $$
  select a.area,
         public.v6147_can_read_area(p_business_id,a.area) as can_read,
         public.v6147_can_write_area(p_business_id,a.area) as can_write
  from (values ('core'),('expenses'),('bank'),('financials'),('payroll'),('reports')) a(area)
  where auth.uid() is not null
$$;

create or replace function public.v6148_list_member_access(p_business_id uuid,p_membership_id uuid)
returns table(
  area text,
  default_read boolean,
  default_write boolean,
  override_level text,
  effective_read boolean,
  effective_write boolean
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  actor_role text;
  target_role text;
  target_business uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not public.v6145_can_manage_team(p_business_id) then raise exception 'Owner or Admin access required'; end if;

  select bm.role,bm.business_id into target_role,target_business
  from public.business_memberships bm where bm.id=p_membership_id;
  if target_business is distinct from p_business_id then raise exception 'Membership not found for this business'; end if;

  select case when public.is_super_admin() then 'owner' else bm.role end into actor_role
  from public.business_memberships bm
  where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active'
  limit 1;
  actor_role:=coalesce(actor_role,case when public.is_super_admin() then 'owner' else null end);

  if target_role='owner' then raise exception 'Owner access is protected'; end if;
  if actor_role='admin' and target_role='admin' then raise exception 'Admins cannot customise another Admin'; end if;

  return query
  with areas(area) as (values ('core'::text),('expenses'),('bank'),('financials'),('payroll'),('reports'))
  select a.area,
         public.v6148_role_default_read(target_role,a.area),
         public.v6148_role_default_write(target_role,a.area),
         case when o.id is null then 'default'
              when o.can_write then 'write'
              when o.can_read then 'read'
              else 'none' end,
         coalesce(o.can_read,public.v6148_role_default_read(target_role,a.area)),
         coalesce(o.can_write,public.v6148_role_default_write(target_role,a.area))
  from areas a
  left join public.business_member_access_overrides o
    on o.business_id=p_business_id and o.membership_id=p_membership_id and o.area=a.area
  order by case a.area when 'core' then 1 when 'expenses' then 2 when 'bank' then 3 when 'financials' then 4 when 'payroll' then 5 else 6 end;
end;
$$;

create or replace function public.v6148_set_member_access(p_business_id uuid,p_membership_id uuid,p_area text,p_level text)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  actor_role text;
  target_role text;
  target_user uuid;
  target_business uuid;
  r boolean;
  w boolean;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not public.v6145_can_manage_team(p_business_id) then raise exception 'Owner or Admin access required'; end if;
  if p_area not in ('core','expenses','bank','financials','payroll','reports') then raise exception 'Invalid access area'; end if;
  if p_level not in ('default','none','read','write') then raise exception 'Invalid access level'; end if;

  select bm.role,bm.user_id,bm.business_id into target_role,target_user,target_business
  from public.business_memberships bm where bm.id=p_membership_id;
  if target_business is distinct from p_business_id then raise exception 'Membership not found for this business'; end if;
  if target_user=auth.uid() then raise exception 'You cannot customise your own access here'; end if;
  if target_role='owner' then raise exception 'Owner access is protected'; end if;

  select case when public.is_super_admin() then 'owner' else bm.role end into actor_role
  from public.business_memberships bm
  where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active'
  limit 1;
  actor_role:=coalesce(actor_role,case when public.is_super_admin() then 'owner' else null end);
  if actor_role='admin' and target_role='admin' then raise exception 'Admins cannot customise another Admin'; end if;

  if p_level='default' then
    delete from public.business_member_access_overrides
    where business_id=p_business_id and membership_id=p_membership_id and area=p_area;
    return;
  end if;

  r:=p_level in ('read','write');
  w:=p_level='write';
  insert into public.business_member_access_overrides(business_id,membership_id,area,can_read,can_write,updated_at)
  values(p_business_id,p_membership_id,p_area,r,w,now())
  on conflict (membership_id,area) do update
  set business_id=excluded.business_id,can_read=excluded.can_read,can_write=excluded.can_write,updated_at=now();
end;
$$;

create or replace function public.v6148_reset_member_access(p_business_id uuid,p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare target_role text; target_user uuid; target_business uuid; actor_role text;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not public.v6145_can_manage_team(p_business_id) then raise exception 'Owner or Admin access required'; end if;
  select role,user_id,business_id into target_role,target_user,target_business from public.business_memberships where id=p_membership_id;
  if target_business is distinct from p_business_id then raise exception 'Membership not found for this business'; end if;
  if target_user=auth.uid() then raise exception 'You cannot customise your own access here'; end if;
  if target_role='owner' then raise exception 'Owner access is protected'; end if;
  select case when public.is_super_admin() then 'owner' else bm.role end into actor_role from public.business_memberships bm where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' limit 1;
  actor_role:=coalesce(actor_role,case when public.is_super_admin() then 'owner' else null end);
  if actor_role='admin' and target_role='admin' then raise exception 'Admins cannot customise another Admin'; end if;
  delete from public.business_member_access_overrides where business_id=p_business_id and membership_id=p_membership_id;
end;
$$;

-- Add command-specific restrictive policies to payroll so custom Read Only really is read-only.
create or replace function public.v6148_add_payroll_restrictive(p_table text)
returns void
language plpgsql security definer set search_path=public
as $$
begin
  execute format('drop policy if exists v6148_%I_select on public.%I',p_table,p_table);
  execute format('drop policy if exists v6148_%I_insert on public.%I',p_table,p_table);
  execute format('drop policy if exists v6148_%I_update on public.%I',p_table,p_table);
  execute format('drop policy if exists v6148_%I_delete on public.%I',p_table,p_table);
  execute format('create policy v6148_%I_select on public.%I as restrictive for select to authenticated using (public.v6147_can_read_area(business_id,''payroll''))',p_table,p_table);
  execute format('create policy v6148_%I_insert on public.%I as restrictive for insert to authenticated with check (public.v6147_can_write_area(business_id,''payroll''))',p_table,p_table);
  execute format('create policy v6148_%I_update on public.%I as restrictive for update to authenticated using (public.v6147_can_write_area(business_id,''payroll'')) with check (public.v6147_can_write_area(business_id,''payroll''))',p_table,p_table);
  execute format('create policy v6148_%I_delete on public.%I as restrictive for delete to authenticated using (public.v6147_can_write_area(business_id,''payroll''))',p_table,p_table);
end;
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'payroll_audit_log','payroll_country_rules','payroll_document_types','payroll_employee_documents',
    'payroll_employee_leave','payroll_employees','payroll_financial_transactions','payroll_leave_transactions',
    'payroll_leave_types','payroll_pay_items','payroll_pay_run_employees','payroll_pay_run_lines',
    'payroll_pay_runs','payroll_payslips','payroll_settings','payroll_timesheet_expenses','payroll_timesheets'
  ] loop
    perform public.v6148_add_payroll_restrictive(t);
  end loop;
end $$;

revoke all on function public.v6148_role_default_read(text,text) from public,anon;
revoke all on function public.v6148_role_default_write(text,text) from public,anon;
revoke all on function public.v6148_my_effective_access(uuid) from public,anon;
revoke all on function public.v6148_list_member_access(uuid,uuid) from public,anon;
revoke all on function public.v6148_set_member_access(uuid,uuid,text,text) from public,anon;
revoke all on function public.v6148_reset_member_access(uuid,uuid) from public,anon;
revoke all on function public.v6148_add_payroll_restrictive(text) from public,anon,authenticated;
grant execute on function public.v6148_role_default_read(text,text) to authenticated;
grant execute on function public.v6148_role_default_write(text,text) to authenticated;
grant execute on function public.v6148_my_effective_access(uuid) to authenticated;
grant execute on function public.v6148_list_member_access(uuid,uuid) to authenticated;
grant execute on function public.v6148_set_member_access(uuid,uuid,text,text) to authenticated;
grant execute on function public.v6148_reset_member_access(uuid,uuid) to authenticated;

notify pgrst,'reload schema';
