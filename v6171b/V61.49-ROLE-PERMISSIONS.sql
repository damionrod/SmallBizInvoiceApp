-- Finlo V61.49 — Business-level role permission defaults
-- Individual V61.48 overrides remain highest priority.
-- Owner/Admin account-control permissions remain protected and are not customisable here.

create table if not exists public.business_role_access_defaults (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  role text not null check (role in ('accountant','bookkeeper','staff','viewer')),
  area text not null check (area in ('core','expenses','bank','financials','payroll','reports')),
  can_read boolean not null,
  can_write boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id,role,area),
  check (not can_write or can_read)
);
create index if not exists business_role_access_defaults_business_idx on public.business_role_access_defaults(business_id,role);
alter table public.business_role_access_defaults enable row level security;
revoke all on public.business_role_access_defaults from anon,authenticated;

create or replace function public.v6149_effective_role_default_read(p_business_id uuid,p_role text,p_area text)
returns boolean language sql stable security definer set search_path=public as $$
  select coalesce(
    (select d.can_read from public.business_role_access_defaults d
      where d.business_id=p_business_id and d.role=p_role and d.area=p_area),
    public.v6148_role_default_read(p_role,p_area)
  )
$$;
create or replace function public.v6149_effective_role_default_write(p_business_id uuid,p_role text,p_area text)
returns boolean language sql stable security definer set search_path=public as $$
  select coalesce(
    (select d.can_write from public.business_role_access_defaults d
      where d.business_id=p_business_id and d.role=p_role and d.area=p_area),
    public.v6148_role_default_write(p_role,p_area)
  )
$$;

