-- Finlo V61.44 — Business Membership Foundation
-- Additive only. Does not change current_business_id(), existing tenant RLS,
-- operational tables, subscriptions, or existing profile/business ownership.

begin;

create table if not exists public.business_memberships (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member'
    check (role in ('owner','admin','member','accountant','bookkeeper','staff','viewer')),
  status text not null default 'active'
    check (status in ('active','suspended','removed')),
  invited_by uuid references auth.users(id) on delete set null,
  joined_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_memberships_business_user_key unique (business_id,user_id)
);

create index if not exists business_memberships_user_status_idx
  on public.business_memberships(user_id,status);

create index if not exists business_memberships_business_status_idx
  on public.business_memberships(business_id,status);

create or replace function public.v6144_touch_business_membership_updated_at()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists v6144_business_memberships_updated_at on public.business_memberships;
create trigger v6144_business_memberships_updated_at
before update on public.business_memberships
for each row execute function public.v6144_touch_business_membership_updated_at();

-- Backfill one active membership for every existing profile/business link.
-- ON CONFLICT makes this idempotent and preserves an existing membership if one already exists.
insert into public.business_memberships (
  business_id,user_id,role,status,joined_at,created_at,updated_at
)
select
  p.business_id,
  p.id,
  case
    when p.role in ('owner','admin','member','accountant','bookkeeper','staff','viewer') then p.role
    else 'member'
  end,
  'active',
  coalesce(p.created_at,now()),
  coalesce(p.created_at,now()),
  now()
from public.profiles p
where p.business_id is not null
on conflict (business_id,user_id) do nothing;

-- Foundation helper for later membership-aware RLS. Existing RLS is intentionally
-- NOT changed in this version, so current application behaviour remains unchanged.
create or replace function public.has_active_business_membership(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else exists (
      select 1
      from public.business_memberships bm
      where bm.business_id = p_business_id
        and bm.user_id = auth.uid()
        and bm.status = 'active'
    )
  end;
$$;

-- Add membership creation to the existing signup flow without changing the
-- existing business/profile/subscription/module behaviour.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  b_id uuid;
  trial_plan uuid;
  trial_modules text[];
  business_name text;
begin
  business_name := coalesce(nullif(new.raw_user_meta_data->>'business_name',''), split_part(new.email,'@',1), 'My Business');

  insert into public.businesses(name,address,phone)
  values (business_name, new.raw_user_meta_data->>'business_address', new.raw_user_meta_data->>'phone')
  returning id into b_id;

  insert into public.profiles(id,business_id,full_name,email,role)
  values (new.id,b_id,new.raw_user_meta_data->>'full_name',new.email,'owner');

  insert into public.business_memberships(business_id,user_id,role,status,joined_at)
  values (b_id,new.id,'owner','active',now())
  on conflict (business_id,user_id) do nothing;

  select id,included_modules into trial_plan,trial_modules
  from public.plans
  where slug='trial'
  limit 1;

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

alter table public.business_memberships enable row level security;

drop policy if exists v6144_business_memberships_select on public.business_memberships;
create policy v6144_business_memberships_select
on public.business_memberships
for select
to authenticated
using (user_id = auth.uid() or public.is_super_admin());

-- Intentionally no browser INSERT/UPDATE/DELETE policy in this foundation release.
-- Membership writes will be performed through controlled server-side flows in later versions.

revoke all on function public.v6144_touch_business_membership_updated_at() from public, anon, authenticated;
grant execute on function public.has_active_business_membership(uuid) to authenticated;

commit;
