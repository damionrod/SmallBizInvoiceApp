-- Core purchase review is available with Expenses, independently of the optional
-- Stock & Equipment subscription. Existing expense documents/payments remain sources.
create table if not exists public.purchase_document_items (
 business_id uuid not null references public.businesses(id),
 expense_id uuid primary key references public.expenses(id),
 attachment_ids uuid[] not null default '{}',
 proposals jsonb not null check(jsonb_typeof(proposals)='array'),
 scanned_at timestamptz not null default now(),
 saved_by uuid not null,
 unique(business_id,expense_id)
);
create table if not exists public.purchase_invoice_reviews (
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
create index if not exists purchase_invoice_reviews_latest on public.purchase_invoice_reviews(business_id,expense_id,revision desc);
alter table public.purchase_document_items enable row level security;
alter table public.purchase_invoice_reviews enable row level security;
drop policy if exists purchase_document_items_read on public.purchase_document_items;
create policy purchase_document_items_read on public.purchase_document_items for select to authenticated
 using(business_id=public.current_business_id() and public.v6147_can_read_area(business_id,'expenses'));
drop policy if exists purchase_invoice_reviews_read on public.purchase_invoice_reviews;
create policy purchase_invoice_reviews_read on public.purchase_invoice_reviews for select to authenticated
 using(business_id=public.current_business_id() and public.v6147_can_read_area(business_id,'expenses'));
revoke all on public.purchase_document_items,public.purchase_invoice_reviews from anon,authenticated;
grant select on public.purchase_document_items,public.purchase_invoice_reviews to authenticated;

-- Keep reviews already confirmed through the optional register visible in Expenses.
-- The original operational history remains intact and is never replayed here.
do $$ begin
 if to_regclass('public.se_invoice_reviews') is not null then
  insert into public.purchase_invoice_reviews
    (business_id,expense_id,revision,rows,source_ex_gst,source_gst,reviewed_by,reviewed_at,reason)
  select business_id,expense_id,revision,rows,source_ex_gst,source_gst,reviewed_by,reviewed_at,reason
    from public.se_invoice_reviews
  on conflict (business_id,expense_id,revision) do nothing;
 end if;
end $$;

create or replace function public.v6190_save_purchase_scan(p_business_id uuid,p_expense_id uuid,p_attachment_ids uuid[],p_items jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare v_attachment uuid;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id
    or not public.v6147_can_write_area(p_business_id,'expenses') then raise exception 'Expense access denied'; end if;
 perform 1 from public.expenses where id=p_expense_id and business_id=p_business_id and coalesce(archived,false)=false for update;
 if not found then raise exception 'Bill not available'; end if;
 if exists(select 1 from public.purchase_invoice_reviews where business_id=p_business_id and expense_id=p_expense_id)
    then raise exception 'Confirmed items cannot be replaced by an AI scan'; end if;
 if p_attachment_ids is null or cardinality(p_attachment_ids) not between 1 and 20
    or cardinality(p_attachment_ids)<>cardinality(array(select distinct x from unnest(p_attachment_ids) x))
    or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>150 then raise exception 'Invalid invoice pages or item proposals'; end if;
 foreach v_attachment in array p_attachment_ids loop
   if not exists(select 1 from public.expense_attachments where id=v_attachment and expense_id=p_expense_id and business_id=p_business_id)
     then raise exception 'An invoice page does not belong to this bill'; end if;
 end loop;
 insert into public.purchase_document_items(business_id,expense_id,attachment_ids,proposals,saved_by)
 values(p_business_id,p_expense_id,p_attachment_ids,p_items,auth.uid())
 on conflict(expense_id) do update set attachment_ids=excluded.attachment_ids,proposals=excluded.proposals,scanned_at=now(),saved_by=excluded.saved_by;
end $$;
revoke all on function public.v6190_save_purchase_scan(uuid,uuid,uuid[],jsonb) from public,anon;
grant execute on function public.v6190_save_purchase_scan(uuid,uuid,uuid[],jsonb) to authenticated;

-- An invoice is confirmed once in this transaction. No change to the supplier
-- payable, source GST, payments or bank allocations occurs here.
create or replace function public.v6190_review_purchase(p_business_id uuid,p_expense_id uuid,p_expected_revision integer,p_rows jsonb,p_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_bill public.expenses%rowtype; v_previous public.purchase_invoice_reviews%rowtype;
 v_line jsonb; v_category uuid; v_ex numeric; v_gst numeric; v_qty numeric;
 v_ex_total numeric:=0;v_gst_total numeric:=0;v_id uuid;v_date date;v_life integer;
 v_se_revision integer;v_stock_enabled boolean;
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
  if jsonb_typeof(v_line)<>'object' or coalesce(v_line->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment')
     or length(trim(coalesce(v_line->>'description',''))) not between 1 and 500
     or nullif(v_line->>'category_id','') is null or nullif(v_line->>'ex_gst','') is null
     or nullif(v_line->>'gst','') is null or nullif(v_line->>'quantity','') is null then raise exception 'Complete every item, category, quantity and GST amount'; end if;
  begin
   v_category:=(v_line->>'category_id')::uuid;v_ex:=(v_line->>'ex_gst')::numeric;
   v_gst:=(v_line->>'gst')::numeric;v_qty:=(v_line->>'quantity')::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Invalid item category or amount'; end;
  if not exists(select 1 from public.expense_categories c where c.id=v_category and c.business_id=p_business_id and not c.archived)
     or v_ex<0 or v_gst<0 or v_qty<=0 or v_qty>1000000 or v_ex<>round(v_ex,2) or v_gst<>round(v_gst,2)
     then raise exception 'Check category, amount and quantity on every item'; end if;
  if v_line->>'kind'='equipment' then
   begin v_date:=(v_line->>'available_on')::date;v_life:=(v_line->>'life_months')::integer;
   exception when invalid_datetime_format or invalid_text_representation then raise exception 'Check the equipment ready date and life'; end;
   if v_date is null or v_date<v_bill.invoice_date or v_life not between 1 and 1200
      or coalesce(v_line->>'book_method','') not in ('SL','DV') then raise exception 'Equipment needs a ready date, useful life and method'; end if;
  end if;
  v_ex_total:=v_ex_total+v_ex;v_gst_total:=v_gst_total+v_gst;
 end loop;
 if v_ex_total<>v_bill.ex_gst or v_gst_total<>v_bill.gst_amount then raise exception 'Item ex GST and GST totals must match the bill exactly'; end if;
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
   perform public.se_review_invoice(p_business_id,p_expense_id,v_se_revision,p_rows,p_reason);
 end if;
 insert into public.purchase_invoice_reviews(business_id,expense_id,revision,rows,source_ex_gst,source_gst,reviewed_by,reason)
 values(p_business_id,p_expense_id,coalesce(v_previous.revision,0)+1,p_rows,v_bill.ex_gst,v_bill.gst_amount,auth.uid(),nullif(trim(p_reason),'')) returning id into v_id;
 return v_id;
end $$;
revoke all on function public.v6190_review_purchase(uuid,uuid,integer,jsonb,text) from public,anon;
grant execute on function public.v6190_review_purchase(uuid,uuid,integer,jsonb,text) to authenticated;
