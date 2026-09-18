-- Invoice Manager v58 — Financials module
-- Run this entire file in Supabase SQL Editor BEFORE deploying v58.
-- Adds a business-scoped Financials reporting/budget/GST layer without duplicating invoice,
-- expense, payroll, customer or job source data.

create extension if not exists pgcrypto;

insert into public.modules(slug,name,description,monthly_price,is_active)
values ('financials','Financials','Simple financial overview, P&L, cash flow, GST returns and budgets',0,true)
on conflict (slug) do update set name=excluded.name,description=excluded.description,is_active=true;

create or replace function public.v58_financials_access(p_business_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else exists(select 1 from public.profiles p where p.id=auth.uid() and p.business_id=p_business_id)
      and exists(select 1 from public.modules m where m.slug='financials' and m.is_active=true)
      and (
        exists(
          select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
          where bm.business_id=p_business_id and m.slug='financials' and bm.status in ('active','trialing')
        )
        or (
          not exists(
            select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
            where bm.business_id=p_business_id and m.slug='financials'
          )
          and exists(
            select 1 from public.subscriptions s join public.plans pl on pl.id=s.plan_id
            where s.business_id=p_business_id and coalesce(s.status,'') not in ('suspended','canceled')
              and 'financials'=any(coalesce(pl.included_modules,'{}'::text[]))
          )
        )
      )
  end;
$$;
revoke all on function public.v58_financials_access(uuid) from public;
grant execute on function public.v58_financials_access(uuid) to authenticated;

create table if not exists public.financial_settings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique default public.current_business_id() references public.businesses(id) on delete cascade,
  financial_year_start_month smallint not null default 4 check(financial_year_start_month between 1 and 12),
  financial_year_start_day smallint not null default 1 check(financial_year_start_day between 1 and 31),
  default_report_period text not null default 'fytd',
  business_entity_type text not null default 'company',
  estimated_tax_rate numeric(7,3) not null default 28 check(estimated_tax_rate between 0 and 100),
  provisional_tax_enabled boolean not null default false,
  tax_payment_frequency text,
  gst_registered boolean not null default true,
  gst_filing_frequency text not null default 'two_monthly',
  gst_accounting_basis text not null default 'invoice',
  gst_default_treatment text not null default 'standard',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create table if not exists public.financial_category_mappings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  source_type text not null check(source_type in ('expense_category','payroll_type','manual')),
  source_id uuid,
  source_key text,
  display_name text not null,
  classification text not null check(classification in ('revenue','direct_cost','indirect_cost','asset','liability','tax','equity','other')),
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
create unique index if not exists financial_mapping_source_id_uniq on public.financial_category_mappings(business_id,source_type,source_id) where source_id is not null;
create unique index if not exists financial_mapping_source_key_uniq on public.financial_category_mappings(business_id,source_type,source_key) where source_key is not null;

create table if not exists public.financial_budgets (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  name text not null,
  financial_year_start date not null,
  financial_year_end date not null,
  status text not null default 'draft' check(status in ('draft','active','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,name)
);
create unique index if not exists financial_one_active_budget_per_year on public.financial_budgets(business_id,financial_year_start) where status='active';

create table if not exists public.financial_budget_lines (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  budget_id uuid not null references public.financial_budgets(id) on delete cascade,
  classification text not null check(classification in ('revenue','direct_cost','indirect_cost','tax','cash_planning','other')),
  source_type text,
  source_id uuid,
  source_key text,
  label text not null,
  annual_amount numeric(16,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists financial_budget_lines_budget_idx on public.financial_budget_lines(budget_id);

create table if not exists public.financial_budget_month_values (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  budget_line_id uuid not null references public.financial_budget_lines(id) on delete cascade,
  month_start date not null,
  amount numeric(16,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(budget_line_id,month_start)
);
create index if not exists financial_budget_month_business_idx on public.financial_budget_month_values(business_id,month_start);

create table if not exists public.gst_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  status text not null default 'draft' check(status in ('draft','reviewed','finalised')),
  gst_rate numeric(7,3) not null default 15,
  taxable_sales_ex_gst numeric(16,2) not null default 0,
  gst_collected numeric(16,2) not null default 0,
  taxable_purchases_ex_gst numeric(16,2) not null default 0,
  gst_paid numeric(16,2) not null default 0,
  gst_net numeric(16,2) not null default 0,
  snapshot jsonb not null default '{}'::jsonb,
  finalised_at timestamptz,
  finalised_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,period_start,period_end)
);

create table if not exists public.financial_audit_log (
  id bigserial primary key,
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  entity_type text not null,
  entity_id uuid,
  action text not null,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create index if not exists financial_mappings_business_idx on public.financial_category_mappings(business_id,classification);
create index if not exists financial_budgets_business_year_idx on public.financial_budgets(business_id,financial_year_start);
create index if not exists gst_returns_business_period_idx on public.gst_returns(business_id,period_start,period_end);

-- Tenant guard prevents normal users from changing business ownership.
create or replace function public.v58_financials_tenant_guard()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  -- Supabase SQL Editor / trusted service migrations do not carry an end-user JWT.
  -- Permit those trusted database contexts so installation/seeding can run, while
  -- keeping the tenant guard strict for normal application requests.
  if auth.uid() is null then
    if session_user in ('postgres','supabase_admin') or coalesce(auth.role(),'') = 'service_role' then
      return new;
    end if;
    raise exception 'Authentication required';
  end if;
  if public.is_super_admin() then return new; end if;
  if tg_op='INSERT' then new.business_id:=public.current_business_id();
  elsif new.business_id is distinct from old.business_id then raise exception 'Business ownership cannot be changed'; end if;
  return new;
end;$$;

-- Cross-business references for budget lines/months.
create or replace function public.v58_validate_financial_refs()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_table_name='financial_budget_lines' then
    if not exists(select 1 from financial_budgets b where b.id=new.budget_id and b.business_id=new.business_id) then raise exception 'Budget does not belong to this business'; end if;
  elsif tg_table_name='financial_budget_month_values' then
    if not exists(select 1 from financial_budget_lines l where l.id=new.budget_line_id and l.business_id=new.business_id) then raise exception 'Budget line does not belong to this business'; end if;
  end if;
  return new;
end;$$;

-- Finalised GST returns are immutable for normal business users.
create or replace function public.v58_lock_finalised_gst()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if public.is_super_admin() then return new; end if;
  if old.status='finalised' then raise exception 'Finalised GST returns cannot be directly changed'; end if;
  return new;
end;$$;

drop trigger if exists v58_lock_finalised_gst on public.gst_returns;
create trigger v58_lock_finalised_gst before update on public.gst_returns for each row execute function public.v58_lock_finalised_gst();

-- RLS and guards.
do $$
declare t text;
begin
  foreach t in array array['financial_settings','financial_category_mappings','financial_budgets','financial_budget_lines','financial_budget_month_values','gst_returns','financial_audit_log'] loop
    execute format('alter table public.%I enable row level security',t);
    begin execute format('drop policy if exists v58_financials_tenant_all on public.%I',t); exception when others then null; end;
    execute format('create policy v58_financials_tenant_all on public.%I for all to authenticated using (public.v58_financials_access(business_id)) with check (public.v58_financials_access(business_id))',t);
    if t<>'financial_audit_log' then
      begin execute format('drop trigger if exists v58_financials_tenant_guard on public.%I',t); exception when others then null; end;
      execute format('create trigger v58_financials_tenant_guard before insert or update on public.%I for each row execute function public.v58_financials_tenant_guard()',t);
    end if;
  end loop;
end$$;

drop trigger if exists v58_financial_budget_line_ref on public.financial_budget_lines;
create trigger v58_financial_budget_line_ref before insert or update on public.financial_budget_lines for each row execute function public.v58_validate_financial_refs();
drop trigger if exists v58_financial_budget_month_ref on public.financial_budget_month_values;
create trigger v58_financial_budget_month_ref before insert or update on public.financial_budget_month_values for each row execute function public.v58_validate_financial_refs();

-- Seed settings for existing businesses. The tax figure is an editable planning estimate, not a filed tax return.
insert into public.financial_settings(business_id)
select b.id from public.businesses b
on conflict (business_id) do nothing;

-- Seed mappings from existing expense categories without altering the Expenses module.
insert into public.financial_category_mappings(business_id,source_type,source_id,display_name,classification)
select c.business_id,'expense_category',c.id,c.name,
       case when lower(coalesce(c.group_name,'')) like '%direct%' then 'direct_cost' else 'indirect_cost' end
from public.expense_categories c
on conflict do nothing;

-- Standard payroll classifications are Financials metadata only; Payroll source rows remain unchanged.
insert into public.financial_category_mappings(business_id,source_type,source_key,display_name,classification)
select b.id,'payroll_type',x.source_key,x.display_name,x.classification
from public.businesses b
cross join (values
 ('wage_expense','Payroll Wages','direct_cost'),
 ('employer_contribution_expense','Employer Contributions','indirect_cost'),
 ('reimbursement_expense','Payroll Reimbursements','direct_cost'),
 ('paye_payable','PAYE Payable','liability'),
 ('kiwisaver_payable','KiwiSaver Payable','liability')
) as x(source_key,display_name,classification)
on conflict do nothing;

-- Seed category mappings automatically for future businesses/categories.
create or replace function public.v58_seed_financial_category_mapping()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.financial_category_mappings(business_id,source_type,source_id,display_name,classification)
  values(new.business_id,'expense_category',new.id,new.name,case when lower(coalesce(new.group_name,'')) like '%direct%' then 'direct_cost' else 'indirect_cost' end)
  on conflict do nothing;
  return new;
end;$$;
drop trigger if exists v58_seed_financial_category_mapping on public.expense_categories;
create trigger v58_seed_financial_category_mapping after insert on public.expense_categories for each row execute function public.v58_seed_financial_category_mapping();

create or replace function public.v58_seed_financials_for_profile()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.business_id is not null then
    insert into public.financial_settings(business_id) values(new.business_id) on conflict(business_id) do nothing;
    insert into public.financial_category_mappings(business_id,source_type,source_key,display_name,classification)
    values
      (new.business_id,'payroll_type','wage_expense','Payroll Wages','direct_cost'),
      (new.business_id,'payroll_type','employer_contribution_expense','Employer Contributions','indirect_cost'),
      (new.business_id,'payroll_type','reimbursement_expense','Payroll Reimbursements','direct_cost'),
      (new.business_id,'payroll_type','paye_payable','PAYE Payable','liability'),
      (new.business_id,'payroll_type','kiwisaver_payable','KiwiSaver Payable','liability')
    on conflict do nothing;
  end if;
  return new;
end;$$;
drop trigger if exists v58_seed_financials_for_profile on public.profiles;
create trigger v58_seed_financials_for_profile after insert or update of business_id on public.profiles for each row execute function public.v58_seed_financials_for_profile();

-- Lightweight audit trail for Financials-owned configuration and finalisation records.
create or replace function public.v58_financial_audit_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
declare bid uuid; eid uuid; act text;
begin
  bid:=coalesce(new.business_id,old.business_id);
  begin eid:=coalesce(new.id,old.id); exception when others then eid:=null; end;
  act:=case when tg_op='INSERT' then 'created' when tg_op='DELETE' then 'deleted' else 'updated' end;
  insert into public.financial_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by)
  values(bid,tg_table_name,eid,act,case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,auth.uid());
  if tg_op='DELETE' then return old; end if;
  return new;
end;$$;

do $$
declare t text;
begin
  foreach t in array array['financial_settings','financial_category_mappings','financial_budgets','financial_budget_lines','financial_budget_month_values','gst_returns'] loop
    begin execute format('drop trigger if exists v58_financial_audit on public.%I',t); exception when others then null; end;
    execute format('create trigger v58_financial_audit after insert or update or delete on public.%I for each row execute function public.v58_financial_audit_trigger()',t);
  end loop;
end$$;


-- Audit rows are readable by the tenant but written only by the SECURITY DEFINER audit trigger.
drop policy if exists v58_financials_tenant_all on public.financial_audit_log;
create policy v58_financial_audit_select on public.financial_audit_log for select to authenticated using (public.v58_financials_access(business_id));
