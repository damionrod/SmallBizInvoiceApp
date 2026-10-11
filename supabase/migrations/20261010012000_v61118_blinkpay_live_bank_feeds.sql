-- v61.118: BlinkPay live bank feeds foundation.
-- Adds a plan-gated live_bank_feeds module and read-only feed state.
-- Existing CSV bank import and reconciliation behaviour is unchanged.

do $$
begin
  if to_regclass('public.modules') is not null then
    insert into public.modules(name, slug, description, monthly_price, stripe_price_id, is_active)
    values (
      'Live Bank Feeds',
      'live_bank_feeds',
      'Connect read-only BlinkPay bank feeds and sync bank transactions into Bank Reconciliation.',
      0,
      null,
      true
    )
    on conflict (slug) do update set
      name = excluded.name,
      description = excluded.description,
      is_active = true;
  end if;
end $$;

do $$
begin
  if to_regclass('public.public_plan_features') is not null and to_regclass('public.modules') is not null then
    update public.public_plan_features
       set title = 'Live bank feeds',
           description = 'Connect supported NZ bank accounts through BlinkPay and sync transactions into reconciliation.',
           feature_group = 'Banking',
           module_slug = 'live_bank_feeds',
           value_source = 'module',
           is_public = true,
           sort_order = 165
     where feature_key = 'live_bank_feeds';

    if not found then
      insert into public.public_plan_features(
        feature_key, title, description, feature_group, module_slug, value_source, is_public, sort_order
      )
      values (
        'live_bank_feeds',
        'Live bank feeds',
        'Connect supported NZ bank accounts through BlinkPay and sync transactions into reconciliation.',
        'Banking',
        'live_bank_feeds',
        'module',
        true,
        165
      );
    end if;
  end if;
end $$;

create table if not exists public.blinkpay_feed_connections (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider text not null default 'blinkpay',
  environment text not null default 'sandbox',
  status text not null default 'pending',
  bank_name text,
  consent_id text,
  consent_state text,
  scopes text[] not null default '{}',
  access_token text,
  refresh_token text,
  token_expires_at timestamptz,
  consent_expires_at timestamptz,
  last_sync_at timestamptz,
  last_sync_status text,
  last_sync_message text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint blinkpay_feed_connections_provider_chk check (provider in ('blinkpay')),
  constraint blinkpay_feed_connections_environment_chk check (environment in ('sandbox','production')),
  constraint blinkpay_feed_connections_status_chk check (status in ('pending','active','needs_reconnect','disconnected','error'))
);

create index if not exists blinkpay_feed_connections_business_idx
  on public.blinkpay_feed_connections(business_id, status, created_at desc);

create unique index if not exists blinkpay_feed_connections_state_uq
  on public.blinkpay_feed_connections(consent_state)
  where consent_state is not null;

create table if not exists public.blinkpay_feed_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  connection_id uuid not null references public.blinkpay_feed_connections(id) on delete cascade,
  bank_account_id uuid references public.bank_accounts(id) on delete set null,
  provider_account_id text not null,
  account_name text,
  account_number text,
  currency text not null default 'NZD',
  account_type text,
  status text not null default 'active',
  last_balance numeric(14,2),
  last_balance_at timestamptz,
  last_synced_at timestamptz,
  raw_account jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint blinkpay_feed_accounts_status_chk check (status in ('active','archived','error')),
  constraint blinkpay_feed_accounts_currency_len check (char_length(currency) between 3 and 3)
);

create unique index if not exists blinkpay_feed_accounts_provider_uq
  on public.blinkpay_feed_accounts(connection_id, provider_account_id);

create index if not exists blinkpay_feed_accounts_business_idx
  on public.blinkpay_feed_accounts(business_id, bank_account_id);

create table if not exists public.blinkpay_feed_sync_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  connection_id uuid references public.blinkpay_feed_connections(id) on delete set null,
  status text not null default 'running',
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  imported_count integer not null default 0,
  duplicate_count integer not null default 0,
  account_count integer not null default 0,
  error_message text,
  created_by uuid references auth.users(id) on delete set null,
  constraint blinkpay_feed_sync_runs_status_chk check (status in ('running','completed','failed','skipped'))
);

create index if not exists blinkpay_feed_sync_runs_business_idx
  on public.blinkpay_feed_sync_runs(business_id, started_at desc);

alter table public.bank_transactions
  add column if not exists source_provider text not null default 'csv',
  add column if not exists external_transaction_id text,
  add column if not exists external_account_id text,
  add column if not exists source_payload jsonb not null default '{}'::jsonb,
  add column if not exists pending_status text;

create unique index if not exists bank_transactions_external_provider_uq
  on public.bank_transactions(business_id, bank_account_id, source_provider, external_transaction_id)
  where external_transaction_id is not null;

alter table public.blinkpay_feed_connections enable row level security;
alter table public.blinkpay_feed_accounts enable row level security;
alter table public.blinkpay_feed_sync_runs enable row level security;

revoke all on public.blinkpay_feed_connections from public, anon, authenticated;
revoke all on public.blinkpay_feed_accounts from public, anon, authenticated;
revoke all on public.blinkpay_feed_sync_runs from public, anon, authenticated;
grant select, insert, update, delete on public.blinkpay_feed_connections to service_role;
grant select, insert, update, delete on public.blinkpay_feed_accounts to service_role;
grant select, insert, update, delete on public.blinkpay_feed_sync_runs to service_role;

drop policy if exists blinkpay_feed_connections_service_only on public.blinkpay_feed_connections;
create policy blinkpay_feed_connections_service_only on public.blinkpay_feed_connections
for all to service_role using (true) with check (true);

drop policy if exists blinkpay_feed_accounts_service_only on public.blinkpay_feed_accounts;
create policy blinkpay_feed_accounts_service_only on public.blinkpay_feed_accounts
for all to service_role using (true) with check (true);

drop policy if exists blinkpay_feed_sync_runs_service_only on public.blinkpay_feed_sync_runs;
create policy blinkpay_feed_sync_runs_service_only on public.blinkpay_feed_sync_runs
for all to service_role using (true) with check (true);

create or replace function public.v61118_live_bank_feeds_enabled(p_business_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select true
    from public.business_modules bm
    join public.modules m on m.id = bm.module_id
    where bm.business_id = p_business_id
      and m.slug = 'live_bank_feeds'
      and m.is_active = true
      and bm.status in ('active','trialing')
      and (bm.trial_ends_at is null or bm.trial_ends_at >= now())
    limit 1
  ), false)
  or coalesce((
    select true
    from public.profiles p
    where p.id = auth.uid()
      and coalesce(p.is_super_admin,false) = true
    limit 1
  ), false)
  or coalesce((
    select true
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
    join public.modules m on m.slug = 'live_bank_feeds'
    where s.business_id = p_business_id
      and s.status in ('active','trialing')
      and (s.trial_ends_at is null or s.trial_ends_at >= now())
      and m.is_active = true
      and to_jsonb(p.included_modules) ? 'live_bank_feeds'
    limit 1
  ), false);
$$;

revoke execute on function public.v61118_live_bank_feeds_enabled(uuid) from public, anon;
grant execute on function public.v61118_live_bank_feeds_enabled(uuid) to authenticated, service_role;
