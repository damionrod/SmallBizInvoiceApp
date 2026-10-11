-- v61.122: Make Akahu bank feeds a separately gated module.
-- BlinkPay remains behind live_bank_feeds; Akahu is now controlled by akahu_bank_feeds.

do $$
begin
  if to_regclass('public.modules') is not null then
    insert into public.modules(name, slug, description, monthly_price, stripe_price_id, is_active)
    values (
      'Akahu Bank Feeds',
      'akahu_bank_feeds',
      'Connect read-only Akahu bank feeds and sync bank transactions into Bank Reconciliation.',
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
       set title = 'Akahu bank feeds',
           description = 'Connect supported NZ bank accounts through Akahu and sync transactions into reconciliation.',
           feature_group = 'Banking',
           module_slug = 'akahu_bank_feeds',
           value_source = 'module',
           is_public = true,
           sort_order = 166
     where feature_key = 'akahu_bank_feeds';

    if not found then
      insert into public.public_plan_features(
        feature_key, title, description, feature_group, module_slug, value_source, is_public, sort_order
      )
      values (
        'akahu_bank_feeds',
        'Akahu bank feeds',
        'Connect supported NZ bank accounts through Akahu and sync transactions into reconciliation.',
        'Banking',
        'akahu_bank_feeds',
        'module',
        true,
        166
      );
    end if;
  end if;
end $$;

create or replace function public.v61122_akahu_bank_feeds_enabled(p_business_id uuid)
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
      and m.slug = 'akahu_bank_feeds'
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
    join public.modules m on m.slug = 'akahu_bank_feeds'
    where s.business_id = p_business_id
      and s.status in ('active','trialing')
      and (s.trial_ends_at is null or s.trial_ends_at >= now())
      and m.is_active = true
      and to_jsonb(p.included_modules) ? 'akahu_bank_feeds'
    limit 1
  ), false);
$$;

revoke execute on function public.v61122_akahu_bank_feeds_enabled(uuid) from public, anon;
grant execute on function public.v61122_akahu_bank_feeds_enabled(uuid) to authenticated, service_role;
