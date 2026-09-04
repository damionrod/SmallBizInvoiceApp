-- Invoice Manager v35
-- Safe public checkout-availability signal. No payment credentials are exposed.

create or replace function public.v35_checkout_available()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select coalesce((
    select enabled
    from public.payment_provider_settings
    where provider='stripe'
    limit 1
  ),false)
$$;

revoke all on function public.v35_checkout_available() from public;
grant execute on function public.v35_checkout_available() to anon, authenticated;
