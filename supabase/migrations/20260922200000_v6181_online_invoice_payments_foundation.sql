-- V61.81: Online Invoice Payments foundation.
--
-- This is an additive module. It is seeded globally inactive so a Super Admin
-- must explicitly enable it before it can be included in a plan or granted to
-- an individual business.

begin;

insert into public.modules (name, slug, description, monthly_price, is_active)
select
  'Online Invoice Payments',
  'invoice_payments',
  'Stripe Connect payments from invoice emails, including partial payments.',
  0,
  false
where not exists (
  select 1 from public.modules where slug = 'invoice_payments'
);

create table if not exists public.invoice_payment_settings (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  stripe_account_id text,
  connect_status text not null default 'not_started'
    check (connect_status in ('not_started','pending','active','restricted','disabled')),
  card_payments_status text not null default 'not_requested',
  details_submitted boolean not null default false,
  requirements jsonb not null default '{}'::jsonb,
  fee_mode text not null default 'bear'
    check (fee_mode in ('bear','split','pass')),
  -- These are configurable estimates used only to display a surcharge at
  -- checkout. Stripe's actual fee is recorded separately from the webhook.
  fee_percent numeric(8,5) not null default 2.65
    check (fee_percent >= 0 and fee_percent < 100),
  fee_fixed_amount numeric(12,2) not null default 0.30
    check (fee_fixed_amount >= 0),
  allow_partial_payments boolean not null default true,
  currency text not null default 'nzd',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.invoice_payment_links (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  token_hash text not null unique,
  active boolean not null default true,
  expires_at timestamptz,
  last_used_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, invoice_id, token_hash)
);

create index if not exists invoice_payment_links_invoice_idx
  on public.invoice_payment_links (business_id, invoice_id, active);

create table if not exists public.invoice_payment_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  payment_link_id uuid references public.invoice_payment_links(id) on delete set null,
  customer_payment_id uuid references public.customer_payments(id) on delete set null,
  stripe_account_id text not null,
  stripe_checkout_session_id text,
  stripe_payment_intent_id text,
  stripe_charge_id text,
  stripe_event_id text,
  amount numeric(14,2) not null check (amount > 0),
  gross_amount numeric(14,2) not null check (gross_amount > 0),
  customer_fee_amount numeric(14,2) not null default 0 check (customer_fee_amount >= 0),
  stripe_fee_amount numeric(14,2),
  net_amount numeric(14,2),
  currency text not null default 'nzd',
  fee_mode text not null check (fee_mode in ('bear','split','pass')),
  status text not null default 'pending'
    check (status in ('pending','processing','succeeded','failed','needs_review','refunded','partially_refunded','disputed')),
  failure_reason text,
  payment_method_type text,
  payment_date timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (stripe_checkout_session_id),
  unique (stripe_payment_intent_id)
);

create index if not exists invoice_payment_transactions_business_idx
  on public.invoice_payment_transactions (business_id, created_at desc);
create index if not exists invoice_payment_transactions_invoice_idx
  on public.invoice_payment_transactions (business_id, invoice_id, created_at desc);
create index if not exists invoice_payment_transactions_status_idx
  on public.invoice_payment_transactions (status, created_at desc);

alter table public.customer_payments
  add column if not exists payment_source text not null default 'manual',
  add column if not exists stripe_payment_intent_id text,
  add column if not exists stripe_checkout_session_id text,
  add column if not exists invoice_payment_transaction_id uuid references public.invoice_payment_transactions(id) on delete set null,
  add column if not exists currency text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'customer_payments_payment_source_check'
      and conrelid = 'public.customer_payments'::regclass
  ) then
    alter table public.customer_payments
      add constraint customer_payments_payment_source_check
      check (payment_source in ('manual','bank_reconciliation','stripe_connect'));
  end if;
end $$;

create unique index if not exists customer_payments_stripe_payment_intent_uidx
  on public.customer_payments (stripe_payment_intent_id)
  where stripe_payment_intent_id is not null;
create unique index if not exists customer_payments_stripe_checkout_session_uidx
  on public.customer_payments (stripe_checkout_session_id)
  where stripe_checkout_session_id is not null;

alter table public.invoice_payment_settings enable row level security;
alter table public.invoice_payment_links enable row level security;
alter table public.invoice_payment_transactions enable row level security;

drop policy if exists v6181_invoice_payment_settings_read on public.invoice_payment_settings;
create policy v6181_invoice_payment_settings_read
  on public.invoice_payment_settings for select to authenticated
  using (business_id = public.current_business_id() or public.is_super_admin());

drop policy if exists v6181_invoice_payment_links_admin_read on public.invoice_payment_links;
create policy v6181_invoice_payment_links_admin_read
  on public.invoice_payment_links for select to authenticated
  using (public.is_super_admin());

drop policy if exists v6181_invoice_payment_transactions_read on public.invoice_payment_transactions;
create policy v6181_invoice_payment_transactions_read
  on public.invoice_payment_transactions for select to authenticated
  using (business_id = public.current_business_id() or public.is_super_admin());

