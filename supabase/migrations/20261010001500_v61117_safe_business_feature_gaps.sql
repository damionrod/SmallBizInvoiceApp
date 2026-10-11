-- Frindly v61.117 - safe additive feature gaps.
-- Adds guarded support for purchase orders, provisional-tax planning and manual journals.
-- Customer statements and late-fee helpers are read-only/draft UI features and do not post accounting.

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  po_number text not null,
  supplier_id uuid null references public.suppliers(id) on delete set null,
  supplier_name text,
  order_date date not null default current_date,
  expected_date date,
  status text not null default 'draft',
  notes text,
  currency text not null default 'NZD',
  subtotal numeric not null default 0,
  gst_amount numeric not null default 0,
  total_amount numeric not null default 0,
  source_job_costing_id uuid null,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchase_orders_status_chk check (status in ('draft','approved','sent','partially_received','billed','closed','cancelled')),
  constraint purchase_orders_amount_chk check (subtotal >= 0 and gst_amount >= 0 and total_amount >= 0),
  constraint purchase_orders_currency_chk check (currency ~ '^[A-Z]{3}$')
);

create unique index if not exists purchase_orders_business_number_uq
  on public.purchase_orders(business_id, lower(po_number));

create table if not exists public.purchase_order_lines (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  line_order integer not null default 1,
  description text not null,
  qty numeric not null default 1,
  unit_price numeric not null default 0,
  gst_rate numeric not null default 0,
  gst_amount numeric not null default 0,
  line_total numeric not null default 0,
  job_costing_id uuid null,
  created_at timestamptz not null default now(),
  constraint purchase_order_lines_qty_chk check (qty >= 0 and unit_price >= 0 and gst_rate >= 0 and gst_amount >= 0 and line_total >= 0)
);

create index if not exists purchase_order_lines_po_idx
  on public.purchase_order_lines(business_id, purchase_order_id, line_order);

create table if not exists public.purchase_order_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  event_type text not null,
  note text,
  created_by uuid,
  created_at timestamptz not null default now()
);

create index if not exists purchase_order_events_po_idx
  on public.purchase_order_events(business_id, purchase_order_id, created_at desc);

create table if not exists public.provisional_tax_plans (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  tax_year_end date not null,
  method text not null default 'estimate',
  estimated_taxable_profit numeric not null default 0,
  estimated_income_tax numeric not null default 0,
  status text not null default 'draft',
  notes text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint provisional_tax_plans_method_chk check (method in ('estimate','standard_uplift','accountant_advised')),
  constraint provisional_tax_plans_status_chk check (status in ('draft','reviewed','archived'))
);

create unique index if not exists provisional_tax_plans_business_year_uq
  on public.provisional_tax_plans(business_id, tax_year_end);

create table if not exists public.provisional_tax_instalments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  plan_id uuid not null references public.provisional_tax_plans(id) on delete cascade,
  instalment_number integer not null,
  due_date date not null,
  suggested_amount numeric not null default 0,
  paid_amount numeric not null default 0,
  status text not null default 'planned',
  notes text,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint provisional_tax_instalments_number_chk check (instalment_number between 1 and 6),
  constraint provisional_tax_instalments_amount_chk check (suggested_amount >= 0 and paid_amount >= 0),
  constraint provisional_tax_instalments_status_chk check (status in ('planned','paid','review','skipped'))
);

create unique index if not exists provisional_tax_instalments_plan_number_uq
  on public.provisional_tax_instalments(plan_id, instalment_number);

alter table public.purchase_orders enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.purchase_order_events enable row level security;
alter table public.provisional_tax_plans enable row level security;
alter table public.provisional_tax_instalments enable row level security;

drop policy if exists purchase_orders_business_select on public.purchase_orders;
create policy purchase_orders_business_select on public.purchase_orders for select to authenticated
using (business_id = public.current_business_id());

