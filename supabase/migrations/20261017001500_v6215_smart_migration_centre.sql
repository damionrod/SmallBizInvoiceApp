-- Frindly v62.15 — Smart Migration Centre
-- Additive migration. Existing operational records and V61.71B import evidence are preserved.

begin;

alter table public.import_sheets add column if not exists source_adapter text not null default 'generic_file';

create table if not exists public.import_records (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.import_batches(id) on delete cascade,
  sheet_id uuid not null references public.import_sheets(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  record_type text not null check (record_type in ('customers','suppliers','invoices','expenses','quotes','stock','equipment','employees','payroll_history')),
  source_external_id text,
  group_key text not null,
  canonical_hash text not null,
  display_label text not null,
  normalized_data jsonb not null default '{}'::jsonb,
  validation_status text not null default 'ready' check (validation_status in ('ready','warning','rejected','skipped','imported','failed')),
  validation_messages jsonb not null default '[]'::jsonb,
  duplicate_status text not null default 'new' check (duplicate_status in ('new','possible','exact','imported')),
  duplicate_action text not null default 'create' check (duplicate_action in ('create','skip','update_safe','historical_reference')),
  commit_mode text not null check (commit_mode in ('native_master','native_opening','native_quote','native_stock','native_asset','native_employee','historical_reference','payroll_history')),
  existing_record_id uuid,
  imported_record_type text,
  imported_record_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists import_records_batch_idx on public.import_records(batch_id,validation_status);
create index if not exists import_records_business_hash_idx on public.import_records(business_id,record_type,canonical_hash);
create index if not exists import_records_business_external_idx on public.import_records(business_id,record_type,source_external_id) where source_external_id is not null;

create table if not exists public.import_record_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  batch_id uuid not null references public.import_batches(id) on delete cascade,
  import_record_id uuid not null references public.import_records(id) on delete cascade,
  import_row_id uuid not null references public.import_rows(id) on delete cascade,
  member_role text not null default 'source',
  created_at timestamptz not null default now(),
  unique(import_record_id,import_row_id)
);

create index if not exists import_record_members_batch_idx on public.import_record_members(batch_id,import_record_id);

create table if not exists public.import_mapping_profiles (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  source_adapter text not null,
  record_type text not null,
  header_signature text not null,
  mapping jsonb not null default '{}'::jsonb,
  confirmed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,source_adapter,record_type,header_signature)
);

create table if not exists public.import_commit_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  batch_id uuid not null references public.import_batches(id) on delete cascade,
  import_record_id uuid not null references public.import_records(id) on delete cascade,
  action text not null,
  result text not null check (result in ('imported','updated','skipped','failed')),
  target_type text,
  target_id uuid,
  detail jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.migration_historical_documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  batch_id uuid not null references public.import_batches(id) on delete restrict,
  import_record_id uuid not null references public.import_records(id) on delete restrict,
  document_type text not null check (document_type in ('invoice','expense')),
  source_platform text not null,
  source_external_id text,
  document_number text,
  document_date date,
  due_date date,
  party_name text not null,
  party_external_id text,
  currency char(3) not null default 'NZD',
  items jsonb not null default '[]'::jsonb,
  subtotal numeric(14,2) not null default 0,
  gst numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  paid_amount numeric(14,2) not null default 0,
  outstanding_amount numeric(14,2) not null default 0,
  source_status text,
  source_evidence jsonb not null default '{}'::jsonb,
  canonical_hash text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(business_id,document_type,canonical_hash)
);

create index if not exists migration_historical_documents_business_date_idx on public.migration_historical_documents(business_id,document_type,document_date desc);
create unique index if not exists migration_historical_documents_external_idx on public.migration_historical_documents(business_id,document_type,source_platform,source_external_id) where source_external_id is not null;

create table if not exists public.payroll_migration_history (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  batch_id uuid not null references public.import_batches(id) on delete restrict,
  import_record_id uuid not null references public.import_records(id) on delete restrict,
  employee_external_id text,
  employee_number text,
  employee_name text not null,
  period_start date,
  period_end date,
  pay_date date,
  gross_pay numeric(14,2) not null default 0,
  paye numeric(14,2) not null default 0,
  deductions numeric(14,2) not null default 0,
  net_pay numeric(14,2) not null default 0,
  source_platform text not null,
  canonical_hash text not null,
  source_evidence jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(business_id,canonical_hash)
);

