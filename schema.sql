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
