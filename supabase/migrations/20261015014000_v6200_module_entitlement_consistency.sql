-- Keep paid-plan module access from being overridden by an expired per-module trial.
-- Explicit active, suspended and canceled overrides remain authoritative.

create or replace function public.v6135_bank_module_enabled(p_business_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_status text;
  v_trial_ends_at timestamptz;
begin
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;
  if not exists(select 1 from public.modules where slug='bank_reconciliation' and is_active) then return false; end if;

  select bm.status,bm.trial_ends_at into v_status,v_trial_ends_at
  from public.business_modules bm
  join public.modules m on m.id=bm.module_id
  where bm.business_id=p_business_id and m.slug='bank_reconciliation'
  order by bm.created_at desc
  limit 1;

  if v_status in ('suspended','canceled') then return false; end if;
  if v_status='active' then return true; end if;
  if v_status='trialing' and (v_trial_ends_at is null or v_trial_ends_at>=now()) then return true; end if;

  return exists(
    select 1
    from public.subscriptions s
    join public.plans p on p.id=s.plan_id
    where s.business_id=p_business_id
      and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
      and (s.cancel_at is null or s.cancel_at>now())
      and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
      and 'bank_reconciliation'=any(coalesce(p.included_modules,'{}'::text[]))
  );
end
$function$;

create or replace function public.v6181_invoice_payments_enabled(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists(select 1 from public.modules where slug='invoice_payments' and is_active)
    and not exists(
      select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
      where bm.business_id=p_business_id and m.slug='invoice_payments' and bm.status in ('suspended','canceled')
    )
    and (
      exists(
        select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
        where bm.business_id=p_business_id and m.slug='invoice_payments'
          and (bm.status='active' or (bm.status='trialing' and (bm.trial_ends_at is null or bm.trial_ends_at>=now())))
      )
      or exists(
        select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
        where s.business_id=p_business_id
          and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
          and (s.cancel_at is null or s.cancel_at>now())
          and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
          and 'invoice_payments'=any(coalesce(p.included_modules,'{}'::text[]))
      )
    )
$function$;

create or replace function public.v6200_stock_module_enabled(p_business_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_status text;
  v_trial_ends_at timestamptz;
begin
  if public.is_super_admin() then return true; end if;
  if auth.uid() is null or p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;
  if not exists(select 1 from public.modules where slug='stock_equipment' and is_active) then return false; end if;

  select bm.status,bm.trial_ends_at into v_status,v_trial_ends_at
  from public.business_modules bm
  join public.modules m on m.id=bm.module_id
  where bm.business_id=p_business_id and m.slug='stock_equipment'
  order by bm.created_at desc
  limit 1;

  if v_status in ('suspended','canceled') then return false; end if;
  if v_status='active' then return true; end if;
  if v_status='trialing' and (v_trial_ends_at is null or v_trial_ends_at>=now()) then return true; end if;

  return exists(
    select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
    where s.business_id=p_business_id
      and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
      and (s.cancel_at is null or s.cancel_at>now())
      and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
      and 'stock_equipment'=any(coalesce(p.included_modules,'{}'::text[]))
  );
end
$function$;

create or replace function public.se_require_access(p_business_id uuid, p_write boolean default true)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
begin
  if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
    raise exception 'No access to this business';
  end if;
  select m.role into v_role from public.business_memberships m
  where m.business_id=p_business_id and m.user_id=auth.uid() and m.status='active';
  if v_role is null then raise exception 'Active membership required'; end if;
  if p_write then
    if not public.v6147_can_write_area(p_business_id,'expenses') then
      raise exception 'Expense editor access and an active subscription are required';
    end if;
    if not public.v6200_stock_module_enabled(p_business_id) then
      raise exception 'Stock & Equipment is not enabled for this business';
    end if;
  end if;
end
$function$;

-- v6190_review_purchase is large and contains one inline copy of the old Stock entitlement rule.
-- Replace only that statement, retaining the rest of the function byte-for-byte.
do $migration$
declare
  v_sql text;
  v_start integer;
  v_end_relative integer;
  v_after integer;
  v_start_marker constant text := ' select exists(select 1 from public.modules m where m.slug=''stock_equipment''';
  v_end_marker constant text := ' into v_stock_enabled;';
begin
  select pg_get_functiondef(p.oid) into v_sql
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='v6190_review_purchase' and p.prokind='f'
  limit 1;
  if v_sql is null then raise exception 'v6190_review_purchase was not found'; end if;
  v_start := strpos(v_sql,v_start_marker);
  if v_start=0 then raise exception 'Stock entitlement statement start was not found in v6190_review_purchase'; end if;
  v_end_relative := strpos(substr(v_sql,v_start),v_end_marker);
  if v_end_relative=0 then raise exception 'Stock entitlement statement end was not found in v6190_review_purchase'; end if;
  v_after := v_start+v_end_relative-1+length(v_end_marker);
  v_sql := substr(v_sql,1,v_start-1)
    || ' select public.v6200_stock_module_enabled(p_business_id) into v_stock_enabled;'
    || substr(v_sql,v_after);
  execute v_sql;
end
$migration$;

create or replace function public.v55_payroll_access(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else public.v6147_can_read_area(p_business_id,'payroll')
      and exists(select 1 from public.modules where slug='payroll' and is_active)
      and not exists(
        select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
        where bm.business_id=p_business_id and m.slug='payroll' and bm.status in ('suspended','canceled')
      )
      and (
        exists(
          select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
          where bm.business_id=p_business_id and m.slug='payroll'
            and (bm.status='active' or (bm.status='trialing' and (bm.trial_ends_at is null or bm.trial_ends_at>=now())))
        )
        or exists(
          select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
          where s.business_id=p_business_id
            and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
            and (s.cancel_at is null or s.cancel_at>now())
            and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
            and 'payroll'=any(coalesce(p.included_modules,'{}'::text[]))
        )
      )
  end
$function$;

create or replace function public.v58_financials_access(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else public.v6147_can_read_area(p_business_id,'financials')
      and exists(select 1 from public.modules where slug='financials' and is_active)
      and not exists(
        select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
        where bm.business_id=p_business_id and m.slug='financials' and bm.status in ('suspended','canceled')
      )
      and (
        exists(
          select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
          where bm.business_id=p_business_id and m.slug='financials'
            and (bm.status='active' or (bm.status='trialing' and (bm.trial_ends_at is null or bm.trial_ends_at>=now())))
        )
        or exists(
          select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
          where s.business_id=p_business_id
            and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
            and (s.cancel_at is null or s.cancel_at>now())
            and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
            and 'financials'=any(coalesce(p.included_modules,'{}'::text[]))
        )
      )
  end
$function$;

comment on function public.v6200_stock_module_enabled(uuid) is
  'Effective Stock & Equipment entitlement. Expired module trials fall back to an eligible active plan; explicit suspension or cancellation still denies access.';

revoke all on function public.v6200_stock_module_enabled(uuid) from public;
revoke execute on function public.v6200_stock_module_enabled(uuid) from anon;
grant execute on function public.v6200_stock_module_enabled(uuid) to authenticated, service_role;
