-- Frindly v61.105 Phase 10
-- NZ supplier-purchase equipment asset cost basis only.
-- Existing assets and opening equipment are intentionally not rewritten/reinterpreted.
do $phase10$
declare
  f text;
  old1 text := 'asset_id:=public.se_create_asset(p_business_id,item_id,source_amount+source_gst,source_gst,
       exp.invoice_date,exp.invoice_date,coalesce(exp.business_use_percent,100),
       ''unknown'','''',null,null);';
  new1 text := 'asset_id:=public.se_create_asset(p_business_id,item_id,
       case when upper(coalesce(public.v61105_effective_tax_status(exp.invoice_date)->>''jurisdiction'',''''))=''NZ''
              and coalesce((public.v61105_effective_tax_status(exp.invoice_date)->>''gst_registered'')::boolean,false)
            then source_amount else source_amount+source_gst end,
       case when upper(coalesce(public.v61105_effective_tax_status(exp.invoice_date)->>''jurisdiction'',''''))=''NZ''
              and not coalesce((public.v61105_effective_tax_status(exp.invoice_date)->>''gst_registered'')::boolean,false)
            then 0 else source_gst end,
       exp.invoice_date,exp.invoice_date,coalesce(exp.business_use_percent,100),
       ''unknown'','''',null,null);';
  old2 text := 'v_asset:=public.se_create_asset(p_business_id,v_item,v_ex+v_gst,v_gst,
         e.invoice_date,v_available,coalesce(e.business_use_percent,100),''unknown'','''',null,null);';
  new2 text := 'v_asset:=public.se_create_asset(p_business_id,v_item,
         case when upper(coalesce(public.v61105_effective_tax_status(e.invoice_date)->>''jurisdiction'',''''))=''NZ''
                and coalesce((public.v61105_effective_tax_status(e.invoice_date)->>''gst_registered'')::boolean,false)
              then v_ex else v_ex+v_gst end,
         case when upper(coalesce(public.v61105_effective_tax_status(e.invoice_date)->>''jurisdiction'',''''))=''NZ''
                and not coalesce((public.v61105_effective_tax_status(e.invoice_date)->>''gst_registered'')::boolean,false)
              then 0 else v_gst end,
         e.invoice_date,v_available,coalesce(e.business_use_percent,100),''unknown'','''',null,null);';
begin
  select pg_get_functiondef('public.se_confirm_purchase(uuid,uuid,uuid,text,text,numeric,uuid)'::regprocedure) into f;
  if position(old1 in f)=0 then raise exception 'Phase 10 guard: se_confirm_purchase asset call not found'; end if;
  execute replace(f,old1,new1);

  select pg_get_functiondef('public.se_review_invoice(uuid,uuid,integer,jsonb,text)'::regprocedure) into f;
  if position(old2 in f)=0 then raise exception 'Phase 10 guard: se_review_invoice asset call not found'; end if;
  execute replace(f,old2,new2);
end
$phase10$;

revoke execute on function public.se_confirm_purchase(uuid,uuid,uuid,text,text,numeric,uuid) from public, anon;
grant execute on function public.se_confirm_purchase(uuid,uuid,uuid,text,text,numeric,uuid) to authenticated;
revoke execute on function public.se_review_invoice(uuid,uuid,integer,jsonb,text) from public, anon;
grant execute on function public.se_review_invoice(uuid,uuid,integer,jsonb,text) to authenticated;
