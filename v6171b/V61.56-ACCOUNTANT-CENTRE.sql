-- Finlo V61.56 — Accountant Centre (Phase 1)
-- Additive only: business-specific export mappings and export history.
begin;

create table if not exists public.accounting_export_mappings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  destination text not null default 'xero',
  source_type text not null check (source_type in ('sales_default','expense_category')),
  source_id uuid,
  source_key text,
  source_name text not null,
  account_code text not null default '',
  account_name text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  constraint accounting_export_mapping_source_ck check (
    (source_type='expense_category' and source_id is not null) or
    (source_type='sales_default' and source_id is null and source_key is not null)
  )
);
create unique index if not exists accounting_export_mapping_unique_expense
  on public.accounting_export_mappings(business_id,destination,source_type,source_id)
  where source_id is not null;
create unique index if not exists accounting_export_mapping_unique_key
  on public.accounting_export_mappings(business_id,destination,source_type,source_key)
  where source_key is not null;
create index if not exists accounting_export_mappings_business_idx
  on public.accounting_export_mappings(business_id,destination);

create table if not exists public.tax_export_mappings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  destination text not null default 'xero',
  direction text not null check(direction in ('income','expense')),
  finlo_tax_treatment text not null,
  destination_tax_type text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  unique(business_id,destination,direction,finlo_tax_treatment)
);
create index if not exists tax_export_mappings_business_idx
  on public.tax_export_mappings(business_id,destination);

create table if not exists public.accounting_exports (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  destination text not null,
  export_type text not null,
  period_start date not null,
  period_end date not null,
  record_count integer not null default 0,
  file_manifest jsonb not null default '[]'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  status text not null default 'generated' check(status in ('generated','downloaded','failed')),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create index if not exists accounting_exports_business_period_idx
  on public.accounting_exports(business_id,period_start desc,period_end desc);

alter table public.accounting_export_mappings enable row level security;
alter table public.tax_export_mappings enable row level security;
alter table public.accounting_exports enable row level security;

drop policy if exists v6156_accounting_export_mappings_tenant on public.accounting_export_mappings;
create policy v6156_accounting_export_mappings_tenant on public.accounting_export_mappings
for all to authenticated
using (public.has_active_business_membership(business_id) or public.is_super_admin())
with check (public.has_active_business_membership(business_id) or public.is_super_admin());

drop policy if exists v6156_tax_export_mappings_tenant on public.tax_export_mappings;
create policy v6156_tax_export_mappings_tenant on public.tax_export_mappings
for all to authenticated
using (public.has_active_business_membership(business_id) or public.is_super_admin())
with check (public.has_active_business_membership(business_id) or public.is_super_admin());

drop policy if exists v6156_accounting_exports_tenant on public.accounting_exports;
create policy v6156_accounting_exports_tenant on public.accounting_exports
for select to authenticated
using (public.has_active_business_membership(business_id) or public.is_super_admin());

drop policy if exists v6156_accounting_exports_insert on public.accounting_exports;
create policy v6156_accounting_exports_insert on public.accounting_exports
for insert to authenticated
with check ((public.has_active_business_membership(business_id) or public.is_super_admin()) and (created_by=auth.uid() or public.is_super_admin()));

commit;
