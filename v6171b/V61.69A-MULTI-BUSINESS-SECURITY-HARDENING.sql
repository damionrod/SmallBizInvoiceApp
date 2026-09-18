-- Finlo V61.69A — Gate A/B multi-business security hardening only
-- Small additive hardening migration. No customer-facing multi-business creation UX.
begin;

-- Restore the safer V61.46 semantics: neither active_business_id nor legacy business_id
-- is authoritative without an ACTIVE membership. Super Admin retains its intentional context.
create or replace function public.current_business_id()
returns uuid
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_active uuid;
  v_home uuid;
begin
  if auth.uid() is null then return null; end if;
  select p.active_business_id,p.business_id into v_active,v_home
  from public.profiles p where p.id=auth.uid();

  if public.is_super_admin() then return coalesce(v_active,v_home); end if;

  if v_active is not null and exists(
    select 1 from public.business_memberships bm
    where bm.user_id=auth.uid() and bm.business_id=v_active and bm.status='active'
  ) then return v_active; end if;

  if v_home is not null and exists(
    select 1 from public.business_memberships bm
    where bm.user_id=auth.uid() and bm.business_id=v_home and bm.status='active'
  ) then return v_home; end if;

  return null;
end $$;
revoke execute on function public.current_business_id() from anon;
grant execute on function public.current_business_id() to authenticated;

-- Accountant Centre: normal tenants must operate only in the selected active business.
-- Read follows the existing Reports permission model. Writes preserve Owner/Admin/Accountant/Bookkeeper behaviour.
create or replace function public.v6169a_accountant_centre_access(p_business_id uuid,p_write boolean default false)
returns boolean
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_role text;
begin
  if auth.uid() is null then return false; end if;
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id<>public.current_business_id() then return false; end if;
  select bm.role into v_role from public.business_memberships bm
   where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' limit 1;
  if v_role is null then return false; end if;
  if p_write then return v_role in ('owner','admin','accountant','bookkeeper'); end if;
  return public.v6147_can_read_area(p_business_id,'reports');
end $$;
revoke all on function public.v6169a_accountant_centre_access(uuid,boolean) from public,anon;
grant execute on function public.v6169a_accountant_centre_access(uuid,boolean) to authenticated;

-- Mapping tables: read/write active-business constrained.
drop policy if exists v6156_accounting_export_mappings_tenant on public.accounting_export_mappings;
create policy v6169a_accounting_export_mappings_tenant on public.accounting_export_mappings
for all to authenticated
using (public.v6169a_accountant_centre_access(business_id,true))
with check (public.v6169a_accountant_centre_access(business_id,true));

drop policy if exists v6156_tax_export_mappings_tenant on public.tax_export_mappings;
create policy v6169a_tax_export_mappings_tenant on public.tax_export_mappings
for all to authenticated
using (public.v6169a_accountant_centre_access(business_id,true))
with check (public.v6169a_accountant_centre_access(business_id,true));

drop policy if exists v6157_accounting_destination_accounts_tenant on public.accounting_destination_accounts;
create policy v6169a_accounting_destination_accounts_tenant on public.accounting_destination_accounts
for all to authenticated
using (public.v6169a_accountant_centre_access(business_id,true))
with check (public.v6169a_accountant_centre_access(business_id,true));

-- Export history: readable to report readers, insertable by authorised Accountant Centre writers.
drop policy if exists v6156_accounting_exports_tenant on public.accounting_exports;
create policy v6169a_accounting_exports_select on public.accounting_exports
for select to authenticated
using (public.v6169a_accountant_centre_access(business_id,false));

drop policy if exists v6156_accounting_exports_insert on public.accounting_exports;
create policy v6169a_accounting_exports_insert on public.accounting_exports
for insert to authenticated
with check (public.v6169a_accountant_centre_access(business_id,true) and (created_by=auth.uid() or public.is_super_admin()));

-- Cross-business invoice references: ordinary FK constraints ensure existence, this trigger ensures tenant locality.
create or replace function public.v6169a_validate_invoice_business_refs()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.customer_id is not null and not exists(
    select 1 from public.customers c where c.id=new.customer_id and c.business_id=new.business_id
  ) then raise exception 'Invoice customer must belong to the same business'; end if;
  if new.job_costing_id is not null and not exists(
    select 1 from public.job_costings j where j.id=new.job_costing_id and j.business_id=new.business_id
  ) then raise exception 'Invoice job must belong to the same business'; end if;
  return new;
end $$;
revoke all on function public.v6169a_validate_invoice_business_refs() from public,anon,authenticated;
drop trigger if exists v6169a_invoice_business_refs on public.invoices;
create trigger v6169a_invoice_business_refs before insert or update of business_id,customer_id,job_costing_id on public.invoices
for each row execute function public.v6169a_validate_invoice_business_refs();

-- Mutable search_path warnings: no business logic change.
alter function public.v6148_role_default_read(text,text) set search_path=public;
alter function public.v6148_role_default_write(text,text) set search_path=public;

-- Remove PostgreSQL's default PUBLIC EXECUTE from every SECURITY DEFINER function.
-- Existing explicit authenticated/service_role grants are preserved; v35 is restored below for intentional pre-login use.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef loop
    execute format('revoke execute on function %s from public',r.sig);
  end loop;
end $$;
grant execute on function public.v35_checkout_available() to anon,authenticated;
revoke execute on function public.v55_seed_payroll_defaults(uuid) from anon;

-- Trigger/internal SECURITY DEFINER helpers must not be directly API callable.
do $$
declare r record;
begin
  for r in
    select distinct p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef
      and exists(select 1 from pg_trigger t where t.tgfoid=p.oid and not t.tgisinternal)
  loop
    execute format('revoke execute on function %s from anon, authenticated',r.sig);
  end loop;
end $$;

-- Internal helpers that are not direct frontend/API RPCs.
revoke execute on function public.v51_refresh_expense_payment_totals(uuid) from anon,authenticated;
revoke execute on function public.v51_seed_expense_categories(uuid) from anon,authenticated;
-- RLS/access helpers remain authenticated-callable where policies depend on them, but never anonymous.
revoke execute on function public.has_active_business_membership(uuid) from anon;
revoke execute on function public.is_super_admin() from anon;
revoke execute on function public.v55_payroll_access(uuid) from anon;
revoke execute on function public.v58_financials_access(uuid) from anon;
revoke execute on function public.v6135_bank_module_enabled(uuid) from anon;
-- v35_checkout_available intentionally remains anon+authenticated for pre-login signup payment UX.
-- V61.68B statutory ruleset RPCs are Super Admin-only internally; anonymous API execution is unnecessary.
revoke execute on function public.v6168b_activate_ruleset(uuid) from anon;
revoke execute on function public.v6168b_create_draft_ruleset(uuid,text,text,date,date) from anon;
revoke execute on function public.v6168b_set_ruleset_status(uuid,text) from anon;

commit;
