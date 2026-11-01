-- Bank setup is available to business owners/accountants without Bank Reconciliation.
-- The existing bank_accounts row is the single source of truth. No duplicate cleanup.
create or replace function public.frindly_bank_setup_list_v1()
returns table(id uuid,name text,account_number text,is_default boolean,opening_balance numeric,opening_balance_date date)
language plpgsql security definer set search_path='' as $$
declare v_bid uuid:=public.current_business_id();
begin
 if auth.uid() is null or v_bid is null or not public.v6169a_accountant_centre_access(v_bid,true) then
  raise exception 'Owner or accountant permission required';
 end if;
 return query select b.id,b.name::text,b.account_number::text,b.is_default,b.opening_balance,b.opening_balance_date
 from public.bank_accounts b where b.business_id=v_bid and not coalesce(b.archived,false) order by b.created_at,b.id;
end $$;
create or replace function public.frindly_bank_setup_save_v1(p_id uuid,p_name text,p_number text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_bid uuid:=public.current_business_id();v_id uuid;v_number text:=nullif(trim(p_number),'');v_name text:=nullif(trim(p_name),'');
begin
 if auth.uid() is null or v_bid is null or not public.v6169a_accountant_centre_access(v_bid,true) then
  raise exception 'Owner or accountant permission required';
 end if;
 if v_name is null or length(v_name)>160 or length(coalesce(v_number,''))>100 then raise exception 'Valid bank label and account number required';end if;
 if p_id is not null then
  update public.bank_accounts b set name=v_name,account_number=v_number,updated_at=now(),updated_by=auth.uid()
  where b.id=p_id and b.business_id=v_bid and not coalesce(b.archived,false)
  returning b.id into v_id;
  if v_id is null then raise exception 'Bank account not found for this business';end if;
 else
  -- Never insert when a numbered bank account already exists. Force explicit ID resolution.
  if v_number is not null and exists(select 1 from public.bank_accounts b where b.business_id=v_bid and not coalesce(b.archived,false) and lower(regexp_replace(coalesce(b.account_number,''),'[^0-9a-z]','','gi'))=lower(regexp_replace(v_number,'[^0-9a-z]','','gi'))) then
   raise exception 'Existing bank number: select its existing account before saving';
  end if;
  insert into public.bank_accounts(business_id,name,account_number,currency,is_default,created_by,updated_by)
  values(v_bid,v_name,v_number,'NZD',false,auth.uid(),auth.uid()) returning public.bank_accounts.id into v_id;
 end if;
 return v_id;
end $$;
revoke all on function public.frindly_bank_setup_list_v1() from public,anon;
revoke all on function public.frindly_bank_setup_save_v1(uuid,text,text) from public,anon;
grant execute on function public.frindly_bank_setup_list_v1() to authenticated,service_role;
grant execute on function public.frindly_bank_setup_save_v1(uuid,text,text) to authenticated,service_role;