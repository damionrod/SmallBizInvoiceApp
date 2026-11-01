-- Atomic, tenant-scoped default switch. Clear first to respect the immediate
-- partial unique index; serialize switches within a business.
create or replace function public.frindly_bank_setup_default_v1(p_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_bid uuid:=public.current_business_id();
begin
 if auth.uid() is null or v_bid is null or not public.v6169a_accountant_centre_access(v_bid,true) then
  raise exception 'Owner or accountant permission required';
 end if;
 perform 1 from public.businesses where id=v_bid for update;
 if not found then raise exception 'Business not found';end if;
 if not exists(select 1 from public.bank_accounts where id=p_id and business_id=v_bid and not coalesce(archived,false)) then
  raise exception 'Bank account not found';
 end if;
 if exists(select 1 from public.bank_accounts where id=p_id and business_id=v_bid and is_default=true and not coalesce(archived,false)) then
  return;
 end if;
 update public.bank_accounts set is_default=false,updated_at=now(),updated_by=auth.uid()
 where business_id=v_bid and is_default=true and not coalesce(archived,false);
 update public.bank_accounts set is_default=true,updated_at=now(),updated_by=auth.uid()
 where id=p_id and business_id=v_bid and not coalesce(archived,false);
end $$;
revoke all on function public.frindly_bank_setup_default_v1(uuid) from public,anon;
grant execute on function public.frindly_bank_setup_default_v1(uuid) to authenticated,service_role;