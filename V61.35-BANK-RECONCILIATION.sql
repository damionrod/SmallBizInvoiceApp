-- V61.35 Bank Reconciliation module
-- Additive migration only. Run after existing V60/V61 migrations.
-- No existing tables/columns are dropped or renamed.
create extension if not exists pgcrypto;

insert into public.modules(slug,name,description,monthly_price,is_active)
values ('bank_reconciliation','Bank Reconciliation','Import bank transactions and reconcile them to invoices and expenses',0,true)
on conflict (slug) do update set name=excluded.name,description=excluded.description,is_active=true;

create table if not exists public.bank_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  name text not null,
  account_number text,
  bank_name text,
  currency char(3) not null default 'NZD',
  is_default boolean not null default false,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid()
);

create table if not exists public.bank_import_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  bank_account_id uuid not null references public.bank_accounts(id) on delete restrict,
  filename text,
  imported_count integer not null default 0,
  duplicate_count integer not null default 0,
  possible_duplicate_count integer not null default 0,
  mapping jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now(),
  imported_by uuid default auth.uid()
);

create table if not exists public.bank_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  bank_account_id uuid not null references public.bank_accounts(id) on delete restrict,
  import_batch_id uuid references public.bank_import_batches(id) on delete set null,
  transaction_date date not null,
  amount numeric(14,2) not null check (amount <> 0),
  description text,
  reference text,
  payee text,
  bank_transaction_id text,
  import_fingerprint text not null,
  duplicate_status text not null default 'new' check (duplicate_status in ('new','possible_duplicate','already_imported')),
  status text not null default 'unreconciled' check (status in ('unreconciled','reconciled','excluded')),
  reconciliation_type text check (reconciliation_type in ('invoice','expense','created_expense','split','transfer','excluded')),
  reconciled_at timestamptz,
  reconciled_by uuid,
  excluded_reason text,
  transfer_bank_account_id uuid references public.bank_accounts(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,bank_account_id,import_fingerprint)
);

create table if not exists public.bank_reconciliation_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  bank_transaction_id uuid not null references public.bank_transactions(id) on delete cascade,
  allocation_type text not null check (allocation_type in ('invoice','expense','transfer','exclude')),
  amount numeric(14,2) not null check (amount > 0),
  invoice_id uuid references public.invoices(id) on delete restrict,
  expense_id uuid references public.expenses(id) on delete restrict,
  customer_payment_id uuid references public.customer_payments(id) on delete set null,
  expense_payment_id uuid references public.expense_payments(id) on delete set null,
  transfer_bank_account_id uuid references public.bank_accounts(id) on delete set null,
  created_expense boolean not null default false,
  note text,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists public.bank_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  name text not null,
  match_field text not null default 'description' check (match_field in ('description','reference','payee')),
  match_type text not null default 'contains' check (match_type in ('contains','equals','starts_with')),
  match_value text not null,
  direction text not null default 'any' check (direction in ('any','in','out')),
  action text not null default 'suggest_expense' check (action in ('suggest_expense','suggest_transfer','suggest_exclude')),
  expense_category_id uuid references public.expense_categories(id) on delete set null,
  gst_treatment text check (gst_treatment in ('gst','no_gst','zero_rated')),
  transfer_bank_account_id uuid references public.bank_accounts(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid()
);

