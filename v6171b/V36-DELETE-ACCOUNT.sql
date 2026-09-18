-- v36 Super Admin permanent business deletion
-- Run once in Supabase SQL Editor before using the Delete button.

create or replace function public.v36_admin_delete_business(
  p_business_id uuid,
  p_confirmation_name text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
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
  where id=p_business_id;

  if v_business_name is null then
    raise exception 'Business not found';
  end if;

  if trim(coalesce(p_confirmation_name,'')) <> trim(v_business_name) then
    raise exception 'Business name confirmation does not match';
  end if;

  -- Prevent the logged-in Super Admin from deleting the business that contains
  -- their own profile, which would immediately remove their own login.
  if exists(
    select 1
    from public.profiles
    where business_id=p_business_id
      and id=auth.uid()
  ) then
    raise exception 'You cannot delete the business account you are currently logged into';
  end if;

  select coalesce(array_agg(id),'{}'::uuid[]), count(*)::integer
    into v_user_ids, v_user_count
  from public.profiles
  where business_id=p_business_id;

  -- Financials tables have AFTER DELETE audit triggers. Delete these rows while
  -- the parent business still exists so their audit rows can satisfy the
  -- financial_audit_log.business_id foreign key. Remove those audit rows before
  -- deleting the business itself.
  delete from public.financial_budget_month_values where business_id=p_business_id;
  delete from public.financial_budget_lines where business_id=p_business_id;
  delete from public.financial_budgets where business_id=p_business_id;
  delete from public.financial_category_mappings where business_id=p_business_id;
  delete from public.gst_returns where business_id=p_business_id;
  delete from public.financial_settings where business_id=p_business_id;
  delete from public.financial_audit_log where business_id=p_business_id;

  -- Remaining business-owned data continues to cascade through the existing
  -- foreign keys. Profiles are detached by their ON DELETE SET NULL relationship
  -- and their auth users are removed below.
  delete from public.businesses
  where id=p_business_id;

  if coalesce(array_length(v_user_ids,1),0) > 0 then
    delete from auth.users
    where id=any(v_user_ids);
  end if;

  return jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'business_name', v_business_name,
    'users_deleted', v_user_count
  );
end
$$;

revoke all on function public.v36_admin_delete_business(uuid,text) from public, anon;
grant execute on function public.v36_admin_delete_business(uuid,text) to authenticated;

notify pgrst, 'reload schema';
