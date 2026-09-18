-- Finlo V61.57 — Xero Account Codes
-- Additive only: tenant-specific destination account list used by Accountant Centre mappings.
begin;

create table if not exists public.accounting_destination_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  destination text not null default 'xero',
  account_code text not null,
  account_name text not null,
  account_type text not null default 'other' check(account_type in ('income','expense','asset','liability','equity','bank','other')),
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  unique(business_id,destination,account_code)
);
create index if not exists accounting_destination_accounts_business_idx
  on public.accounting_destination_accounts(business_id,destination,archived,account_code);

alter table public.accounting_destination_accounts enable row level security;
drop policy if exists v6157_accounting_destination_accounts_tenant on public.accounting_destination_accounts;
create policy v6157_accounting_destination_accounts_tenant on public.accounting_destination_accounts
for all to authenticated
using (public.has_active_business_membership(business_id) or public.is_super_admin())
with check (public.has_active_business_membership(business_id) or public.is_super_admin());

commit;
