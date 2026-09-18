-- Invoice Manager v51 — My Expenses module
-- Run this entire file in Supabase SQL Editor BEFORE deploying v51.
-- Adds the Expenses module, business-scoped expense data, private document storage,
-- payment/reconciliation structures and strict tenant security.

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Module catalogue (NOT automatically enabled for customer businesses).
-- Super Admin controls access per business using the existing Modules action.
-- -----------------------------------------------------------------------------
insert into public.modules(slug,name,description,monthly_price,is_active)
values ('expenses','My Expenses','Capture bills and receipts, manage suppliers, payments, GST and expense reporting',0,true)
on conflict (slug) do update set
  name=excluded.name,
  description=excluded.description,
  is_active=true;

-- -----------------------------------------------------------------------------
-- Core tables
-- -----------------------------------------------------------------------------
create table if not exists public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  name text not null,
  group_name text not null default 'Operating Expenses',
  sort_order integer not null default 0,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,name)
);

create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  supplier_name text not null,
  trading_name text,
  contact_person text,
  address text,
  phone text,
  mobile text,
  email text,
  website text,
  registration_number text,
  tax_number text,
  notes text,
  default_category_id uuid references public.expense_categories(id) on delete set null,
  default_gst_treatment text not null default 'gst' check (default_gst_treatment in ('gst','no_gst','zero_rated')),
  payment_terms_days integer not null default 0 check (payment_terms_days >= 0),
  bank_account text,
  payment_reference text,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  expense_number text not null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  supplier_name text,
  supplier_reference text,
  invoice_date date not null default current_date,
  upload_date timestamptz not null default now(),
  due_date date,
  description text,
  category_id uuid references public.expense_categories(id) on delete set null,
  job_costing_id uuid references public.job_costings(id) on delete set null,
  amount_type text not null default 'inclusive' check (amount_type in ('inclusive','exclusive')),
  gst_treatment text not null default 'gst' check (gst_treatment in ('gst','no_gst','zero_rated')),
  gst_rate numeric(7,3) not null default 15 check (gst_rate >= 0),
  gst_override boolean not null default false,
  ex_gst numeric(14,2) not null default 0 check (ex_gst >= 0),
  gst_amount numeric(14,2) not null default 0 check (gst_amount >= 0),
  total_amount numeric(14,2) not null default 0 check (total_amount >= 0),
  amount_paid numeric(14,2) not null default 0 check (amount_paid >= 0),
  outstanding_balance numeric(14,2) not null default 0 check (outstanding_balance >= 0),
  payment_status text not null default 'unpaid' check (payment_status in ('draft','unpaid','part_paid','paid')),
  reconciled boolean not null default false,
  reconciled_at timestamptz,
  reconciled_by uuid,
  bank_transaction_reference text,
  currency char(3) not null default 'NZD',
  is_split boolean not null default false,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,expense_number)
);

create table if not exists public.expense_lines (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  expense_id uuid not null references public.expenses(id) on delete cascade,
  description text,
  category_id uuid references public.expense_categories(id) on delete set null,
  job_costing_id uuid references public.job_costings(id) on delete set null,
  amount_type text not null default 'inclusive' check (amount_type in ('inclusive','exclusive')),
  gst_treatment text not null default 'gst' check (gst_treatment in ('gst','no_gst','zero_rated')),
  gst_rate numeric(7,3) not null default 15 check (gst_rate >= 0),
  ex_gst numeric(14,2) not null default 0 check (ex_gst >= 0),
  gst_amount numeric(14,2) not null default 0 check (gst_amount >= 0),
  total_amount numeric(14,2) not null default 0 check (total_amount >= 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid()
);

create table if not exists public.expense_attachments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  expense_id uuid not null references public.expenses(id) on delete cascade,
  original_filename text not null,
  stored_path text not null,
  mime_type text,
  file_size bigint not null default 0 check (file_size >= 0),
  uploaded_at timestamptz not null default now(),
  uploaded_by uuid default auth.uid(),
  unique(business_id,stored_path)
);