-- Server-side entitlement check. A business-specific override wins over the
-- subscription plan. A suspended/canceled override therefore blocks a plan
-- that includes the module, while an active/trialing override grants it.
create or replace function public.v6181_invoice_payments_enabled(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public'
as $$
  select exists (
    select 1
    from public.modules m
    where m.slug = 'invoice_payments'
      and m.is_active = true
  )
  and (
    exists (
      select 1
      from public.business_modules bm
      join public.modules m on m.id = bm.module_id
      where bm.business_id = p_business_id
        and m.slug = 'invoice_payments'
        and bm.status in ('active','trialing')
        and (bm.status <> 'trialing' or bm.trial_ends_at is null or bm.trial_ends_at >= now())
    )
    or (
      not exists (
        select 1
        from public.business_modules bm
        join public.modules m on m.id = bm.module_id
        where bm.business_id = p_business_id
          and m.slug = 'invoice_payments'
      )
      and exists (
        select 1
        from public.subscriptions s
        join public.plans p on p.id = s.plan_id
        where s.business_id = p_business_id
          and (
            s.status = 'active'
            or (s.status = 'trialing' and (s.trial_ends_at is null or s.trial_ends_at >= now()))
          )
          and 'invoice_payments' = any(coalesce(p.included_modules, '{}'::text[]))
      )
    )
  );
$$;

revoke all on function public.v6181_invoice_payments_enabled(uuid) from public, anon, authenticated;
grant execute on function public.v6181_invoice_payments_enabled(uuid) to service_role;

-- Atomically convert a verified Stripe success into Frindly's existing
-- customer_payments ledger entry. The invoice row lock prevents two checkout
-- sessions from applying more than the remaining invoice balance.
create or replace function public.v6181_record_online_invoice_payment(
  p_transaction_id uuid,
  p_payment_date date default current_date,
  p_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_tx public.invoice_payment_transactions%rowtype;
  v_invoice public.invoices%rowtype;
  v_paid numeric := 0;
  v_outstanding numeric := 0;
  v_payment_id uuid;
  v_reference text;
begin
  select * into v_tx
  from public.invoice_payment_transactions
  where id = p_transaction_id
  for update;

  if v_tx.id is null then
    raise exception 'Online payment transaction not found';
  end if;

  if v_tx.status = 'succeeded' then
    return jsonb_build_object(
      'transaction_id', v_tx.id,
      'status', v_tx.status,
      'customer_payment_id', v_tx.customer_payment_id,
      'already_recorded', true
    );
  end if;

  select * into v_invoice
  from public.invoices
  where id = v_tx.invoice_id
    and business_id = v_tx.business_id
  for update;

  if v_invoice.id is null then
    update public.invoice_payment_transactions
    set status = 'needs_review', failure_reason = 'Invoice was not found for the payment.', updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;

  if coalesce(v_invoice.lifecycle_state, 'issued') = 'voided' then
    update public.invoice_payment_transactions
    set status = 'needs_review', failure_reason = 'Payment received for a voided invoice.', updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;

  select coalesce(sum(cp.amount), 0)
  into v_paid
  from public.customer_payments cp
  where cp.invoice_id = v_invoice.id;

  v_outstanding := greatest(0, coalesce(v_invoice.total, 0) - v_paid);

  if v_tx.amount > v_outstanding + 0.005 then
    update public.invoice_payment_transactions
    set status = 'needs_review',
        failure_reason = format('Payment amount %s exceeds the remaining invoice balance %s.', v_tx.amount, v_outstanding),
        updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object(
      'transaction_id', v_tx.id,
      'status', 'needs_review',
      'remaining_balance', v_outstanding
    );
  end if;

  v_reference := coalesce(nullif(trim(p_reference), ''), 'Stripe Connect online payment');
  insert into public.customer_payments (
    business_id,
    invoice_id,
    payment_date,
    amount,
    reference,
    notes,
    payment_source,
    stripe_payment_intent_id,
    stripe_checkout_session_id,
    invoice_payment_transaction_id,
    currency
  ) values (
    v_tx.business_id,
    v_tx.invoice_id,
    coalesce(p_payment_date, current_date),
    v_tx.amount,
    v_reference,
    'Recorded automatically from a verified Stripe Connect payment.',
    'stripe_connect',
    v_tx.stripe_payment_intent_id,
    v_tx.stripe_checkout_session_id,
    v_tx.id,
    upper(v_tx.currency)
  )
  returning id into v_payment_id;

  update public.invoice_payment_transactions
  set status = 'succeeded',
      customer_payment_id = v_payment_id,
      payment_date = coalesce(payment_date, now()),
      updated_at = now()
  where id = v_tx.id;

  return jsonb_build_object(
    'transaction_id', v_tx.id,
    'status', 'succeeded',
    'customer_payment_id', v_payment_id,
    'remaining_balance', greatest(0, v_outstanding - v_tx.amount)
  );
exception
  when unique_violation then
    select * into v_tx from public.invoice_payment_transactions where id = p_transaction_id;
    return jsonb_build_object(
      'transaction_id', p_transaction_id,
      'status', coalesce(v_tx.status, 'needs_review'),
      'customer_payment_id', v_tx.customer_payment_id,
      'already_recorded', true
    );
end;
$$;

revoke all on function public.v6181_record_online_invoice_payment(uuid,date,text) from public, anon, authenticated;
grant execute on function public.v6181_record_online_invoice_payment(uuid,date,text) to service_role;

commit;
