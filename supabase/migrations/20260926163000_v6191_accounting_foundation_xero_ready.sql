-- v61.91 accounting foundation for Xero-ready exports.
-- This migration is intentionally non-posting: it creates/extends chart and
-- mapping structures, but does not rewrite invoices, expenses, GST, stock,
-- payroll, existing journals, or historical reports.

begin;

create table if not exists public.accounting_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  account_code text not null,
  account_name text not null,
  account_type text not null default 'expense',
  normal_balance text not null default 'debit',
  report_section text not null default 'other',
  system_key text,
  is_system boolean not null default false,
  is_control boolean not null default false,
  xero_account_code text,
  xero_account_type text,
  xero_tax_type text,
  description text,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid,
  updated_by uuid
);

alter table public.accounting_accounts add column if not exists account_code text;
alter table public.accounting_accounts add column if not exists account_name text;
alter table public.accounting_accounts add column if not exists account_type text not null default 'expense';
alter table public.accounting_accounts add column if not exists normal_balance text not null default 'debit';
alter table public.accounting_accounts add column if not exists report_section text not null default 'other';
alter table public.accounting_accounts add column if not exists system_key text;
alter table public.accounting_accounts add column if not exists is_system boolean not null default false;
alter table public.accounting_accounts add column if not exists is_control boolean not null default false;
alter table public.accounting_accounts add column if not exists xero_account_code text;
alter table public.accounting_accounts add column if not exists xero_account_type text;
alter table public.accounting_accounts add column if not exists xero_tax_type text;
alter table public.accounting_accounts add column if not exists description text;
alter table public.accounting_accounts add column if not exists archived boolean not null default false;
alter table public.accounting_accounts add column if not exists created_at timestamptz not null default now();
alter table public.accounting_accounts add column if not exists updated_at timestamptz not null default now();
alter table public.accounting_accounts add column if not exists created_by uuid;
alter table public.accounting_accounts add column if not exists updated_by uuid;

do $$ begin
  alter table public.accounting_accounts
    add constraint accounting_accounts_type_check
    check (account_type in ('bank','current_asset','fixed_asset','inventory','non_current_asset','current_liability','non_current_liability','equity','income','cost_of_sales','expense','tax','other'));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.accounting_accounts
    add constraint accounting_accounts_normal_balance_check
    check (normal_balance in ('debit','credit'));
exception when duplicate_object then null;
end $$;

create unique index if not exists accounting_accounts_business_code_unique
  on public.accounting_accounts(business_id, account_code) where archived = false;
create unique index if not exists accounting_accounts_business_system_key_unique
  on public.accounting_accounts(business_id, system_key) where system_key is not null and archived = false;
create index if not exists accounting_accounts_business_type_idx
  on public.accounting_accounts(business_id, account_type) where archived = false;

create table if not exists public.accounting_source_mappings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  source_type text not null,
  source_id uuid,
  source_key text,
  source_name text not null default '',
  purpose text not null default 'expense',
  account_id uuid references public.accounting_accounts(id) on delete set null,
  xero_account_code text,
  xero_tax_type text,
  requires_review boolean not null default false,
  notes text,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  check (source_id is not null or source_key is not null)
);

create unique index if not exists accounting_source_mappings_source_id_unique
  on public.accounting_source_mappings(business_id, source_type, source_id, purpose)
  where source_id is not null and archived = false;
create unique index if not exists accounting_source_mappings_source_key_unique
  on public.accounting_source_mappings(business_id, source_type, source_key, purpose)
  where source_key is not null and archived = false;

alter table public.accounting_accounts enable row level security;
alter table public.accounting_source_mappings enable row level security;

do $$ begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='accounting_accounts' and policyname='accounting_accounts_read') then
    create policy accounting_accounts_read on public.accounting_accounts for select to authenticated
      using (business_id = public.current_business_id());
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='accounting_accounts' and policyname='accounting_accounts_write') then
    create policy accounting_accounts_write on public.accounting_accounts for all to authenticated
      using (business_id = public.current_business_id() and public.v6147_can_write_area(business_id,'business_settings'))
      with check (business_id = public.current_business_id() and public.v6147_can_write_area(business_id,'business_settings'));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='accounting_source_mappings' and policyname='accounting_source_mappings_read') then
    create policy accounting_source_mappings_read on public.accounting_source_mappings for select to authenticated
      using (business_id = public.current_business_id());
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='accounting_source_mappings' and policyname='accounting_source_mappings_write') then
    create policy accounting_source_mappings_write on public.accounting_source_mappings for all to authenticated
      using (business_id = public.current_business_id() and public.v6147_can_write_area(business_id,'business_settings'))
      with check (business_id = public.current_business_id() and public.v6147_can_write_area(business_id,'business_settings'));
  end if;
end $$;

revoke all on public.accounting_accounts, public.accounting_source_mappings from anon;
grant select, insert, update on public.accounting_accounts, public.accounting_source_mappings to authenticated;