create table if not exists public.batch_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  batch_number text not null,
  payment_date date not null default current_date,
  bank_account text,
  reference text,
  notes text,
  total_amount numeric(14,2) not null default 0 check (total_amount >= 0),
  status text not null default 'draft' check (status in ('draft','paid')),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  unique(business_id,batch_number)
);

create table if not exists public.expense_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  expense_id uuid not null references public.expenses(id) on delete cascade,
  batch_payment_id uuid references public.batch_payments(id) on delete set null,
  payment_date date not null default current_date,
  amount numeric(14,2) not null check (amount > 0),
  payment_method text,
  bank_account text,
  reference text,
  notes text,
  reconciled boolean not null default false,
  reconciled_at timestamptz,
  reconciled_by uuid,
  bank_transaction_reference text,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists public.expense_reconciliations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  expense_id uuid not null references public.expenses(id) on delete cascade,
  payment_id uuid references public.expense_payments(id) on delete cascade,
  reconciled_at timestamptz not null default now(),
  reconciled_by uuid default auth.uid(),
  bank_transaction_reference text,
  notes text,
  created_at timestamptz not null default now(),
  unique(expense_id,payment_id)
);

create table if not exists public.batch_payment_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  batch_payment_id uuid not null references public.batch_payments(id) on delete cascade,
  expense_id uuid not null references public.expenses(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique(batch_payment_id,expense_id)
);

-- Underlying structures for future supplier credits and recurring expense automation.
create table if not exists public.supplier_credits (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  supplier_id uuid references public.suppliers(id) on delete set null,
  credit_note_number text,
  credit_date date not null default current_date,
  category_id uuid references public.expense_categories(id) on delete set null,
  ex_gst numeric(14,2) not null default 0,
  gst_amount numeric(14,2) not null default 0,
  total_amount numeric(14,2) not null default 0,
  status text not null default 'available' check (status in ('available','applied','refunded')),
  applied_expense_id uuid references public.expenses(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid()
);

create table if not exists public.recurring_expense_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  supplier_id uuid references public.suppliers(id) on delete set null,
  category_id uuid references public.expense_categories(id) on delete set null,
  description text,
  amount_type text not null default 'inclusive' check (amount_type in ('inclusive','exclusive')),
  gst_treatment text not null default 'gst' check (gst_treatment in ('gst','no_gst','zero_rated')),
  amount numeric(14,2) not null default 0,
  frequency text not null check (frequency in ('weekly','fortnightly','monthly','quarterly','annually')),
  next_date date,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid()
);

