CREATE OR REPLACE FUNCTION public.v61107v_update_business_owner(p_owner_id uuid, p_display_name text, p_owner_type text, p_is_shareholder boolean, p_is_director boolean, p_ownership_percent numeric, p_share_class text, p_shares_held numeric, p_status text, p_director_appointed_on date, p_director_resigned_on date, p_effective_date date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bid uuid;v_old public.business_owners%rowtype;v_new public.business_owners%rowtype;v_change text:='details_corrected';
begin
 v_bid:=public.current_business_id();
 if auth.uid() is null or v_bid is null then raise exception 'Authentication and an active business are required'; end if;
 if public.v6147_current_business_role(v_bid) not in ('owner','admin','bookkeeper') then raise exception 'You do not have permission to edit owners/shareholders'; end if;
 select * into v_old from public.business_owners where id=p_owner_id and business_id=v_bid for update;
 if not found then raise exception 'Owner/shareholder not found'; end if;
 if nullif(trim(p_display_name),'') is null then raise exception 'Name is required'; end if;
 if p_owner_type not in ('owner','shareholder','director','partner','trustee','other') then raise exception 'Invalid owner type'; end if;
 if p_status not in ('active','inactive') then raise exception 'Invalid status'; end if;
 if p_ownership_percent is not null and (p_ownership_percent<0 or p_ownership_percent>100) then raise exception 'Ownership percentage must be between 0 and 100'; end if;
 if p_shares_held is not null and p_shares_held<0 then raise exception 'Shares held cannot be negative'; end if;
 if p_director_resigned_on is not null and p_director_appointed_on is not null and p_director_resigned_on<p_director_appointed_on then raise exception 'Director resignation cannot predate appointment'; end if;
 if v_old.is_director is distinct from p_is_director then v_change:=case when p_is_director then 'appointed_director' else 'resigned_director' end;
 elsif v_old.is_shareholder is distinct from p_is_shareholder or v_old.ownership_percent is distinct from p_ownership_percent or v_old.share_class is distinct from nullif(trim(p_share_class),'') or v_old.shares_held is distinct from p_shares_held then v_change:='shareholding_changed';
 elsif v_old.status is distinct from p_status then v_change:=case when p_status='active' then 'activated' else 'deactivated' end;
 elsif v_old.owner_type is distinct from p_owner_type then v_change:='role_changed'; end if;
 update public.business_owners set display_name=trim(p_display_name),owner_type=p_owner_type,is_shareholder=coalesce(p_is_shareholder,false),is_director=coalesce(p_is_director,false),ownership_percent=p_ownership_percent,share_class=nullif(trim(p_share_class),''),shares_held=p_shares_held,status=p_status,director_appointed_on=p_director_appointed_on,director_resigned_on=p_director_resigned_on,notes=coalesce(p_note,notes),updated_at=now(),updated_by=auth.uid() where id=p_owner_id returning * into v_new;
 insert into public.business_owner_history(business_id,owner_id,effective_date,change_type,before_data,after_data,note,created_by)
 values(v_bid,p_owner_id,coalesce(p_effective_date,current_date),v_change,to_jsonb(v_old),to_jsonb(v_new),p_note,auth.uid());
 return jsonb_build_object('ok',true,'owner_id',p_owner_id,'change_type',v_change);
end $function$;
