-- DRAFT for a future migration; do not run on the main project until reviewed.
-- Global Stock & Equipment remains disabled. A time-limited explicit grant
-- enables the existing authenticated RPCs for Bingo only.
begin;

create table if not exists public.se_preview_grants (
  business_id uuid primary key references public.businesses(id),
  enabled boolean not null default false,
  expires_at timestamptz not null,
  purpose text not null,
  created_at timestamptz not null default now()
);
alter table public.se_preview_grants enable row level security;
revoke all on public.se_preview_grants from public, anon, authenticated;

create or replace function public.se_preview_access_status(p_business_id uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
    return false;
  end if;
  if not exists (
    select 1 from public.business_memberships m
    where m.business_id = p_business_id and m.user_id = auth.uid()
      and m.status = 'active' and m.role in ('owner', 'admin')
  ) then return false; end if;
  if not public.v6147_can_write_area(p_business_id, 'expenses') then return false; end if;
  return exists (
    select 1 from public.se_preview_grants g
    where g.business_id = p_business_id and g.enabled
      and g.expires_at > now()
  );
end $$;
revoke all on function public.se_preview_access_status(uuid) from public, anon;
grant execute on function public.se_preview_access_status(uuid) to authenticated;

create or replace function public.se_require_access(p_business_id uuid,p_write boolean default true)
returns void language plpgsql security definer set search_path=public as $$
declare allowed boolean; member_role text;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
   raise exception 'No access to this business'; end if;
 select m.role into member_role from public.business_memberships m
 where m.business_id=p_business_id and m.user_id=auth.uid() and m.status='active';
 if member_role is null then raise exception 'Active membership required'; end if;
 if p_write then
   if not public.v6147_can_write_area(p_business_id,'expenses') then
     raise exception 'Expense editor access and an active subscription are required'; end if;
   select exists(select 1 from public.modules mod where mod.slug='stock_equipment' and mod.is_active=true)
     and coalesce((select case when bm.status='active' then true
           when bm.status='trialing' then bm.trial_ends_at is null or bm.trial_ends_at>now()
           else false end
       from public.business_modules bm join public.modules mod on mod.id=bm.module_id
       where bm.business_id=p_business_id and mod.slug='stock_equipment'),
       (select s.status in ('active','trialing') and 'stock_equipment'=any(pl.included_modules)
       from public.subscriptions s join public.plans pl on pl.id=s.plan_id
       where s.business_id=p_business_id limit 1),false) into allowed;
   allowed := allowed or public.se_preview_access_status(p_business_id);
   if not allowed then raise exception 'Stock & Equipment is not enabled for this business'; end if;
 end if;
end $$;
revoke all on function public.se_require_access(uuid,boolean) from public,anon,authenticated;

-- Seed only when Bingo and the intended owner still match their reviewed IDs.
insert into public.se_preview_grants(business_id,enabled,expires_at,purpose)
select b.id,true,'2026-10-31 00:00:00+00'::timestamptz,
       'Bingo-only synthetic Financials and Stock & Equipment verification'
from public.businesses b
where b.id='a484542c-4073-4fdb-9e3c-f02f2d78c061'
  and b.name='Bingo'
  and exists (
    select 1 from public.business_memberships m
    join public.profiles p on p.id=m.user_id
    where m.business_id=b.id and m.role='owner' and m.status='active'
      and lower(p.email)='damionrod@gmail.com'
  )
on conflict (business_id) do nothing;

-- A mismatch is an error, not a silent grant to some other business.
do $$ begin
  if not exists (select 1 from public.se_preview_grants
                 where business_id='a484542c-4073-4fdb-9e3c-f02f2d78c061'
                   and enabled and expires_at > now()) then
    raise exception 'Bingo preview grant did not pass identity and expiry checks';
  end if;
end $$;
commit;
