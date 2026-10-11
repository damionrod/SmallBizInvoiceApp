-- v61.119: Allow Super Admin to manage BlinkPay platform credentials.
-- Reuses the existing payment_provider_settings + Supabase Vault pattern used by Stripe.

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
    when 'paypal' then 3
    when 'mollie' then 4
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
  if v_provider not in ('stripe','blinkpay','paypal','mollie','other') then
    raise exception 'Unsupported payment provider';
  end if;
  if p_mode not in ('test','live') then
    raise exception 'Mode must be test or live';
  end if;
  -- Stripe and BlinkPay have active adapters. Other credentials can be stored safely now.
  if coalesce(p_enabled,false) and v_provider not in ('stripe','blinkpay') then
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
  'blinkpay',
  'BlinkPay',
  false,
  'test',
  jsonb_build_object(
    'client_id', '',
    'auth_url', '',
    'token_url', '',
    'data_base_url', '',
    'scopes', 'accounts balances transactions statements',
    'accounts_path', '/accounts',
    'transactions_path', '/accounts/{accountId}/transactions',
    'redirect_uri', 'https://oxsbzytwbphagcbilxud.supabase.co/functions/v1/blinkpay-bank-feeds?action=callback'
  ),
  now()
)
on conflict(provider) do nothing;
