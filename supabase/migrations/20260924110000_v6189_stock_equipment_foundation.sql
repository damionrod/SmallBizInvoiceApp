-- Offline-only release. Apply after review; this migration deliberately changes no
-- legacy invoices, expenses, GST returns, financial postings or historical reports.
begin;

insert into public.modules(name,slug,description,monthly_price,is_active)
select 'Stock & Equipment','stock_equipment','Track goods for sale, work supplies and equipment.',0,false
where not exists (select 1 from public.modules where slug='stock_equipment');

create table public.se_rule_versions (
 id uuid primary key default gen_random_uuid(), version integer not null unique,
 status text not null default 'draft' check(status in ('draft','published','retired')),
 effective_from date not null, effective_to date,
 low_value_limit numeric(14,2) check(low_value_limit>0),
 investment_boost_percent numeric(6,2) check(investment_boost_percent between 0 and 100),
 investment_boost_from date, source_url text not null,
 review_note text not null default '', rules jsonb not null default '{}'::jsonb,
 created_by uuid, approved_by uuid, approved_at timestamptz,
 created_at timestamptz not null default now(),
 check(effective_to is null or effective_to>=effective_from)
);
-- A later approved correction may replace a published reference for the same date.
-- Both versions remain in history; no existing asset or filing is rewritten.
create table public.se_rule_audit (
 id uuid primary key default gen_random_uuid(), rule_id uuid references public.se_rule_versions(id),
 action text not null, actor uuid, note text, detail jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
-- IRD publishes a $1,000 low-value threshold and Investment Boost from 22 May 2025.
-- These figures are a review reference, not a rate decision or automatic tax claim.
insert into public.se_rule_versions(version,status,effective_from,low_value_limit,
 investment_boost_percent,investment_boost_from,source_url,review_note)
values(1,'draft','2025-05-22',1000,20,'2025-05-22',
 'https://www.ird.govt.nz/income-tax/income-tax-for-businesses-and-organisations/types-of-business-expenses/depreciation/claiming-depreciation',
 'Verify each asset, grouped purchases, GST basis and IRD category rate before publishing or claiming.');

create table public.se_items (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id),
 kind text not null check(kind in ('stock','supplies','equipment')),
 name text not null check(length(trim(name))>0), sku text, unit text not null default 'each',
 supplier_name text, sale_price numeric(14,2), low_stock_at numeric(14,3),
 quantity numeric(14,3) not null default 0 check(quantity>=0),
 value_ex_gst numeric(14,2) not null default 0 check(value_ex_gst>=0),
 origin_expense_id uuid references public.expenses(id),
 source_attachment_id uuid references public.expense_attachments(id),
 archived boolean not null default false, created_by uuid,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(business_id,id)
);
create unique index se_item_sku_unique on public.se_items(business_id,lower(sku)) where sku is not null and not archived;

create table public.se_assets (
 id uuid primary key default gen_random_uuid(), business_id uuid not null,
 item_id uuid not null unique, purchased_on date, available_on date,
 original_cost numeric(14,2) not null check(original_cost>=0), gst_amount numeric(14,2) not null default 0,
 gst_registered boolean, business_use_percent numeric(5,2) not null default 100 check(business_use_percent between 0 and 100),
 book_opening_value numeric(14,2), tax_opening_value numeric(14,2),
 asset_category text, location text, asset_condition text check(asset_condition in ('new','used_nz','used_imported','unknown')),
 tax_treatment text not null default 'needs_review' check(tax_treatment in ('needs_review','low_value','depreciate','not_depreciable')),
 tax_rule_version_id uuid references public.se_rule_versions(id),
 accounting_rate numeric(8,4), tax_rate numeric(8,4), tax_method text check(tax_method in ('SL','DV')),
 last_reviewed_by uuid, disposed_on date, disposal_proceeds numeric(14,2), voided_at timestamptz,
 created_at timestamptz not null default now(),
 foreign key (business_id,item_id) references public.se_items(business_id,id),
 check(book_opening_value>=0 and tax_opening_value>=0 or book_opening_value is null and tax_opening_value is null)
);