create table if not exists public.payroll_migration_opening_balances (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  employee_id uuid not null references public.payroll_employees(id) on delete cascade,
  batch_id uuid references public.import_batches(id) on delete set null,
  effective_date date not null,
  gross_ytd numeric(14,2) not null default 0,
  paye_ytd numeric(14,2) not null default 0,
  net_ytd numeric(14,2) not null default 0,
  annual_leave_hours numeric(14,4),
  sick_leave_hours numeric(14,4),
  alternative_holiday_hours numeric(14,4),
  evidence jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(business_id,employee_id,effective_date)
);

alter table public.import_records enable row level security;
alter table public.import_record_members enable row level security;
alter table public.import_mapping_profiles enable row level security;
alter table public.import_commit_events enable row level security;
alter table public.migration_historical_documents enable row level security;
alter table public.payroll_migration_history enable row level security;
alter table public.payroll_migration_opening_balances enable row level security;

drop policy if exists import_records_read on public.import_records;
create policy import_records_read on public.import_records for select to authenticated using (business_id=current_business_id() or is_super_admin());
drop policy if exists import_record_members_read on public.import_record_members;
create policy import_record_members_read on public.import_record_members for select to authenticated using (business_id=current_business_id() or is_super_admin());
drop policy if exists import_mapping_profiles_read on public.import_mapping_profiles;
create policy import_mapping_profiles_read on public.import_mapping_profiles for select to authenticated using (business_id=current_business_id() or is_super_admin());
drop policy if exists import_commit_events_read on public.import_commit_events;
create policy import_commit_events_read on public.import_commit_events for select to authenticated using (business_id=current_business_id() or is_super_admin());
drop policy if exists migration_historical_documents_read on public.migration_historical_documents;
create policy migration_historical_documents_read on public.migration_historical_documents for select to authenticated using (business_id=current_business_id() or is_super_admin());
drop policy if exists payroll_migration_history_read on public.payroll_migration_history;
create policy payroll_migration_history_read on public.payroll_migration_history for select to authenticated using (business_id=current_business_id() or is_super_admin());
drop policy if exists payroll_migration_opening_balances_read on public.payroll_migration_opening_balances;
create policy payroll_migration_opening_balances_read on public.payroll_migration_opening_balances for select to authenticated using (business_id=current_business_id() or is_super_admin());

grant select on public.import_records,public.import_record_members,public.import_mapping_profiles,public.import_commit_events,public.migration_historical_documents,public.payroll_migration_history,public.payroll_migration_opening_balances to authenticated;
revoke insert,update,delete on public.import_records,public.import_record_members,public.import_mapping_profiles,public.import_commit_events,public.migration_historical_documents,public.payroll_migration_history,public.payroll_migration_opening_balances from anon,authenticated;

