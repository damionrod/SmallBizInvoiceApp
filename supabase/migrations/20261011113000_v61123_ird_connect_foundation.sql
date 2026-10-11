-- v61.123: IRD Connect foundation module.
-- Adds module gating plus review/export tracking for IRD-ready filing packages.
-- This does not enable live IRD gateway submission.

do $$
begin
  if to_regclass('public.modules') is not null then
    insert into public.modules(name, slug, description, monthly_price, stripe_price_id, is_active)
    values (
      'IRD Connect',
      'ird_connect',
      'Prepare IRD-ready GST and payday filing packages, with live gateway submission reserved for approved IRD provider access.',
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
       set title = 'IRD Connect',
           description = 'Prepare IRD-ready GST and payday filing packages, record exports, and track myIR filing references.',
           feature_group = 'Tax',
           module_slug = 'ird_connect',
           value_source = 'module',
           is_public = true,
           sort_order = 167
     where feature_key = 'ird_connect';

    if not found then
      insert into public.public_plan_features(
        feature_key, title, description, feature_group, module_slug, value_source, is_public, sort_order
      )
      values (
        'ird_connect',
        'IRD Connect',
        'Prepare IRD-ready GST and payday filing packages, record exports, and track myIR filing references.',
        'Tax',
        'ird_connect',
        'module',
        true,
        167
      );
    end if;
  end if;
end $$;

create table if not exists public.ird_connect_settings (
  provider text primary key default 'ird',
  enabled boolean not null default false,
  mode text not null default 'manual',
  public_config jsonb not null default '{}'::jsonb,
  notes text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  constraint ird_connect_settings_provider_chk check (provider = 'ird'),
  constraint ird_connect_settings_mode_chk check (mode in ('manual','test','live'))
);

insert into public.ird_connect_settings(provider, enabled, mode, public_config, notes, updated_at)
values (
  'ird',
  false,
  'manual',
  jsonb_build_object(
    'gateway_status', 'not_connected',
    'requires_digital_service_provider_approval', true,
    'supports', jsonb_build_array('gst_return_package','payday_filing_package')
  ),
  'Live IRD gateway submission requires IRD Digital Service Provider approval, certificates and final endpoint configuration.',
  now()
)
on conflict(provider) do nothing;

create table if not exists public.ird_filing_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  filing_type text not null,
  source_table text,
  source_id uuid,
  period_start date not null,
  period_end date not null,
  due_date date,
  status text not null default 'draft',
  filing_method text not null default 'manual',
  package_payload jsonb not null default '{}'::jsonb,
  validation_summary jsonb not null default '{}'::jsonb,
  file_name text,
  file_hash text,
  ird_reference text,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  constraint ird_filing_batches_type_chk check (filing_type in ('gst_return','payday_filing','aim_statement','income_tax_return')),
  constraint ird_filing_batches_status_chk check (status in ('draft','reviewed','exported','filed_in_myir','gateway_pending','gateway_accepted','gateway_rejected','cancelled')),
  constraint ird_filing_batches_method_chk check (filing_method in ('manual','file_upload','gateway')),
  constraint ird_filing_batches_period_chk check (period_start <= period_end)
);

create index if not exists ird_filing_batches_business_idx
  on public.ird_filing_batches(business_id, filing_type, period_start desc, created_at desc);

create table if not exists public.ird_filing_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  batch_id uuid not null references public.ird_filing_batches(id) on delete cascade,
  event_type text not null,
  status text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  constraint ird_filing_events_type_chk check (event_type in ('created','reviewed','exported','filed_in_myir','gateway_status','note','cancelled'))
);

create index if not exists ird_filing_events_business_idx
  on public.ird_filing_events(business_id, batch_id, created_at desc);

alter table public.ird_connect_settings enable row level security;
alter table public.ird_filing_batches enable row level security;
alter table public.ird_filing_events enable row level security;

revoke all on public.ird_connect_settings from public, anon, authenticated;
revoke all on public.ird_filing_batches from public, anon, authenticated;
revoke all on public.ird_filing_events from public, anon, authenticated;

grant select on public.ird_connect_settings to authenticated;
grant select on public.ird_filing_batches to authenticated;
grant select on public.ird_filing_events to authenticated;
grant select, insert, update, delete on public.ird_connect_settings to service_role;
grant select, insert, update, delete on public.ird_filing_batches to service_role;
grant select, insert, update, delete on public.ird_filing_events to service_role;

