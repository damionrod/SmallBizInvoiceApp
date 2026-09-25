-- Same-invoice discounts are signed review lines linked to positive charge rows.
-- No change to source bills, GST returns, bank allocations, posted journals or entitlements.
begin;

-- Keep the signed source rows in purchase_invoice_reviews. Operational stock/assets
-- receive a net cost for each linked charge; discounts never create negative units.
create or replace function public.v6190_net_purchase_rows(p_rows jsonb)
returns jsonb language plpgsql immutable set search_path=public as $$
declare v_line jsonb; v_discount jsonb; v_result jsonb:='[]'::jsonb;
 v_i integer:=0;v_ex numeric;v_gst numeric;
begin
 if jsonb_typeof(p_rows)<>'array' then raise exception 'Invoice rows must be an array'; end if;
 for v_line in select value from jsonb_array_elements(p_rows) loop
  if v_line->>'kind'<>'discount' then
   v_ex:=(v_line->>'ex_gst')::numeric;v_gst:=(v_line->>'gst')::numeric;
   for v_discount in select value from jsonb_array_elements(p_rows) loop
    if v_discount->>'kind'='discount' and v_discount->>'discount_target_index'=v_i::text then
     v_ex:=v_ex+(v_discount->>'ex_gst')::numeric;
     v_gst:=v_gst+(v_discount->>'gst')::numeric;
    end if;
   end loop;
   if v_ex<0 or v_gst<0 or (v_line->>'kind'<>'regular' and v_ex<=0) then
    raise exception 'A discount exceeds its linked charge; split the discount across charges'; end if;
   v_result:=v_result||jsonb_build_array(v_line||jsonb_build_object('ex_gst',v_ex,'gst',v_gst));
  end if;
  v_i:=v_i+1;
 end loop;
 return v_result;
end $$;
revoke all on function public.v6190_net_purchase_rows(jsonb) from public,anon,authenticated;

