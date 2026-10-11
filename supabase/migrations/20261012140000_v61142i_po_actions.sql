-- PO lifecycle actions only; no changes to accounting tables.
create or replace function public.v61142i_po_action(p_id uuid,p_action text)
returns void language plpgsql security definer set search_path=public as $$
declare v_po public.purchase_orders%rowtype;
begin
 select * into v_po from public.purchase_orders where id=p_id and business_id=public.current_business_id() for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not public.v6147_can_write_area(v_po.business_id,'expenses') then raise exception 'Permission denied'; end if;
 if p_action='delete' then
   if v_po.status<>'draft' then raise exception 'Only draft orders can be deleted'; end if;
   delete from public.purchase_order_lines where purchase_order_id=p_id and business_id=v_po.business_id;
   delete from public.purchase_order_events where purchase_order_id=p_id and business_id=v_po.business_id;
   delete from public.purchase_orders where id=p_id and business_id=v_po.business_id;
 elsif p_action='cancel' then
   if v_po.status not in ('approved','sent','partially_received') then raise exception 'This order cannot be cancelled'; end if;
   update public.purchase_orders set status='cancelled',updated_at=clock_timestamp(),updated_by=auth.uid() where id=p_id;
   insert into public.purchase_order_events(business_id,purchase_order_id,event_type,note,created_by)
   values(v_po.business_id,p_id,'cancelled','Cancelled by user',auth.uid());
 else raise exception 'Unsupported purchase order action'; end if;
end $$;
revoke all on function public.v61142i_po_action(uuid,text) from public;
grant execute on function public.v61142i_po_action(uuid,text) to authenticated;
-- Guard the existing atomic-save RPC against changes to non-draft orders.
-- This migration deliberately does not replace the entire save function.
