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

  -- Financials tables have AFTER DELETE audit triggers. Delete these rows while
  -- the parent business still exists so their audit rows can satisfy the
  -- financial_audit_log.business_id foreign key. Remove those audit rows before
  -- deleting the business itself.
  delete from public.financial_budget_month_values where business_id=p_business_id;
  delete from public.financial_budget_lines where business_id=p_business_id;
  delete from public.financial_budgets where business_id=p_business_id;
  delete from public.financial_category_mappings where business_id=p_business_id;
  delete from public.gst_returns where business_id=p_business_id;
  delete from public.financial_settings where business_id=p_business_id;
  delete from public.financial_audit_log where business_id=p_business_id;

  -- Remaining business-owned data continues to cascade through the existing
  -- foreign keys. Profiles are detached by their ON DELETE SET NULL relationship
  -- and their auth users are removed below.
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

-- ---------- v50 profile privilege hardening ----------
create or replace function public.v50_protect_profile_security_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() = 'service_role' or public.is_super_admin() then
    return new;
  end if;
  if auth.uid() is null or old.id is distinct from auth.uid() then
    raise exception 'You may only update your own profile.';
  end if;
  if new.id is distinct from old.id
     or new.business_id is distinct from old.business_id
     or new.email is distinct from old.email
     or new.role is distinct from old.role
     or new.is_super_admin is distinct from old.is_super_admin
     or new.created_at is distinct from old.created_at then
    raise exception 'Profile security fields cannot be changed.';
  end if;
  return new;
end;
$$;
revoke all on function public.v50_protect_profile_security_fields() from public, anon, authenticated;
grant execute on function public.v50_protect_profile_security_fields() to service_role;
drop trigger if exists v50_protect_profile_security_fields on public.profiles;
create trigger v50_protect_profile_security_fields
before update on public.profiles
for each row execute function public.v50_protect_profile_security_fields();
drop policy if exists v22_profiles_update on public.profiles;
create policy v22_profiles_update on public.profiles for update
using (id=auth.uid() or public.is_super_admin())
with check (id=auth.uid() or public.is_super_admin());
notify pgrst, 'reload schema';

-- ---------- V61.66 signup/membership/module alignment ----------
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

  select id,included_modules into trial_plan_id,trial_modules
  from public.plans where slug='trial' limit 1;
  if trial_plan_id is null then raise exception 'Trial plan is not configured'; end if;

  insert into public.subscriptions(business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end)
  values (b_id,trial_plan_id,'trialing',trial_end,now(),trial_end);

  insert into public.business_modules(business_id,module_id,status,trial_ends_at)
  select b_id,m.id,'trialing',trial_end
  from public.modules m
  where m.is_active=true and m.slug=any(coalesce(trial_modules,array[]::text[]))
  on conflict (business_id,module_id) do update
    set status='trialing', trial_ends_at=excluded.trial_ends_at;
  return new;
end $$;

create or replace function public.current_business_id()
returns uuid
language sql stable security definer set search_path=public
as $$
  select coalesce(
    case when p.active_business_id is not null and exists (
      select 1 from public.business_memberships bm
      where bm.user_id=auth.uid() and bm.business_id=p.active_business_id and bm.status='active'
    ) then p.active_business_id end,
    p.business_id
  )
  from public.profiles p where p.id=auth.uid()
$$;


-- ============================================================
-- V61.67 - Job Costing actuals / profitability upgrade

-- V61.67 - Job Costing actuals / profitability upgrade
-- Additive only. Keeps job_costings as the canonical job record.

alter table public.job_costings add column if not exists status text not null default 'draft';
alter table public.job_costings add column if not exists estimate_status text not null default 'not_estimated';
alter table public.job_costings add column if not exists estimate_frozen_at timestamptz;
alter table public.job_costings add column if not exists original_estimate_snapshot jsonb;
alter table public.job_costings add column if not exists current_estimate_snapshot jsonb;
alter table public.job_costings add column if not exists started_at timestamptz;
alter table public.job_costings add column if not exists completed_at timestamptz;

alter table public.invoices add column if not exists job_costing_id uuid;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='invoices_job_costing_id_fkey') then
    alter table public.invoices add constraint invoices_job_costing_id_fkey foreign key (job_costing_id) references public.job_costings(id) on delete set null;
  end if;
end $$;

create index if not exists job_costings_business_status_idx on public.job_costings(business_id,status);
create index if not exists invoices_business_job_costing_idx on public.invoices(business_id,job_costing_id);

