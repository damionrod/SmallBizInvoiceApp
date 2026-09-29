-- V61.79K: allow the existing Super Admin business-delete workflow to remove
-- non-cascading tenant records before deleting the business row.
--
-- This is intentionally limited to the already-authorised
-- v36_admin_delete_business RPC. No foreign-key delete rules are changed and
-- no data is removed by this migration itself.

create or replace function public.v36_admin_delete_business(
  p_business_id uuid,
  p_confirmation_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_business_name text;
  v_user_ids uuid[];
  v_user_count integer := 0;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;

  select name into v_business_name
  from public.businesses
  where id = p_business_id;

  if v_business_name is null then
    raise exception 'Business not found';
  end if;

  if trim(coalesce(p_confirmation_name, '')) <> trim(v_business_name) then
    raise exception 'Business name confirmation does not match';
  end if;

  if exists (
    select 1
    from public.profiles
    where business_id = p_business_id
      and id = auth.uid()
  ) then
    raise exception 'You cannot delete the business account you are currently logged into';
  end if;

  select coalesce(array_agg(id), '{}'::uuid[]), count(*)::integer
    into v_user_ids, v_user_count
  from public.profiles
  where business_id = p_business_id;

  -- These tenant tables intentionally use RESTRICT/NO ACTION rather than
  -- changing their FK rules globally. Remove their rows in dependency order
  -- only when the Super Admin has explicitly confirmed this business deletion.
  delete from public.google_calendar_sync_log where business_id = p_business_id;
  delete from public.google_calendar_event_links where business_id = p_business_id;
  delete from public.google_calendar_connections where business_id = p_business_id;
  delete from public.job_schedule_assignments where business_id = p_business_id;
  delete from public.job_schedules where business_id = p_business_id;
  delete from public.job_recurrence_series where business_id = p_business_id;
  delete from public.referrals
   where referring_business_id = p_business_id
      or referred_business_id = p_business_id;

  -- Accounting setup rows are also intentionally restricted. Journal rows are
  -- removed first so account deletion is safe for unused/system chart rows.
  -- Posted journals remain protected by the existing immutability trigger.
  if exists (
    select 1
    from public.accounting_journals
    where business_id = p_business_id
      and status in ('posted', 'reversed')
  ) then
    raise exception 'This business has posted accounting journals and cannot be deleted. Suspend or close it instead.';
  end if;
  delete from public.accounting_journal_lines where business_id = p_business_id;
  delete from public.accounting_journals where business_id = p_business_id;
  delete from public.accounting_accounts where business_id = p_business_id;
  delete from public.accounting_periods where business_id = p_business_id;
  delete from public.accounting_migration_exceptions where business_id = p_business_id;

  -- Financials tables have AFTER DELETE audit triggers. Delete these rows while
  -- the parent business still exists so their audit rows can satisfy the
  -- financial_audit_log.business_id foreign key. The audit rows are then
  -- removed before the business itself is deleted.
  delete from public.financial_budget_month_values where business_id = p_business_id;
  delete from public.financial_budget_lines where business_id = p_business_id;
  delete from public.financial_budgets where business_id = p_business_id;
  delete from public.financial_category_mappings where business_id = p_business_id;
  delete from public.gst_returns where business_id = p_business_id;
  delete from public.financial_settings where business_id = p_business_id;
  delete from public.financial_audit_log where business_id = p_business_id;
  delete from public.accounting_audit_log where business_id = p_business_id;

  delete from public.businesses
  where id = p_business_id;

  if coalesce(array_length(v_user_ids, 1), 0) > 0 then
    delete from auth.users
    where id = any(v_user_ids);
  end if;

  return jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'business_name', v_business_name,
    'users_deleted', v_user_count
  );
end
$function$;
