-- v61.121: Akahu live bank feeds foundation.
-- Adds Akahu as a second provider under the existing live_bank_feeds module.
-- Existing BlinkPay, CSV import and reconciliation behaviour is unchanged.

create or replace function public.v34_admin_get_payment_providers()
returns table(
  provider text,
  display_name text,
  enabled boolean,
  mode text,
  public_config jsonb,
  has_secret boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, vault
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;

  return query
  select p.provider,p.display_name,p.enabled,p.mode,p.public_config,(p.secret_id is not null),p.updated_at
  from public.payment_provider_settings p
  order by case p.provider
    when 'stripe' then 1
    when 'blinkpay' then 2
    when 'akahu' then 3
    when 'paypal' then 4
    when 'mollie' then 5
    else 99
  end,p.provider;
end $$;

create or replace function public.v34_admin_save_payment_provider(
  p_provider text,
  p_enabled boolean,
  p_mode text,
  p_display_name text,
  p_public_config jsonb,
  p_secret_patch jsonb default null::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_provider text := lower(trim(coalesce(p_provider,'')));
  v_secret_id uuid;
  v_existing_secret jsonb := '{}'::jsonb;
  v_merged_secret jsonb := '{}'::jsonb;
  v_secret_name text;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if v_provider not in ('stripe','blinkpay','akahu','paypal','mollie','other') then
    raise exception 'Unsupported payment provider';
  end if;
  if p_mode not in ('test','live') then
    raise exception 'Mode must be test or live';
  end if;
  -- Stripe, BlinkPay and Akahu have active adapters. Other credentials can be stored safely now.
  if coalesce(p_enabled,false) and v_provider not in ('stripe','blinkpay','akahu') then
    raise exception '% checkout is not enabled in this version yet', initcap(v_provider);
  end if;

  select secret_id into v_secret_id
  from public.payment_provider_settings
  where provider=v_provider;

  v_secret_name := 'smallbiz_payment_' || v_provider;
  if v_secret_id is null then
    select id into v_secret_id from vault.secrets where name=v_secret_name limit 1;
  end if;

  if p_secret_patch is not null and p_secret_patch <> '{}'::jsonb then
    if v_secret_id is not null then
      begin
        select decrypted_secret::jsonb into v_existing_secret
        from vault.decrypted_secrets where id=v_secret_id;
      exception when others then
        v_existing_secret := '{}'::jsonb;
      end;
    end if;
    v_merged_secret := coalesce(v_existing_secret,'{}'::jsonb) || p_secret_patch;

    if v_secret_id is null then
      select vault.create_secret(v_merged_secret::text,v_secret_name,'SaaS payment gateway credentials for '||v_provider)
      into v_secret_id;
    else
      perform vault.update_secret(v_secret_id,v_merged_secret::text,v_secret_name,'SaaS payment gateway credentials for '||v_provider);
    end if;
  end if;

  insert into public.payment_provider_settings(provider,display_name,enabled,mode,public_config,secret_id,updated_at)
  values(v_provider,coalesce(nullif(trim(p_display_name),''),initcap(v_provider)),coalesce(p_enabled,false),p_mode,coalesce(p_public_config,'{}'::jsonb),v_secret_id,now())
  on conflict(provider) do update set
    display_name=excluded.display_name,
    enabled=excluded.enabled,
    mode=excluded.mode,
    public_config=excluded.public_config,
    secret_id=coalesce(excluded.secret_id,public.payment_provider_settings.secret_id),
    updated_at=now();
end $$;

insert into public.payment_provider_settings(provider, display_name, enabled, mode, public_config, updated_at)
values (
  'akahu',
  'Akahu',
  false,
  'test',
  jsonb_build_object(
    'app_token', '',
    'auth_url', 'https://oauth.akahu.nz',
    'token_url', 'https://oauth.akahu.nz/token',
    'api_base_url', 'https://api.akahu.io/v1',
    'scopes', 'ENDURING_CONSENT ACCOUNTS TRANSACTIONS',
    'accounts_path', '/accounts',
    'transactions_path', '/transactions',
    'revoke_path', '/token',
    'sync_start_days', '90',
    'redirect_uri', 'https://oxsbzytwbphagcbilxud.supabase.co/functions/v1/akahu-bank-feeds?action=callback'
  ),
  now()
)
on conflict(provider) do nothing;

create table if not exists public.akahu_feed_connections (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider text not null default 'akahu',
  environment text not null default 'sandbox',
  status text not null default 'pending',
  akahu_user_id text,
  consent_state text,
  scopes text[] not null default '{}',
  access_token text,
  refresh_token text,
  token_expires_at timestamptz,
  last_sync_at timestamptz,
  last_sync_status text,
  last_sync_message text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint akahu_feed_connections_provider_chk check (provider in ('akahu')),
  constraint akahu_feed_connections_environment_chk check (environment in ('sandbox','production')),
  constraint akahu_feed_connections_status_chk check (status in ('pending','active','needs_reconnect','disconnected','error'))
);

create index if not exists akahu_feed_connections_business_idx
  on public.akahu_feed_connections(business_id, status, created_at desc);

create unique index if not exists akahu_feed_connections_state_uq
  on public.akahu_feed_connections(consent_state)
  where consent_state is not null;

create table if not exists public.akahu_feed_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  connection_id uuid not null references public.akahu_feed_connections(id) on delete cascade,
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
  constraint akahu_feed_accounts_status_chk check (status in ('active','archived','error','inactive')),
  constraint akahu_feed_accounts_currency_len check (char_length(currency) between 3 and 3)
);

create unique index if not exists akahu_feed_accounts_provider_uq
  on public.akahu_feed_accounts(connection_id, provider_account_id);

create index if not exists akahu_feed_accounts_business_idx
  on public.akahu_feed_accounts(business_id, bank_account_id);

create table if not exists public.akahu_feed_sync_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  connection_id uuid references public.akahu_feed_connections(id) on delete set null,
  status text not null default 'running',
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  imported_count integer not null default 0,
  duplicate_count integer not null default 0,
  account_count integer not null default 0,
  error_message text,
  created_by uuid references auth.users(id) on delete set null,
  constraint akahu_feed_sync_runs_status_chk check (status in ('running','completed','failed','skipped'))
);

create index if not exists akahu_feed_sync_runs_business_idx
  on public.akahu_feed_sync_runs(business_id, started_at desc);

alter table public.akahu_feed_connections enable row level security;
alter table public.akahu_feed_accounts enable row level security;
alter table public.akahu_feed_sync_runs enable row level security;

revoke all on public.akahu_feed_connections from public, anon, authenticated;
revoke all on public.akahu_feed_accounts from public, anon, authenticated;
revoke all on public.akahu_feed_sync_runs from public, anon, authenticated;
grant select, insert, update, delete on public.akahu_feed_connections to service_role;
grant select, insert, update, delete on public.akahu_feed_accounts to service_role;
grant select, insert, update, delete on public.akahu_feed_sync_runs to service_role;

drop policy if exists akahu_feed_connections_service_only on public.akahu_feed_connections;
create policy akahu_feed_connections_service_only on public.akahu_feed_connections
for all to service_role using (true) with check (true);

drop policy if exists akahu_feed_accounts_service_only on public.akahu_feed_accounts;
create policy akahu_feed_accounts_service_only on public.akahu_feed_accounts
for all to service_role using (true) with check (true);

drop policy if exists akahu_feed_sync_runs_service_only on public.akahu_feed_sync_runs;
create policy akahu_feed_sync_runs_service_only on public.akahu_feed_sync_runs
for all to service_role using (true) with check (true);