create table public.se_movements (
 id uuid primary key default gen_random_uuid(), business_id uuid not null, item_id uuid not null,
 kind text not null check(kind in ('purchase','opening','sale','use','return','stocktake','correction','disposal')),
 quantity_delta numeric(14,3) not null, value_delta numeric(14,2) not null,
 quantity_after numeric(14,3) not null check(quantity_after>=0),
 value_after numeric(14,2) not null check(value_after>=0),
 occurred_on date not null, expense_id uuid references public.expenses(id),
 invoice_id uuid references public.invoices(id), job_costing_id uuid references public.job_costings(id),
 invoice_line_index integer, invoice_line_description text,
 reason text not null, created_by uuid not null, created_at timestamptz not null default now(),
 foreign key (business_id,item_id) references public.se_items(business_id,id),
 check(quantity_delta<>0 or value_delta<>0)
);
create index se_movements_business_item on public.se_movements(business_id,item_id,created_at desc);

create table public.se_reviews (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id),
 expense_id uuid not null references public.expenses(id), expense_line_id uuid references public.expense_lines(id),
 item_id uuid, purchase_movement_id uuid, proposed_kind text check(proposed_kind in ('stock','supplies','equipment','regular','needs_review')),
 source_description text, source_ex_gst numeric(14,2), source_gst numeric(14,2),
 quantity numeric(14,3), status text not null default 'needs_review' check(status in ('needs_review','confirmed','dismissed')),
 suggestion_source text, confirmed_by uuid, confirmed_at timestamptz, created_at timestamptz not null default now(),
 foreign key(business_id,item_id) references public.se_items(business_id,id)
);
create unique index se_review_one_per_line on public.se_reviews(business_id,expense_line_id) where expense_line_id is not null;
create unique index se_review_one_per_whole_expense on public.se_reviews(business_id,expense_id) where expense_line_id is null;

create table public.se_activity (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id),
 actor uuid, action text not null, item_id uuid, detail jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

alter table public.se_rule_versions enable row level security;
alter table public.se_rule_audit enable row level security;
alter table public.se_items enable row level security;
alter table public.se_assets enable row level security;
alter table public.se_movements enable row level security;
alter table public.se_reviews enable row level security;
alter table public.se_activity enable row level security;

create policy se_admin_rules_read on public.se_rule_versions for select to authenticated using(public.is_super_admin());
create policy se_admin_rule_audit_read on public.se_rule_audit for select to authenticated using(public.is_super_admin());
create policy se_business_items_read on public.se_items for select to authenticated using(business_id=public.current_business_id());
create policy se_business_assets_read on public.se_assets for select to authenticated using(business_id=public.current_business_id());
create policy se_business_movements_read on public.se_movements for select to authenticated using(business_id=public.current_business_id());
create policy se_business_reviews_read on public.se_reviews for select to authenticated using(business_id=public.current_business_id());
create policy se_business_activity_read on public.se_activity for select to authenticated using(business_id=public.current_business_id());
-- Direct writes are deliberately unavailable: all mutations pass through checked RPCs.
revoke all on public.se_rule_versions,public.se_rule_audit,public.se_items,public.se_assets,
 public.se_movements,public.se_reviews,public.se_activity from anon,authenticated;
grant select on public.se_rule_versions,public.se_rule_audit,public.se_items,public.se_assets,
 public.se_movements,public.se_reviews,public.se_activity to authenticated;

create function public.se_require_access(p_business_id uuid,p_write boolean default true)
returns void language plpgsql security definer set search_path=public as $$
declare allowed boolean; member_role text;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
   raise exception 'No access to this business'; end if;
 select m.role into member_role from public.business_memberships m
 where m.business_id=p_business_id and m.user_id=auth.uid() and m.status='active';
 if member_role is null then raise exception 'Active membership required'; end if;
 if p_write then
   if not public.v6147_can_write_area(p_business_id,'expenses') then raise exception 'Expense editor access and an active subscription are required'; end if;
   select exists(select 1 from public.modules mod where mod.slug='stock_equipment' and mod.is_active=true)
     and coalesce((select case when bm.status='active' then true
           when bm.status='trialing' then bm.trial_ends_at is null or bm.trial_ends_at>now()
           else false end
       from public.business_modules bm join public.modules mod on mod.id=bm.module_id
       where bm.business_id=p_business_id and mod.slug='stock_equipment'),
       (select s.status in ('active','trialing') and 'stock_equipment'=any(pl.included_modules)
       from public.subscriptions s join public.plans pl on pl.id=s.plan_id
       where s.business_id=p_business_id limit 1),false) into allowed;
   if not allowed then raise exception 'Stock & Equipment is not enabled for this business'; end if;
 end if;
