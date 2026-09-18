-- Invoice Manager v22 SaaS Foundation
-- Run this entire file in Supabase SQL Editor BEFORE deploying v22.
-- It converts the existing single-business prototype into a multi-tenant SaaS database.

create extension if not exists pgcrypto;

-- ---------- SaaS core ----------
create table if not exists public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  phone text,
  status text not null default 'active' check (status in ('active','suspended','closed')),
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  business_id uuid references public.businesses(id) on delete set null,
  full_name text,
  email text,
  role text not null default 'owner' check (role in ('owner','admin','member')),
  is_super_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.plans (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  description text,
  monthly_price numeric(12,2) not null default 0,
  invoice_limit integer, -- NULL = unlimited
  included_modules text[] not null default array['invoice_manager']::text[],
  stripe_price_id text,
  is_public boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.plans(slug,name,description,monthly_price,invoice_limit,included_modules,is_public,sort_order)
values
 ('trial','Trial','Try invoicing before choosing a paid plan',0,10,array['invoice_manager'],false,0),
 ('starter','Starter','For small businesses sending a few invoices',19,25,array['invoice_manager'],true,10),
 ('business','Business','For growing businesses',39,100,array['invoice_manager'],true,20),
 ('pro','Pro','Unlimited invoicing for busy businesses',69,null,array['invoice_manager'],true,30)
on conflict (slug) do update set
 name=excluded.name, description=excluded.description, monthly_price=excluded.monthly_price,
 invoice_limit=excluded.invoice_limit, included_modules=excluded.included_modules,
 is_public=excluded.is_public, sort_order=excluded.sort_order;

create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique references public.businesses(id) on delete cascade,
  plan_id uuid not null references public.plans(id),
  status text not null default 'trialing' check (status in ('trialing','active','past_due','canceled','suspended')),
  trial_ends_at timestamptz,
  current_period_start timestamptz not null default now(),
  current_period_end timestamptz not null default (now() + interval '1 month'),
  stripe_customer_id text,
  stripe_subscription_id text,
  cancel_at_period_end boolean not null default false,
  invoice_limit_override integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.modules (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  description text,
  monthly_price numeric(12,2) not null default 0,
  stripe_price_id text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.modules(slug,name,description,monthly_price)
values ('invoice_manager','Invoice Manager','Create, email, manage and report on invoices',0)
on conflict (slug) do nothing;

create table if not exists public.business_modules (
  business_id uuid not null references public.businesses(id) on delete cascade,
  module_id uuid not null references public.modules(id) on delete cascade,
  status text not null default 'active' check (status in ('trialing','active','canceled','suspended')),
  trial_ends_at timestamptz,
  stripe_subscription_item_id text,
  created_at timestamptz not null default now(),
  primary key (business_id,module_id)
);

-- ---------- Tenant ownership on existing app tables ----------
alter table public.invoices add column if not exists business_id uuid references public.businesses(id) on delete cascade;
alter table public.customers add column if not exists business_id uuid references public.businesses(id) on delete cascade;
alter table public.recurring_rules add column if not exists business_id uuid references public.businesses(id) on delete cascade;

-- Remove old global uniqueness: different businesses can both have INV-0001 / CUST-0001.
alter table public.invoices drop constraint if exists invoices_invoice_number_key;
alter table public.customers drop constraint if exists customers_customer_number_key;
create unique index if not exists invoices_business_number_key on public.invoices(business_id,invoice_number) where business_id is not null;
create unique index if not exists customers_business_number_key on public.customers(business_id,customer_number) where business_id is not null;
create index if not exists invoices_business_idx on public.invoices(business_id);
create index if not exists customers_business_idx on public.customers(business_id);
create index if not exists recurring_business_idx on public.recurring_rules(business_id);
create index if not exists profiles_business_idx on public.profiles(business_id);

-- ---------- Helpers ----------
create or replace function public.current_business_id()
returns uuid
language sql stable security definer set search_path=public
as $$ select business_id from public.profiles where id=auth.uid() $$;

create or replace function public.is_super_admin()
returns boolean
language sql stable security definer set search_path=public
as $$ select coalesce((select is_super_admin from public.profiles where id=auth.uid()),false) $$;

alter table public.invoices alter column business_id set default public.current_business_id();
alter table public.customers alter column business_id set default public.current_business_id();
alter table public.recurring_rules alter column business_id set default public.current_business_id();

-- ---------- Sign-up provisioning ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path=public
as $$
declare
  b_id uuid;
  trial_plan uuid;
  business_name text;
begin
  business_name := coalesce(nullif(new.raw_user_meta_data->>'business_name',''), split_part(new.email,'@',1), 'My Business');
  insert into public.businesses(name,address,phone)
  values (business_name, new.raw_user_meta_data->>'business_address', new.raw_user_meta_data->>'phone')
  returning id into b_id;

  insert into public.profiles(id,business_id,full_name,email,role)
  values (new.id,b_id,new.raw_user_meta_data->>'full_name',new.email,'owner');

  select id into trial_plan from public.plans where slug='trial' limit 1;
  insert into public.subscriptions(business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end)
  values (b_id,trial_plan,'trialing',now()+interval '14 days',now(),now()+interval '14 days');

  insert into public.business_modules(business_id,module_id,status,trial_ends_at)
  select b_id,id,'trialing',now()+interval '14 days' from public.modules where slug='invoice_manager'
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- ---------- Invoice-limit enforcement ----------
create or replace function public.enforce_invoice_subscription()
returns trigger
language plpgsql security definer set search_path=public
as $$
declare
  sub record;
  lim integer;
  used integer;
begin
  if new.business_id is null then new.business_id := public.current_business_id(); end if;
  if public.is_super_admin() then return new; end if;
  select s.*,p.invoice_limit into sub
  from public.subscriptions s join public.plans p on p.id=s.plan_id
  where s.business_id=new.business_id limit 1;
  if sub.id is null then raise exception 'No subscription is attached to this business.'; end if;
  -- Historical records migrated from the pre-SaaS version do not consume the new account's current-period quota.
  if new.created_at is not null and new.created_at < sub.current_period_start then return new; end if;
  if sub.status in ('canceled','suspended','past_due') then raise exception 'Your subscription is not active.'; end if;
  if sub.status='trialing' and sub.trial_ends_at is not null and sub.trial_ends_at < now() then raise exception 'Your trial has ended. Please choose a plan.'; end if;
  lim := coalesce(sub.invoice_limit_override,sub.invoice_limit);
  if lim is not null then
    select count(*) into used from public.invoices
      where business_id=new.business_id and created_at>=sub.current_period_start and created_at<sub.current_period_end;
    if used >= lim then raise exception 'Invoice limit reached for the current subscription period.'; end if;
  end if;
  return new;
end $$;

drop trigger if exists enforce_invoice_subscription_trigger on public.invoices;
create trigger enforce_invoice_subscription_trigger before insert on public.invoices
for each row execute function public.enforce_invoice_subscription();

-- ---------- RLS: replace permissive prototype policies ----------
alter table public.businesses enable row level security;
alter table public.profiles enable row level security;
alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.modules enable row level security;
alter table public.business_modules enable row level security;
alter table public.invoices enable row level security;
alter table public.customers enable row level security;
alter table public.recurring_rules enable row level security;

drop policy if exists "temporary invoice access" on public.invoices;
drop policy if exists "temporary customer access" on public.customers;
drop policy if exists "temporary recurring access" on public.recurring_rules;

-- clean v22 policies on rerun
do $$ declare r record; begin
  for r in select schemaname,tablename,policyname from pg_policies where schemaname='public' and policyname like 'v22_%' loop
    execute format('drop policy if exists %I on %I.%I',r.policyname,r.schemaname,r.tablename);
  end loop;
end $$;

create policy v22_business_select on public.businesses for select using (id=public.current_business_id() or public.is_super_admin());
create policy v22_business_update on public.businesses for update using (id=public.current_business_id() or public.is_super_admin()) with check (id=public.current_business_id() or public.is_super_admin());
create policy v22_profiles_select on public.profiles for select using (business_id=public.current_business_id() or id=auth.uid() or public.is_super_admin());
create policy v22_profiles_update on public.profiles for update using (id=auth.uid() or public.is_super_admin()) with check (id=auth.uid() or public.is_super_admin());
create policy v22_plans_read on public.plans for select using (is_public or public.is_super_admin() or slug='trial');
create policy v22_plans_admin on public.plans for all using (public.is_super_admin()) with check (public.is_super_admin());
create policy v22_subscriptions_read on public.subscriptions for select using (business_id=public.current_business_id() or public.is_super_admin());
create policy v22_subscriptions_admin on public.subscriptions for all using (public.is_super_admin()) with check (public.is_super_admin());
create policy v22_modules_read on public.modules for select using (is_active or public.is_super_admin());
create policy v22_modules_admin on public.modules for all using (public.is_super_admin()) with check (public.is_super_admin());
create policy v22_business_modules_read on public.business_modules for select using (business_id=public.current_business_id() or public.is_super_admin());
create policy v22_business_modules_admin on public.business_modules for all using (public.is_super_admin()) with check (public.is_super_admin());

create policy v22_invoice_tenant on public.invoices for all using (business_id=public.current_business_id() or public.is_super_admin()) with check (business_id=public.current_business_id() or public.is_super_admin());
create policy v22_customer_tenant on public.customers for all using (business_id=public.current_business_id() or public.is_super_admin()) with check (business_id=public.current_business_id() or public.is_super_admin());
create policy v22_recurring_tenant on public.recurring_rules for all using (business_id=public.current_business_id() or public.is_super_admin()) with check (business_id=public.current_business_id() or public.is_super_admin());

-- ---------- Optional admin bootstrap ----------
-- AFTER you create your own account, run ONE of these with your login email:
-- update public.profiles set is_super_admin=true where email='YOUR-LOGIN-EMAIL';
-- This should only be done for the SaaS owner account.