create table if not exists public.expense_audit_log (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  expense_id uuid references public.expenses(id) on delete cascade,
  action text not null,
  changed_fields jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

-- Per-business counters avoid invoice-like numbering collisions.
create table if not exists public.expense_number_counters (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  last_number bigint not null default 0
);

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
create index if not exists expense_categories_business_idx on public.expense_categories(business_id,archived,sort_order);
create index if not exists suppliers_business_idx on public.suppliers(business_id,archived,supplier_name);
create index if not exists expenses_business_date_idx on public.expenses(business_id,invoice_date desc);
create index if not exists expenses_business_supplier_idx on public.expenses(business_id,supplier_id);
create index if not exists expenses_business_category_idx on public.expenses(business_id,category_id);
create index if not exists expenses_business_job_idx on public.expenses(business_id,job_costing_id);
create index if not exists expenses_business_status_idx on public.expenses(business_id,payment_status,reconciled);
create index if not exists expense_lines_expense_idx on public.expense_lines(expense_id,sort_order);
create index if not exists expense_lines_business_job_idx on public.expense_lines(business_id,job_costing_id);
create index if not exists expense_attachments_expense_idx on public.expense_attachments(expense_id);
create index if not exists expense_payments_expense_idx on public.expense_payments(expense_id,payment_date);
create index if not exists expense_reconciliations_expense_idx on public.expense_reconciliations(business_id,expense_id,reconciled_at);
create unique index if not exists expense_reconciliations_expense_only_key on public.expense_reconciliations(expense_id) where payment_id is null;
create index if not exists batch_payments_business_idx on public.batch_payments(business_id,payment_date desc);
create index if not exists batch_items_batch_idx on public.batch_payment_items(batch_payment_id);
create index if not exists supplier_credits_business_idx on public.supplier_credits(business_id,supplier_id);
create index if not exists recurring_expenses_business_idx on public.recurring_expense_rules(business_id,active,next_date);
create index if not exists expense_audit_business_idx on public.expense_audit_log(business_id,created_at desc);

-- -----------------------------------------------------------------------------
-- Tenant ownership and same-business relationship enforcement
-- The browser cannot move a record to another tenant by supplying business_id.
-- -----------------------------------------------------------------------------
create or replace function public.v51_enforce_expense_business()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_current uuid;
begin
  v_current := public.current_business_id();
  -- SQL/service operations have no auth.uid(); authenticated browser users must always be tenant-bound.
  if auth.uid() is not null and not public.is_super_admin() then
    if v_current is null then raise exception 'Business account not found'; end if;
    if tg_op='INSERT' then new.business_id := v_current;
    elsif new.business_id is distinct from old.business_id then raise exception 'Business ownership cannot be changed';
    end if;
  end if;
  return new;
end $$;

create or replace function public.v51_validate_expense_refs()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.supplier_id is not null and not exists(select 1 from public.suppliers s where s.id=new.supplier_id and s.business_id=new.business_id) then
    raise exception 'Supplier does not belong to this business';
  end if;
  if new.category_id is not null and not exists(select 1 from public.expense_categories c where c.id=new.category_id and c.business_id=new.business_id) then
    raise exception 'Expense category does not belong to this business';
  end if;
  if new.job_costing_id is not null and not exists(select 1 from public.job_costings j where j.id=new.job_costing_id and j.business_id=new.business_id) then
    raise exception 'Job does not belong to this business';
  end if;
  return new;
end $$;

create or replace function public.v51_validate_expense_child()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.expense_id is not null and not exists(select 1 from public.expenses e where e.id=new.expense_id and e.business_id=new.business_id) then
    raise exception 'Expense does not belong to this business';
  end if;
  return new;
end $$;

create or replace function public.v51_validate_line_refs()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if not exists(select 1 from public.expenses e where e.id=new.expense_id and e.business_id=new.business_id) then
    raise exception 'Expense does not belong to this business';
  end if;
  if new.category_id is not null and not exists(select 1 from public.expense_categories c where c.id=new.category_id and c.business_id=new.business_id) then
    raise exception 'Expense category does not belong to this business';
  end if;
  if new.job_costing_id is not null and not exists(select 1 from public.job_costings j where j.id=new.job_costing_id and j.business_id=new.business_id) then
    raise exception 'Job does not belong to this business';
  end if;
  return new;
end $$;

create or replace function public.v51_validate_supplier_defaults()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.default_category_id is not null and not exists(select 1 from public.expense_categories c where c.id=new.default_category_id and c.business_id=new.business_id) then
    raise exception 'Default expense category does not belong to this business';
  end if;
  return new;
end $$;

-- Apply ownership trigger to every tenant table.
do $$
declare t text;
begin
  foreach t in array array['expense_categories','suppliers','expenses','expense_lines','expense_attachments','expense_payments','expense_reconciliations','batch_payments','batch_payment_items','supplier_credits','recurring_expense_rules']
  loop
    execute format('drop trigger if exists v51_tenant_guard on public.%I',t);
    execute format('drop trigger if exists v51_00_tenant_guard on public.%I',t);
    execute format('create trigger v51_00_tenant_guard before insert or update on public.%I for each row execute function public.v51_enforce_expense_business()',t);
  end loop;
end $$;

drop trigger if exists v51_expense_refs on public.expenses;
create trigger v51_expense_refs before insert or update on public.expenses for each row execute function public.v51_validate_expense_refs();

drop trigger if exists v51_line_refs on public.expense_lines;
create trigger v51_line_refs before insert or update on public.expense_lines for each row execute function public.v51_validate_line_refs();

drop trigger if exists v51_attachment_ref on public.expense_attachments;
create trigger v51_attachment_ref before insert or update on public.expense_attachments for each row execute function public.v51_validate_expense_child();

drop trigger if exists v51_payment_ref on public.expense_payments;
create trigger v51_payment_ref before insert or update on public.expense_payments for each row execute function public.v51_validate_expense_child();

drop trigger if exists v51_supplier_default_ref on public.suppliers;
create trigger v51_supplier_default_ref before insert or update on public.suppliers for each row execute function public.v51_validate_supplier_defaults();

create or replace function public.v51_validate_reconciliation_refs()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.expenses e where e.id=new.expense_id and e.business_id=new.business_id) then raise exception 'Expense does not belong to this business'; end if;
  if new.payment_id is not null and not exists(select 1 from public.expense_payments p where p.id=new.payment_id and p.expense_id=new.expense_id and p.business_id=new.business_id) then raise exception 'Payment does not belong to this expense/business'; end if;
  return new;
