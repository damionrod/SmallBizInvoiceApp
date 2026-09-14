-- Finlo V61.45 — Team & Access management foundation
-- Additive only: no tenant-owned business data or existing RLS policies are changed.

create or replace function public.v6145_has_active_business_membership(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else exists(
      select 1 from public.business_memberships bm
      where bm.user_id=auth.uid()
        and bm.business_id=p_business_id
        and bm.status='active'
    )
  end
$$;

create or replace function public.v6145_can_manage_team(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else exists(
      select 1 from public.business_memberships bm
      where bm.user_id=auth.uid()
        and bm.business_id=p_business_id
        and bm.status='active'
        and bm.role in ('owner','admin')
    )
  end
$$;

create or replace function public.v6145_list_business_team(p_business_id uuid)
returns table(
  membership_id uuid,
  user_id uuid,
  full_name text,
  email text,
  role text,
  status text,
  joined_at timestamptz,
  created_at timestamptz,
  is_self boolean
)
language plpgsql
stable
security definer
set search_path=public
as $$
begin
  if not public.v6145_can_manage_team(p_business_id) then
    raise exception 'Owner or Admin access required';
  end if;

  return query
  select bm.id, bm.user_id, p.full_name, p.email, bm.role, bm.status,
         bm.joined_at, bm.created_at, (bm.user_id=auth.uid())
  from public.business_memberships bm
  left join public.profiles p on p.id=bm.user_id
  where bm.business_id=p_business_id
    and bm.status <> 'removed'
  order by case bm.role when 'owner' then 0 when 'admin' then 1 else 2 end,
           lower(coalesce(p.full_name,p.email,''));
end
$$;

create or replace function public.v6145_update_business_member(
  p_business_id uuid,
  p_membership_id uuid,
  p_role text,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_actor_role text;
  v_target public.business_memberships%rowtype;
  v_role text := lower(trim(coalesce(p_role,'')));
  v_status text := lower(trim(coalesce(p_status,'')));
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select bm.role into v_actor_role
  from public.business_memberships bm
  where bm.business_id=p_business_id and bm.user_id=auth.uid() and bm.status='active';

  if public.is_super_admin() then v_actor_role := 'owner'; end if;
  if v_actor_role not in ('owner','admin') then raise exception 'Owner or Admin access required'; end if;

  select * into v_target
  from public.business_memberships
  where id=p_membership_id and business_id=p_business_id;
  if not found then raise exception 'Team member not found'; end if;

  if v_target.user_id=auth.uid() then raise exception 'You cannot change your own access here'; end if;
  if v_target.role='owner' then raise exception 'Owner access is protected'; end if;
  if v_actor_role='admin' and v_target.role='admin' then raise exception 'Admins cannot change another Admin'; end if;
  if v_role not in ('admin','accountant','bookkeeper','staff','viewer') then raise exception 'Invalid role'; end if;
  if v_actor_role='admin' and v_role='admin' then raise exception 'Only an Owner can assign Admin access'; end if;
  if v_status not in ('active','suspended','removed') then raise exception 'Invalid status'; end if;

  update public.business_memberships
  set role=v_role,
      status=v_status,
      joined_at=case when v_status='active' then coalesce(joined_at,now()) else joined_at end,
      updated_at=now()
  where id=p_membership_id and business_id=p_business_id;

  return jsonb_build_object('ok',true,'membership_id',p_membership_id,'role',v_role,'status',v_status);
end
$$;

revoke all on function public.v6145_has_active_business_membership(uuid) from public, anon;
revoke all on function public.v6145_can_manage_team(uuid) from public, anon;
revoke all on function public.v6145_list_business_team(uuid) from public, anon;
revoke all on function public.v6145_update_business_member(uuid,uuid,text,text) from public, anon;
grant execute on function public.v6145_has_active_business_membership(uuid) to authenticated;
grant execute on function public.v6145_can_manage_team(uuid) to authenticated;
grant execute on function public.v6145_list_business_team(uuid) to authenticated;
grant execute on function public.v6145_update_business_member(uuid,uuid,text,text) to authenticated;