end $$;
revoke all on function public.se_require_access(uuid,boolean) from public,anon,authenticated;

-- One transaction updates weighted-average-cost quantity/value and stores the audit event.
create function public.se_record_movement(p_business_id uuid,p_item_id uuid,p_kind text,
 p_quantity numeric,p_unit_cost numeric,p_occurred_on date,p_reason text,
 p_invoice_id uuid default null,p_job_id uuid default null,p_invoice_line_index integer default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare i public.se_items%rowtype; delta numeric(14,3); cost numeric(14,2); new_quantity numeric(14,3);
 new_value numeric(14,2); m_id uuid; invoice_items jsonb; invoice_line jsonb; line_desc text;
begin
 perform public.se_require_access(p_business_id,true);
 if p_kind not in ('opening','purchase','sale','use','return','stocktake') then raise exception 'Unsupported stock movement'; end if;
 if p_quantity<=0 or p_quantity is null then raise exception 'Enter a positive quantity'; end if;
 select * into i from public.se_items where id=p_item_id and business_id=p_business_id for update;
 if not found or i.archived or i.kind='equipment' then raise exception 'Active stock or supplies item required'; end if;
 if p_invoice_id is not null and not exists(select 1 from public.invoices where id=p_invoice_id and business_id=p_business_id)
   then raise exception 'Invoice does not belong to this business'; end if;
 if p_job_id is not null and not exists(select 1 from public.job_costings where id=p_job_id and business_id=p_business_id)
   then raise exception 'Job does not belong to this business'; end if;
 if p_kind='sale' then
   if i.kind<>'stock' or p_invoice_id is null or p_invoice_line_index is null then
     raise exception 'Select a sales invoice and a specific invoice line'; end if;
   select to_jsonb(items) into invoice_items from public.invoices where id=p_invoice_id and business_id=p_business_id;
   if jsonb_typeof(invoice_items)<>'array' or p_invoice_line_index<0 or p_invoice_line_index>=jsonb_array_length(invoice_items) then
     raise exception 'Invoice line is unavailable'; end if;
   invoice_line:=invoice_items->p_invoice_line_index;
   line_desc:=nullif(trim(invoice_line->>'description'),'');
   if line_desc is null then raise exception 'Invoice line needs a description'; end if;
   if (invoice_line->>'qty') is null or (invoice_line->>'qty') !~ '^[0-9]+(\.[0-9]+)?$' then
     raise exception 'Invoice line has no reliable quantity; ask an accountant to review the sale'; end if;
   if (invoice_line->>'qty')::numeric<=0 then raise exception 'Invoice line quantity must be positive'; end if;
   if (invoice_line->>'qty') ~ '^[0-9]+(\.[0-9]+)?$' then
     if (select coalesce(sum(-m.quantity_delta),0) from public.se_movements m
         where m.business_id=p_business_id and m.invoice_id=p_invoice_id
           and m.invoice_line_index=p_invoice_line_index and m.kind='sale') + p_quantity > (invoice_line->>'qty')::numeric then
       raise exception 'Quantity exceeds the selected invoice line'; end if;
   end if;
   -- The owner explicitly chooses the item and the line. No automatic text match is used.
 end if;
 if p_kind='use' and i.kind<>'supplies' then raise exception 'Only work supplies can be used'; end if;
 if p_kind in ('opening','purchase','return') then
   if p_unit_cost is null or p_unit_cost<0 then raise exception 'Enter a non-negative unit cost'; end if;
   delta:=p_quantity;cost:=round(p_quantity*p_unit_cost,2);
 else
   if p_kind='stocktake' and p_quantity>=i.quantity then raise exception 'Record additions as purchases or returns'; end if;
   delta:=-p_quantity;
   if i.quantity<p_quantity then raise exception 'Not enough units available'; end if;
   cost:=case when p_quantity=i.quantity then i.value_ex_gst else round(i.value_ex_gst*p_quantity/i.quantity,2) end;
   cost:=-cost;
 end if;
 new_quantity:=i.quantity+delta;new_value:=i.value_ex_gst+cost;
 if new_quantity=0 then new_value:=0; end if;
 if new_value<0 then raise exception 'Stock value cannot be negative'; end if;
 update public.se_items set quantity=new_quantity,value_ex_gst=new_value,updated_at=now() where id=i.id;
 insert into public.se_movements(business_id,item_id,kind,quantity_delta,value_delta,quantity_after,value_after,
 occurred_on,invoice_id,job_costing_id,invoice_line_index,invoice_line_description,reason,created_by)
 values(p_business_id,i.id,p_kind,delta,cost,new_quantity,new_value,
 coalesce(p_occurred_on,current_date),p_invoice_id,p_job_id,p_invoice_line_index,line_desc,coalesce(nullif(trim(p_reason),''),'Confirmed by owner'),auth.uid()) returning id into m_id;
 insert into public.se_activity(business_id,actor,action,item_id,detail)
 values(p_business_id,auth.uid(),'movement',i.id,jsonb_build_object('movement_id',m_id,'kind',p_kind,'quantity',delta,'value',cost));
 return m_id;
end $$;
revoke all on function public.se_record_movement(uuid,uuid,text,numeric,numeric,date,text,uuid,uuid,integer) from public,anon;
grant execute on function public.se_record_movement(uuid,uuid,text,numeric,numeric,date,text,uuid,uuid,integer) to authenticated;

create function public.se_create_item(p_business_id uuid,p_kind text,p_name text,p_sku text default null,
 p_unit text default 'each',p_low_stock_at numeric default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
 perform public.se_require_access(p_business_id,true);
 if p_kind not in ('stock','supplies','equipment') or trim(coalesce(p_name,''))='' then raise exception 'Select a type and name'; end if;
 insert into public.se_items(business_id,kind,name,sku,unit,low_stock_at,created_by)
 values(p_business_id,p_kind,trim(p_name),nullif(trim(coalesce(p_sku,'')),''),
 coalesce(nullif(trim(p_unit),''),'each'),p_low_stock_at,auth.uid()) returning id into new_id;
 insert into public.se_activity(business_id,actor,action,item_id) values(p_business_id,auth.uid(),'item_added',new_id);
 return new_id;
end $$;
revoke all on function public.se_create_item(uuid,text,text,text,text,numeric) from public,anon;
grant execute on function public.se_create_item(uuid,text,text,text,text,numeric) to authenticated;

create function public.se_create_asset(p_business_id uuid,p_item_id uuid,p_original_cost numeric,
 p_gst_amount numeric,p_purchased_on date,p_available_on date,p_business_use numeric,
 p_condition text,p_category text,p_book_opening numeric,p_tax_opening numeric)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid; n text;
begin
 perform public.se_require_access(p_business_id,true);
 select name into n from public.se_items where id=p_item_id and business_id=p_business_id and kind='equipment' for update;
 if n is null then raise exception 'Select equipment owned by this business'; end if;
 if p_original_cost is null or p_original_cost<0 or p_gst_amount<0 or p_gst_amount>p_original_cost then raise exception 'Check purchase and GST amounts'; end if;
 if p_available_on<p_purchased_on then raise exception 'Available date precedes purchase date'; end if;
 if p_business_use not between 0 and 100 then raise exception 'Business use must be 0 to 100 percent'; end if;
 if (p_book_opening is null)<>(p_tax_opening is null) then raise exception 'Provide both opening values'; end if;
 insert into public.se_assets(business_id,item_id,original_cost,gst_amount,purchased_on,available_on,
 business_use_percent,asset_condition,asset_category,book_opening_value,tax_opening_value)
 values(p_business_id,p_item_id,p_original_cost,p_gst_amount,p_purchased_on,p_available_on,
 p_business_use,p_condition,nullif(trim(p_category),''),p_book_opening,p_tax_opening) returning id into new_id;
 insert into public.se_activity(business_id,actor,action,item_id,detail)
 values(p_business_id,auth.uid(),'asset_added',p_item_id,jsonb_build_object('asset_id',new_id,'needs_tax_review',true));
 return new_id;
end $$;
revoke all on function public.se_create_asset(uuid,uuid,numeric,numeric,date,date,numeric,text,text,numeric,numeric) from public,anon;
grant execute on function public.se_create_asset(uuid,uuid,numeric,numeric,date,date,numeric,text,text,numeric,numeric) to authenticated;

-- Atomic opening creation: an exception rolls back BOTH the item and asset inserts.
create function public.se_create_opening_asset(p_business_id uuid,p_name text,p_original_cost numeric,
 p_gst_amount numeric,p_purchased_on date,p_available_on date,p_business_use numeric,
 p_condition text,p_category text,p_book_opening numeric,p_tax_opening numeric)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_item uuid;
begin
 perform public.se_require_access(p_business_id,true);
 if nullif(trim(coalesce(p_name,'')),'') is null or p_book_opening is null or p_tax_opening is null
    then raise exception 'Opening equipment needs a name and both opening values'; end if;
 if p_original_cost is null or p_original_cost<0 or p_gst_amount is null or p_gst_amount<0
    or p_gst_amount>p_original_cost or p_available_on<p_purchased_on or p_business_use not between 0 and 100
    or p_book_opening<0 or p_tax_opening<0 then raise exception 'Check equipment values'; end if;
 v_item:=public.se_create_item(p_business_id,'equipment',p_name,null,'each',null);
 perform public.se_create_asset(p_business_id,v_item,p_original_cost,p_gst_amount,p_purchased_on,
     p_available_on,p_business_use,p_condition,p_category,p_book_opening,p_tax_opening);
 return v_item;
end $$;
revoke all on function public.se_create_opening_asset(uuid,text,numeric,numeric,date,date,numeric,text,text,numeric,numeric) from public,anon;
grant execute on function public.se_create_opening_asset(uuid,text,numeric,numeric,date,date,numeric,text,text,numeric,numeric) to authenticated;

-- The source amount always comes from the actual recorded bill, never AI or browser arithmetic.
create function public.se_confirm_purchase(p_business_id uuid,p_expense_id uuid,
 p_expense_line_id uuid,p_kind text,p_item_name text,p_quantity numeric,
 p_existing_item_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare exp public.expenses%rowtype; ln public.expense_lines%rowtype;
 source_amount numeric(14,2); source_gst numeric(14,2); item_id uuid; movement_id uuid;
 review_id uuid; existing public.se_reviews%rowtype; asset_id uuid; v_selected_item uuid;
begin
 perform public.se_require_access(p_business_id,true);
 if p_kind not in ('stock','supplies','equipment','regular','needs_review') then raise exception 'Select how the purchase is used'; end if;
 select * into exp from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found then raise exception 'The supplier bill is unavailable'; end if;
 if exp.payment_status='draft' then raise exception 'Record the bill before classifying it'; end if;
 if p_expense_line_id is not null then
   select * into ln from public.expense_lines where id=p_expense_line_id and expense_id=exp.id;
   if not found then raise exception 'This line does not belong to the supplier bill'; end if;
   source_amount:=ln.ex_gst;source_gst:=ln.gst_amount;
 else
   if exp.is_split then raise exception 'Select an individual line for a split supplier bill'; end if;
   source_amount:=exp.ex_gst;source_gst:=exp.gst_amount;
 end if;
 if source_amount<0 then raise exception 'Use the return workflow for a supplier credit'; end if;
 select * into existing from public.se_reviews
 where business_id=p_business_id and expense_id=exp.id
 and expense_line_id is not distinct from p_expense_line_id for update;
 if found and existing.status='confirmed' then raise exception 'This purchase is already confirmed. Use a correction.'; end if;
 if p_kind in ('stock','supplies','equipment') then
   if p_quantity is null or p_quantity<=0 or trim(coalesce(p_item_name,''))='' then raise exception 'Enter an item and quantity'; end if;
   if p_existing_item_id is not null then
     select id into item_id from public.se_items where id=p_existing_item_id
       and business_id=p_business_id and kind=p_kind and not archived for update;
     if item_id is null then raise exception 'Select an item of the same type from this business'; end if;
   else
     item_id:=public.se_create_item(p_business_id,p_kind,p_item_name,null,'each',null);
     update public.se_items set origin_expense_id=exp.id,supplier_name=exp.supplier_name where id=item_id;
   end if;
   if p_kind='equipment' then
     if p_quantity<>1 or p_existing_item_id is not null then raise exception 'Record each piece of equipment separately'; end if;
     asset_id:=public.se_create_asset(p_business_id,item_id,source_amount+source_gst,source_gst,
       exp.invoice_date,exp.invoice_date,coalesce(exp.business_use_percent,100),
       'unknown','',null,null);
   else
     movement_id:=public.se_record_movement(p_business_id,item_id,'purchase',p_quantity,
       source_amount/p_quantity,exp.invoice_date,'Purchase from supplier bill',null,null);
     update public.se_movements set expense_id=exp.id where id=movement_id;
   end if;
 end if;
 v_selected_item:=item_id;
 if existing.id is null then
   insert into public.se_reviews(business_id,expense_id,expense_line_id,item_id,proposed_kind,
      source_description,source_ex_gst,source_gst,quantity,status,suggestion_source,confirmed_by,confirmed_at,purchase_movement_id)
   values(p_business_id,exp.id,p_expense_line_id,item_id,p_kind,
     coalesce(ln.description,exp.description),source_amount,source_gst,p_quantity,
     case when p_kind='needs_review' then 'needs_review' else 'confirmed' end,
     'owner_confirmation',auth.uid(),case when p_kind='needs_review' then null else now() end,movement_id)
   returning id into review_id;
 else
   update public.se_reviews set item_id=v_selected_item,purchase_movement_id=movement_id,proposed_kind=p_kind,
     source_ex_gst=source_amount,source_gst=source_gst,quantity=p_quantity,
     status=case when p_kind='needs_review' then 'needs_review' else 'confirmed' end,
     confirmed_by=auth.uid(),confirmed_at=case when p_kind='needs_review' then null else now() end
   where id=existing.id returning id into review_id;
 end if;
 insert into public.se_activity(business_id,actor,action,item_id,detail)
 values(p_business_id,auth.uid(),'purchase_review',item_id,
   jsonb_build_object('review_id',review_id,'expense_id',p_expense_id,'classification',p_kind));
 return review_id;
end $$;
revoke all on function public.se_confirm_purchase(uuid,uuid,uuid,text,text,numeric,uuid) from public,anon;
grant execute on function public.se_confirm_purchase(uuid,uuid,uuid,text,text,numeric,uuid) to authenticated;

-- Compensating correction is allowed only if the purchase is untouched: once goods
-- have moved, only an accountant-led correction can resolve their financial history.
create function public.se_correct_purchase(p_business_id uuid,p_review_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.se_reviews%rowtype; i public.se_items%rowtype; m public.se_movements%rowtype;
begin
 perform public.se_require_access(p_business_id,true);
 if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Explain the correction'; end if;
 select * into r from public.se_reviews where id=p_review_id and business_id=p_business_id for update;
 if not found or r.status<>'confirmed' then raise exception 'Choose a confirmed purchase'; end if;
 if r.item_id is not null then
   select * into i from public.se_items where id=r.item_id and business_id=p_business_id for update;
   if i.kind='equipment' then
     if exists(select 1 from public.se_assets a where a.item_id=i.id and (a.disposed_on is not null or a.voided_at is not null))
       then raise exception 'Disposed equipment needs accountant review'; end if;
     update public.se_assets set voided_at=now() where item_id=i.id;
     update public.se_items set archived=true where id=i.id;
   else
     select * into m from public.se_movements where business_id=p_business_id and item_id=i.id
       and id=r.purchase_movement_id and kind='purchase' limit 1;
     if not found or m.quantity_delta<>r.quantity then raise exception 'Purchase movement needs accountant review'; end if;
     if exists(select 1 from public.se_movements where business_id=p_business_id and item_id=i.id and created_at>m.created_at)
        or i.quantity<m.quantity_delta or i.value_ex_gst<m.value_delta then
       raise exception 'Stock has changed since this purchase. Ask an accountant to review the correction'; end if;
     update public.se_items set quantity=quantity-m.quantity_delta,value_ex_gst=value_ex_gst-m.value_delta,updated_at=now() where id=i.id;
     insert into public.se_movements(business_id,item_id,kind,quantity_delta,value_delta,quantity_after,value_after,occurred_on,expense_id,reason,created_by)
      values(p_business_id,i.id,'correction',-m.quantity_delta,-m.value_delta,i.quantity-m.quantity_delta,i.value_ex_gst-m.value_delta,current_date,r.expense_id,p_reason,auth.uid());
   end if;
 end if;
 update public.se_reviews set status='needs_review',confirmed_at=null,confirmed_by=null,item_id=null
 where id=r.id;
 insert into public.se_activity(business_id,actor,action,item_id,detail)
 values(p_business_id,auth.uid(),'purchase_corrected',r.item_id,
 jsonb_build_object('review_id',r.id,'old_kind',r.proposed_kind,'reason',p_reason));
end $$;
revoke all on function public.se_correct_purchase(uuid,uuid,text) from public,anon;
grant execute on function public.se_correct_purchase(uuid,uuid,text) to authenticated;

create function public.se_save_rule_draft(p_effective_from date,p_low_value numeric,
 p_boost_percent numeric,p_boost_from date,p_source_url text,p_note text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
 if not public.is_super_admin() then raise exception 'Super Admin required'; end if;
 if p_effective_from is null or p_low_value<=0 or p_boost_percent not between 0 and 100
   or p_source_url not like 'https://www.ird.govt.nz/%' then raise exception 'Check official source and rule values'; end if;
 insert into public.se_rule_versions(version,status,effective_from,low_value_limit,investment_boost_percent,
 investment_boost_from,source_url,review_note,created_by)
 values((select coalesce(max(version),0)+1 from public.se_rule_versions),'draft',p_effective_from,
 p_low_value,p_boost_percent,p_boost_from,p_source_url,coalesce(p_note,''),auth.uid()) returning id into new_id;
 insert into public.se_rule_audit(rule_id,action,actor,note) values(new_id,'draft_created',auth.uid(),p_note);
 return new_id;
end $$;
revoke all on function public.se_save_rule_draft(date,numeric,numeric,date,text,text) from public,anon;
grant execute on function public.se_save_rule_draft(date,numeric,numeric,date,text,text) to authenticated;

create function public.se_publish_rule(p_id uuid,p_note text)
returns void language plpgsql security definer set search_path=public as $$
declare v public.se_rule_versions%rowtype;
begin
 if not public.is_super_admin() then raise exception 'Super Admin required'; end if;
 select * into v from public.se_rule_versions where id=p_id for update;
 if not found or v.status<>'draft' then raise exception 'Only drafts can be published'; end if;
 if nullif(trim(coalesce(p_note,'')),'') is null then raise exception 'Record your approval notes'; end if;
 if exists(select 1 from public.se_rule_versions where status='published' and effective_from=v.effective_from) then
   update public.se_rule_versions set status='retired' where status='published' and effective_from=v.effective_from;
   insert into public.se_rule_audit(rule_id,action,actor,note) values(v.id,'same_date_reference_correction',auth.uid(),p_note);
 end if;
 update public.se_rule_versions set status='published',approved_by=auth.uid(),approved_at=now() where id=v.id;
 insert into public.se_rule_audit(rule_id,action,actor,note) values(v.id,'published',auth.uid(),p_note);
end $$;
revoke all on function public.se_publish_rule(uuid,text) from public,anon;
grant execute on function public.se_publish_rule(uuid,text) to authenticated;

-- A disposal is an auditable operational event. It never posts a balancing tax adjustment.
create function public.se_record_disposal(p_business_id uuid,p_asset_id uuid,p_disposed_on date,
 p_proceeds numeric,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v public.se_assets%rowtype;
begin
 perform public.se_require_access(p_business_id,true);
 if p_disposed_on is null or p_proceeds is null or p_proceeds<0 or
    nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Enter date, proceeds and reason'; end if;
 select * into v from public.se_assets where id=p_asset_id and business_id=p_business_id for update;
 if not found or v.disposed_on is not null then raise exception 'Equipment is missing or already disposed'; end if;
 if v.purchased_on is not null and p_disposed_on<v.purchased_on then raise exception 'Disposal precedes purchase'; end if;
 update public.se_assets set disposed_on=p_disposed_on,disposal_proceeds=p_proceeds where id=v.id;
 insert into public.se_activity(business_id,actor,action,item_id,detail)
 values(p_business_id,auth.uid(),'asset_disposed',v.item_id,
 jsonb_build_object('asset_id',v.id,'proceeds',p_proceeds,'date',p_disposed_on,'reason',p_reason,'accountant_review',true));
 return v.id;
end $$;
revoke all on function public.se_record_disposal(uuid,uuid,date,numeric,text) from public,anon;
grant execute on function public.se_record_disposal(uuid,uuid,date,numeric,text) to authenticated;

commit;