end $$;

drop trigger if exists v51_reconciliation_refs on public.expense_reconciliations;
create trigger v51_reconciliation_refs before insert or update on public.expense_reconciliations for each row execute function public.v51_validate_reconciliation_refs();

-- Additional same-business checks for batch payments, payment batches, credits and recurring rules.
create or replace function public.v51_validate_payment_refs()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.expenses e where e.id=new.expense_id and e.business_id=new.business_id) then raise exception 'Expense does not belong to this business'; end if;
  if new.batch_payment_id is not null and not exists(select 1 from public.batch_payments b where b.id=new.batch_payment_id and b.business_id=new.business_id) then raise exception 'Batch payment does not belong to this business'; end if;
  return new;
end $$;

drop trigger if exists v51_payment_refs on public.expense_payments;
create trigger v51_payment_refs before insert or update on public.expense_payments for each row execute function public.v51_validate_payment_refs();

create or replace function public.v51_validate_batch_item_refs()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.batch_payments b where b.id=new.batch_payment_id and b.business_id=new.business_id) then raise exception 'Batch payment does not belong to this business'; end if;
  if not exists(select 1 from public.expenses e where e.id=new.expense_id and e.business_id=new.business_id) then raise exception 'Expense does not belong to this business'; end if;
  return new;
end $$;

drop trigger if exists v51_batch_item_refs on public.batch_payment_items;
create trigger v51_batch_item_refs before insert or update on public.batch_payment_items for each row execute function public.v51_validate_batch_item_refs();

create or replace function public.v51_validate_credit_refs()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.supplier_id is not null and not exists(select 1 from public.suppliers s where s.id=new.supplier_id and s.business_id=new.business_id) then raise exception 'Supplier does not belong to this business'; end if;
  if new.category_id is not null and not exists(select 1 from public.expense_categories c where c.id=new.category_id and c.business_id=new.business_id) then raise exception 'Category does not belong to this business'; end if;
  if new.applied_expense_id is not null and not exists(select 1 from public.expenses e where e.id=new.applied_expense_id and e.business_id=new.business_id) then raise exception 'Expense does not belong to this business'; end if;
  return new;
end $$;

drop trigger if exists v51_credit_refs on public.supplier_credits;
create trigger v51_credit_refs before insert or update on public.supplier_credits for each row execute function public.v51_validate_credit_refs();

create or replace function public.v51_validate_recurring_refs()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.supplier_id is not null and not exists(select 1 from public.suppliers s where s.id=new.supplier_id and s.business_id=new.business_id) then raise exception 'Supplier does not belong to this business'; end if;
  if new.category_id is not null and not exists(select 1 from public.expense_categories c where c.id=new.category_id and c.business_id=new.business_id) then raise exception 'Category does not belong to this business'; end if;
  return new;
end $$;

drop trigger if exists v51_recurring_refs on public.recurring_expense_rules;
create trigger v51_recurring_refs before insert or update on public.recurring_expense_rules for each row execute function public.v51_validate_recurring_refs();