drop policy if exists purchase_orders_business_insert on public.purchase_orders;
create policy purchase_orders_business_insert on public.purchase_orders for insert to authenticated
with check (business_id = public.current_business_id());

drop policy if exists purchase_orders_business_update on public.purchase_orders;
create policy purchase_orders_business_update on public.purchase_orders for update to authenticated
using (business_id = public.current_business_id())
with check (business_id = public.current_business_id());

drop policy if exists purchase_order_lines_business_select on public.purchase_order_lines;
create policy purchase_order_lines_business_select on public.purchase_order_lines for select to authenticated
using (business_id = public.current_business_id());

drop policy if exists purchase_order_lines_business_insert on public.purchase_order_lines;
create policy purchase_order_lines_business_insert on public.purchase_order_lines for insert to authenticated
with check (
  business_id = public.current_business_id()
  and exists (
    select 1 from public.purchase_orders po
    where po.id = purchase_order_id
      and po.business_id = public.current_business_id()
  )
);

drop policy if exists purchase_order_lines_business_update on public.purchase_order_lines;
create policy purchase_order_lines_business_update on public.purchase_order_lines for update to authenticated
using (business_id = public.current_business_id())
with check (
  business_id = public.current_business_id()
  and exists (
    select 1 from public.purchase_orders po
    where po.id = purchase_order_id
      and po.business_id = public.current_business_id()
  )
);

drop policy if exists purchase_order_lines_business_delete on public.purchase_order_lines;
create policy purchase_order_lines_business_delete on public.purchase_order_lines for delete to authenticated
using (business_id = public.current_business_id());

drop policy if exists purchase_order_events_business_select on public.purchase_order_events;
create policy purchase_order_events_business_select on public.purchase_order_events for select to authenticated
using (business_id = public.current_business_id());

drop policy if exists purchase_order_events_business_insert on public.purchase_order_events;
create policy purchase_order_events_business_insert on public.purchase_order_events for insert to authenticated
with check (
  business_id = public.current_business_id()
  and exists (
    select 1 from public.purchase_orders po
    where po.id = purchase_order_id
      and po.business_id = public.current_business_id()
  )
);

drop policy if exists provisional_tax_plans_business_select on public.provisional_tax_plans;
create policy provisional_tax_plans_business_select on public.provisional_tax_plans for select to authenticated
using (business_id = public.current_business_id() and public.v6169a_accountant_centre_access(business_id,false));

drop policy if exists provisional_tax_plans_business_all on public.provisional_tax_plans;
create policy provisional_tax_plans_business_all on public.provisional_tax_plans for all to authenticated
using (business_id = public.current_business_id() and public.v6169a_accountant_centre_access(business_id,true))
with check (business_id = public.current_business_id() and public.v6169a_accountant_centre_access(business_id,true));

drop policy if exists provisional_tax_instalments_business_select on public.provisional_tax_instalments;
create policy provisional_tax_instalments_business_select on public.provisional_tax_instalments for select to authenticated
using (business_id = public.current_business_id() and public.v6169a_accountant_centre_access(business_id,false));

drop policy if exists provisional_tax_instalments_business_all on public.provisional_tax_instalments;
create policy provisional_tax_instalments_business_all on public.provisional_tax_instalments for all to authenticated
using (business_id = public.current_business_id() and public.v6169a_accountant_centre_access(business_id,true))
with check (business_id = public.current_business_id() and public.v6169a_accountant_centre_access(business_id,true));

grant select, insert, update on public.purchase_orders to authenticated;
grant select, insert, update, delete on public.purchase_order_lines to authenticated;
grant select, insert on public.purchase_order_events to authenticated;
grant select, insert, update on public.provisional_tax_plans to authenticated;
grant select, insert, update on public.provisional_tax_instalments to authenticated;