create or replace function public.v6191_seed_default_chart(p_business_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare inserted integer := 0;
begin
  if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
    raise exception 'Business access denied';
  end if;
  if not public.v6147_can_write_area(p_business_id,'business_settings') then
    raise exception 'Settings access is required';
  end if;

  with defaults(account_code, account_name, account_type, normal_balance, report_section, system_key, xero_account_type, description) as (
    values
      ('090','Business Bank','bank','debit','asset','bank_main','BANK','Primary bank or transaction account.'),
      ('120','Accounts Receivable','current_asset','debit','asset','accounts_receivable','CURRENT','Customer balances owing.'),
      ('140','Inventory - Stock for Sale','inventory','debit','asset','inventory_stock','INVENTORY','Goods bought for resale; accountant-reviewed postings only.'),
      ('145','Materials and Consumables on Hand','inventory','debit','asset','materials_on_hand','INVENTORY','Work materials or consumables not yet expensed.'),
      ('150','Fixed Assets - Equipment','fixed_asset','debit','asset','fixed_assets_equipment','FIXED','Equipment kept by the business.'),
      ('155','Accumulated Depreciation - Equipment','fixed_asset','credit','asset','accum_depn_equipment','FIXED','Contra-asset for posted depreciation.'),
      ('200','Sales','income','credit','revenue','sales','REVENUE','Default sales income.'),
      ('205','Other Income','income','credit','revenue','other_income','REVENUE','Other operating income.'),
      ('260','GST Collected','tax','credit','liability','gst_collected','CURRLIAB','GST on sales.'),
      ('261','GST Paid','tax','debit','asset','gst_paid','CURRLIAB','GST on purchases.'),
      ('265','PAYE / Payroll Liabilities','current_liability','credit','liability','payroll_liability','CURRLIAB','Payroll deductions and employer obligations.'),
      ('300','Purchases / Cost of Sales','cost_of_sales','debit','cost_of_sales','cost_of_sales','DIRECTCOSTS','Posted cost of goods sold or direct purchases.'),
      ('310','Materials and Consumables Used','cost_of_sales','debit','cost_of_sales','materials_used','DIRECTCOSTS','Work supplies consumed on jobs.'),
      ('315','Depreciation Expense','expense','debit','expense','depreciation_expense','EXPENSE','Posted book depreciation.'),
      ('400','Advertising and Marketing','expense','debit','expense','advertising','EXPENSE','Advertising, marketing and promotion.'),
      ('404','Bank Fees','expense','debit','expense','bank_fees','EXPENSE','Bank and merchant fees.'),
      ('420','Motor Vehicle Expenses','expense','debit','expense','motor_vehicle','EXPENSE','Vehicle running costs.'),
      ('429','General Expenses','expense','debit','expense','general_expenses','EXPENSE','Fallback expense account.'),
      ('477','Telephone and Internet','expense','debit','expense','telephone_internet','EXPENSE','Phone and internet costs.'),
      ('800','Owner Drawings / Private Use','equity','debit','equity','owner_drawings','EQUITY','Private-use or owner drawings allocation.'),
      ('860','Retained Earnings','equity','credit','equity','retained_earnings','EQUITY','Prior year retained profit.')
  ), upserted as (
    insert into public.accounting_accounts(
      business_id, account_code, account_name, account_type, normal_balance,
      report_section, system_key, xero_account_code, xero_account_type,
      description, is_system, is_control, created_by, updated_by
    )
    select p_business_id, d.account_code, d.account_name, d.account_type, d.normal_balance,
      d.report_section, d.system_key, d.account_code, d.xero_account_type,
      d.description, true, d.system_key in ('accounts_receivable','gst_collected','gst_paid','payroll_liability','retained_earnings'), auth.uid(), auth.uid()
    from defaults d
    on conflict (business_id, account_code) where archived = false do update
      set account_name = excluded.account_name,
          account_type = excluded.account_type,
          normal_balance = excluded.normal_balance,
          report_section = excluded.report_section,
          system_key = coalesce(public.accounting_accounts.system_key, excluded.system_key),
          xero_account_code = coalesce(public.accounting_accounts.xero_account_code, excluded.xero_account_code),
          xero_account_type = coalesce(public.accounting_accounts.xero_account_type, excluded.xero_account_type),
          description = coalesce(public.accounting_accounts.description, excluded.description),
          is_system = true,
          updated_at = now(),
          updated_by = auth.uid()
    returning 1
  )
  select count(*) into inserted from upserted;

  return inserted;
end $$;

revoke all on function public.v6191_seed_default_chart(uuid) from public, anon;
grant execute on function public.v6191_seed_default_chart(uuid) to authenticated;

create or replace view public.v6191_xero_chart_export
with (security_invoker = true) as
select
  a.business_id,
  a.account_code as finlo_account_code,
  a.account_name as finlo_account_name,
  a.account_type as finlo_account_type,
  a.report_section,
  a.xero_account_code,
  a.xero_account_type,
  a.xero_tax_type,
  a.system_key,
  a.is_control,
  a.archived
from public.accounting_accounts a
where coalesce(a.archived,false) = false
  and a.business_id = public.current_business_id();

grant select on public.v6191_xero_chart_export to authenticated;

commit;