create table if not exists public.job_actual_costs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  job_costing_id uuid not null references public.job_costings(id) on delete cascade,
  cost_date date not null default current_date,
  cost_type text not null default 'other',
  description text not null,
  quantity numeric(12,3) not null default 1,
  unit text not null default 'Item',
  unit_cost numeric(12,4) not null default 0,
  amount_ex_gst numeric(12,2) not null default 0,
  notes text,
  source_type text not null default 'manual',
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_actual_costs_source_check check (source_type in ('manual')),
  constraint job_actual_costs_amount_check check (quantity >= 0 and unit_cost >= 0 and amount_ex_gst >= 0)
);
create index if not exists job_actual_costs_business_job_idx on public.job_actual_costs(business_id,job_costing_id);
create index if not exists job_actual_costs_job_date_idx on public.job_actual_costs(job_costing_id,cost_date);

create table if not exists public.job_activity (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  job_costing_id uuid not null references public.job_costings(id) on delete cascade,
  activity_type text not null,
  description text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists job_activity_business_job_idx on public.job_activity(business_id,job_costing_id,created_at desc);

alter table public.job_actual_costs enable row level security;
alter table public.job_activity enable row level security;

drop policy if exists v6167_job_actual_costs_tenant on public.job_actual_costs;
create policy v6167_job_actual_costs_tenant on public.job_actual_costs for all to authenticated
using (public.is_super_admin() or business_id=public.current_business_id())
with check (public.is_super_admin() or business_id=public.current_business_id());

drop policy if exists v6167_job_activity_tenant on public.job_activity;
create policy v6167_job_activity_tenant on public.job_activity for all to authenticated
using (public.is_super_admin() or business_id=public.current_business_id())
with check (public.is_super_admin() or business_id=public.current_business_id());

create or replace function public.v6167_validate_job_business()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  job_business uuid;
begin
  if new.job_costing_id is null then return new; end if;
  select business_id into job_business from public.job_costings where id=new.job_costing_id;
  if job_business is null then raise exception 'Job not found'; end if;
  if new.business_id is null then new.business_id:=job_business; end if;
  if new.business_id is distinct from job_business then raise exception 'Job belongs to a different business'; end if;
  return new;
end $$;

drop trigger if exists v6167_job_actual_costs_business_guard on public.job_actual_costs;
create trigger v6167_job_actual_costs_business_guard before insert or update of business_id,job_costing_id on public.job_actual_costs
for each row execute function public.v6167_validate_job_business();

drop trigger if exists v6167_job_activity_business_guard on public.job_activity;
create trigger v6167_job_activity_business_guard before insert or update of business_id,job_costing_id on public.job_activity
for each row execute function public.v6167_validate_job_business();

create or replace function public.v6167_invoice_job_guard()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  quote_job uuid;
  job_business uuid;
begin
  if new.job_costing_id is null and new.source_quote_id is not null then
    select job_costing_id into quote_job from public.quotes where id=new.source_quote_id;
    new.job_costing_id:=quote_job;
  end if;
  if new.job_costing_id is not null then
    select business_id into job_business from public.job_costings where id=new.job_costing_id;
    if job_business is null then raise exception 'Job not found'; end if;
    if new.business_id is null then new.business_id:=job_business; end if;
    if new.business_id is distinct from job_business then raise exception 'Invoice job belongs to a different business'; end if;
  end if;
  return new;
end $$;

drop trigger if exists v6167_invoice_job_guard on public.invoices;
create trigger v6167_invoice_job_guard before insert or update of business_id,job_costing_id,source_quote_id on public.invoices
for each row execute function public.v6167_invoice_job_guard();

create or replace function public.v6167_sync_job_from_quote()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  snap jsonb;
begin
  if new.job_costing_id is null then return new; end if;
  select coalesce(current_estimate_snapshot,costing_snapshot,'{}'::jsonb) into snap from public.job_costings where id=new.job_costing_id;
  if tg_op='INSERT' then
    update public.job_costings
      set original_estimate_snapshot=coalesce(original_estimate_snapshot,snap),
          current_estimate_snapshot=coalesce(current_estimate_snapshot,snap),
          estimate_frozen_at=coalesce(estimate_frozen_at,now()),
          estimate_status=case when estimate_status='not_estimated' then 'frozen' else 'frozen' end,
          status=case when status in ('approved_won','in_progress','completed','cancelled') then status else 'quoted' end,
          updated_at=now()
    where id=new.job_costing_id;
  end if;
  if new.status in ('approved','won') and (tg_op='INSERT' or old.status is distinct from new.status) then
    update public.job_costings set status=case when status='completed' then status else 'approved_won' end,updated_at=now() where id=new.job_costing_id;
    if tg_op='UPDATE' and old.status is distinct from new.status then
      insert into public.job_activity(business_id,job_costing_id,activity_type,description,metadata,created_by)
      values(new.business_id,new.job_costing_id,'quote_approved','Quote '||new.quote_number||' approved / won',jsonb_build_object('quote_id',new.id),auth.uid());
    end if;
  end if;
  return new;
end $$;

drop trigger if exists v6167_sync_job_from_quote on public.quotes;
create trigger v6167_sync_job_from_quote after insert or update of status on public.quotes
for each row execute function public.v6167_sync_job_from_quote();


-- Lightweight activity hooks for existing source modules. They log links/status changes only;
-- source transactions remain authoritative and are never copied into job_actual_costs.
create or replace function public.v6167_record_source_activity()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  jid uuid;
  label text;
  typ text;
begin
  jid:=new.job_costing_id;
  if jid is null then return new; end if;
  if tg_op='UPDATE' and old.job_costing_id is not distinct from new.job_costing_id then
    if tg_table_name='payroll_timesheets' and old.status is distinct from new.status and new.status='approved' then
      null;
    else
      return new;
    end if;
  end if;
  if tg_table_name='expenses' then typ:='expense_assigned'; label:='Expense '||coalesce(new.expense_number,'')||' assigned to job';
  elsif tg_table_name='expense_lines' then typ:='expense_assigned'; label:='Split expense line assigned to job';
  elsif tg_table_name='payroll_timesheets' then typ:='timesheet_assigned'; label:=case when new.status='approved' then 'Approved timesheet assigned to job' else 'Timesheet assigned to job' end;
  elsif tg_table_name='invoices' then typ:='invoice_created'; label:='Invoice '||coalesce(new.invoice_number,'')||' linked to job';
  else return new;
  end if;
  insert into public.job_activity(business_id,job_costing_id,activity_type,description,metadata,created_by)
  values(new.business_id,jid,typ,label,jsonb_build_object('source_table',tg_table_name,'source_id',new.id),auth.uid());
  return new;
end $$;

drop trigger if exists v6167_expense_job_activity on public.expenses;
create trigger v6167_expense_job_activity after insert or update of job_costing_id on public.expenses
for each row execute function public.v6167_record_source_activity();

drop trigger if exists v6167_expense_line_job_activity on public.expense_lines;
create trigger v6167_expense_line_job_activity after insert or update of job_costing_id on public.expense_lines
for each row execute function public.v6167_record_source_activity();

drop trigger if exists v6167_timesheet_job_activity on public.payroll_timesheets;
create trigger v6167_timesheet_job_activity after insert or update of job_costing_id,status on public.payroll_timesheets
for each row execute function public.v6167_record_source_activity();

drop trigger if exists v6167_invoice_job_activity on public.invoices;
create trigger v6167_invoice_job_activity after insert or update of job_costing_id on public.invoices
for each row execute function public.v6167_record_source_activity();

-- Backfill invoice job links only when the existing quote relationship is unambiguous.
update public.invoices i
set job_costing_id=q.job_costing_id
from public.quotes q
where i.job_costing_id is null
  and i.source_quote_id=q.id
  and q.job_costing_id is not null
  and (i.business_id is null or i.business_id=q.business_id);

-- Preserve current estimate data for existing records without overwriting costing_snapshot.
update public.job_costings
set current_estimate_snapshot=coalesce(current_estimate_snapshot,costing_snapshot),
    estimate_status=case
      when coalesce(total_cost_ex_gst,0)>0 or coalesce(proposed_quote_price_ex_gst,0)>0 or coalesce(costing_snapshot,'{}'::jsonb) <> '{}'::jsonb then 'estimated'
      else 'not_estimated'
    end
where current_estimate_snapshot is null;

-- Safe initial lifecycle inference. Never infer completion.
update public.job_costings j
set status=case
  when exists(select 1 from public.quotes q where q.job_costing_id=j.id and q.status in ('approved','won'))
       or exists(select 1 from public.invoices i where i.job_costing_id=j.id) then 'approved_won'
  when exists(select 1 from public.quotes q where q.job_costing_id=j.id) then 'quoted'
  when j.estimate_status in ('estimated','frozen') then 'estimated'
  else 'draft'
end
where j.status='draft';

-- Freeze the original estimate for existing quoted jobs if it was not already captured.
update public.job_costings j
set original_estimate_snapshot=coalesce(j.original_estimate_snapshot,j.current_estimate_snapshot,j.costing_snapshot),
    estimate_frozen_at=coalesce(j.estimate_frozen_at,(select min(q.created_at) from public.quotes q where q.job_costing_id=j.id)),
    estimate_status='frozen'
where exists(select 1 from public.quotes q where q.job_costing_id=j.id)
  and j.original_estimate_snapshot is null;
-- V61.68A — platform payroll rulesets + official compliance monitoring
-- Additive only. Detection/review NEVER changes active production payroll rules.

create table if not exists public.payroll_rulesets (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null check (country_code ~ '^[A-Z]{2}$'),
  name text not null,
  version text not null,
  effective_from date not null,
  effective_to date,
  status text not null default 'draft' check (status in ('draft','validated','approved','active','retired')),
  source_update_id uuid,
  created_by uuid references auth.users(id) on delete set null,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  activated_by uuid references auth.users(id) on delete set null,
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  unique(country_code,name,version)
);

create table if not exists public.payroll_ruleset_rules (
  id uuid primary key default gen_random_uuid(),
  ruleset_id uuid not null references public.payroll_rulesets(id) on delete cascade,
  rule_type text not null,
  rule_key text not null,
  numeric_value numeric,
  text_value text,
  json_value jsonb,
  source_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (num_nonnulls(numeric_value,text_value,json_value)=1),
  unique(ruleset_id,rule_type,rule_key)
);

create table if not exists public.payroll_compliance_sources (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null check (country_code ~ '^[A-Z]{2}$'),
  source_name text not null,
  source_type text not null default 'official_specification',
  source_url text not null,
  source_identifier text not null,
  purpose text,
  active boolean not null default true,
  check_frequency text not null default 'daily',
  last_checked_at timestamptz,
  last_successful_check_at timestamptz,
  last_changed_at timestamptz,
  last_known_version text,
  last_known_fingerprint text,
  last_source_reference text,
  last_check_status text not null default 'never_checked' check (last_check_status in ('never_checked','no_change','change_detected','check_error')),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(country_code,source_identifier)
);

create table if not exists public.payroll_compliance_updates (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references public.payroll_compliance_sources(id) on delete restrict,
  country_code char(2) not null,
  detected_at timestamptz not null default now(),
  source_version text,
  source_fingerprint text not null,
  previous_fingerprint text,
  status text not null default 'review_required' check (status in ('review_required','draft_prepared','validated','approved','activated','dismissed_no_payroll_impact')),
  summary text,
  source_reference text,
  proposed_ruleset_id uuid references public.payroll_rulesets(id) on delete set null,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_notes text,
  dismissed_at timestamptz,
  dismissed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(source_id,source_fingerprint)
);

alter table public.payroll_rulesets drop constraint if exists payroll_rulesets_source_update_id_fkey;
alter table public.payroll_rulesets add constraint payroll_rulesets_source_update_id_fkey foreign key(source_update_id) references public.payroll_compliance_updates(id) on delete set null;

create table if not exists public.payroll_compliance_audit (
  id uuid primary key default gen_random_uuid(),
  country_code char(2),
  source_id uuid references public.payroll_compliance_sources(id) on delete set null,
  update_id uuid references public.payroll_compliance_updates(id) on delete set null,
  ruleset_id uuid references public.payroll_rulesets(id) on delete set null,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists payroll_rulesets_country_status_idx on public.payroll_rulesets(country_code,status,effective_from);
create index if not exists payroll_ruleset_rules_ruleset_idx on public.payroll_ruleset_rules(ruleset_id,rule_type,rule_key);
create index if not exists payroll_compliance_updates_status_idx on public.payroll_compliance_updates(country_code,status,detected_at desc);
create index if not exists payroll_compliance_audit_created_idx on public.payroll_compliance_audit(created_at desc);

alter table public.payroll_rulesets enable row level security;
alter table public.payroll_ruleset_rules enable row level security;
alter table public.payroll_compliance_sources enable row level security;
alter table public.payroll_compliance_updates enable row level security;
alter table public.payroll_compliance_audit enable row level security;

do $$ declare t text; begin
  foreach t in array array['payroll_rulesets','payroll_ruleset_rules','payroll_compliance_sources','payroll_compliance_updates','payroll_compliance_audit'] loop
    execute format('drop policy if exists %I on public.%I',t||'_super_admin',t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin())',t||'_super_admin',t);
  end loop;
end $$;

-- Server/service-role monitor writes are intentionally separate from ordinary tenant access.
-- Seed the authoritative NZ IRD landing page. The server monitor resolves and fingerprints the actual specification document.
insert into public.payroll_compliance_sources(country_code,source_name,source_type,source_url,source_identifier,purpose,active,check_frequency)
values ('NZ','Inland Revenue New Zealand','official_specification','https://www.ird.govt.nz/digital-service-providers/services-catalogue/returns-and-information/payday-filing/payroll-calculations-and-business-rules','ird-nz-payroll-calculations-business-rules','Payroll Calculations & Business Rules',true,'daily')
on conflict(country_code,source_identifier) do update set source_name=excluded.source_name,source_type=excluded.source_type,source_url=excluded.source_url,purpose=excluded.purpose,active=true,updated_at=now();

create or replace function public.v6168a_create_draft_ruleset(p_update_id uuid, p_name text, p_version text, p_effective_from date, p_effective_to date default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare u public.payroll_compliance_updates; r_id uuid;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into u from public.payroll_compliance_updates where id=p_update_id;
  if u.id is null then raise exception 'Compliance update not found'; end if;
  if u.status not in ('review_required','draft_prepared') then raise exception 'This update is not available for draft preparation'; end if;
  insert into public.payroll_rulesets(country_code,name,version,effective_from,effective_to,status,source_update_id,created_by)
  values(u.country_code,trim(p_name),trim(p_version),p_effective_from,p_effective_to,'draft',u.id,auth.uid()) returning id into r_id;
  insert into public.payroll_ruleset_rules(ruleset_id,rule_type,rule_key,numeric_value,text_value,json_value,source_note)
  select r_id,rule_type,rule_key,numeric_value,text_value,json_value,source_note
  from public.country_payroll_rules
  where country_code=u.country_code and active=true
    and effective_from <= p_effective_from and (effective_to is null or effective_to >= p_effective_from)
  on conflict do nothing;
  update public.payroll_compliance_updates set status='draft_prepared',proposed_ruleset_id=r_id,reviewed_at=coalesce(reviewed_at,now()),reviewed_by=coalesce(reviewed_by,auth.uid()),updated_at=now() where id=u.id;
  insert into public.payroll_compliance_audit(country_code,source_id,update_id,ruleset_id,action,actor_user_id) values(u.country_code,u.source_id,u.id,r_id,'draft_created',auth.uid());
  return r_id;
end $$;

create or replace function public.v6168a_mark_update_no_impact(p_update_id uuid,p_notes text default null)
returns void language plpgsql security definer set search_path=public as $$
declare u public.payroll_compliance_updates;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into u from public.payroll_compliance_updates where id=p_update_id;
  if u.id is null then raise exception 'Compliance update not found'; end if;
  update public.payroll_compliance_updates set status='dismissed_no_payroll_impact',reviewed_at=now(),reviewed_by=auth.uid(),review_notes=nullif(trim(coalesce(p_notes,'')),''),dismissed_at=now(),dismissed_by=auth.uid(),updated_at=now() where id=p_update_id;
  insert into public.payroll_compliance_audit(country_code,source_id,update_id,action,detail,actor_user_id) values(u.country_code,u.source_id,u.id,'update_dismissed',jsonb_build_object('notes',coalesce(p_notes,'')),auth.uid());
end $$;

create or replace function public.v6168a_set_ruleset_status(p_ruleset_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.payroll_rulesets; u public.payroll_compliance_updates;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  if p_status not in ('validated','approved') then raise exception 'Only validated or approved status may be set here'; end if;
  select * into r from public.payroll_rulesets where id=p_ruleset_id;
  if r.id is null then raise exception 'Ruleset not found'; end if;
  if p_status='validated' and r.status<>'draft' then raise exception 'Only Draft rulesets can be validated'; end if;
  if p_status='approved' and r.status<>'validated' then raise exception 'Ruleset must be validated before approval'; end if;
  update public.payroll_rulesets set status=p_status,approved_by=case when p_status='approved' then auth.uid() else approved_by end,approved_at=case when p_status='approved' then now() else approved_at end,updated_at=now() where id=r.id;
  if r.source_update_id is not null then update public.payroll_compliance_updates set status=p_status,updated_at=now() where id=r.source_update_id; end if;
  insert into public.payroll_compliance_audit(country_code,update_id,ruleset_id,action,actor_user_id) values(r.country_code,r.source_update_id,r.id,case when p_status='validated' then 'validation_run' else 'ruleset_approved' end,auth.uid());
end $$;

create or replace function public.v6168a_activate_ruleset(p_ruleset_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.payroll_rulesets; rr record;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into r from public.payroll_rulesets where id=p_ruleset_id for update;
  if r.id is null then raise exception 'Ruleset not found'; end if;
  if r.status<>'approved' then raise exception 'Ruleset must be explicitly approved before activation'; end if;
  if not exists(select 1 from public.payroll_ruleset_rules where ruleset_id=r.id) then raise exception 'Ruleset has no rules'; end if;
  -- This is the ONLY V61.68A path that writes production payroll rules, and it requires an approved ruleset + Super Admin.
  for rr in select * from public.payroll_ruleset_rules where ruleset_id=r.id loop
    insert into public.country_payroll_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,effective_to,active,source_note,created_at,updated_at)
    values(r.country_code,rr.rule_type,rr.rule_key,rr.numeric_value,rr.text_value,rr.json_value,r.effective_from,r.effective_to,true,coalesce(rr.source_note,'Approved Finlo payroll ruleset '||r.name||' '||r.version),now(),now())
    on conflict(country_code,rule_type,rule_key,effective_from) do update set numeric_value=excluded.numeric_value,text_value=excluded.text_value,json_value=excluded.json_value,effective_to=excluded.effective_to,active=true,source_note=excluded.source_note,updated_at=now();
  end loop;
  update public.payroll_rulesets set status='active',activated_by=auth.uid(),activated_at=now(),updated_at=now() where id=r.id;
  if r.source_update_id is not null then update public.payroll_compliance_updates set status='activated',updated_at=now() where id=r.source_update_id; end if;
  insert into public.payroll_compliance_audit(country_code,update_id,ruleset_id,action,actor_user_id) values(r.country_code,r.source_update_id,r.id,'ruleset_activated',auth.uid());
end $$;

revoke all on function public.v6168a_create_draft_ruleset(uuid,text,text,date,date) from public,anon;
revoke all on function public.v6168a_mark_update_no_impact(uuid,text) from public,anon;
revoke all on function public.v6168a_set_ruleset_status(uuid,text) from public,anon;
revoke all on function public.v6168a_activate_ruleset(uuid) from public,anon;
grant execute on function public.v6168a_create_draft_ruleset(uuid,text,text,date,date) to authenticated;
grant execute on function public.v6168a_mark_update_no_impact(uuid,text) to authenticated;
grant execute on function public.v6168a_set_ruleset_status(uuid,text) to authenticated;
grant execute on function public.v6168a_activate_ruleset(uuid) to authenticated;

-- Close the legacy direct-write path. Production rules are readable by tenants,
-- but V61.68A activation is the only supported write path and is SECURITY DEFINER.
drop policy if exists country_payroll_rules_admin_insert on public.country_payroll_rules;
drop policy if exists country_payroll_rules_admin_update on public.country_payroll_rules;
drop policy if exists country_payroll_rules_admin_delete on public.country_payroll_rules;


-- V61.68B final additive migration
-- V61.68B — NZ Business Tax/GST statutory rules and GST return period experience.
-- Additive only. Tenant circumstances remain in financial_settings. Finalised GST returns are never rewritten.

create table if not exists public.country_business_tax_rules (
  id uuid primary key default gen_random_uuid(), country_code char(2) not null check(country_code ~ '^[A-Z]{2}$'),
  rule_type text not null, rule_key text not null, numeric_value numeric, text_value text, json_value jsonb,
  effective_from date not null, effective_to date, active boolean not null default true, source_note text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check(num_nonnulls(numeric_value,text_value,json_value)=1), check(effective_to is null or effective_to>=effective_from),
  unique(country_code,rule_type,rule_key,effective_from)
);
alter table public.country_business_tax_rules enable row level security;
drop policy if exists country_business_tax_rules_read on public.country_business_tax_rules;
create policy country_business_tax_rules_read on public.country_business_tax_rules for select to authenticated using (true);

-- Production statutory values. These are centrally controlled and date-effective; tenants cannot edit them.
insert into public.country_business_tax_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,source_note) values
('NZ','gst','standard_rate_percent',15,null,null,'1989-07-01','IRD GST'),
('NZ','gst','registration_threshold_12m',60000,null,null,'2009-04-01','IRD GST registration'),
('NZ','gst','payments_basis_threshold_12m',2000000,null,null,'2000-10-10','IRD GST accounting basis'),
('NZ','gst','six_monthly_threshold_12m',500000,null,null,'2000-10-10','IRD GST filing frequency'),
('NZ','gst','monthly_mandatory_threshold_12m',24000000,null,null,'2000-10-10','IRD GST filing frequency'),
('NZ','gst','standard_due_day',28,null,null,'1986-10-01','IRD GST filing'),
('NZ','gst','march_period_due',null,'05-07',null,'1986-10-01','Period ending 31 March: 7 May'),
('NZ','gst','november_period_due',null,'01-15',null,'1986-10-01','Period ending 30 November: 15 January'),
('NZ','income_tax','company_rate_percent',28,null,null,'2011-04-01','IRD company tax rate'),
('NZ','income_tax','trust_rate_percent',39,null,null,'2024-04-01','NZ trustee income rate; tenant circumstances may vary'),
('NZ','income_tax','individual_brackets',null,null,'[{"up_to":15600,"rate":0.105},{"up_to":53500,"rate":0.175},{"up_to":78100,"rate":0.30},{"up_to":180000,"rate":0.33},{"up_to":null,"rate":0.39}]'::jsonb,'2024-07-31','IRD individual income tax rates')
on conflict(country_code,rule_type,rule_key,effective_from) do nothing;

-- Preserve historical GST return facts. New returns snapshot the statutory/tenant basis used.
alter table public.gst_returns add column if not exists statutory_due_date date;
alter table public.gst_returns add column if not exists accounting_basis text;
alter table public.gst_returns add column if not exists filing_frequency text;
alter table public.gst_returns add column if not exists statutory_rule_snapshot jsonb not null default '{}'::jsonb;

-- Official-source monitoring is additive and separate from Payroll monitoring.
create table if not exists public.business_tax_compliance_sources (
 id uuid primary key default gen_random_uuid(), country_code char(2) not null, source_name text not null, source_url text not null,
 source_identifier text not null, purpose text, active boolean not null default true, last_checked_at timestamptz,
 last_successful_check_at timestamptz,last_changed_at timestamptz,last_known_fingerprint text,last_check_status text not null default 'never_checked'
 check(last_check_status in('never_checked','no_change','change_detected','check_error')),last_error text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(country_code,source_identifier));
create table if not exists public.business_tax_compliance_updates (
 id uuid primary key default gen_random_uuid(),source_id uuid not null references public.business_tax_compliance_sources(id) on delete restrict,country_code char(2) not null,
 detected_at timestamptz not null default now(),source_fingerprint text not null,previous_fingerprint text,status text not null default 'review_required'
 check(status in('review_required','reviewed_no_impact')),summary text,source_reference text,reviewed_at timestamptz,reviewed_by uuid references auth.users(id) on delete set null,review_notes text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(source_id,source_fingerprint));
alter table public.business_tax_compliance_sources enable row level security;alter table public.business_tax_compliance_updates enable row level security;
drop policy if exists business_tax_compliance_sources_super_admin on public.business_tax_compliance_sources;
create policy business_tax_compliance_sources_super_admin on public.business_tax_compliance_sources for all to authenticated using(public.is_super_admin()) with check(public.is_super_admin());
drop policy if exists business_tax_compliance_updates_super_admin on public.business_tax_compliance_updates;
create policy business_tax_compliance_updates_super_admin on public.business_tax_compliance_updates for all to authenticated using(public.is_super_admin()) with check(public.is_super_admin());
insert into public.business_tax_compliance_sources(country_code,source_name,source_url,source_identifier,purpose) values
('NZ','Inland Revenue New Zealand','https://www.ird.govt.nz/gst/filing-and-paying-gst-and-refunds/filing-gst','ird-nz-gst-filing','GST filing and statutory due dates'),
('NZ','Inland Revenue New Zealand','https://www.ird.govt.nz/gst/registering-for-gst/which-gst-accounting-basis-and-filing-frequency-should-i-use','ird-nz-gst-basis-frequency','GST accounting basis and filing-frequency eligibility')
on conflict(country_code,source_identifier) do update set source_url=excluded.source_url,purpose=excluded.purpose,active=true,updated_at=now();

-- V61.68B Business Tax/GST human approval workflow (see V61.68B-BUSINESS-TAX-GST-RULES.sql)
-- Human-controlled Business Tax/GST ruleset workflow. Detection cannot write production rules.
create table if not exists public.business_tax_rulesets (
 id uuid primary key default gen_random_uuid(),country_code char(2) not null,name text not null,version text not null,effective_from date not null,effective_to date,
 status text not null default 'draft' check(status in('draft','validated','approved','active','retired')),source_update_id uuid references public.business_tax_compliance_updates(id) on delete set null,
 created_by uuid references auth.users(id) on delete set null,approved_by uuid references auth.users(id) on delete set null,approved_at timestamptz,activated_by uuid references auth.users(id) on delete set null,activated_at timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),check(effective_to is null or effective_to>=effective_from),unique(country_code,name,version));
create table if not exists public.business_tax_ruleset_rules (
 id uuid primary key default gen_random_uuid(),ruleset_id uuid not null references public.business_tax_rulesets(id) on delete cascade,rule_type text not null,rule_key text not null,numeric_value numeric,text_value text,json_value jsonb,source_note text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),check(num_nonnulls(numeric_value,text_value,json_value)=1),unique(ruleset_id,rule_type,rule_key));
alter table public.business_tax_rulesets enable row level security;alter table public.business_tax_ruleset_rules enable row level security;
drop policy if exists business_tax_rulesets_super_admin on public.business_tax_rulesets;create policy business_tax_rulesets_super_admin on public.business_tax_rulesets for all to authenticated using(public.is_super_admin()) with check(public.is_super_admin());
drop policy if exists business_tax_ruleset_rules_super_admin on public.business_tax_ruleset_rules;create policy business_tax_ruleset_rules_super_admin on public.business_tax_ruleset_rules for all to authenticated using(public.is_super_admin()) with check(public.is_super_admin());

create or replace function public.v6168b_create_draft_ruleset(p_update_id uuid,p_name text,p_version text,p_effective_from date,p_effective_to date default null) returns uuid language plpgsql security definer set search_path=public as $$
declare u public.business_tax_compliance_updates;r_id uuid;begin if not public.is_super_admin() then raise exception 'Super Admin access required';end if;select * into u from public.business_tax_compliance_updates where id=p_update_id;if u.id is null then raise exception 'Compliance update not found';end if;insert into public.business_tax_rulesets(country_code,name,version,effective_from,effective_to,status,source_update_id,created_by) values(u.country_code,trim(p_name),trim(p_version),p_effective_from,p_effective_to,'draft',u.id,auth.uid()) returning id into r_id;insert into public.business_tax_ruleset_rules(ruleset_id,rule_type,rule_key,numeric_value,text_value,json_value,source_note) select r_id,rule_type,rule_key,numeric_value,text_value,json_value,source_note from public.country_business_tax_rules where country_code=u.country_code and active=true and effective_from<=p_effective_from and(effective_to is null or effective_to>=p_effective_from) on conflict do nothing;return r_id;end$$;
create or replace function public.v6168b_set_ruleset_status(p_ruleset_id uuid,p_status text) returns void language plpgsql security definer set search_path=public as $$
declare r public.business_tax_rulesets;begin if not public.is_super_admin() then raise exception 'Super Admin access required';end if;if p_status not in('validated','approved') then raise exception 'Only validated or approved status may be set here';end if;select * into r from public.business_tax_rulesets where id=p_ruleset_id;if r.id is null then raise exception 'Ruleset not found';end if;if p_status='validated' and r.status<>'draft' then raise exception 'Only Draft rulesets can be validated';end if;if p_status='approved' and r.status<>'validated' then raise exception 'Ruleset must be validated before approval';end if;update public.business_tax_rulesets set status=p_status,approved_by=case when p_status='approved' then auth.uid() else approved_by end,approved_at=case when p_status='approved' then now() else approved_at end,updated_at=now() where id=r.id;end$$;
create or replace function public.v6168b_activate_ruleset(p_ruleset_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare r public.business_tax_rulesets;rr record;begin if not public.is_super_admin() then raise exception 'Super Admin access required';end if;select * into r from public.business_tax_rulesets where id=p_ruleset_id for update;if r.id is null then raise exception 'Ruleset not found';end if;if r.status<>'approved' then raise exception 'Ruleset must be explicitly approved before activation';end if;if not exists(select 1 from public.business_tax_ruleset_rules where ruleset_id=r.id) then raise exception 'Ruleset has no rules';end if;for rr in select * from public.business_tax_ruleset_rules where ruleset_id=r.id loop update public.country_business_tax_rules set active=false,effective_to=case when effective_from<r.effective_from then r.effective_from-1 else effective_to end,updated_at=now() where country_code=r.country_code and rule_type=rr.rule_type and rule_key=rr.rule_key and active=true and effective_from<r.effective_from;insert into public.country_business_tax_rules(country_code,rule_type,rule_key,numeric_value,text_value,json_value,effective_from,effective_to,active,source_note) values(r.country_code,rr.rule_type,rr.rule_key,rr.numeric_value,rr.text_value,rr.json_value,r.effective_from,r.effective_to,true,rr.source_note) on conflict(country_code,rule_type,rule_key,effective_from) do update set numeric_value=excluded.numeric_value,text_value=excluded.text_value,json_value=excluded.json_value,effective_to=excluded.effective_to,active=true,source_note=excluded.source_note,updated_at=now();end loop;update public.business_tax_rulesets set status='active',activated_by=auth.uid(),activated_at=now(),updated_at=now() where id=r.id;end$$;
revoke all on function public.v6168b_create_draft_ruleset(uuid,text,text,date,date) from public;grant execute on function public.v6168b_create_draft_ruleset(uuid,text,text,date,date) to authenticated;
revoke all on function public.v6168b_set_ruleset_status(uuid,text) from public;grant execute on function public.v6168b_set_ruleset_status(uuid,text) to authenticated;
revoke all on function public.v6168b_activate_ruleset(uuid) from public;grant execute on function public.v6168b_activate_ruleset(uuid) to authenticated;


-- V61.68B expense business/private allocation (additive compatibility block)
alter table public.expenses add column if not exists business_use_percent numeric(5,2) not null default 100;
alter table public.expenses add column if not exists business_use_amount numeric(14,2);
alter table public.expenses add column if not exists private_use_amount numeric(14,2);
alter table public.expenses add column if not exists business_ex_gst numeric(14,2);
alter table public.expenses add column if not exists business_gst_amount numeric(14,2);
alter table public.expenses add column if not exists allocation_method text not null default 'percentage';
alter table public.expenses add column if not exists allocation_basis text;
alter table public.expenses add column if not exists allocation_notes text;

alter table public.expenses drop constraint if exists expenses_business_use_percent_check;
alter table public.expenses add constraint expenses_business_use_percent_check check (business_use_percent >= 0 and business_use_percent <= 100);
alter table public.expenses drop constraint if exists expenses_allocation_method_check;
alter table public.expenses add constraint expenses_allocation_method_check check (allocation_method in ('percentage','business_amount'));