create table if not exists public.bank_reconciliation_settings (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  date_tolerance_days integer not null default 5 check (date_tolerance_days between 0 and 30),
  high_confidence_threshold integer not null default 85 check (high_confidence_threshold between 50 and 100),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create table if not exists public.bank_reconciliation_audit (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  bank_transaction_id uuid references public.bank_transactions(id) on delete set null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create index if not exists bank_transactions_queue_idx on public.bank_transactions(business_id,status,transaction_date desc);
create index if not exists bank_transactions_account_idx on public.bank_transactions(business_id,bank_account_id,transaction_date desc);
create index if not exists bank_allocations_tx_idx on public.bank_reconciliation_allocations(bank_transaction_id);
create index if not exists bank_audit_tx_idx on public.bank_reconciliation_audit(bank_transaction_id,created_at desc);

create or replace function public.v6135_bank_module_enabled(p_business_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare bm_status text; bm_end timestamptz; plan_has boolean:=false;
begin
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id<>public.current_business_id() then return false; end if;
  select bm.status,bm.trial_ends_at into bm_status,bm_end
  from public.business_modules bm join public.modules m on m.id=bm.module_id
  where bm.business_id=p_business_id and m.slug='bank_reconciliation' limit 1;
  if bm_status='active' then return true; end if;
  if bm_status='trialing' then return bm_end is null or bm_end>=now(); end if;
  if bm_status in ('suspended','canceled') then return false; end if;
  select coalesce('bank_reconciliation'=any(coalesce(pl.included_modules,'{}'::text[])),false) into plan_has
  from public.subscriptions s left join public.plans pl on pl.id=s.plan_id
  where s.business_id=p_business_id and s.status in ('active','trialing') limit 1;
  return coalesce(plan_has,false);
end $$;

alter table public.bank_accounts enable row level security;
alter table public.bank_import_batches enable row level security;
alter table public.bank_transactions enable row level security;
alter table public.bank_reconciliation_allocations enable row level security;
alter table public.bank_rules enable row level security;
alter table public.bank_reconciliation_settings enable row level security;
alter table public.bank_reconciliation_audit enable row level security;

do $$ declare t text; p text; begin
  foreach t in array array['bank_accounts','bank_import_batches','bank_transactions','bank_reconciliation_allocations','bank_rules','bank_reconciliation_settings','bank_reconciliation_audit'] loop
    p:='v6135_'||t||'_select'; execute format('drop policy if exists %I on public.%I',p,t); execute format('create policy %I on public.%I for select to authenticated using (public.is_super_admin() or (business_id=public.current_business_id() and public.v6135_bank_module_enabled(business_id)))',p,t);
    p:='v6135_'||t||'_insert'; execute format('drop policy if exists %I on public.%I',p,t); execute format('create policy %I on public.%I for insert to authenticated with check (public.is_super_admin() or (business_id=public.current_business_id() and public.v6135_bank_module_enabled(business_id)))',p,t);
    p:='v6135_'||t||'_update'; execute format('drop policy if exists %I on public.%I',p,t); execute format('create policy %I on public.%I for update to authenticated using (public.is_super_admin() or (business_id=public.current_business_id() and public.v6135_bank_module_enabled(business_id))) with check (public.is_super_admin() or (business_id=public.current_business_id() and public.v6135_bank_module_enabled(business_id)))',p,t);
    p:='v6135_'||t||'_delete'; execute format('drop policy if exists %I on public.%I',p,t); execute format('create policy %I on public.%I for delete to authenticated using (public.is_super_admin() or (business_id=public.current_business_id() and public.v6135_bank_module_enabled(business_id)))',p,t);
  end loop;
end $$;

-- Validate that allocations cannot cross tenants or reference records from another business.
create or replace function public.v6135_validate_bank_allocation()
returns trigger language plpgsql security definer set search_path=public as $$
declare tx_business uuid;
begin
  select business_id into tx_business from public.bank_transactions where id=new.bank_transaction_id;
  if tx_business is null or tx_business<>new.business_id then raise exception 'Bank allocation must belong to the same business as the bank transaction'; end if;
  if new.invoice_id is not null and not exists(select 1 from public.invoices where id=new.invoice_id and business_id=new.business_id) then raise exception 'Invoice does not belong to this business'; end if;
  if new.expense_id is not null and not exists(select 1 from public.expenses where id=new.expense_id and business_id=new.business_id) then raise exception 'Expense does not belong to this business'; end if;
  if new.customer_payment_id is not null and not exists(select 1 from public.customer_payments where id=new.customer_payment_id and business_id=new.business_id) then raise exception 'Customer payment does not belong to this business'; end if;
  if new.expense_payment_id is not null and not exists(select 1 from public.expense_payments where id=new.expense_payment_id and business_id=new.business_id) then raise exception 'Expense payment does not belong to this business'; end if;
  return new;
end $$;
drop trigger if exists v6135_validate_bank_allocation_trg on public.bank_reconciliation_allocations;
create trigger v6135_validate_bank_allocation_trg before insert or update on public.bank_reconciliation_allocations for each row execute function public.v6135_validate_bank_allocation();

-- Keep one default bank account at most per tenant.
create unique index if not exists bank_accounts_one_default_per_business on public.bank_accounts(business_id) where is_default=true and archived=false;
