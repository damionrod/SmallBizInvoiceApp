-- V61.66 - Keep signup, tenancy membership and Trial module provisioning aligned.
-- Scope: new-user provisioning + active business resolution + safe legacy membership backfill only.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  b_id uuid;
  trial_plan_id uuid;
  trial_modules text[];
  business_name text;
  trial_end timestamptz := now() + interval '14 days';
begin
  business_name := coalesce(nullif(new.raw_user_meta_data->>'business_name',''), split_part(new.email,'@',1), 'My Business');

  insert into public.businesses(name,address,phone)
  values (business_name, new.raw_user_meta_data->>'business_address', new.raw_user_meta_data->>'phone')
  returning id into b_id;

  insert into public.profiles(id,business_id,active_business_id,full_name,email,role)
  values (new.id,b_id,b_id,new.raw_user_meta_data->>'full_name',new.email,'owner');

  insert into public.business_memberships(business_id,user_id,role,status,joined_at)
  values (b_id,new.id,'owner','active',now())
  on conflict (business_id,user_id) do update
    set role='owner', status='active', joined_at=coalesce(public.business_memberships.joined_at,excluded.joined_at), updated_at=now();

  select id,included_modules
    into trial_plan_id,trial_modules
  from public.plans
  where slug='trial'
  limit 1;

  if trial_plan_id is null then
    raise exception 'Trial plan is not configured';
  end if;

  insert into public.subscriptions(business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end)
  values (b_id,trial_plan_id,'trialing',trial_end,now(),trial_end);

  insert into public.business_modules(business_id,module_id,status,trial_ends_at)
  select b_id,m.id,'trialing',trial_end
  from public.modules m
  where m.is_active=true
    and m.slug = any(coalesce(trial_modules,array[]::text[]))
  on conflict (business_id,module_id) do update
    set status='trialing', trial_ends_at=excluded.trial_ends_at;

  return new;
end $$;

create or replace function public.current_business_id()
returns uuid
language sql
stable
security definer
set search_path=public
as $$
  select coalesce(
    case
      when p.active_business_id is not null
       and exists (
         select 1
         from public.business_memberships bm
         where bm.user_id=auth.uid()
           and bm.business_id=p.active_business_id
           and bm.status='active'
       )
      then p.active_business_id
      else null
    end,
    p.business_id
  )
  from public.profiles p
  where p.id=auth.uid()
$$;

-- Backfill only profiles that have a legacy business_id and no membership row.
insert into public.business_memberships(business_id,user_id,role,status,joined_at)
select p.business_id,p.id,
       case when p.role in ('owner','admin','member') then p.role else 'member' end,
       'active',coalesce(p.created_at,now())
from public.profiles p
where p.business_id is not null
  and not exists (
    select 1 from public.business_memberships bm
    where bm.business_id=p.business_id and bm.user_id=p.id
  )
on conflict (business_id,user_id) do nothing;

-- Align active_business_id only where it has never been set.
update public.profiles p
set active_business_id=p.business_id,
    updated_at=now()
where p.business_id is not null
  and p.active_business_id is null
  and exists (
    select 1 from public.business_memberships bm
    where bm.business_id=p.business_id
      and bm.user_id=p.id
      and bm.status='active'
  );
