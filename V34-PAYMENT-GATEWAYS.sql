-- Invoice Manager v34
-- Secure Super Admin payment-gateway configuration.
-- Run once in Supabase SQL Editor after V33-SUBSCRIPTIONS-ADMIN-SIGNUP.sql.
-- API secrets are stored in Supabase Vault, not in browser localStorage or public tables.

create schema if not exists vault;
create extension if not exists supabase_vault with schema vault;

create table if not exists public.payment_provider_settings (
  provider text primary key,
  display_name text not null,
  enabled boolean not null default false,
  mode text not null default 'test' check (mode in ('test','live')),
  public_config jsonb not null default '{}'::jsonb,
  secret_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_provider_name_check check (provider ~ '^[a-z0-9_]+$')
);

alter table public.payment_provider_settings enable row level security;
revoke all on table public.payment_provider_settings from anon, authenticated;
grant select on table public.payment_provider_settings to service_role;

-- Seed provider records without credentials.
insert into public.payment_provider_settings(provider,display_name,enabled,mode,public_config)
values
  ('stripe','Stripe',false,'test','{}'::jsonb),
  ('paypal','PayPal',false,'test','{}'::jsonb),
  ('mollie','Mollie',false,'test','{}'::jsonb),
  ('other','Other / future gateway',false,'test','{}'::jsonb)
on conflict (provider) do nothing;

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
set search_path=public,vault
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;

  return query
  select p.provider,p.display_name,p.enabled,p.mode,p.public_config,(p.secret_id is not null),p.updated_at
  from public.payment_provider_settings p
  order by case p.provider when 'stripe' then 1 when 'paypal' then 2 when 'mollie' then 3 else 99 end,p.provider;
end $$;

create or replace function public.v34_admin_save_payment_provider(
  p_provider text,
  p_enabled boolean,
  p_mode text,
  p_display_name text,
  p_public_config jsonb,
  p_secret_patch jsonb default null
)
returns void
language plpgsql
security definer
set search_path=public,vault
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
  if v_provider not in ('stripe','paypal','mollie','other') then
    raise exception 'Unsupported payment provider';
  end if;
  if p_mode not in ('test','live') then
    raise exception 'Mode must be test or live';
  end if;
  -- v34 only has a live checkout adapter for Stripe. Other credentials can be stored safely now.
  if coalesce(p_enabled,false) and v_provider <> 'stripe' then
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

-- Server-only helper for Edge Functions. Never grant this to browser roles.
create or replace function public.v34_get_payment_provider_secret(p_provider text)
returns text
language plpgsql
security definer
set search_path=public,vault
as $$
declare
  v_secret text;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  select d.decrypted_secret into v_secret
  from public.payment_provider_settings p
  join vault.decrypted_secrets d on d.id=p.secret_id
  where p.provider=lower(trim(p_provider));

  return v_secret;
end $$;

revoke all on function public.v34_admin_get_payment_providers() from public,anon;
revoke all on function public.v34_admin_save_payment_provider(text,boolean,text,text,jsonb,jsonb) from public,anon;
revoke all on function public.v34_get_payment_provider_secret(text) from public,anon,authenticated;

grant execute on function public.v34_admin_get_payment_providers() to authenticated;
grant execute on function public.v34_admin_save_payment_provider(text,boolean,text,text,jsonb,jsonb) to authenticated;
grant execute on function public.v34_get_payment_provider_secret(text) to service_role;