-- Dev was missing the opening-asset wrapper already used by the frontend and Main.
-- Keep the original RPC untouched and add the same controlled opening-balance path.
create or replace function public.se_create_opening_asset_v61105(
  p_business_id uuid,p_name text,p_original_cost numeric,p_gst_amount numeric,
  p_purchased_on date,p_available_on date,p_business_use numeric,p_condition text,
  p_category text,p_book_opening numeric,p_tax_opening numeric,p_opening_date date
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_item uuid;v_asset uuid;v_fixed uuid;v_opening_equity uuid;v_journal uuid;v_book_business numeric;v_lines jsonb;
begin
  perform public.se_require_access(p_business_id,true);
  if auth.uid() is null or public.current_business_id() is distinct from p_business_id then raise exception 'Choose the equipment business before adding an opening balance'; end if;
  if nullif(trim(coalesce(p_name,'')),'') is null or p_book_opening is null or p_tax_opening is null or p_opening_date is null then raise exception 'Opening equipment needs a name, opening date and both opening values'; end if;
  if p_original_cost is null or p_original_cost<0 or coalesce(p_gst_amount,0)<0 or p_gst_amount>p_original_cost or p_available_on<p_purchased_on or p_business_use not between 0 and 100 or p_book_opening<0 or p_tax_opening<0 then raise exception 'Check equipment values'; end if;
  if p_opening_date<p_available_on then raise exception 'Opening balance date cannot be before the equipment was ready to use'; end if;
  if not public.v6170a_period_is_open(p_business_id,p_opening_date) then raise exception 'Opening balance date must be in an open accounting period'; end if;
  insert into public.accounting_accounts(business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by) values
    (p_business_id,'150','Fixed Assets - Equipment','fixed_asset','debit','asset','fixed_assets_equipment','150','FIXED','Equipment kept by the business.',true,false,auth.uid(),auth.uid()),
    (p_business_id,'859','Opening Balance Equity','equity','credit','equity','opening_balance_equity','859','EQUITY','Balancing equity for reviewed opening balances.',true,true,auth.uid(),auth.uid())
  on conflict(business_id,account_code) do nothing;
  v_fixed:=public.v61105_account_role_id(p_business_id,'fixed_equipment');
  v_opening_equity:=public.v6192_account_id(p_business_id,'opening_balance_equity','859');
  if v_fixed is null or v_opening_equity is null then raise exception 'Opening-balance accounts are incomplete'; end if;
  v_item:=public.se_create_item(p_business_id,'equipment',p_name,null,'each',null);
  v_asset:=public.se_create_asset(p_business_id,v_item,p_original_cost,p_gst_amount,p_purchased_on,p_available_on,p_business_use,p_condition,p_category,p_book_opening,p_tax_opening);
  v_book_business:=round(p_book_opening*greatest(0,least(100,p_business_use))/100,2);
  if v_book_business<=0 then raise exception 'Business opening book value must be greater than zero'; end if;
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',v_fixed,'description','Opening equipment book value','debit',v_book_business,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
    jsonb_build_object('account_id',v_opening_equity,'description','Opening balance equity','debit',0,'credit',v_book_business,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
  );
  v_journal:=public.v6192_create_posted_journal(p_business_id,p_opening_date,'opening_balance','opening_asset',v_asset,'OPEN-ASSET-'||left(v_asset::text,8),'Opening equipment balance',v_lines);
  insert into public.se_activity(business_id,actor,action,item_id,detail) values(p_business_id,auth.uid(),'opening_balance_posted',v_item,jsonb_build_object('asset_id',v_asset,'journal_id',v_journal,'opening_date',p_opening_date,'book_value_business',v_book_business));
  return v_asset;
end$$;

revoke execute on function public.se_create_opening_asset_v61105(uuid,text,numeric,numeric,date,date,numeric,text,text,numeric,numeric,date) from public,anon;
grant execute on function public.se_create_opening_asset_v61105(uuid,text,numeric,numeric,date,date,numeric,text,text,numeric,numeric,date) to authenticated;

create or replace function public.v6215_import_get(p_batch uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_bid uuid:=current_business_id();v_batch import_batches;
begin
  if v_bid is null then raise exception 'No active business' using errcode='42501'; end if;
  select * into v_batch from import_batches where id=p_batch and business_id=v_bid;
  if not found then raise exception 'Import batch not found' using errcode='42501'; end if;
  return jsonb_build_object(
    'batch',to_jsonb(v_batch),
    'sheets',(select coalesce(jsonb_agg(to_jsonb(s) order by s.sheet_index),'[]'::jsonb) from import_sheets s where s.batch_id=p_batch),
    'mappings',(select coalesce(jsonb_agg(to_jsonb(m) order by m.source_column),'[]'::jsonb) from import_mappings m where m.batch_id=p_batch),
    'records',(select coalesce(jsonb_agg(to_jsonb(r) order by r.display_label),'[]'::jsonb) from import_records r where r.batch_id=p_batch),
    'events',(select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at),'[]'::jsonb) from import_commit_events e where e.batch_id=p_batch)
  );
end$$;

