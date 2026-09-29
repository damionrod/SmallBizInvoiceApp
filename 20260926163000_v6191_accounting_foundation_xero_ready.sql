-- v61.91 accounting foundation for Xero-ready exports.
-- Production-safe and non-posting: creates/extends chart and mapping structures
-- without rewriting invoices, expenses, GST, stock, payroll, existing journals,
-- or historical reports.

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

alter table public.accounting_accounts drop constraint if exists accounting_accounts_type_check;
alter table public.accounting_accounts drop constraint if exists accounting_accounts_account_type_check;
alter table public.accounting_accounts
  add constraint accounting_accounts_account_type_check
  check (account_type in (
    'asset','liability','revenue','other_income','other_expense',
    'bank','current_asset','fixed_asset','inventory','non_current_asset',
    'current_liability','non_current_liability','equity','income',
    'cost_of_sales','expense','tax','other'
  ));

alter table public.accounting_accounts drop constraint if exists accounting_accounts_normal_balance_check;
alter table public.accounting_accounts
  add constraint accounting_accounts_normal_balance_check
  check (normal_balance in ('debit','credit'));

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
create index if not exists accounting_source_mappings_account_id_idx
  on public.accounting_source_mappings(account_id) where account_id is not null;

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
declare affected integer := 0;
begin
  if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
    raise exception 'Business access denied';
  end if;
  if not public.v6147_can_write_area(p_business_id,'business_settings') then
    raise exception 'Settings access is required';
  end if;

  with defaults(account_code, account_name, account_type, normal_balance, report_section, system_key, xero_account_type, description) as (
    values
      ('1000','Bank','asset','debit','current_assets','bank','BANK','Main business bank account.'),
      ('1100','Money customers owe you','asset','debit','current_assets','accounts_receivable','CURRENT','Money owed by customers.'),
      ('1200','GST you can claim','asset','debit','current_assets','gst_receivable','CURRENT','GST claimable on purchases.'),
      ('1500','Business equipment & assets','asset','debit','fixed_assets','fixed_assets','FIXED','Business equipment and assets.'),
      ('1550','Accumulated depreciation','asset','credit','fixed_assets','accumulated_depreciation','FIXED','Accumulated depreciation contra asset.'),
      ('2000','Bills you need to pay','liability','credit','current_liabilities','accounts_payable','CURRLIAB','Supplier bills payable.'),
      ('2100','GST you collected','liability','credit','current_liabilities','gst_payable','CURRLIAB','GST collected on sales.'),
      ('2200','PAYE payable','liability','credit','current_liabilities','paye_payable','CURRLIAB','PAYE payable.'),
      ('2210','KiwiSaver payable','liability','credit','current_liabilities','kiwisaver_payable','CURRLIAB','KiwiSaver payable.'),
      ('2220','Wages payable','liability','credit','current_liabilities','wages_payable','CURRLIAB','Wages payable.'),
      ('3000','Owner funds / share capital','equity','credit','equity','owner_funds','EQUITY','Owner funds or share capital.'),
      ('3100','Owner drawings','equity','debit','equity','owner_drawings','EQUITY','Owner drawings.'),
      ('3200','Retained earnings','equity','credit','equity','retained_earnings','EQUITY','Prior year retained earnings.'),
      ('3300','Current year earnings','equity','credit','equity','current_year_earnings','EQUITY','Current year earnings.'),
      ('4000','Sales','revenue','credit','income','sales','REVENUE','Sales and invoice revenue.'),
      ('5000','Cost of sales','cost_of_sales','debit','cost_of_sales','cost_of_sales','DIRECTCOSTS','Direct cost of sales.'),
      ('6000','Business expenses','expense','debit','operating_expenses','business_expenses','EXPENSE','General business expenses.'),
      ('6100','Wages','expense','debit','operating_expenses','wages','EXPENSE','Wages expense.'),
      ('6110','Employer contributions','expense','debit','operating_expenses','employer_contributions','EXPENSE','Employer payroll contributions.'),
      ('6200','Depreciation','expense','debit','operating_expenses','depreciation','DEPRECIATN','Depreciation expense.'),
      ('9999','Needs review','asset','debit','review','needs_review','EXPENSE','Temporary account for items needing accountant review.')
  ), updated as (
    update public.accounting_accounts a
    set account_name = d.account_name,
        normal_balance = d.normal_balance,
        report_section = d.report_section,
        system_key = coalesce(a.system_key, d.system_key),
        xero_account_code = coalesce(a.xero_account_code, a.account_code),
        xero_account_type = coalesce(a.xero_account_type, d.xero_account_type),
        description = coalesce(nullif(a.description,''), d.description),
        is_system = true,
        is_control = d.system_key in ('accounts_receivable','accounts_payable','gst_receivable','gst_payable','paye_payable','kiwisaver_payable','wages_payable','retained_earnings'),
        updated_at = now(),
        updated_by = auth.uid()
    from defaults d
    where a.business_id = p_business_id
      and a.account_code = d.account_code
      and coalesce(a.archived,false) = false
    returning 1
  ), inserted as (
    insert into public.accounting_accounts(
      business_id, account_code, account_name, account_type, normal_balance,
      report_section, system_key, xero_account_code, xero_account_type,
      description, is_system, is_control, created_by, updated_by
    )
    select p_business_id, d.account_code, d.account_name, d.account_type, d.normal_balance,
      d.report_section, d.system_key, d.account_code, d.xero_account_type,
      d.description, true,
      d.system_key in ('accounts_receivable','accounts_payable','gst_receivable','gst_payable','paye_payable','kiwisaver_payable','wages_payable','retained_earnings'),
      auth.uid(), auth.uid()
    from defaults d
    where not exists (
      select 1 from public.accounting_accounts a
      where a.business_id = p_business_id
        and a.account_code = d.account_code
        and coalesce(a.archived,false) = false
    )
    returning 1
  )
  select count(*) into affected from (
    select 1 from updated
    union all
    select 1 from inserted
  ) x;

  return affected;
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

notify pgrst, 'reload schema';

commit;
