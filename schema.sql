create extension if not exists pgcrypto;

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_number text not null unique,
  invoice_date date not null,
  due_date date,
  customer_name text not null,
  customer_address text,
  customer_email text,
  reference text,
  customer_note text,
  items jsonb not null default '[]'::jsonb,
  subtotal numeric(12,2) not null default 0,
  gst numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  company_snapshot jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- v7 fields. These ALTER statements also upgrade an existing v1-v6 table.
alter table public.invoices add column if not exists discount_type text;
alter table public.invoices add column if not exists discount_value numeric(12,2) not null default 0;
alter table public.invoices add column if not exists discount_amount numeric(12,2) not null default 0;
alter table public.invoices add column if not exists extra_fee numeric(12,2) not null default 0;
alter table public.invoices add column if not exists amount_paid numeric(12,2) not null default 0;
alter table public.invoices add column if not exists balance_due numeric(12,2);
alter table public.invoices add column if not exists recurring boolean not null default false;
alter table public.invoices add column if not exists recurring_frequency text;

create table if not exists public.recurring_rules (
  id uuid primary key,
  source_invoice_id text not null,
  frequency text not null check (frequency in ('weekly','fortnightly','monthly')),
  next_invoice_date date not null,
  template jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.invoices enable row level security;
alter table public.recurring_rules enable row level security;

-- SIMPLE SINGLE-OWNER STARTER POLICIES. Replace with authenticated-user policies before wider use.
do $$ begin
  create policy "temporary invoice access" on public.invoices for all using (true) with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "temporary recurring access" on public.recurring_rules for all using (true) with check (true);
exception when duplicate_object then null; end $$;


-- v11 customer CRM
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  customer_number text not null unique,
  customer_type text not null default 'individual',
  category text,
  name text not null,
  address text,
  dob date,
  contacts jsonb not null default '[]'::jsonb,
  custom_fields jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.invoices add column if not exists customer_id uuid;
alter table public.invoices add column if not exists customer_contact_name text;
alter table public.invoices add column if not exists customer_phone text;
alter table public.invoices add column if not exists customer_mobile text;
alter table public.invoices add column if not exists customer_category text;
do $$ begin
  alter table public.invoices add constraint invoices_customer_id_fkey foreign key (customer_id) references public.customers(id) on delete set null;
exception when duplicate_object then null; end $$;
alter table public.customers enable row level security;
do $$ begin
  create policy "temporary customer access" on public.customers for all using (true) with check (true);
exception when duplicate_object then null; end $$;
create index if not exists invoices_customer_id_idx on public.invoices(customer_id);
create index if not exists customers_name_idx on public.customers(name);

-- v16 invoice email delivery tracking
alter table public.invoices add column if not exists email_sent boolean not null default false;
alter table public.invoices add column if not exists last_sent_to text;
alter table public.invoices add column if not exists last_sent_at timestamptz;


-- ============================================================
-- v22 SaaS foundation migration
-- ============================================================
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
-- Invoice Manager v23 — Job Costing + Quotes
-- Run this entire file ONCE in Supabase SQL Editor after the v22 migration and before deploying v23.

create extension if not exists pgcrypto;

-- ---------- Job costing module catalogue ----------
insert into public.modules(slug,name,description,monthly_price,is_active)
values ('job_costing','Job Costing','Cost jobs, build margins, create quotes and progress won work into invoices',0,true)
on conflict (slug) do update set
  name=excluded.name,
  description=excluded.description,
  is_active=true;

-- Trial accounts can evaluate Job Costing. Paid plans can include it or sell it as an add-on from Super Admin.
update public.plans
set included_modules=(select array_agg(distinct x) from unnest(included_modules || array['job_costing']::text[]) x),
    updated_at=now()
where slug='trial';

-- Give existing businesses access so current v22 users can use/test the new module immediately.
insert into public.business_modules(business_id,module_id,status,trial_ends_at)
select b.id,m.id,
       case when s.status='trialing' then 'trialing' else 'active' end,
       case when s.status='trialing' then s.trial_ends_at else null end
from public.businesses b
join public.subscriptions s on s.business_id=b.id
cross join public.modules m
where m.slug='job_costing'
on conflict (business_id,module_id) do nothing;

-- ---------- Job costings ----------
create table if not exists public.job_costings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  costing_number text not null,
  costing_date date not null default current_date,
  customer_id uuid references public.customers(id) on delete set null,
  customer_name text not null,
  job_description text not null,
  notes text,
  labour_items jsonb not null default '[]'::jsonb,
  variable_costs jsonb not null default '[]'::jsonb,
  custom_fields jsonb not null default '[]'::jsonb,
  total_labour numeric(12,2) not null default 0,
  total_variable numeric(12,2) not null default 0,
  total_cost_ex_gst numeric(12,2) not null default 0,
  margin_percent numeric(7,3) not null default 0,
  recommended_price_ex_gst numeric(12,2) not null default 0,
  proposed_quote_price_ex_gst numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists job_costings_business_number_key on public.job_costings(business_id,costing_number);
create index if not exists job_costings_business_idx on public.job_costings(business_id);
create index if not exists job_costings_customer_idx on public.job_costings(customer_id);

-- ---------- Quotes ----------
create table if not exists public.quotes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  job_costing_id uuid references public.job_costings(id) on delete set null,
  quote_number text not null,
  quote_date date not null default current_date,
  valid_until date,
  customer_id uuid references public.customers(id) on delete set null,
  customer_name text not null,
  customer_address text,
  customer_email text,
  description text not null,
  quoted_price_ex_gst numeric(12,2) not null default 0,
  gst_rate numeric(7,3) not null default 15,
  gst_amount numeric(12,2) not null default 0,
  total_incl_gst numeric(12,2) not null default 0,
  notes text,
  terms text,
  status text not null default 'draft' check (status in ('draft','sent','approved','won','rejected')),
  invoice_id uuid,
  last_sent_to text,
  last_sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists quotes_business_number_key on public.quotes(business_id,quote_number);
create index if not exists quotes_business_idx on public.quotes(business_id);
create index if not exists quotes_customer_idx on public.quotes(customer_id);
create index if not exists quotes_costing_idx on public.quotes(job_costing_id);

-- Link an invoice back to the quote it came from.
alter table public.invoices add column if not exists source_quote_id uuid references public.quotes(id) on delete set null;
create index if not exists invoices_source_quote_idx on public.invoices(source_quote_id);

do $$ begin
  alter table public.quotes add constraint quotes_invoice_id_fkey foreign key (invoice_id) references public.invoices(id) on delete set null;
exception when duplicate_object then null; end $$;

-- When an invoice created from a quote is actually saved, mark that quote as Deal Won.
create or replace function public.mark_quote_won_from_invoice()
returns trigger
language plpgsql security definer set search_path=public
as $$
begin
  if new.source_quote_id is not null then
    update public.quotes
       set status='won', invoice_id=new.id, updated_at=now()
     where id=new.source_quote_id and business_id=new.business_id;
  end if;
  return new;
end $$;

drop trigger if exists mark_quote_won_from_invoice_trigger on public.invoices;
create trigger mark_quote_won_from_invoice_trigger
after insert or update of source_quote_id on public.invoices
for each row execute function public.mark_quote_won_from_invoice();

-- ---------- RLS ----------
alter table public.job_costings enable row level security;
alter table public.quotes enable row level security;

do $$ declare r record; begin
  for r in select schemaname,tablename,policyname from pg_policies
           where schemaname='public' and policyname like 'v23_%' loop
    execute format('drop policy if exists %I on %I.%I',r.policyname,r.schemaname,r.tablename);
  end loop;
end $$;

create policy v23_job_costings_tenant on public.job_costings for all
using (business_id=public.current_business_id() or public.is_super_admin())
with check (business_id=public.current_business_id() or public.is_super_admin());

create policy v23_quotes_tenant on public.quotes for all
using (business_id=public.current_business_id() or public.is_super_admin())
with check (business_id=public.current_business_id() or public.is_super_admin());

-- ---------- Future sign-ups ----------
-- Provision every module included in the Trial plan rather than hardcoding only Invoice Manager.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path=public
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

  select id,included_modules into trial_plan,trial_modules from public.plans where slug='trial' limit 1;
  insert into public.subscriptions(business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end)
  values (b_id,trial_plan,'trialing',now()+interval '14 days',now(),now()+interval '14 days');

  insert into public.business_modules(business_id,module_id,status,trial_ends_at)
  select b_id,m.id,'trialing',now()+interval '14 days'
  from public.modules m
  where m.slug=any(coalesce(trial_modules,array['invoice_manager']::text[]))
  on conflict do nothing;
  return new;
end $$;

-- Existing auth trigger continues to call public.handle_new_user().

-- v24 universal job costing additions
alter table public.job_costings add column if not exists job_address text;
alter table public.job_costings add column if not exists job_duration_hours numeric(12,3) not null default 0;
alter table public.job_costings add column if not exists direct_costs jsonb not null default '[]'::jsonb;
alter table public.job_costings add column if not exists total_direct numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists allocated_overhead numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists subtotal_job_cost numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists contingency_percent numeric(7,3) not null default 0;
alter table public.job_costings add column if not exists contingency_amount numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists expected_profit numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists expected_margin_percent numeric(9,4) not null default 0;
alter table public.job_costings add column if not exists costing_snapshot jsonb not null default '{}'::jsonb;
alter table public.quotes add column if not exists quote_items jsonb not null default '[]'::jsonb;

-- v30 quotation advance-payment support
alter table public.quotes add column if not exists advance_enabled boolean not null default false;
alter table public.quotes add column if not exists advance_percent numeric(7,3) not null default 0;
alter table public.quotes add column if not exists advance_amount numeric(12,2) not null default 0;
-- Invoice Manager v33
-- Super Admin subscription controls + subscription-plan management hardening.
-- Run this file once in Supabase SQL Editor before testing v33 admin changes.

create or replace function public.v33_admin_set_subscription(
  p_business_id uuid,
  p_plan_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  existing_id uuid;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if p_status not in ('trialing','active','past_due','suspended','canceled') then
    raise exception 'Invalid subscription status';
  end if;
  if not exists(select 1 from public.businesses where id=p_business_id) then
    raise exception 'Business not found';
  end if;
  if not exists(select 1 from public.plans where id=p_plan_id) then
    raise exception 'Plan not found';
  end if;

  select id into existing_id from public.subscriptions where business_id=p_business_id;
  if existing_id is null then
    insert into public.subscriptions(
      business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end,updated_at
    ) values (
      p_business_id,p_plan_id,p_status,
      case when p_status='trialing' then now()+interval '14 days' else null end,
      now(),
      case when p_status='trialing' then now()+interval '14 days' else now()+interval '1 month' end,
      now()
    );
  else
    update public.subscriptions
       set plan_id=p_plan_id,
           status=p_status,
           trial_ends_at=case
             when p_status='trialing' then coalesce(trial_ends_at,now()+interval '14 days')
             else null
           end,
           updated_at=now()
     where business_id=p_business_id;
  end if;

  update public.businesses
     set status=case
       when p_status='suspended' then 'suspended'
       when p_status='canceled' then 'closed'
       else 'active'
     end,
     updated_at=now()
   where id=p_business_id;
end $$;

create or replace function public.v33_admin_set_suspension(
  p_business_id uuid,
  p_suspend boolean
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  next_status text;
  plan_slug text;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if not exists(select 1 from public.businesses where id=p_business_id) then
    raise exception 'Business not found';
  end if;

  if p_suspend then
    next_status := 'suspended';
  else
    select p.slug into plan_slug
      from public.subscriptions s
      join public.plans p on p.id=s.plan_id
     where s.business_id=p_business_id;
    next_status := case when plan_slug='trial' then 'trialing' else 'active' end;
  end if;

  update public.subscriptions
     set status=next_status,updated_at=now()
   where business_id=p_business_id;

  if not found then
    raise exception 'Subscription not found for this business';
  end if;

  update public.businesses
     set status=case when p_suspend then 'suspended' else 'active' end,
         updated_at=now()
   where id=p_business_id;
end $$;

create or replace function public.v33_admin_extend_trial(
  p_business_id uuid,
  p_days integer default 14
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  new_end timestamptz;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if p_days < 1 or p_days > 365 then
    raise exception 'Trial extension must be between 1 and 365 days';
  end if;

  new_end := now() + make_interval(days=>p_days);
  update public.subscriptions
     set status='trialing',
         trial_ends_at=new_end,
         current_period_start=now(),
         current_period_end=new_end,
         updated_at=now()
   where business_id=p_business_id;
  if not found then
    raise exception 'Subscription not found for this business';
  end if;

  update public.businesses set status='active',updated_at=now() where id=p_business_id;
end $$;

create or replace function public.v33_admin_upsert_plan(
  p_id uuid,
  p_slug text,
  p_name text,
  p_description text,
  p_monthly_price numeric,
  p_invoice_limit integer,
  p_included_modules text[],
  p_stripe_price_id text,
  p_is_public boolean,
  p_sort_order integer
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  result_id uuid;
  clean_slug text;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  clean_slug := lower(trim(p_slug));
  if clean_slug is null or clean_slug='' or p_name is null or trim(p_name)='' then
    raise exception 'Plan name and slug are required';
  end if;
  if p_monthly_price < 0 then
    raise exception 'Monthly price cannot be negative';
  end if;
  if p_invoice_limit is not null and p_invoice_limit < 0 then
    raise exception 'Invoice limit cannot be negative';
  end if;

  if p_id is null then
    insert into public.plans(
      slug,name,description,monthly_price,invoice_limit,included_modules,
      stripe_price_id,is_public,sort_order,updated_at
    ) values (
      clean_slug,trim(p_name),nullif(trim(coalesce(p_description,'')),''),coalesce(p_monthly_price,0),
      p_invoice_limit,coalesce(p_included_modules,array['invoice_manager']::text[]),
      nullif(trim(coalesce(p_stripe_price_id,'')),''),coalesce(p_is_public,true),coalesce(p_sort_order,0),now()
    ) returning id into result_id;
  else
    update public.plans
       set slug=clean_slug,
           name=trim(p_name),
           description=nullif(trim(coalesce(p_description,'')),''),
           monthly_price=coalesce(p_monthly_price,0),
           invoice_limit=p_invoice_limit,
           included_modules=coalesce(p_included_modules,array['invoice_manager']::text[]),
           stripe_price_id=nullif(trim(coalesce(p_stripe_price_id,'')),''),
           is_public=coalesce(p_is_public,true),
           sort_order=coalesce(p_sort_order,0),
           updated_at=now()
     where id=p_id
     returning id into result_id;
    if result_id is null then raise exception 'Plan not found'; end if;
  end if;
  return result_id;
end $$;

revoke all on function public.v33_admin_set_subscription(uuid,uuid,text) from public, anon;
revoke all on function public.v33_admin_set_suspension(uuid,boolean) from public, anon;
revoke all on function public.v33_admin_extend_trial(uuid,integer) from public, anon;
revoke all on function public.v33_admin_upsert_plan(uuid,text,text,text,numeric,integer,text[],text,boolean,integer) from public, anon;

grant execute on function public.v33_admin_set_subscription(uuid,uuid,text) to authenticated;
grant execute on function public.v33_admin_set_suspension(uuid,boolean) to authenticated;
grant execute on function public.v33_admin_extend_trial(uuid,integer) to authenticated;
grant execute on function public.v33_admin_upsert_plan(uuid,text,text,text,numeric,integer,text[],text,boolean,integer) to authenticated;
-- Invoice Manager v34
-- Secure Super Admin payment-gateway configuration.
-- Run once in Supabase SQL Editor after V33-SUBSCRIPTIONS-ADMIN-SIGNUP.sql.
-- API secrets are stored in Supabase Vault, not in browser localStorage or public tables.

create schema if not exists vault;
create extension if not exists supabase_vault with schema vault;

create table if not exists public.payment_provider_settings (
  provider text primary key,
  display_name text not null,
  enabled boolean not null default false,
  mode text not null default 'test' check (mode in ('test','live')),
  public_config jsonb not null default '{}'::jsonb,
  secret_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_provider_name_check check (provider ~ '^[a-z0-9_]+$')
);

alter table public.payment_provider_settings enable row level security;
revoke all on table public.payment_provider_settings from anon, authenticated;
grant select on table public.payment_provider_settings to service_role;

-- Seed provider records without credentials.
insert into public.payment_provider_settings(provider,display_name,enabled,mode,public_config)
values
  ('stripe','Stripe',false,'test','{}'::jsonb),
  ('paypal','PayPal',false,'test','{}'::jsonb),
  ('mollie','Mollie',false,'test','{}'::jsonb),
  ('other','Other / future gateway',false,'test','{}'::jsonb)
on conflict (provider) do nothing;

create or replace function public.v34_admin_get_payment_providers()
returns table(
  provider text,
  display_name text,
  enabled boolean,
  mode text,
  public_config jsonb,
  has_secret boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=public,vault
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;

  return query
  select p.provider,p.display_name,p.enabled,p.mode,p.public_config,(p.secret_id is not null),p.updated_at
  from public.payment_provider_settings p
  order by case p.provider when 'stripe' then 1 when 'paypal' then 2 when 'mollie' then 3 else 99 end,p.provider;
end $$;

create or replace function public.v34_admin_save_payment_provider(
  p_provider text,
  p_enabled boolean,
  p_mode text,
  p_display_name text,
  p_public_config jsonb,
  p_secret_patch jsonb default null
)
returns void
language plpgsql
security definer
set search_path=public,vault
as $$
declare
  v_provider text := lower(trim(coalesce(p_provider,'')));
  v_secret_id uuid;
  v_existing_secret jsonb := '{}'::jsonb;
  v_merged_secret jsonb := '{}'::jsonb;
  v_secret_name text;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if v_provider not in ('stripe','paypal','mollie','other') then
    raise exception 'Unsupported payment provider';
  end if;
  if p_mode not in ('test','live') then
    raise exception 'Mode must be test or live';
  end if;
  -- v34 only has a live checkout adapter for Stripe. Other credentials can be stored safely now.
  if coalesce(p_enabled,false) and v_provider <> 'stripe' then
    raise exception '% checkout is not enabled in this version yet', initcap(v_provider);
  end if;

  select secret_id into v_secret_id
  from public.payment_provider_settings
  where provider=v_provider;

  v_secret_name := 'smallbiz_payment_' || v_provider;
  if v_secret_id is null then
    select id into v_secret_id from vault.secrets where name=v_secret_name limit 1;
  end if;

  if p_secret_patch is not null and p_secret_patch <> '{}'::jsonb then
    if v_secret_id is not null then
      begin
        select decrypted_secret::jsonb into v_existing_secret
        from vault.decrypted_secrets where id=v_secret_id;
      exception when others then
        v_existing_secret := '{}'::jsonb;
      end;
    end if;
    v_merged_secret := coalesce(v_existing_secret,'{}'::jsonb) || p_secret_patch;

    if v_secret_id is null then
      select vault.create_secret(v_merged_secret::text,v_secret_name,'SaaS payment gateway credentials for '||v_provider)
      into v_secret_id;
    else
      perform vault.update_secret(v_secret_id,v_merged_secret::text,v_secret_name,'SaaS payment gateway credentials for '||v_provider);
    end if;
  end if;

  insert into public.payment_provider_settings(provider,display_name,enabled,mode,public_config,secret_id,updated_at)
  values(v_provider,coalesce(nullif(trim(p_display_name),''),initcap(v_provider)),coalesce(p_enabled,false),p_mode,coalesce(p_public_config,'{}'::jsonb),v_secret_id,now())
  on conflict(provider) do update set
    display_name=excluded.display_name,
    enabled=excluded.enabled,
    mode=excluded.mode,
    public_config=excluded.public_config,
    secret_id=coalesce(excluded.secret_id,public.payment_provider_settings.secret_id),
    updated_at=now();
end $$;

-- Server-only helper for Edge Functions. Never grant this to browser roles.
create or replace function public.v34_get_payment_provider_secret(p_provider text)
returns text
language plpgsql
security definer
set search_path=public,vault
as $$
declare
  v_secret text;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  select d.decrypted_secret into v_secret
  from public.payment_provider_settings p
  join vault.decrypted_secrets d on d.id=p.secret_id
  where p.provider=lower(trim(p_provider));

  return v_secret;
end $$;

revoke all on function public.v34_admin_get_payment_providers() from public,anon;
revoke all on function public.v34_admin_save_payment_provider(text,boolean,text,text,jsonb,jsonb) from public,anon;
revoke all on function public.v34_get_payment_provider_secret(text) from public,anon,authenticated;

grant execute on function public.v34_admin_get_payment_providers() to authenticated;
grant execute on function public.v34_admin_save_payment_provider(text,boolean,text,text,jsonb,jsonb) to authenticated;
grant execute on function public.v34_get_payment_provider_secret(text) to service_role;

-- v35 signup/payment UX
create or replace function public.v35_checkout_available()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select coalesce((select enabled from public.payment_provider_settings where provider='stripe' limit 1),false)
$$;
revoke all on function public.v35_checkout_available() from public;
grant execute on function public.v35_checkout_available() to anon, authenticated;
-- v36 Super Admin permanent business deletion
-- Run once in Supabase SQL Editor before using the Delete button.

create or replace function public.v36_admin_delete_business(
  p_business_id uuid,
  p_confirmation_name text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  v_business_name text;
  v_user_ids uuid[];
  v_user_count integer := 0;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;

  select name into v_business_name
  from public.businesses
  where id=p_business_id;

  if v_business_name is null then
    raise exception 'Business not found';
  end if;

  if trim(coalesce(p_confirmation_name,'')) <> trim(v_business_name) then
    raise exception 'Business name confirmation does not match';
  end if;

  -- Prevent the logged-in Super Admin from deleting the business that contains
  -- their own profile, which would immediately remove their own login.
  if exists(
    select 1
    from public.profiles
    where business_id=p_business_id
      and id=auth.uid()
  ) then
    raise exception 'You cannot delete the business account you are currently logged into';
  end if;

  select coalesce(array_agg(id),'{}'::uuid[]), count(*)::integer
    into v_user_ids, v_user_count
  from public.profiles
  where business_id=p_business_id;

  -- Deleting the business cascades all business-owned data through the existing
  -- foreign keys: subscriptions, business modules, invoices, customers,
  -- recurring rules, job costings and quotes. Profiles are temporarily detached
  -- by their ON DELETE SET NULL relationship and are removed below with auth users.
  delete from public.businesses
  where id=p_business_id;

  if coalesce(array_length(v_user_ids,1),0) > 0 then
    delete from auth.users
    where id=any(v_user_ids);
  end if;

  return jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'business_name', v_business_name,
    'users_deleted', v_user_count
  );
end
$$;

revoke all on function public.v36_admin_delete_business(uuid,text) from public, anon;
grant execute on function public.v36_admin_delete_business(uuid,text) to authenticated;

notify pgrst, 'reload schema';
