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

  -- Deleting the business cascades all business-owned data through the existing
  -- foreign keys: subscriptions, business modules, invoices, customers,
  -- recurring rules, job costings and quotes. Profiles are temporarily detached
  -- by their ON DELETE SET NULL relationship and are removed below with auth users.
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
