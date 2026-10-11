-- Phase 1: preserves PO delivery date, currency and line GST; no table alterations.
-- Purchase orders only. Atomic save with optimistic concurrency.
create or replace function public.v61142b_save_purchase_order(p_order jsonb,p_lines jsonb,p_expected_updated_at timestamptz default null)
returns uuid language plpgsql security invoker set search_path=public as $$
declare v_id uuid; v_bid uuid; v_old public.purchase_orders%rowtype; v_item jsonb; v_total numeric:=0; v_qty numeric; v_price numeric; v_count int:=0; v_gst numeric:=0; v_line_gst numeric; v_rate numeric;
begin
 v_bid:=(p_order->>'business_id')::uuid;
 if v_bid is null or not public.v6147_can_write_area(v_bid,'expenses') then raise exception 'Purchase order write permission denied'; end if;
 if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines)=0 then raise exception 'Purchase order must contain items'; end if;
 if nullif(trim(p_order->>'supplier_name'),'') is null or nullif(p_order->>'supplier_id','') is null then raise exception 'Select a supplier'; end if;
 if not exists(select 1 from public.suppliers where id=(p_order->>'supplier_id')::uuid and business_id=v_bid and not archived) then raise exception 'Supplier does not belong to this business'; end if;
 for v_item in select value from jsonb_array_elements(p_lines) loop
  v_count:=v_count+1; v_qty:=(v_item->>'qty')::numeric;v_price:=(v_item->>'unit_price')::numeric;
  if nullif(trim(v_item->>'description'),'') is null or v_qty is null or v_qty<=0 or v_price is null or v_price<0 then raise exception 'Invalid purchase order line'; end if;
  v_rate:=coalesce(nullif(v_item->>'gst_rate','')::numeric,0); if v_rate<0 or v_rate>100 then raise exception 'Invalid GST rate'; end if; v_line_gst:=round(v_qty*v_price*v_rate/100,2); v_gst:=v_gst+v_line_gst; v_total:=v_total+v_qty*v_price;
 end loop;
 if nullif(p_order->>'id','') is not null then
  v_id:=(p_order->>'id')::uuid;
  select * into v_old from public.purchase_orders where id=v_id and business_id=v_bid for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if p_expected_updated_at is null or v_old.updated_at is distinct from p_expected_updated_at then raise exception 'Purchase order changed by another user. Reopen before saving'; end if;
  update public.purchase_orders set po_number=p_order->>'po_number',supplier_id=(p_order->>'supplier_id')::uuid,supplier_name=p_order->>'supplier_name',order_date=(p_order->>'order_date')::date,expected_date=coalesce(nullif(p_order->>'expected_date','')::date,v_old.expected_date),currency=coalesce(nullif(p_order->>'currency',''),v_old.currency),gst_amount=v_gst,notes=p_order->>'notes',total_amount=v_total+v_gst,subtotal=v_total,updated_by=auth.uid(),updated_at=clock_timestamp() where id=v_id;
  delete from public.purchase_order_lines where purchase_order_id=v_id and business_id=v_bid;
 else
  insert into public.purchase_orders(business_id,po_number,supplier_id,supplier_name,order_date,expected_date,status,notes,total_amount,subtotal,gst_amount,currency,created_by,updated_by)
  values(v_bid,p_order->>'po_number',(p_order->>'supplier_id')::uuid,p_order->>'supplier_name',(p_order->>'order_date')::date,nullif(p_order->>'expected_date','')::date,'draft',p_order->>'notes',v_total+v_gst,v_total,v_gst,coalesce(nullif(p_order->>'currency',''),'NZD'),auth.uid(),auth.uid()) returning id into v_id;
 end if;
 insert into public.purchase_order_lines(business_id,purchase_order_id,line_order,description,qty,unit_price,gst_rate,gst_amount,line_total)
 select v_bid,v_id,ordinality::integer,value->>'description',(value->>'qty')::numeric,(value->>'unit_price')::numeric,coalesce(nullif(value->>'gst_rate','')::numeric,0),round((value->>'qty')::numeric*(value->>'unit_price')::numeric*coalesce(nullif(value->>'gst_rate','')::numeric,0)/100,2),(value->>'qty')::numeric*(value->>'unit_price')::numeric+round((value->>'qty')::numeric*(value->>'unit_price')::numeric*coalesce(nullif(value->>'gst_rate','')::numeric,0)/100,2) from jsonb_array_elements(p_lines) with ordinality;
 return v_id;
end $$;
revoke all on function public.v61142b_save_purchase_order(jsonb,jsonb,timestamptz) from public;
grant execute on function public.v61142b_save_purchase_order(jsonb,jsonb,timestamptz) to authenticated;
