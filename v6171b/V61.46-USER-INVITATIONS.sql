-- Finlo V61.46 — User Invitations and safe active-business context
-- Additive / compatibility focused. Existing tenant data remains business-owned.

create extension if not exists pgcrypto;

alter table public.profiles
  add column if not exists active_business_id uuid references public.businesses(id) on delete set null;


create table if not exists public.business_invites (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  email text not null,
  role text not null,
  token_hash text not null unique,
  status text not null default 'pending',
  invited_by uuid null references public.profiles(id) on delete set null,
  expires_at timestamptz not null,
  accepted_at timestamptz null,
  last_sent_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint v6146_business_invites_role_check check (role in ('admin','accountant','bookkeeper','staff','viewer')),
  constraint v6146_business_invites_status_check check (status in ('pending','accepted','expired','revoked'))
);

create unique index if not exists v6146_business_invites_pending_unique
  on public.business_invites (business_id, lower(email))
  where status='pending';
create index if not exists v6146_business_invites_business_status_idx
  on public.business_invites (business_id,status,created_at desc);
create index if not exists v6146_business_invites_email_idx
  on public.business_invites (lower(email),status);

alter table public.business_invites enable row level security;
revoke all on table public.business_invites from anon, authenticated;

-- Existing direct profile editing remains protected. The new active-business field is also immutable to browser updates.
create or replace function public.v50_protect_profile_security_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if session_user in ('postgres','supabase_admin','supabase_auth_admin') or auth.role() = 'service_role' or public.is_super_admin() then
    return new;
  end if;
  if auth.uid() is null or old.id is distinct from auth.uid() then
    raise exception 'You may only update your own profile.';
  end if;
  if new.id is distinct from old.id
     or new.business_id is distinct from old.business_id
     or new.active_business_id is distinct from old.active_business_id
     or new.email is distinct from old.email
     or new.role is distinct from old.role
     or new.is_super_admin is distinct from old.is_super_admin
     or new.created_at is distinct from old.created_at then
    raise exception 'Profile security fields cannot be changed.';
  end if;
  return new;
end;
$$;

update public.profiles
set active_business_id=business_id
where active_business_id is null and business_id is not null;

-- Current tenant remains backward compatible, but a normal user only gets a business context backed by an ACTIVE membership.
create or replace function public.current_business_id()
returns uuid
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_active uuid;
  v_home uuid;
begin
  if auth.uid() is null then return null; end if;
  select p.active_business_id,p.business_id into v_active,v_home
  from public.profiles p where p.id=auth.uid();

  if public.is_super_admin() then return coalesce(v_active,v_home); end if;

  if v_active is not null and exists(
    select 1 from public.business_memberships bm
    where bm.user_id=auth.uid() and bm.business_id=v_active and bm.status='active'
  ) then return v_active; end if;

  if v_home is not null and exists(
    select 1 from public.business_memberships bm
    where bm.user_id=auth.uid() and bm.business_id=v_home and bm.status='active'
  ) then return v_home; end if;

  return null;
end;
$$;

-- Membership-aware helpers for modules that previously checked profiles.business_id directly.
create or replace function public.v55_payroll_access(p_business_id uuid)
returns boolean
language sql
stable security definer
set search_path=public
as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else p_business_id=public.current_business_id()
      and public.v6145_has_active_business_membership(p_business_id)
      and exists(select 1 from public.modules m where m.slug='payroll' and m.is_active=true)
      and (
        exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
               where bm.business_id=p_business_id and m.slug='payroll' and bm.status in ('active','trialing'))
        or (
          not exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
                     where bm.business_id=p_business_id and m.slug='payroll')
          and exists(select 1 from public.subscriptions s join public.plans pl on pl.id=s.plan_id
                     where s.business_id=p_business_id and coalesce(s.status,'') not in ('suspended','canceled')
                       and 'payroll'=any(coalesce(pl.included_modules,'{}'::text[])))
        )
      )
  end
$$;

create or replace function public.v58_financials_access(p_business_id uuid)
returns boolean
language sql
stable security definer
set search_path=public
as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else p_business_id=public.current_business_id()
      and public.v6145_has_active_business_membership(p_business_id)
      and exists(select 1 from public.modules m where m.slug='financials' and m.is_active=true)
      and (
        exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
               where bm.business_id=p_business_id and m.slug='financials' and bm.status in ('active','trialing'))
        or (
          not exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
                     where bm.business_id=p_business_id and m.slug='financials')
          and exists(select 1 from public.subscriptions s join public.plans pl on pl.id=s.plan_id
                     where s.business_id=p_business_id and coalesce(s.status,'') not in ('suspended','canceled')
                       and 'financials'=any(coalesce(pl.included_modules,'{}'::text[])))
        )
      )
  end
$$;

-- New signups continue exactly as before unless they present a valid business invitation token.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  b_id uuid;
  trial_plan uuid;
  trial_modules text[];
  business_name text;
  invite_token text;
  invite_hash text;
  inv public.business_invites%rowtype;
begin
  invite_token := nullif(new.raw_user_meta_data->>'business_invite_token','');

  if invite_token is not null then
    invite_hash := encode(digest(invite_token,'sha256'),'hex');
    select * into inv
    from public.business_invites bi
    where bi.token_hash=invite_hash
      and bi.status='pending'
      and bi.expires_at>now()
      and lower(bi.email)=lower(new.email)
    for update;

    if found then
      insert into public.profiles(id,business_id,active_business_id,full_name,email,role)
      values (new.id,inv.business_id,inv.business_id,new.raw_user_meta_data->>'full_name',new.email,'member');

      insert into public.business_memberships(business_id,user_id,role,status,invited_by,joined_at)
      values (inv.business_id,new.id,inv.role,'active',inv.invited_by,now())
      on conflict (business_id,user_id) do update
        set role=excluded.role,status='active',invited_by=excluded.invited_by,joined_at=coalesce(public.business_memberships.joined_at,now()),updated_at=now();

      update public.business_invites
      set status='accepted',accepted_at=now(),updated_at=now()
      where id=inv.id;
      return new;
    end if;
    raise exception 'This business invitation is invalid, expired, or does not match this email address.';
  end if;

  business_name := coalesce(nullif(new.raw_user_meta_data->>'business_name',''), split_part(new.email,'@',1), 'My Business');
  insert into public.businesses(name,address,phone)
  values (business_name,new.raw_user_meta_data->>'business_address',new.raw_user_meta_data->>'phone')
  returning id into b_id;

  insert into public.profiles(id,business_id,active_business_id,full_name,email,role)
  values (new.id,b_id,b_id,new.raw_user_meta_data->>'full_name',new.email,'owner');

  insert into public.business_memberships(business_id,user_id,role,status,joined_at)
  values (b_id,new.id,'owner','active',now())
  on conflict (business_id,user_id) do nothing;

  select id,included_modules into trial_plan,trial_modules from public.plans where slug='trial' limit 1;
  insert into public.subscriptions(business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end)
  values (b_id,trial_plan,'trialing',now()+interval '14 days',now(),now()+interval '14 days');

  insert into public.business_modules(business_id,module_id,status,trial_ends_at)
  select b_id,m.id,'trialing',now()+interval '14 days'
  from public.modules m
  where m.slug=any(coalesce(trial_modules,array['invoice_manager']::text[]))
  on conflict do nothing;
  return new;
end;
$$;

notify pgrst, 'reload schema';