-- Keep the V61.47 policy entry points stable; only their default source changes.
create or replace function public.v6147_can_read_area(p_business_id uuid, p_area text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare r text; m_id uuid; o_read boolean;
begin
  if auth.uid() is null then return false; end if;
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;
  select bm.id,bm.role into m_id,r from public.business_memberships bm
   where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' limit 1;
  if m_id is null then return false; end if;
  if p_area in ('team','business_settings','billing') then
    if r in ('owner','admin') then return p_area <> 'billing' or r='owner'; end if; return false;
  end if;
  select o.can_read into o_read from public.business_member_access_overrides o
   where o.membership_id=m_id and o.business_id=p_business_id and o.area=p_area;
  if found then return o_read; end if;
  return public.v6149_effective_role_default_read(p_business_id,r,p_area);
end $$;

create or replace function public.v6147_can_write_area(p_business_id uuid, p_area text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare r text; m_id uuid; o_write boolean;
begin
  if auth.uid() is null then return false; end if;
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;
  select bm.id,bm.role into m_id,r from public.business_memberships bm
   where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' limit 1;
  if m_id is null then return false; end if;
  if p_area='billing' then return r='owner'; end if;
  if p_area in ('team','business_settings') then return r in ('owner','admin'); end if;
  select o.can_write into o_write from public.business_member_access_overrides o
   where o.membership_id=m_id and o.business_id=p_business_id and o.area=p_area;
  if found then return o_write; end if;
  return public.v6149_effective_role_default_write(p_business_id,r,p_area);
end $$;

-- V61.48 per-user screen now shows the business's effective role default.
create or replace function public.v6148_list_member_access(p_business_id uuid,p_membership_id uuid)
returns table(area text,default_read boolean,default_write boolean,override_level text,effective_read boolean,effective_write boolean)
language plpgsql stable security definer set search_path=public as $$
declare actor_role text; target_role text; target_business uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not public.v6145_can_manage_team(p_business_id) then raise exception 'Owner or Admin access required'; end if;
  select bm.role,bm.business_id into target_role,target_business from public.business_memberships bm where bm.id=p_membership_id;
  if target_business is distinct from p_business_id then raise exception 'Membership not found for this business'; end if;
  select case when public.is_super_admin() then 'owner' else bm.role end into actor_role from public.business_memberships bm
   where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' limit 1;
  actor_role:=coalesce(actor_role,case when public.is_super_admin() then 'owner' else null end);
  if target_role='owner' then raise exception 'Owner access is protected'; end if;
  if actor_role='admin' and target_role='admin' then raise exception 'Admins cannot customise another Admin'; end if;
  return query with areas(area) as (values ('core'::text),('expenses'),('bank'),('financials'),('payroll'),('reports'))
  select a.area,
    public.v6149_effective_role_default_read(p_business_id,target_role,a.area),
    public.v6149_effective_role_default_write(p_business_id,target_role,a.area),
    case when o.id is null then 'default' when o.can_write then 'write' when o.can_read then 'read' else 'none' end,
    coalesce(o.can_read,public.v6149_effective_role_default_read(p_business_id,target_role,a.area)),
    coalesce(o.can_write,public.v6149_effective_role_default_write(p_business_id,target_role,a.area))
  from areas a left join public.business_member_access_overrides o
   on o.business_id=p_business_id and o.membership_id=p_membership_id and o.area=a.area
  order by case a.area when 'core' then 1 when 'expenses' then 2 when 'bank' then 3 when 'financials' then 4 when 'payroll' then 5 else 6 end;
end $$;

create or replace function public.v6149_list_role_permissions(p_business_id uuid,p_role text)
returns table(area text,system_read boolean,system_write boolean,custom_level text,effective_read boolean,effective_write boolean)
language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('accountant','bookkeeper','staff','viewer') then raise exception 'This role is protected'; end if;
  if not (public.is_super_admin() or exists(select 1 from public.business_memberships bm where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' and bm.role='owner')) then
    raise exception 'Owner access required';
  end if;
  return query with areas(area) as (values ('core'::text),('expenses'),('bank'),('financials'),('payroll'),('reports'))
  select a.area, public.v6148_role_default_read(p_role,a.area), public.v6148_role_default_write(p_role,a.area),
    case when d.id is null then 'default' when d.can_write then 'write' when d.can_read then 'read' else 'none' end,
    coalesce(d.can_read,public.v6148_role_default_read(p_role,a.area)),
    coalesce(d.can_write,public.v6148_role_default_write(p_role,a.area))
  from areas a left join public.business_role_access_defaults d on d.business_id=p_business_id and d.role=p_role and d.area=a.area
  order by case a.area when 'core' then 1 when 'expenses' then 2 when 'bank' then 3 when 'financials' then 4 when 'payroll' then 5 else 6 end;
end $$;

create or replace function public.v6149_set_role_permission(p_business_id uuid,p_role text,p_area text,p_level text)
returns void language plpgsql security definer set search_path=public as $$
declare r boolean; w boolean;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('accountant','bookkeeper','staff','viewer') then raise exception 'This role is protected'; end if;
  if p_area not in ('core','expenses','bank','financials','payroll','reports') then raise exception 'Invalid access area'; end if;
  if p_level not in ('default','none','read','write') then raise exception 'Invalid access level'; end if;
  if not (public.is_super_admin() or exists(select 1 from public.business_memberships bm where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' and bm.role='owner')) then raise exception 'Owner access required'; end if;
  if p_level='default' then delete from public.business_role_access_defaults where business_id=p_business_id and role=p_role and area=p_area; return; end if;
  r:=p_level in ('read','write'); w:=p_level='write';
  insert into public.business_role_access_defaults(business_id,role,area,can_read,can_write,updated_at)
   values(p_business_id,p_role,p_area,r,w,now())
  on conflict (business_id,role,area) do update set can_read=excluded.can_read,can_write=excluded.can_write,updated_at=now();
end $$;

create or replace function public.v6149_reset_role_permissions(p_business_id uuid,p_role text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('accountant','bookkeeper','staff','viewer') then raise exception 'This role is protected'; end if;
  if not (public.is_super_admin() or exists(select 1 from public.business_memberships bm where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' and bm.role='owner')) then raise exception 'Owner access required'; end if;
  delete from public.business_role_access_defaults where business_id=p_business_id and role=p_role;
end $$;

revoke all on function public.v6149_effective_role_default_read(uuid,text,text) from public,anon,authenticated;
revoke all on function public.v6149_effective_role_default_write(uuid,text,text) from public,anon,authenticated;
revoke all on function public.v6149_list_role_permissions(uuid,text) from public,anon;
revoke all on function public.v6149_set_role_permission(uuid,text,text,text) from public,anon;
revoke all on function public.v6149_reset_role_permissions(uuid,text) from public,anon;
grant execute on function public.v6149_list_role_permissions(uuid,text) to authenticated;
grant execute on function public.v6149_set_role_permission(uuid,text,text,text) to authenticated;
grant execute on function public.v6149_reset_role_permissions(uuid,text) to authenticated;
