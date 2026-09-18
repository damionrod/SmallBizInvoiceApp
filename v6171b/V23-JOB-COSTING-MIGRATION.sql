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
