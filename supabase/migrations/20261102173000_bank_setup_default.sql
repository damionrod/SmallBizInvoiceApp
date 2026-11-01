create or replace function public.frindly_bank_setup_default_v1(p_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_bid uuid:=public.current_business_id();
begin
 if auth.uid() is null or v_bid is null or not public.v6169a_accountant_centre_access(v_bid,true) then raise exception 'Owner or accountant permission required';end if;
 if not exists(select 1 from public.bank_accounts where id=p_id and business_id=v_bid and not coalesce(archived,false)) then raise exception 'Bank account not found';end if;
 update public.bank_accounts set is_default=(id=p_id),updated_at=now(),updated_by=auth.uid()
 where business_id=v_bid and not coalesce(archived,false) and is_default is distinct from (id=p_id);
end $$;
revoke all on function public.frindly_bank_setup_default_v1(uuid) from public,anon;
grant execute on function public.frindly_bank_setup_default_v1(uuid) to authenticated,service_role;