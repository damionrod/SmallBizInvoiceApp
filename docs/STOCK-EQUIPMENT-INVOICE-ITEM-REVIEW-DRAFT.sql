-- Apply after v61.89B only. Never apply to the live project before isolated verification.
-- Item proposals and invoice reviews are separate from accounting expense_lines.
begin;

create table public.se_document_items (
 business_id uuid not null references public.businesses(id),
 expense_id uuid primary key references public.expenses(id) on delete cascade,
 attachment_id uuid references public.expense_attachments(id) on delete set null,
 proposals jsonb not null check(jsonb_typeof(proposals)='array'),
 source_filename text,
 scanned_at timestamptz not null default now(),
 saved_by uuid not null,
 unique(business_id,expense_id)
);
create table public.se_invoice_reviews (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id),
 expense_id uuid not null references public.expenses(id),
 revision integer not null check(revision>0),
 rows jsonb not null check(jsonb_typeof(rows)='array'),
 source_ex_gst numeric(14,2) not null,
 source_gst numeric(14,2) not null,
 reviewed_by uuid not null,
 reviewed_at timestamptz not null default now(),
 reason text,
 unique(business_id,expense_id,revision)
);
create index se_invoice_reviews_latest on public.se_invoice_reviews(business_id,expense_id,revision desc);
alter table public.se_assets add column tracking_treatment text not null default 'depreciable'
 check(tracking_treatment in ('depreciable','low_value'));
alter table public.se_document_items enable row level security;
alter table public.se_invoice_reviews enable row level security;
create policy se_document_items_read on public.se_document_items for select to authenticated
 using(business_id=public.current_business_id());
create policy se_invoice_reviews_read on public.se_invoice_reviews for select to authenticated
 using(business_id=public.current_business_id());
revoke all on public.se_document_items,public.se_invoice_reviews from anon,authenticated;
grant select on public.se_document_items,public.se_invoice_reviews to authenticated;