create or replace function public.v6190_review_purchase(p_business_id uuid,p_expense_id uuid,p_expected_revision integer,p_rows jsonb,p_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_bill public.expenses%rowtype; v_previous public.purchase_invoice_reviews%rowtype;
 v_line jsonb; v_category uuid; v_ex numeric; v_gst numeric; v_qty numeric;
 v_ex_total numeric:=0;v_gst_total numeric:=0;v_id uuid;v_date date;v_life integer;
 v_se_revision integer;v_stock_enabled boolean;v_target jsonb;v_index integer:=0;v_line_number integer:=0;v_net_rows jsonb;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id
    or not public.v6147_can_write_area(p_business_id,'expenses') then raise exception 'Expense access denied'; end if;
 select * into v_bill from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found or v_bill.payment_status='draft' or coalesce(v_bill.archived,false)
    or coalesce(v_bill.lifecycle_state,'recorded')<>'recorded' then raise exception 'Record an active bill before review'; end if;
 if exists(select 1 from public.accounting_journals where business_id=p_business_id and source_type='expense'
    and source_id=p_expense_id and status='posted') then raise exception 'A posted bill requires an accountant-approved reclassification'; end if;
 if exists(select 1 from public.accounting_periods where business_id=p_business_id
    and status='closed' and v_bill.invoice_date between period_start and period_end)
    or exists(select 1 from public.gst_returns where business_id=p_business_id and status='finalised'
    and v_bill.invoice_date between period_start and period_end)
   then raise exception 'This bill is in a closed accounting or GST period; request an adjustment'; end if;
 select * into v_previous from public.purchase_invoice_reviews where business_id=p_business_id
   and expense_id=p_expense_id order by revision desc limit 1 for update;
 if coalesce(v_previous.revision,0)<>coalesce(p_expected_revision,-1) then raise exception 'The review changed; reload before saving'; end if;
 if v_previous.id is not null and nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Give a reason for correcting a confirmed review'; end if;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 150 then raise exception 'Review between 1 and 150 items'; end if;
 for v_line in select value from jsonb_array_elements(p_rows) loop
  if jsonb_typeof(v_line)<>'object' or coalesce(v_line->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment','discount')
     or length(trim(coalesce(v_line->>'description',''))) not between 1 and 500
     or nullif(v_line->>'category_id','') is null or nullif(v_line->>'ex_gst','') is null
     or nullif(v_line->>'gst','') is null or nullif(v_line->>'quantity','') is null then raise exception 'Complete every item, category, quantity and GST amount'; end if;
  begin
   v_category:=(v_line->>'category_id')::uuid;v_ex:=(v_line->>'ex_gst')::numeric;
   v_gst:=(v_line->>'gst')::numeric;v_qty:=(v_line->>'quantity')::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Invalid item category or amount'; end;
  if not exists(select 1 from public.expense_categories c where c.id=v_category and c.business_id=p_business_id and not c.archived)
     or v_qty<=0 or v_qty>1000000 or v_ex<>round(v_ex,2) or v_gst<>round(v_gst,2)
     then raise exception 'Check category, amount and quantity on every item'; end if;
  if v_line->>'kind'='discount' then
   -- A same-invoice discount belongs to an earlier charge, in the same expense category.
   if coalesce(v_line->>'discount_target_index','') !~ '^[0-9]+$' then
     raise exception 'Choose which invoice charge this discount reduces'; end if;
   v_index:=(v_line->>'discount_target_index')::integer;
   if v_index>=v_line_number or v_ex>=0 or v_gst>0 or v_qty<>1 then
     raise exception 'Check the discount amount and its earlier charge'; end if;
   v_target:=p_rows->v_index;
   if coalesce(v_target->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment')
      or v_target->>'category_id' is distinct from v_line->>'category_id'
      or v_line->>'discount_for' is distinct from v_target->>'kind' then
     raise exception 'Discount must reduce a charge in the same category and Use'; end if;
  elsif v_ex<0 or v_gst<0 then
   raise exception 'Use a discount row for a negative amount';
  end if;
  if v_line->>'kind'='equipment' then
   begin v_date:=(v_line->>'available_on')::date;v_life:=(v_line->>'life_months')::integer;
   exception when invalid_datetime_format or invalid_text_representation then raise exception 'Check the equipment ready date and life'; end;
   if v_date is null or v_date<v_bill.invoice_date or v_life not between 1 and 1200
      or coalesce(v_line->>'book_method','') not in ('SL','DV') then raise exception 'Equipment needs a ready date, useful life and method'; end if;
  end if;
  v_ex_total:=v_ex_total+v_ex;v_gst_total:=v_gst_total+v_gst;v_line_number:=v_line_number+1;
 end loop;
 if v_ex_total<>v_bill.ex_gst or v_gst_total<>v_bill.gst_amount then raise exception 'Item ex GST and GST totals must match the bill exactly'; end if;
 v_net_rows:=public.v6190_net_purchase_rows(p_rows);
 select exists(select 1 from public.modules m where m.slug='stock_equipment' and m.is_active)
   and coalesce((select case when bm.status='active' then true
                   when bm.status='trialing' then bm.trial_ends_at is null or bm.trial_ends_at>now()
                   else false end from public.business_modules bm join public.modules m on m.id=bm.module_id
                 where bm.business_id=p_business_id and m.slug='stock_equipment' and m.is_active),
                (select s.status in ('active','trialing') and 'stock_equipment'=any(pl.included_modules)
                   from public.subscriptions s join public.plans pl on pl.id=s.plan_id
                  where s.business_id=p_business_id limit 1),false) into v_stock_enabled;
 if v_stock_enabled then
   select coalesce(max(revision),0) into v_se_revision from public.se_invoice_reviews
    where business_id=p_business_id and expense_id=p_expense_id;
   perform public.se_review_invoice(p_business_id,p_expense_id,v_se_revision,v_net_rows,p_reason);
 end if;
 insert into public.purchase_invoice_reviews(business_id,expense_id,revision,rows,source_ex_gst,source_gst,reviewed_by,reason)
 values(p_business_id,p_expense_id,coalesce(v_previous.revision,0)+1,p_rows,v_bill.ex_gst,v_bill.gst_amount,auth.uid(),nullif(trim(p_reason),'')) returning id into v_id;
 return v_id;
end $$;
revoke all on function public.v6190_review_purchase(uuid,uuid,integer,jsonb,text) from public,anon;
grant execute on function public.v6190_review_purchase(uuid,uuid,integer,jsonb,text) to authenticated;
commit;
