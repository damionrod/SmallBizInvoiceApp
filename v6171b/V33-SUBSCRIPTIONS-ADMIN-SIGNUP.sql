-- Invoice Manager v33
-- Super Admin subscription controls + subscription-plan management hardening.
-- Run this file once in Supabase SQL Editor before testing v33 admin changes.

create or replace function public.v33_admin_set_subscription(
  p_business_id uuid,
  p_plan_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  existing_id uuid;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if p_status not in ('trialing','active','past_due','suspended','canceled') then
    raise exception 'Invalid subscription status';
  end if;
  if not exists(select 1 from public.businesses where id=p_business_id) then
    raise exception 'Business not found';
  end if;
  if not exists(select 1 from public.plans where id=p_plan_id) then
    raise exception 'Plan not found';
  end if;

  select id into existing_id from public.subscriptions where business_id=p_business_id;
  if existing_id is null then
    insert into public.subscriptions(
      business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end,updated_at
    ) values (
      p_business_id,p_plan_id,p_status,
      case when p_status='trialing' then now()+interval '14 days' else null end,
      now(),
      case when p_status='trialing' then now()+interval '14 days' else now()+interval '1 month' end,
      now()
    );
  else
    update public.subscriptions
       set plan_id=p_plan_id,
           status=p_status,
           trial_ends_at=case
             when p_status='trialing' then coalesce(trial_ends_at,now()+interval '14 days')
             else null
           end,
           updated_at=now()
     where business_id=p_business_id;
  end if;

  update public.businesses
     set status=case
       when p_status='suspended' then 'suspended'
       when p_status='canceled' then 'closed'
       else 'active'
     end,
     updated_at=now()
   where id=p_business_id;
end $$;

create or replace function public.v33_admin_set_suspension(
  p_business_id uuid,
  p_suspend boolean
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  next_status text;
  plan_slug text;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if not exists(select 1 from public.businesses where id=p_business_id) then
    raise exception 'Business not found';
  end if;

  if p_suspend then
    next_status := 'suspended';
  else
    select p.slug into plan_slug
      from public.subscriptions s
      join public.plans p on p.id=s.plan_id
     where s.business_id=p_business_id;
    next_status := case when plan_slug='trial' then 'trialing' else 'active' end;
  end if;

  update public.subscriptions
     set status=next_status,updated_at=now()
   where business_id=p_business_id;

  if not found then
    raise exception 'Subscription not found for this business';
  end if;

  update public.businesses
     set status=case when p_suspend then 'suspended' else 'active' end,
         updated_at=now()
   where id=p_business_id;
end $$;

create or replace function public.v33_admin_extend_trial(
  p_business_id uuid,
  p_days integer default 14
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  new_end timestamptz;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if p_days < 1 or p_days > 365 then
    raise exception 'Trial extension must be between 1 and 365 days';
  end if;

  new_end := now() + make_interval(days=>p_days);
  update public.subscriptions
     set status='trialing',
         trial_ends_at=new_end,
         current_period_start=now(),
         current_period_end=new_end,
         updated_at=now()
   where business_id=p_business_id;
  if not found then
    raise exception 'Subscription not found for this business';
  end if;

  update public.businesses set status='active',updated_at=now() where id=p_business_id;
end $$;

create or replace function public.v33_admin_upsert_plan(
  p_id uuid,
  p_slug text,
  p_name text,
  p_description text,
  p_monthly_price numeric,
  p_invoice_limit integer,
  p_included_modules text[],
  p_stripe_price_id text,
  p_is_public boolean,
  p_sort_order integer
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  result_id uuid;
  clean_slug text;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  clean_slug := lower(trim(p_slug));
  if clean_slug is null or clean_slug='' or p_name is null or trim(p_name)='' then
    raise exception 'Plan name and slug are required';
  end if;
  if p_monthly_price < 0 then
    raise exception 'Monthly price cannot be negative';
  end if;
  if p_invoice_limit is not null and p_invoice_limit < 0 then
    raise exception 'Invoice limit cannot be negative';
  end if;

  if p_id is null then
    insert into public.plans(
      slug,name,description,monthly_price,invoice_limit,included_modules,
      stripe_price_id,is_public,sort_order,updated_at
    ) values (
      clean_slug,trim(p_name),nullif(trim(coalesce(p_description,'')),''),coalesce(p_monthly_price,0),
      p_invoice_limit,coalesce(p_included_modules,array['invoice_manager']::text[]),
      nullif(trim(coalesce(p_stripe_price_id,'')),''),coalesce(p_is_public,true),coalesce(p_sort_order,0),now()
    ) returning id into result_id;
  else
    update public.plans
       set slug=clean_slug,
           name=trim(p_name),
           description=nullif(trim(coalesce(p_description,'')),''),
           monthly_price=coalesce(p_monthly_price,0),
           invoice_limit=p_invoice_limit,
           included_modules=coalesce(p_included_modules,array['invoice_manager']::text[]),
           stripe_price_id=nullif(trim(coalesce(p_stripe_price_id,'')),''),
           is_public=coalesce(p_is_public,true),
           sort_order=coalesce(p_sort_order,0),
           updated_at=now()
     where id=p_id
     returning id into result_id;
    if result_id is null then raise exception 'Plan not found'; end if;
  end if;
  return result_id;
end $$;

revoke all on function public.v33_admin_set_subscription(uuid,uuid,text) from public, anon;
revoke all on function public.v33_admin_set_suspension(uuid,boolean) from public, anon;
revoke all on function public.v33_admin_extend_trial(uuid,integer) from public, anon;
revoke all on function public.v33_admin_upsert_plan(uuid,text,text,text,numeric,integer,text[],text,boolean,integer) from public, anon;

grant execute on function public.v33_admin_set_subscription(uuid,uuid,text) to authenticated;
grant execute on function public.v33_admin_set_suspension(uuid,boolean) to authenticated;
grant execute on function public.v33_admin_extend_trial(uuid,integer) to authenticated;
grant execute on function public.v33_admin_upsert_plan(uuid,text,text,text,numeric,integer,text[],text,boolean,integer) to authenticated;