drop policy if exists ird_connect_settings_super_admin on public.ird_connect_settings;
create policy ird_connect_settings_super_admin on public.ird_connect_settings
for select to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and coalesce(p.is_super_admin,false) = true
  )
);

drop policy if exists ird_filing_batches_select_business on public.ird_filing_batches;
create policy ird_filing_batches_select_business on public.ird_filing_batches
for select to authenticated
using (business_id = public.current_business_id());

drop policy if exists ird_filing_events_select_business on public.ird_filing_events;
create policy ird_filing_events_select_business on public.ird_filing_events
for select to authenticated
using (business_id = public.current_business_id());

create or replace function public.v61123_ird_connect_enabled(p_business_id uuid)
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
      and m.slug = 'ird_connect'
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
    join public.modules m on m.slug = 'ird_connect'
    where s.business_id = p_business_id
      and s.status in ('active','trialing')
      and (s.trial_ends_at is null or s.trial_ends_at >= now())
      and m.is_active = true
      and to_jsonb(p.included_modules) ? 'ird_connect'
    limit 1
  ), false);
$$;

revoke execute on function public.v61123_ird_connect_enabled(uuid) from public, anon;
grant execute on function public.v61123_ird_connect_enabled(uuid) to authenticated, service_role;

create or replace function public.v61123_create_ird_filing_batch(
  p_filing_type text,
  p_source_table text,
  p_source_id uuid,
  p_period_start date,
  p_period_end date,
  p_due_date date default null,
  p_status text default 'exported',
  p_filing_method text default 'manual',
  p_package_payload jsonb default '{}'::jsonb,
  p_validation_summary jsonb default '{}'::jsonb,
  p_file_name text default null,
  p_file_hash text default null,
  p_ird_reference text default null,
  p_notes text default null
)
returns public.ird_filing_batches
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_row public.ird_filing_batches;
begin
  if v_uid is null or v_bid is null then
    raise exception 'Business access required';
  end if;
  if not public.v6147_can_write_area(v_bid,'financials') then
    raise exception 'Financials write access denied';
  end if;
  if not public.v61123_ird_connect_enabled(v_bid) then
    raise exception 'IRD Connect is not enabled for this business';
  end if;
  if p_period_start is null or p_period_end is null or p_period_start > p_period_end then
    raise exception 'Choose a valid filing period';
  end if;

  insert into public.ird_filing_batches(
    business_id, filing_type, source_table, source_id, period_start, period_end, due_date,
    status, filing_method, package_payload, validation_summary, file_name, file_hash,
    ird_reference, notes, created_by, updated_by
  )
  values (
    v_bid, p_filing_type, nullif(trim(coalesce(p_source_table,'')),''), p_source_id,
    p_period_start, p_period_end, p_due_date, coalesce(p_status,'exported'),
    coalesce(p_filing_method,'manual'), coalesce(p_package_payload,'{}'::jsonb),
    coalesce(p_validation_summary,'{}'::jsonb), nullif(trim(coalesce(p_file_name,'')),''),
    nullif(trim(coalesce(p_file_hash,'')),''), nullif(trim(coalesce(p_ird_reference,'')),''),
    nullif(trim(coalesce(p_notes,'')),''), v_uid, v_uid
  )
  returning * into v_row;

  insert into public.ird_filing_events(business_id, batch_id, event_type, status, details, created_by)
  values (
    v_bid,
    v_row.id,
    case v_row.status
      when 'filed_in_myir' then 'filed_in_myir'
      when 'reviewed' then 'reviewed'
      when 'cancelled' then 'cancelled'
      else 'exported'
    end,
    v_row.status,
    jsonb_build_object(
      'filing_type', v_row.filing_type,
      'period_start', v_row.period_start,
      'period_end', v_row.period_end,
      'source_table', v_row.source_table,
      'source_id', v_row.source_id,
      'file_name', v_row.file_name,
      'ird_reference', v_row.ird_reference
    ),
    v_uid
  );

  return v_row;
end $$;

revoke execute on function public.v61123_create_ird_filing_batch(text,text,uuid,date,date,date,text,text,jsonb,jsonb,text,text,text,text) from public, anon;
grant execute on function public.v61123_create_ird_filing_batch(text,text,uuid,date,date,date,text,text,jsonb,jsonb,text,text,text,text) to authenticated;
