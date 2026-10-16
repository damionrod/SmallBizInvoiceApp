-- Supabase may grant new public-schema RPCs to anon automatically.
-- This internal entitlement helper is available only to signed-in users and server processes.
revoke all on function public.v6200_stock_module_enabled(uuid) from public;
revoke execute on function public.v6200_stock_module_enabled(uuid) from anon;
grant execute on function public.v6200_stock_module_enabled(uuid) to authenticated, service_role;