create or replace function public.v51_validate_attachment_path()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if split_part(new.stored_path,'/',1) <> new.business_id::text then raise exception 'Attachment storage path does not belong to this business'; end if;
  return new;
end $$;

drop trigger if exists v51_attachment_path on public.expense_attachments;
create trigger v51_attachment_path before insert or update on public.expense_attachments for each row execute function public.v51_validate_attachment_path();

-- -----------------------------------------------------------------------------
-- Payment totals/status. Payment status and reconciliation deliberately remain separate.
-- -----------------------------------------------------------------------------
create or replace function public.v51_refresh_expense_payment_totals(p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_old_status text;
begin
  select total_amount,payment_status into v_total,v_old_status from public.expenses where id=p_expense_id for update;
  if not found then return; end if;
  select coalesce(sum(amount),0)::numeric(14,2) into v_paid from public.expense_payments where expense_id=p_expense_id;
  if v_paid > v_total + 0.005 then raise exception 'Payment would exceed the outstanding bill balance'; end if;
  update public.expenses
     set amount_paid=v_paid,
         outstanding_balance=greatest(v_total-v_paid,0),
         payment_status=case
           when v_old_status='draft' and v_paid=0 then 'draft'
           when v_paid<=0 then 'unpaid'
           when v_paid >= v_total-0.005 then 'paid'
           else 'part_paid'
         end,
         updated_at=now(),
         updated_by=auth.uid()
   where id=p_expense_id;
end $$;

create or replace function public.v51_payment_change_trigger()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op='DELETE' then perform public.v51_refresh_expense_payment_totals(old.expense_id); return old; end if;
  perform public.v51_refresh_expense_payment_totals(new.expense_id);
  if tg_op='UPDATE' and old.expense_id is distinct from new.expense_id then perform public.v51_refresh_expense_payment_totals(old.expense_id); end if;
  return new;
end $$;

drop trigger if exists v51_payment_totals on public.expense_payments;
create trigger v51_payment_totals after insert or update or delete on public.expense_payments for each row execute function public.v51_payment_change_trigger();

-- Keep outstanding balance aligned if a bill total changes.
create or replace function public.v51_expense_total_change_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    new.outstanding_balance:=new.total_amount;
  else
    new.updated_at:=now(); new.updated_by:=auth.uid();
    if new.total_amount is distinct from old.total_amount then
      new.outstanding_balance:=greatest(new.total_amount-coalesce(new.amount_paid,0),0);
      if coalesce(new.amount_paid,0)>new.total_amount+0.005 then raise exception 'Bill total cannot be reduced below the amount already paid'; end if;
      if old.payment_status <> 'draft' then
        new.payment_status:=case
          when coalesce(new.amount_paid,0)<=0 then 'unpaid'
          when coalesce(new.amount_paid,0)>=new.total_amount-0.005 then 'paid'
          else 'part_paid'
        end;
      end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists v51_expense_total_guard on public.expenses;
create trigger v51_expense_total_guard before insert or update on public.expenses for each row execute function public.v51_expense_total_change_trigger();

-- Audit important expense changes without overwriting historical evidence.
create or replace function public.v51_expense_audit_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
declare changes jsonb := '{}'::jsonb;
begin
  if tg_op='INSERT' then
    insert into public.expense_audit_log(business_id,expense_id,action,changed_fields,created_by)
    values(new.business_id,new.id,'created',jsonb_build_object('total_amount',new.total_amount,'gst_amount',new.gst_amount,'supplier_id',new.supplier_id,'category_id',new.category_id,'job_costing_id',new.job_costing_id),auth.uid());
    return new;
  end if;
  if new.total_amount is distinct from old.total_amount then changes:=changes||jsonb_build_object('total_amount',jsonb_build_array(old.total_amount,new.total_amount)); end if;
  if new.gst_amount is distinct from old.gst_amount then changes:=changes||jsonb_build_object('gst_amount',jsonb_build_array(old.gst_amount,new.gst_amount)); end if;
  if new.supplier_id is distinct from old.supplier_id then changes:=changes||jsonb_build_object('supplier_id',jsonb_build_array(old.supplier_id,new.supplier_id)); end if;
  if new.category_id is distinct from old.category_id then changes:=changes||jsonb_build_object('category_id',jsonb_build_array(old.category_id,new.category_id)); end if;
  if new.job_costing_id is distinct from old.job_costing_id then changes:=changes||jsonb_build_object('job_costing_id',jsonb_build_array(old.job_costing_id,new.job_costing_id)); end if;
  if new.reconciled is distinct from old.reconciled then changes:=changes||jsonb_build_object('reconciled',jsonb_build_array(old.reconciled,new.reconciled)); end if;
  if changes <> '{}'::jsonb then
    insert into public.expense_audit_log(business_id,expense_id,action,changed_fields,created_by) values(new.business_id,new.id,'updated',changes,auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists v51_expense_audit on public.expenses;
create trigger v51_expense_audit after insert or update on public.expenses for each row execute function public.v51_expense_audit_trigger();

-- Atomic per-business numbering.
create or replace function public.v51_next_expense_number()
returns text
language plpgsql
security definer
set search_path=public
as $$
declare b uuid; n bigint;
begin
  b:=public.current_business_id();
  if b is null then raise exception 'Business account not found'; end if;
  insert into public.expense_number_counters(business_id,last_number) values(b,1)
  on conflict (business_id) do update set last_number=public.expense_number_counters.last_number+1
  returning last_number into n;
  return 'EXP-'||lpad(n::text,4,'0');
end $$;
revoke all on function public.v51_next_expense_number() from public,anon;
grant execute on function public.v51_next_expense_number() to authenticated;

-- -----------------------------------------------------------------------------
-- Default categories — business specific.
-- -----------------------------------------------------------------------------
create or replace function public.v51_seed_expense_categories(p_business_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  insert into public.expense_categories(business_id,name,group_name,sort_order,created_by,updated_by)
  values
    (p_business_id,'Materials & Supplies','Direct Costs',10,null,null),
    (p_business_id,'Subcontractors','Direct Costs',20,null,null),
    (p_business_id,'Labour','Direct Costs',30,null,null),
    (p_business_id,'Fuel','Direct Costs',40,null,null),
    (p_business_id,'Equipment Hire','Direct Costs',50,null,null),
    (p_business_id,'Job Expenses','Direct Costs',60,null,null),
    (p_business_id,'Advertising & Marketing','Operating Expenses',110,null,null),
    (p_business_id,'Vehicle Expenses','Operating Expenses',120,null,null),
    (p_business_id,'Insurance','Operating Expenses',130,null,null),
    (p_business_id,'Rent','Operating Expenses',140,null,null),
    (p_business_id,'Utilities','Operating Expenses',150,null,null),
    (p_business_id,'Phone & Internet','Operating Expenses',160,null,null),
    (p_business_id,'Software & Subscriptions','Operating Expenses',170,null,null),
    (p_business_id,'Bank Fees','Operating Expenses',180,null,null),
    (p_business_id,'Accounting & Legal','Operating Expenses',190,null,null),
    (p_business_id,'Office Expenses','Operating Expenses',200,null,null),
    (p_business_id,'Repairs & Maintenance','Operating Expenses',210,null,null),
    (p_business_id,'Training','Operating Expenses',220,null,null),
    (p_business_id,'Travel','Operating Expenses',230,null,null),
    (p_business_id,'Other','Operating Expenses',999,null,null)
  on conflict (business_id,name) do nothing;
end $$;

do $$ declare b record; begin
  for b in select id from public.businesses loop perform public.v51_seed_expense_categories(b.id); end loop;
end $$;

create or replace function public.v51_new_business_expense_defaults()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.business_id is not null then perform public.v51_seed_expense_categories(new.business_id); end if;
  return new;
end $$;

-- Seed after the owner's profile exists, so current_business_id() is already resolvable.
drop trigger if exists v51_seed_expense_defaults on public.businesses;
drop trigger if exists v51_seed_expense_defaults on public.profiles;
create trigger v51_seed_expense_defaults after insert on public.profiles for each row execute function public.v51_new_business_expense_defaults();

-- -----------------------------------------------------------------------------
-- RLS — all expense data is isolated by business_id.
-- -----------------------------------------------------------------------------
do $$ declare t text; r record; begin
  foreach t in array array['expense_categories','suppliers','expenses','expense_lines','expense_attachments','expense_payments','expense_reconciliations','batch_payments','batch_payment_items','supplier_credits','recurring_expense_rules'] loop
    execute format('alter table public.%I enable row level security',t);
    for r in select policyname from pg_policies where schemaname='public' and tablename=t and policyname like 'v51_%' loop
      execute format('drop policy if exists %I on public.%I',r.policyname,t);
    end loop;
    execute format('create policy v51_%I_tenant on public.%I for all using (business_id=public.current_business_id() or public.is_super_admin()) with check (business_id=public.current_business_id() or public.is_super_admin())',t,t);
  end loop;
end $$;

-- Audit logs are readable by the tenant, but normal users cannot edit/delete audit history.
alter table public.expense_audit_log enable row level security;
drop policy if exists v51_expense_audit_log_read on public.expense_audit_log;
drop policy if exists v51_expense_audit_log_admin_write on public.expense_audit_log;
create policy v51_expense_audit_log_read on public.expense_audit_log for select using (business_id=public.current_business_id() or public.is_super_admin());
create policy v51_expense_audit_log_admin_write on public.expense_audit_log for all using (public.is_super_admin()) with check (public.is_super_admin());

-- Number counters are managed only through the security-definer numbering RPC.
alter table public.expense_number_counters enable row level security;
drop policy if exists v51_expense_counter_read on public.expense_number_counters;
drop policy if exists v51_expense_counter_admin_write on public.expense_number_counters;
create policy v51_expense_counter_read on public.expense_number_counters for select using (business_id=public.current_business_id() or public.is_super_admin());
create policy v51_expense_counter_admin_write on public.expense_number_counters for all using (public.is_super_admin()) with check (public.is_super_admin());

-- -----------------------------------------------------------------------------
-- Private receipt/document storage.
-- Path convention: <business_uuid>/<expense_uuid>/<unique_filename>
-- -----------------------------------------------------------------------------
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('expense-documents','expense-documents',false,10485760,array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf'])
on conflict (id) do update set public=false,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists v51_expense_docs_select on storage.objects;
drop policy if exists v51_expense_docs_insert on storage.objects;
drop policy if exists v51_expense_docs_update on storage.objects;
drop policy if exists v51_expense_docs_delete on storage.objects;

create policy v51_expense_docs_select on storage.objects for select to authenticated
using (
  bucket_id='expense-documents' and
  ((storage.foldername(name))[1]::uuid=public.current_business_id() or public.is_super_admin())
);
create policy v51_expense_docs_insert on storage.objects for insert to authenticated
with check (
  bucket_id='expense-documents' and
  ((storage.foldername(name))[1]::uuid=public.current_business_id() or public.is_super_admin())
);
create policy v51_expense_docs_update on storage.objects for update to authenticated
using (
  bucket_id='expense-documents' and
  ((storage.foldername(name))[1]::uuid=public.current_business_id() or public.is_super_admin())
)
with check (
  bucket_id='expense-documents' and
  ((storage.foldername(name))[1]::uuid=public.current_business_id() or public.is_super_admin())
);
create policy v51_expense_docs_delete on storage.objects for delete to authenticated
using (
  bucket_id='expense-documents' and
  ((storage.foldername(name))[1]::uuid=public.current_business_id() or public.is_super_admin())
);

notify pgrst, 'reload schema';

-- Expenses may optionally reference a Job Costing record for expense-side allocation/reporting.
-- The Job Costing module itself remains an estimating tool and is intentionally not modified.

notify pgrst, 'reload schema';