create or replace function public.v6215_set_record_action(p_record uuid,p_action text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_bid uuid:=current_business_id();v_record import_records;
begin
  if v_bid is null or not v6147_can_write_area(v_bid,'core') then raise exception 'Import access denied' using errcode='42501'; end if;
  if p_action not in ('create','skip','update_safe','historical_reference') then raise exception 'Invalid import action'; end if;
  select * into v_record from import_records where id=p_record and business_id=v_bid for update;
  if not found then raise exception 'Import record not found'; end if;
  if exists(select 1 from import_batches where id=v_record.batch_id and status in ('importing','completed')) then raise exception 'Completed imports cannot be changed'; end if;
  if p_action='update_safe' and v_record.record_type not in ('customers','suppliers') then raise exception 'Only contact details support safe update'; end if;
  if p_action='historical_reference' and v_record.record_type not in ('invoices','expenses') then raise exception 'Only financial documents support historical reference'; end if;
  update import_records set duplicate_action=p_action,commit_mode=case when p_action='historical_reference' then 'historical_reference' else commit_mode end,updated_at=now() where id=p_record;
  return v6215_import_get(v_record.batch_id);
end$$;

create or replace function public.v6215_confirm_import(p_batch uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_bid uuid:=current_business_id();v_batch import_batches;v_r import_records;v_n jsonb;v_id uuid;v_existing uuid;
  v_seq integer;v_contact jsonb;v_number text;v_items jsonb;v_total numeric;v_gst numeric;v_subtotal numeric;v_outstanding numeric;
begin
  if v_bid is null or not v6147_can_write_area(v_bid,'core') then raise exception 'Import access denied' using errcode='42501'; end if;
  select * into v_batch from import_batches where id=p_batch and business_id=v_bid for update;
  if not found then raise exception 'Import batch not found'; end if;
  if v_batch.status='completed' then return v6215_import_get(p_batch); end if;
  if v_batch.status not in ('analysed','reviewed') then raise exception 'Review this import before confirming it'; end if;
  perform pg_advisory_xact_lock(hashtext('v6215-import-'||v_bid::text));
  update import_batches set status='importing',updated_at=now() where id=p_batch;

  for v_r in select * from import_records where batch_id=p_batch order by sheet_id,display_label for update loop
    if v_r.validation_status='rejected' or v_r.duplicate_action='skip' then
      update import_records set validation_status='skipped',updated_at=now() where id=v_r.id;
      insert into import_commit_events(business_id,batch_id,import_record_id,action,result,detail,created_by) values(v_bid,p_batch,v_r.id,v_r.duplicate_action,'skipped',jsonb_build_object('reason','Rejected or user selected Skip'),auth.uid());
      continue;
    end if;
    v_n:=v_r.normalized_data;v_id:=null;v_existing:=v_r.existing_record_id;

    if v_r.record_type='customers' then
      if v_existing is null then select id into v_existing from customers where business_id=v_bid and lower(btrim(name))=lower(btrim(v_n->>'name')) limit 1; end if;
      if v_existing is not null and v_r.duplicate_action='update_safe' then
        v_contact:=case when coalesce(nullif(btrim(v_n->>'email'),''),nullif(btrim(v_n->>'phone'),''),nullif(btrim(v_n->>'mobile'),'')) is null then null else jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'name',v_n->>'name','designation','','phone',coalesce(v_n->>'phone',''),'mobile',coalesce(v_n->>'mobile',''),'email',coalesce(v_n->>'email',''),'dob','','billing',true)) end;
        update customers set address=coalesce(nullif(btrim(v_n->>'address'),''),address),contacts=coalesce(v_contact,contacts),updated_at=now() where id=v_existing and business_id=v_bid returning id into v_id;
      elsif v_existing is not null then v_id:=v_existing;
      else
        select coalesce(max(nullif(regexp_replace(customer_number,'\D','','g'),'')::int),0)+1 into v_seq from customers where business_id=v_bid and customer_number~'[0-9]';
        v_contact:=case when coalesce(nullif(btrim(v_n->>'email'),''),nullif(btrim(v_n->>'phone'),''),nullif(btrim(v_n->>'mobile'),'')) is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'name',v_n->>'name','designation','','phone',coalesce(v_n->>'phone',''),'mobile',coalesce(v_n->>'mobile',''),'email',coalesce(v_n->>'email',''),'dob','','billing',true)) end;
        insert into customers(business_id,customer_number,customer_type,name,address,contacts,custom_fields) values(v_bid,'C'||lpad(v_seq::text,4,'0'),'individual',btrim(v_n->>'name'),nullif(btrim(v_n->>'address'),''),v_contact,'[]') returning id into v_id;
      end if;

    elsif v_r.record_type='suppliers' then
      if v_existing is null then select id into v_existing from suppliers where business_id=v_bid and lower(btrim(supplier_name))=lower(btrim(v_n->>'name')) and not archived limit 1; end if;
      if v_existing is not null and v_r.duplicate_action='update_safe' then
        update suppliers set contact_person=coalesce(nullif(btrim(v_n->>'contact_person'),''),contact_person),address=coalesce(nullif(btrim(v_n->>'address'),''),address),phone=coalesce(nullif(btrim(v_n->>'phone'),''),phone),mobile=coalesce(nullif(btrim(v_n->>'mobile'),''),mobile),email=coalesce(nullif(btrim(v_n->>'email'),''),email),registration_number=coalesce(nullif(btrim(v_n->>'registration_number'),''),registration_number),tax_number=coalesce(nullif(btrim(v_n->>'tax_number'),''),tax_number),updated_at=now(),updated_by=auth.uid() where id=v_existing and business_id=v_bid returning id into v_id;
      elsif v_existing is not null then v_id:=v_existing;
      else
        insert into suppliers(business_id,supplier_name,contact_person,address,phone,mobile,email,registration_number,tax_number,default_gst_treatment,payment_terms_days) values(v_bid,btrim(v_n->>'name'),nullif(btrim(v_n->>'contact_person'),''),nullif(btrim(v_n->>'address'),''),nullif(btrim(v_n->>'phone'),''),nullif(btrim(v_n->>'mobile'),''),nullif(btrim(v_n->>'email'),''),nullif(btrim(v_n->>'registration_number'),''),nullif(btrim(v_n->>'tax_number'),''),'gst',0) returning id into v_id;
      end if;

    elsif v_r.record_type in ('invoices','expenses') and (v_r.commit_mode='historical_reference' or v_r.duplicate_action='historical_reference') then
      insert into migration_historical_documents(business_id,batch_id,import_record_id,document_type,source_platform,source_external_id,document_number,document_date,due_date,party_name,party_external_id,currency,items,subtotal,gst,total,paid_amount,outstanding_amount,source_status,source_evidence,canonical_hash,created_by)
      values(v_bid,p_batch,v_r.id,case when v_r.record_type='invoices' then 'invoice' else 'expense' end,coalesce(v_batch.source_adapter,'generic_file'),v_r.source_external_id,nullif(v_n->>'number',''),nullif(v_n->>'date','')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'party_name',''),'Unknown'),nullif(v_n->>'party_external_id',''),upper(coalesce(nullif(v_n->>'currency',''),'NZD'))::char(3),coalesce(v_n->'items','[]'::jsonb),coalesce((v_n->>'subtotal')::numeric,0),coalesce((v_n->>'gst')::numeric,0),coalesce((v_n->>'total')::numeric,0),coalesce((v_n->>'paid_amount')::numeric,0),coalesce((v_n->>'outstanding_amount')::numeric,0),nullif(v_n->>'status',''),coalesce(v_n->'source_evidence','{}'::jsonb),v_r.canonical_hash,auth.uid())
      on conflict (business_id,document_type,canonical_hash) do nothing returning id into v_id;
      if v_id is null then select id into v_id from migration_historical_documents where business_id=v_bid and document_type=case when v_r.record_type='invoices' then 'invoice' else 'expense' end and canonical_hash=v_r.canonical_hash; end if;

    elsif v_r.record_type='invoices' and v_r.commit_mode='native_opening' then
      v_total:=coalesce((v_n->>'total')::numeric,0);v_gst:=coalesce((v_n->>'gst')::numeric,0);v_subtotal:=coalesce((v_n->>'subtotal')::numeric,v_total-v_gst);v_outstanding:=coalesce((v_n->>'outstanding_amount')::numeric,v_total);
      if v_outstanding<=0 then raise exception 'Open invoice % has no outstanding amount',v_r.display_label; end if;
      if exists(select 1 from invoices where business_id=v_bid and invoice_number=v_n->>'number') then select id into v_id from invoices where business_id=v_bid and invoice_number=v_n->>'number' limit 1;
      else
        v_items:=coalesce(v_n->'items',jsonb_build_array(jsonb_build_object('description',coalesce(v_n->>'description','Imported opening invoice'),'quantity',1,'rate',v_subtotal,'amount',v_subtotal)));
        insert into invoices(business_id,invoice_number,invoice_date,due_date,customer_name,customer_address,customer_email,reference,customer_note,items,subtotal,gst,total,amount_paid,balance_due,company_snapshot)
        values(v_bid,v_n->>'number',(v_n->>'date')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'party_name',''),'Imported customer'),nullif(v_n->>'party_address',''),nullif(v_n->>'party_email',''),nullif(v_n->>'reference',''),'Imported opening receivable. Settlement history was not manufactured.',v_items,v_subtotal,v_gst,v_total,greatest(0,v_total-v_outstanding),v_outstanding,jsonb_build_object('migration_batch_id',p_batch,'source_adapter',v_batch.source_adapter)) returning id into v_id;
        perform v6170c1_issue_invoice(v_id);
      end if;

    elsif v_r.record_type='expenses' and v_r.commit_mode='native_opening' then
      v_total:=coalesce((v_n->>'total')::numeric,0);v_gst:=coalesce((v_n->>'gst')::numeric,0);v_subtotal:=coalesce((v_n->>'subtotal')::numeric,v_total-v_gst);v_outstanding:=coalesce((v_n->>'outstanding_amount')::numeric,v_total);
      if v_outstanding<=0 then raise exception 'Open expense % has no outstanding amount',v_r.display_label; end if;
      v_number:=coalesce(nullif(v_n->>'number',''),'MIG-'||substr(v_r.id::text,1,8));
      if exists(select 1 from expenses where business_id=v_bid and expense_number=v_number) then select id into v_id from expenses where business_id=v_bid and expense_number=v_number;
      else insert into expenses(business_id,expense_number,supplier_name,supplier_reference,invoice_date,due_date,description,amount_type,gst_treatment,gst_rate,gst_override,ex_gst,gst_amount,total_amount,amount_paid,outstanding_balance,payment_status,currency,is_split,archived,business_use_percent,business_use_amount,private_use_amount,business_ex_gst,business_gst_amount,allocation_method,allocation_basis,updated_by)
        values(v_bid,v_number,nullif(v_n->>'party_name',''),nullif(v_n->>'reference',''),(v_n->>'date')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'description',''),'Imported opening payable'),'inclusive',case when v_gst>0 then 'gst' else 'no_gst' end,case when v_gst>0 then 15 else 0 end,true,v_subtotal,v_gst,v_total,greatest(0,v_total-v_outstanding),v_outstanding,case when v_outstanding<v_total then 'part_paid' else 'unpaid' end,upper(coalesce(nullif(v_n->>'currency',''),'NZD'))::char(3),false,false,100,v_total,0,v_subtotal,v_gst,'percentage','Imported opening payable',auth.uid()) returning id into v_id; end if;

    elsif v_r.record_type='quotes' then
      v_total:=coalesce((v_n->>'total')::numeric,0);v_gst:=coalesce((v_n->>'gst')::numeric,0);v_subtotal:=coalesce((v_n->>'subtotal')::numeric,v_total-v_gst);
      if exists(select 1 from quotes where business_id=v_bid and quote_number=v_n->>'number') then select id into v_id from quotes where business_id=v_bid and quote_number=v_n->>'number' limit 1;
      else insert into quotes(business_id,quote_number,quote_date,valid_until,customer_name,customer_address,customer_email,description,quoted_price_ex_gst,gst_rate,gst_amount,total_incl_gst,notes,terms,status,quote_items)
        values(v_bid,v_n->>'number',(v_n->>'date')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'party_name',''),'Imported customer'),nullif(v_n->>'party_address',''),nullif(v_n->>'party_email',''),coalesce(nullif(v_n->>'description',''),'Imported quote'),v_subtotal,case when v_subtotal>0 then round(v_gst/v_subtotal*100,4) else 0 end,v_gst,v_total,nullif(v_n->>'notes',''),nullif(v_n->>'terms',''),case when v_n->>'status' in ('draft','sent','approved','won','rejected') then v_n->>'status' else 'draft' end,coalesce(v_n->'items','[]'::jsonb)) returning id into v_id; end if;

    elsif v_r.record_type='stock' then
      if nullif(v_n->>'sku','') is not null then select id into v_id from se_items where business_id=v_bid and lower(sku)=lower(v_n->>'sku') and not archived limit 1; end if;
      if v_id is null then select id into v_id from se_items where business_id=v_bid and lower(btrim(name))=lower(btrim(v_n->>'name')) and kind='stock' and not archived limit 1; end if;
      if v_id is null then v_id:=se_create_item(v_bid,'stock',v_n->>'name',nullif(v_n->>'sku',''),coalesce(nullif(v_n->>'unit',''),'each'),nullif(v_n->>'low_stock_at','')::numeric); end if;
      if coalesce((v_n->>'quantity')::numeric,0)>0 and not exists(select 1 from se_movements where business_id=v_bid and item_id=v_id and kind='opening' and reason like 'Migration batch %') then perform se_record_movement(v_bid,v_id,'opening',(v_n->>'quantity')::numeric,coalesce((v_n->>'unit_cost')::numeric,0),coalesce(nullif(v_n->>'date','')::date,v_batch.cutover_date,current_date),'Migration batch '||p_batch::text,null,null,null); end if;

    elsif v_r.record_type='equipment' then
      select a.id into v_id from se_assets a join se_items i on i.id=a.item_id where a.business_id=v_bid and lower(btrim(i.name))=lower(btrim(v_n->>'name')) and a.voided_at is null limit 1;
      if v_id is null then v_id:=se_create_opening_asset_v61105(v_bid,v_n->>'name',coalesce((v_n->>'original_cost')::numeric,0),coalesce((v_n->>'gst')::numeric,0),nullif(v_n->>'purchased_on','')::date,coalesce(nullif(v_n->>'available_on','')::date,v_batch.cutover_date,current_date),coalesce((v_n->>'business_use_percent')::numeric,100),coalesce(nullif(v_n->>'condition',''),'unknown'),coalesce(v_n->>'category',''),nullif(v_n->>'book_opening_value','')::numeric,nullif(v_n->>'tax_opening_value','')::numeric,coalesce(v_batch.cutover_date,current_date)); end if;

    elsif v_r.record_type='employees' then
      if nullif(v_n->>'employee_number','') is not null then select id into v_id from payroll_employees where business_id=v_bid and employee_number=v_n->>'employee_number' limit 1; end if;
      if v_id is null then select id into v_id from payroll_employees where business_id=v_bid and lower(btrim(first_name))=lower(btrim(v_n->>'first_name')) and lower(btrim(last_name))=lower(btrim(v_n->>'last_name')) and (nullif(v_n->>'date_of_birth','') is null or date_of_birth=nullif(v_n->>'date_of_birth','')::date) limit 1; end if;
      if v_id is null then
        v_number:=coalesce(nullif(v_n->>'employee_number',''),'EMP-'||substr(v_r.id::text,1,8));
        insert into payroll_employees(business_id,employee_number,first_name,last_name,date_of_birth,email,mobile,phone,address,employment_type,job_title,start_date,standard_weekly_hours,standard_working_days,pay_frequency,employment_status,pay_type,hourly_rate,annual_salary,ird_number,tax_code,student_loan,kiwisaver_status,kiwisaver_employee_rate,kiwisaver_employer_rate,annual_holiday_method,holiday_pay_rate,bank_account_name,bank_account_number,bank_payment_reference,notes)
        values(v_bid,v_number,coalesce(nullif(v_n->>'first_name',''),'Imported'),coalesce(nullif(v_n->>'last_name',''),'Employee'),nullif(v_n->>'date_of_birth','')::date,nullif(v_n->>'email',''),nullif(v_n->>'mobile',''),nullif(v_n->>'phone',''),nullif(v_n->>'address',''),coalesce(nullif(v_n->>'employment_type',''),'casual'),nullif(v_n->>'job_title',''),coalesce(nullif(v_n->>'start_date','')::date,v_batch.cutover_date,current_date),coalesce((v_n->>'standard_weekly_hours')::numeric,40),coalesce((v_n->>'standard_working_days')::numeric,5),coalesce(nullif(v_n->>'pay_frequency',''),'fortnightly'),'active',coalesce(nullif(v_n->>'pay_type',''),'hourly'),coalesce((v_n->>'hourly_rate')::numeric,0),coalesce((v_n->>'annual_salary')::numeric,0),nullif(v_n->>'ird_number',''),coalesce(nullif(v_n->>'tax_code',''),'M'),coalesce((v_n->>'student_loan')::boolean,false),coalesce(nullif(v_n->>'kiwisaver_status',''),'not_enrolled'),coalesce((v_n->>'kiwisaver_employee_rate')::numeric,3.5),coalesce((v_n->>'kiwisaver_employer_rate')::numeric,3.5),coalesce(nullif(v_n->>'annual_holiday_method',''),'standard'),coalesce((v_n->>'holiday_pay_rate')::numeric,8),nullif(v_n->>'bank_account_name',''),nullif(v_n->>'bank_account_number',''),nullif(v_n->>'bank_payment_reference',''),'Imported employee setup; verify tax, leave and bank details before first pay run.') returning id into v_id;
      end if;
      if coalesce(nullif(v_n->>'gross_ytd','')::numeric,0)<>0 or coalesce(nullif(v_n->>'paye_ytd','')::numeric,0)<>0 or coalesce(nullif(v_n->>'net_ytd','')::numeric,0)<>0 or coalesce(nullif(v_n->>'annual_leave_hours','')::numeric,0)<>0 or coalesce(nullif(v_n->>'sick_leave_hours','')::numeric,0)<>0 or coalesce(nullif(v_n->>'alternative_holiday_hours','')::numeric,0)<>0 then
        insert into payroll_migration_opening_balances(business_id,employee_id,batch_id,effective_date,gross_ytd,paye_ytd,net_ytd,annual_leave_hours,sick_leave_hours,alternative_holiday_hours,evidence,created_by)
        values(v_bid,v_id,p_batch,coalesce(v_batch.cutover_date,current_date),coalesce(nullif(v_n->>'gross_ytd','')::numeric,0),coalesce(nullif(v_n->>'paye_ytd','')::numeric,0),coalesce(nullif(v_n->>'net_ytd','')::numeric,0),nullif(v_n->>'annual_leave_hours','')::numeric,nullif(v_n->>'sick_leave_hours','')::numeric,nullif(v_n->>'alternative_holiday_hours','')::numeric,jsonb_build_object('source','Smart Migration Centre','record_id',v_r.id),auth.uid())
        on conflict(business_id,employee_id,effective_date) do nothing;
      end if;

    elsif v_r.record_type='payroll_history' then
      insert into payroll_migration_history(business_id,batch_id,import_record_id,employee_external_id,employee_number,employee_name,period_start,period_end,pay_date,gross_pay,paye,deductions,net_pay,source_platform,canonical_hash,source_evidence,created_by)
      values(v_bid,p_batch,v_r.id,nullif(v_n->>'employee_external_id',''),nullif(v_n->>'employee_number',''),coalesce(nullif(v_n->>'employee_name',''),'Imported employee'),nullif(v_n->>'period_start','')::date,nullif(v_n->>'period_end','')::date,nullif(v_n->>'pay_date','')::date,coalesce((v_n->>'gross_pay')::numeric,0),coalesce((v_n->>'paye')::numeric,0),coalesce((v_n->>'deductions')::numeric,0),coalesce((v_n->>'net_pay')::numeric,0),coalesce(v_batch.source_adapter,'generic_file'),v_r.canonical_hash,coalesce(v_n->'source_evidence','{}'::jsonb),auth.uid())
      on conflict (business_id,canonical_hash) do nothing returning id into v_id;
      if v_id is null then select id into v_id from payroll_migration_history where business_id=v_bid and canonical_hash=v_r.canonical_hash; end if;
    end if;

    if v_id is null then raise exception 'Import record % did not produce a target record',v_r.display_label; end if;
    update import_records set validation_status='imported',duplicate_status='imported',imported_record_type=v_r.record_type,imported_record_id=v_id,updated_at=now() where id=v_r.id;
    insert into import_commit_events(business_id,batch_id,import_record_id,action,result,target_type,target_id,detail,created_by) values(v_bid,p_batch,v_r.id,v_r.duplicate_action,case when v_existing is not null and v_r.duplicate_action='update_safe' then 'updated' else 'imported' end,v_r.record_type,v_id,jsonb_build_object('commit_mode',v_r.commit_mode),auth.uid());
  end loop;

  update import_batches set status='completed',mapping_version='v62.15',imported_rows=(select count(*) from import_records where batch_id=p_batch and validation_status='imported'),warning_rows=(select count(*) from import_records where batch_id=p_batch and validation_status='warning'),rejected_rows=(select count(*) from import_records where batch_id=p_batch and validation_status='rejected'),completed_at=now(),updated_at=now() where id=p_batch;
  return v6215_import_get(p_batch);
exception when others then
  raise;
end$$;

revoke execute on function public.v6215_import_get(uuid) from public,anon;
revoke execute on function public.v6215_set_record_action(uuid,text) from public,anon;
revoke execute on function public.v6215_confirm_import(uuid) from public,anon;
grant execute on function public.v6215_import_get(uuid) to authenticated;
grant execute on function public.v6215_set_record_action(uuid,text) to authenticated;
grant execute on function public.v6215_confirm_import(uuid) to authenticated;

commit;