create or replace function public.v61117_post_manual_journal(
  p_journal_date date,
  p_description text,
  p_lines jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_debits numeric := 0;
  v_credits numeric := 0;
  v_journal uuid;
  v_account_business uuid;
begin
  if v_uid is null or v_bid is null then
    raise exception 'Choose a business and sign in';
  end if;
  if not public.v6169a_accountant_centre_access(v_bid,true) then
    raise exception 'Manual journals are restricted to authorised accounting users';
  end if;
  if p_journal_date is null or p_description is null or length(btrim(p_description)) < 5 then
    raise exception 'Manual journal needs a date and clear description';
  end if;
  if not public.v6170a_period_is_open(v_bid,p_journal_date) then
    raise exception 'The accounting period is locked';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'Manual journal needs at least two lines';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    select a.business_id into v_account_business
    from public.accounting_accounts a
    where a.id = (v_line->>'account_id')::uuid;

    if v_account_business is distinct from v_bid then
      raise exception 'Manual journal account does not belong to this business';
    end if;

    v_debits := v_debits + greatest(0, coalesce((v_line->>'debit')::numeric,0));
    v_credits := v_credits + greatest(0, coalesce((v_line->>'credit')::numeric,0));
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', (v_line->>'account_id')::uuid,
      'description', nullif(btrim(coalesce(v_line->>'description',p_description)),''),
      'debit', round(greatest(0, coalesce((v_line->>'debit')::numeric,0)),2),
      'credit', round(greatest(0, coalesce((v_line->>'credit')::numeric,0)),2),
      'tax_code', coalesce(nullif(v_line->>'tax_code',''),'NO_GST'),
      'tax_rate', 0,
      'tax_amount', 0
    ));
  end loop;

  if round(v_debits,2) <= 0 or abs(round(v_debits - v_credits,2)) > 0.005 then
    raise exception 'Manual journal must balance before posting';
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    p_journal_date,
    'manual',
    'manual_journal',
    gen_random_uuid(),
    'MJ-' || to_char(now(),'YYYYMMDDHH24MISS'),
    p_description,
    v_lines
  );

  return v_journal;
end;
$$;

revoke execute on function public.v61117_post_manual_journal(date,text,jsonb) from public, anon;
grant execute on function public.v61117_post_manual_journal(date,text,jsonb) to authenticated;

create or replace function public.v61117_customer_statement(
  p_customer_id uuid,
  p_from date,
  p_to date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_customer record;
  v_rows jsonb;
begin
  if v_bid is null or auth.uid() is null then
    raise exception 'Choose a business and sign in';
  end if;

  select * into v_customer
  from public.customers c
  where c.business_id = v_bid and c.id = p_customer_id;

  if not found then
    raise exception 'Customer not found';
  end if;

  with raw as (
    select invoice_date as d, invoice_number as ref, 'Invoice'::text as kind, total::numeric as debit, 0::numeric as credit
    from public.invoices
    where business_id = v_bid and customer_id = p_customer_id and invoice_date <= p_to and coalesce(lifecycle_state,'issued') <> 'voided'
    union all
    select cp.payment_date, coalesce(cp.reference,'Payment'), 'Payment', 0, cp.amount
    from public.customer_payments cp
    join public.invoices i on i.id = cp.invoice_id and i.business_id = cp.business_id
    where cp.business_id = v_bid and i.customer_id = p_customer_id and cp.payment_date <= p_to
  ), ordered as (
    select d, ref, kind, debit, credit,
      sum(debit-credit) over(order by d, ref rows between unbounded preceding and current row) as balance
    from raw
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date', d,
    'reference', ref,
    'description', kind,
    'debit', debit,
    'credit', credit,
    'balance', balance
  ) order by d, ref),'[]'::jsonb)
  into v_rows
  from ordered
  where d between p_from and p_to;

  return jsonb_build_object(
    'customer_id', v_customer.id,
    'customer_name', v_customer.name,
    'from', p_from,
    'to', p_to,
    'rows', v_rows
  );
end;
$$;

revoke execute on function public.v61117_customer_statement(uuid,date,date) from public, anon;
grant execute on function public.v61117_customer_statement(uuid,date,date) to authenticated;