-- Called silently after the ordinary expense save. Item suggestions never become
-- extra accounting lines or change the bill total, GST, payment or bank match.
create function public.se_save_document_items(p_business_id uuid,p_expense_id uuid,
 p_attachment_id uuid,p_filename text,p_items jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare e public.expenses%rowtype; a public.expense_attachments%rowtype; line jsonb;
begin
 perform public.se_require_access(p_business_id,true);
 select * into e from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found then raise exception 'Supplier bill unavailable'; end if;
 if p_attachment_id is not null then
   select * into a from public.expense_attachments where id=p_attachment_id and
     expense_id=e.id and business_id=p_business_id;
   if not found then raise exception 'Attachment does not belong to this bill'; end if;
 end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>150 then
   raise exception 'The scan contains too many item proposals'; end if;
 if exists(select 1 from public.se_invoice_reviews where business_id=p_business_id and expense_id=e.id)
   then raise exception 'A reviewed invoice cannot have its AI proposals replaced'; end if;
 for line in select value from jsonb_array_elements(p_items) loop
   if jsonb_typeof(line)<>'object' or jsonb_typeof(line->'description') not in ('string','null')
      or length(coalesce(line->>'description',''))>500 then raise exception 'Invalid item description'; end if;
 end loop;
 insert into public.se_document_items(business_id,expense_id,attachment_id,proposals,source_filename,saved_by)
 values(p_business_id,e.id,p_attachment_id,p_items,left(p_filename,180),auth.uid())
 on conflict(expense_id) do update set proposals=excluded.proposals,
   attachment_id=excluded.attachment_id,source_filename=excluded.source_filename,
   scanned_at=now(),saved_by=excluded.saved_by;
end $$;
revoke all on function public.se_save_document_items(uuid,uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.se_save_document_items(uuid,uuid,uuid,text,jsonb) to authenticated;

-- One transaction for every line of a bill. Earlier versions are immutable.
-- Accounting entries are intentionally not posted by this operational RPC.
create function public.se_review_invoice(p_business_id uuid,p_expense_id uuid,
 p_expected_revision integer,p_rows jsonb,p_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare e public.expenses%rowtype; previous public.se_invoice_reviews%rowtype;
 line jsonb; old_line jsonb; result_rows jsonb:='[]'::jsonb;
 v_kind text; v_name text; v_quantity numeric; v_ex numeric; v_gst numeric;
 v_total_ex numeric:=0; v_total_gst numeric:=0; v_item uuid; v_movement uuid;
 v_asset uuid; v_review uuid; v_available date; v_life integer; v_residual numeric;
 v_item_row public.se_items%rowtype; v_move_row public.se_movements%rowtype;
begin
 perform public.se_require_access(p_business_id,true);
 select * into e from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found or e.payment_status='draft' or coalesce(e.archived,false) or
    coalesce(to_jsonb(e)->>'lifecycle_state','recorded') not in ('recorded','') then
   raise exception 'Record an active supplier bill before review'; end if;
 select * into previous from public.se_invoice_reviews where business_id=p_business_id
   and expense_id=e.id order by revision desc limit 1 for update;
 if coalesce(previous.revision,0)<>coalesce(p_expected_revision,-1) then
   raise exception 'Invoice review has changed; reload it before saving'; end if;
 if exists(select 1 from public.se_reviews where business_id=p_business_id and expense_id=e.id
   and status='confirmed') then raise exception 'This bill has legacy confirmed purchase lines; correct them first'; end if;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 150 then
   raise exception 'Review between 1 and 150 invoice items'; end if;
 if previous.id is not null and nullif(trim(coalesce(p_reason,'')),'') is null then
   raise exception 'Explain why this confirmed invoice is changing'; end if;

 -- Roll back earlier operational events only when nothing depends on them.
 if previous.id is not null then
  for old_line in select value from jsonb_array_elements(previous.rows) loop
   if old_line->>'movement_id' is not null then
     select * into v_move_row from public.se_movements where id=(old_line->>'movement_id')::uuid
       and business_id=p_business_id and expense_id=e.id;
     if not found then raise exception 'Earlier movement missing; accountant review required'; end if;
     select * into v_item_row from public.se_items where id=v_move_row.item_id
       and business_id=p_business_id for update;
     if exists(select 1 from public.se_movements where business_id=p_business_id
       and item_id=v_item_row.id and created_at>v_move_row.created_at)
       then raise exception 'Stock has moved since review; accountant review required'; end if;
     if v_item_row.quantity<v_move_row.quantity_delta or v_item_row.value_ex_gst<v_move_row.value_delta then
       raise exception 'Stock quantities need accountant review'; end if;
     update public.se_items set quantity=quantity-v_move_row.quantity_delta,
       value_ex_gst=value_ex_gst-v_move_row.value_delta where id=v_item_row.id;
     insert into public.se_movements(business_id,item_id,kind,quantity_delta,value_delta,
       quantity_after,value_after,occurred_on,expense_id,reason,created_by)
     values(p_business_id,v_item_row.id,'correction',-v_move_row.quantity_delta,
       -v_move_row.value_delta,v_item_row.quantity-v_move_row.quantity_delta,
       v_item_row.value_ex_gst-v_move_row.value_delta,current_date,e.id,p_reason,auth.uid());
     update public.se_items set archived=true where id=v_item_row.id and origin_expense_id=e.id;
   elsif old_line->>'asset_id' is not null then
     select item_id into v_item from public.se_assets where id=(old_line->>'asset_id')::uuid
       and business_id=p_business_id and voided_at is null and disposed_on is null for update;
     if not found then raise exception 'Equipment changed since review; accountant review required'; end if;
     update public.se_assets set voided_at=now() where id=(old_line->>'asset_id')::uuid;
     update public.se_items set archived=true where id=v_item;
   end if;
  end loop;
 end if;
 for line in select value from jsonb_array_elements(p_rows) loop
   v_kind:=line->>'kind';v_name:=trim(coalesce(line->>'description',''));
   if v_kind is null or v_kind not in ('regular','stock','supplies','equipment','low_value_equipment') or
      v_name='' or length(v_name)>500 or (line->>'ex_gst') is null or
      (line->>'gst') is null or (line->>'quantity') is null then
     raise exception 'Complete every item and select a use'; end if;
   begin
     v_ex:=(line->>'ex_gst')::numeric;v_gst:=(line->>'gst')::numeric;
     v_quantity:=(line->>'quantity')::numeric;
   exception when invalid_text_representation or numeric_value_out_of_range then
     raise exception 'Use valid numeric item amounts and quantities'; end;
   if v_ex<0 or v_gst<0 or v_quantity<=0 or v_quantity>1000000 or
      round(v_ex,2)<>v_ex or round(v_gst,2)<>v_gst then
     raise exception 'Check item amounts and quantities'; end if;
   v_total_ex:=v_total_ex+v_ex;v_total_gst:=v_total_gst+v_gst;
   v_item:=null;v_movement:=null;v_asset:=null;
   if v_kind in ('stock','supplies','equipment','low_value_equipment') then
     if v_ex<=0 then raise exception 'Tracked items need a positive cost'; end if;
     if v_kind in ('equipment','low_value_equipment') and v_quantity<>1 then
       raise exception 'Enter equipment as one row per item'; end if;
     v_item:=public.se_create_item(p_business_id,
       case when v_kind='low_value_equipment' then 'equipment' else v_kind end,v_name,null,'each',null);
     update public.se_items set origin_expense_id=e.id,supplier_name=e.supplier_name where id=v_item;
     if v_kind in ('equipment','low_value_equipment') then
       v_available:=nullif(line->>'available_on','')::date;
       if v_kind='equipment' then
         v_life:=nullif(line->>'life_months','')::integer;
         v_residual:=coalesce(nullif(line->>'residual_value','')::numeric,0);
         if v_available is null or coalesce(line->>'book_method','') not in ('SL','DV') or
            v_life is null or v_life<1 or v_life>1200 or
            v_available<e.invoice_date or v_residual<0 or v_residual>v_ex then
           raise exception 'Check equipment ready date, useful life and residual value'; end if;
       else v_available:=coalesce(v_available,e.invoice_date); end if;
       v_asset:=public.se_create_asset(p_business_id,v_item,v_ex+v_gst,v_gst,
         e.invoice_date,v_available,coalesce(e.business_use_percent,100),'unknown','',null,null);
       if v_kind='low_value_equipment' then
         update public.se_assets set tracking_treatment='low_value' where id=v_asset;
       end if;
     else
       v_movement:=public.se_record_movement(p_business_id,v_item,'purchase',v_quantity,
         v_ex/v_quantity,e.invoice_date,'Reviewed invoice item',null,null);
       update public.se_movements set expense_id=e.id where id=v_movement;
     end if;
   end if;
   result_rows:=result_rows||jsonb_build_array(line||jsonb_build_object(
     'item_id',v_item,'movement_id',v_movement,'asset_id',v_asset));
 end loop;
 if v_total_ex<>e.ex_gst or v_total_gst<>e.gst_amount then
   raise exception 'Item totals must equal bill ex GST and GST totals'; end if;
 insert into public.se_invoice_reviews(business_id,expense_id,revision,rows,
   source_ex_gst,source_gst,reviewed_by,reason)
 values(p_business_id,e.id,coalesce(previous.revision,0)+1,result_rows,e.ex_gst,
   e.gst_amount,auth.uid(),nullif(trim(p_reason),'')) returning id into v_review;
 insert into public.se_activity(business_id,actor,action,detail) values
 (p_business_id,auth.uid(),'invoice_review',jsonb_build_object('expense_id',e.id,
  'revision',coalesce(previous.revision,0)+1,'review_id',v_review));
 return v_review;
end $$;
revoke all on function public.se_review_invoice(uuid,uuid,integer,jsonb,text) from public,anon;
grant execute on function public.se_review_invoice(uuid,uuid,integer,jsonb,text) to authenticated;

-- Payments and bank reconciliation may still update the bill; changing a reviewed
-- purchase's source amounts or tax basis requires a separate correction workflow.
create function public.se_guard_reviewed_bill() returns trigger
language plpgsql set search_path=public as $$
begin
 if exists(select 1 from public.se_invoice_reviews r where r.expense_id=old.id) and
   (new.ex_gst is distinct from old.ex_gst or new.gst_amount is distinct from old.gst_amount
    or new.total_amount is distinct from old.total_amount or new.invoice_date is distinct from old.invoice_date
    or new.is_split is distinct from old.is_split or new.business_use_percent is distinct from old.business_use_percent
    or new.archived is distinct from old.archived) then
   raise exception 'This bill has confirmed item allocations. Review an accounting correction before changing its amounts'; end if;
 return new;
end $$;
create trigger se_guard_reviewed_bill before update on public.expenses for each row
 execute function public.se_guard_reviewed_bill();
revoke all on function public.se_guard_reviewed_bill() from public,anon,authenticated;

create function public.se_guard_reviewed_expense_line() returns trigger
language plpgsql set search_path=public as $$
begin
 if exists(select 1 from public.se_invoice_reviews r where r.expense_id=old.expense_id) then
   raise exception 'This bill has confirmed item allocations. Review an accounting correction before changing its split lines'; end if;
 return old;
end $$;
create trigger se_guard_reviewed_expense_line before update or delete on public.expense_lines for each row
 execute function public.se_guard_reviewed_expense_line();
revoke all on function public.se_guard_reviewed_expense_line() from public,anon,authenticated;

commit;
