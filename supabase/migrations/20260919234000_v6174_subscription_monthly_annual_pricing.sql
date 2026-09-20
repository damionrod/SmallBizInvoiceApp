alter table public.plans
  add column if not exists annual_price numeric null,
  add column if not exists annual_saving_message text null,
  add column if not exists stripe_annual_price_id text null;

alter table public.subscriptions
  add column if not exists billing_interval text not null default 'monthly';

do $$ begin
  if not exists (select 1 from pg_constraint where conname='subscriptions_billing_interval_check' and conrelid='public.subscriptions'::regclass) then
    alter table public.subscriptions add constraint subscriptions_billing_interval_check check (billing_interval in ('monthly','annual'));
  end if;
end $$;

create or replace function public.v6174_admin_upsert_plan(p_id uuid,p_slug text,p_name text,p_description text,p_monthly_price numeric,p_annual_price numeric,p_annual_saving_message text,p_invoice_limit integer,p_included_modules text[],p_stripe_monthly_price_id text,p_stripe_annual_price_id text,p_is_public boolean,p_sort_order integer) returns uuid
language plpgsql security definer set search_path='public' as $$
declare result_id uuid; clean_slug text;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  clean_slug:=lower(trim(p_slug));
  if clean_slug is null or clean_slug='' or p_name is null or trim(p_name)='' then raise exception 'Plan name and slug are required'; end if;
  if coalesce(p_monthly_price,0)<0 then raise exception 'Monthly price cannot be negative'; end if;
  if p_annual_price is not null and p_annual_price<0 then raise exception 'Annual price cannot be negative'; end if;
  if p_invoice_limit is not null and p_invoice_limit<0 then raise exception 'Invoice limit cannot be negative'; end if;
  if p_id is null then
    insert into public.plans(slug,name,description,monthly_price,annual_price,annual_saving_message,invoice_limit,included_modules,stripe_price_id,stripe_annual_price_id,is_public,sort_order,updated_at)
    values(clean_slug,trim(p_name),nullif(trim(coalesce(p_description,'')),''),coalesce(p_monthly_price,0),p_annual_price,nullif(trim(coalesce(p_annual_saving_message,'')),''),p_invoice_limit,coalesce(p_included_modules,array['invoice_manager']::text[]),nullif(trim(coalesce(p_stripe_monthly_price_id,'')),''),nullif(trim(coalesce(p_stripe_annual_price_id,'')),''),coalesce(p_is_public,true),coalesce(p_sort_order,0),now()) returning id into result_id;
  else
    update public.plans set slug=clean_slug,name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),monthly_price=coalesce(p_monthly_price,0),annual_price=p_annual_price,annual_saving_message=nullif(trim(coalesce(p_annual_saving_message,'')),''),invoice_limit=p_invoice_limit,included_modules=coalesce(p_included_modules,array['invoice_manager']::text[]),stripe_price_id=nullif(trim(coalesce(p_stripe_monthly_price_id,'')),''),stripe_annual_price_id=nullif(trim(coalesce(p_stripe_annual_price_id,'')),''),is_public=coalesce(p_is_public,true),sort_order=coalesce(p_sort_order,0),updated_at=now() where id=p_id returning id into result_id;
    if result_id is null then raise exception 'Plan not found'; end if;
  end if;
  return result_id;
end $$;
revoke all on function public.v6174_admin_upsert_plan(uuid,text,text,text,numeric,numeric,text,integer,text[],text,text,boolean,integer) from public;
revoke execute on function public.v6174_admin_upsert_plan(uuid,text,text,text,numeric,numeric,text,integer,text[],text,text,boolean,integer) from anon;
grant execute on function public.v6174_admin_upsert_plan(uuid,text,text,text,numeric,numeric,text,integer,text[],text,text,boolean,integer) to authenticated;
