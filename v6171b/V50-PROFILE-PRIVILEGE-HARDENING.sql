-- Invoice Manager v50 - profile privilege hardening
-- Run this file once in Supabase SQL Editor.
-- Purpose: allow ordinary users to edit their own display name while preventing
-- them from changing tenant/security fields such as business_id, role or
-- is_super_admin through a direct API call.

create or replace function public.v50_protect_profile_security_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Trusted server-side operations and existing Super Admins retain full access.
  if auth.role() = 'service_role' or public.is_super_admin() then
    return new;
  end if;

  -- A normal authenticated user may only update their own profile row.
  if auth.uid() is null or old.id is distinct from auth.uid() then
    raise exception 'You may only update your own profile.';
  end if;

  -- Security / tenant identity fields are immutable for ordinary users.
  if new.id is distinct from old.id
     or new.business_id is distinct from old.business_id
     or new.email is distinct from old.email
     or new.role is distinct from old.role
     or new.is_super_admin is distinct from old.is_super_admin
     or new.created_at is distinct from old.created_at then
    raise exception 'Profile security fields cannot be changed.';
  end if;

  return new;
end;
$$;

revoke all on function public.v50_protect_profile_security_fields() from public, anon, authenticated;
grant execute on function public.v50_protect_profile_security_fields() to service_role;

-- The trigger runs for every profile UPDATE. The trigger function itself decides
-- whether the caller is an ordinary user, Super Admin, or trusted service role.
drop trigger if exists v50_protect_profile_security_fields on public.profiles;
create trigger v50_protect_profile_security_fields
before update on public.profiles
for each row execute function public.v50_protect_profile_security_fields();

-- Keep the existing RLS behaviour for the normal Account Settings name update,
-- while the trigger above prevents privilege/tenant escalation.
drop policy if exists v22_profiles_update on public.profiles;
create policy v22_profiles_update
on public.profiles
for update
using (id = auth.uid() or public.is_super_admin())
with check (id = auth.uid() or public.is_super_admin());

notify pgrst, 'reload schema';
