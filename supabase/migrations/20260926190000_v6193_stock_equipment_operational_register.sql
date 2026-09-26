-- V61.93 Stock & Equipment operational register polish.
-- Additive only: no expenses, GST returns, invoices, posted journals or accounting
-- reports are changed by this migration.
begin;

alter table public.se_assets add column if not exists tracking_treatment text not null default 'depreciable'
  check (tracking_treatment in ('depreciable','low_value'));
alter table public.se_assets add column if not exists asset_status text not null default 'in_use'
  check (asset_status in ('in_use','lost','broken','sold','disposed'));
alter table public.se_assets add column if not exists assigned_to text;
alter table public.se_assets add column if not exists last_note text;
alter table public.se_assets add column if not exists status_changed_on date;

create or replace function public.se_record_asset_event(p_business_id uuid,p_asset_id uuid,
 p_action text,p_event_date date default null,p_proceeds numeric default null,p_note text default null,
 p_assigned_to text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v public.se_assets%rowtype; v_status text; v_action text;
begin
 perform public.se_require_access(p_business_id,true);
 select * into v from public.se_assets where id=p_asset_id and business_id=p_business_id for update;
 if not found or v.voided_at is not null then raise exception 'Tracked equipment is unavailable'; end if;
 if p_action not in ('lost','broken','sold','disposed','note','accountant_review','in_use') then
   raise exception 'Unsupported equipment action';
 end if;
 if p_action in ('sold','disposed') and (p_event_date is null or p_proceeds is null or p_proceeds<0) then
   raise exception 'Enter date and proceeds for sold or disposed items';
 end if;
 if p_action in ('lost','broken','note','accountant_review') and nullif(trim(coalesce(p_note,'')),'') is null then
   raise exception 'Add a short note';
 end if;
 v_status:=case when p_action in ('lost','broken','sold','disposed','in_use') then p_action else v.asset_status end;
 v_action:=case
   when p_action='sold' then 'equipment_sold'
   when p_action='disposed' then 'equipment_disposed'
   when p_action='lost' then 'tool_status_changed'
   when p_action='broken' then 'tool_status_changed'
   when p_action='in_use' then 'tool_status_changed'
   when p_action='accountant_review' then 'accountant_review_requested'
   else 'asset_note_added' end;
 update public.se_assets set asset_status=v_status,
   disposed_on=case when p_action in ('sold','disposed') then p_event_date else disposed_on end,
   disposal_proceeds=case when p_action in ('sold','disposed') then p_proceeds else disposal_proceeds end,
   assigned_to=coalesce(nullif(trim(coalesce(p_assigned_to,'')),''),assigned_to),
   last_note=coalesce(nullif(trim(coalesce(p_note,'')),''),last_note),
   status_changed_on=coalesce(p_event_date,current_date)
 where id=v.id;
 insert into public.se_activity(business_id,actor,action,item_id,detail)
 values(p_business_id,auth.uid(),v_action,v.item_id,
   jsonb_build_object('asset_id',v.id,'status',v_status,'date',coalesce(p_event_date,current_date),
     'proceeds',p_proceeds,'note',nullif(trim(coalesce(p_note,'')),''),
     'assigned_to',nullif(trim(coalesce(p_assigned_to,'')),'')));
 return v.id;
end $$;
revoke all on function public.se_record_asset_event(uuid,uuid,text,date,numeric,text,text) from public,anon;
grant execute on function public.se_record_asset_event(uuid,uuid,text,date,numeric,text,text) to authenticated;

commit;
