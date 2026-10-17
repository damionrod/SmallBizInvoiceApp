-- Isolated Market migration boundary. Existing business/module permissions remain authoritative.
DO $$BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape'
 THEN RAISE EXCEPTION 'Market-only migration'; END IF;
END$$;

CREATE OR REPLACE FUNCTION public.v6223_import_type_access(p_business_id uuid,p_record_type text,p_write boolean DEFAULT false)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE area text;
BEGIN
 IF auth.uid() IS NULL OR p_business_id IS DISTINCT FROM public.current_business_id() THEN RETURN false; END IF;
 area:=CASE p_record_type
  WHEN 'customers' THEN 'core' WHEN 'suppliers' THEN 'expenses'
  WHEN 'invoices' THEN 'core' WHEN 'quotes' THEN 'core' WHEN 'expenses' THEN 'expenses'
  WHEN 'stock' THEN 'expenses' WHEN 'equipment' THEN 'expenses'
  WHEN 'employees' THEN 'payroll' WHEN 'payroll_history' THEN 'payroll' ELSE NULL END;
 IF area IS NULL THEN RETURN false; END IF;
 IF p_write THEN
  RETURN coalesce(public.v6147_can_write_area(p_business_id,'core'),false)
    AND coalesce(public.v6147_can_write_area(p_business_id,area),false)
    AND (p_record_type NOT IN ('stock','equipment') OR public.v6200_stock_module_enabled(p_business_id));
 END IF;
 RETURN coalesce(public.v6147_can_read_area(p_business_id,'core'),false)
   AND coalesce(public.v6147_can_read_area(p_business_id,area),false);
END$$;

-- The entire batch is protected: raw rows and sheet samples can contain payroll information.
-- SECURITY DEFINER avoids recursive import-table RLS; every query retains the active tenant.
CREATE OR REPLACE FUNCTION public.v6223_import_batch_access(p_batch uuid,p_write boolean DEFAULT false)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE bid uuid:=public.current_business_id(); typ text;
BEGIN
 IF auth.uid() IS NULL OR bid IS NULL OR NOT EXISTS(SELECT 1 FROM public.import_batches b WHERE b.id=p_batch AND b.business_id=bid)
 THEN RETURN false; END IF;
 IF p_write THEN
  IF NOT coalesce(public.v6147_can_write_area(bid,'core'),false) THEN RETURN false; END IF;
 ELSE
  IF NOT coalesce(public.v6147_can_read_area(bid,'core'),false) THEN RETURN false; END IF;
 END IF;
 FOR typ IN
  SELECT s.detected_record_type FROM public.import_sheets s WHERE s.batch_id=p_batch AND s.business_id=bid
  UNION SELECT r.record_type FROM public.import_records r WHERE r.batch_id=p_batch AND r.business_id=bid
  UNION SELECT r.record_type FROM public.import_rows r WHERE r.batch_id=p_batch AND r.business_id=bid AND r.record_type IS NOT NULL
 LOOP
  IF NOT public.v6223_import_type_access(bid,typ,p_write) THEN RETURN false; END IF;
 END LOOP;
 RETURN true;
END$$;
REVOKE ALL ON FUNCTION public.v6223_import_type_access(uuid,text,boolean),public.v6223_import_batch_access(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6223_import_type_access(uuid,text,boolean),public.v6223_import_batch_access(uuid,boolean) TO authenticated;


CREATE OR REPLACE FUNCTION public.v6171b_confirm_import(p_batch uuid, p_duplicate_action text DEFAULT 'skip'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare bid uuid:=current_business_id();b import_batches;r record;rid uuid;n integer:=0;seq integer;contact jsonb;begin
 if not public.v6223_import_batch_access(p_batch,true) then raise exception 'You need permission for every type of record in this import.' using errcode='42501'; end if;

if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Import access denied' using errcode='42501';end if;if p_duplicate_action<>'skip' then raise exception 'V61.71B only supports safe Skip existing behaviour. Existing financial records are never overwritten.';end if;select * into b from import_batches where id=p_batch and business_id=bid for update;if not found then raise exception 'Import batch not found';end if;if b.status='completed' then return v6171b_import_get(p_batch);end if;if b.status<>'reviewed' then raise exception 'Review and confirm mappings before importing.';end if;update import_batches set status='importing',updated_at=now() where id=p_batch;perform pg_advisory_xact_lock(hashtext('v6171b-import-'||bid::text));
for r in select * from import_rows where batch_id=p_batch and validation_status in('ready','warning') order by sheet_id,source_row_number loop
if exists(select 1 from import_record_links l where l.business_id=bid and l.source_hash=r.source_hash and l.record_type=r.record_type) then update import_rows set validation_status='skipped',validation_messages=validation_messages||jsonb_build_array('Already imported from an earlier batch.') where id=r.id;continue;end if;
if r.record_type='customers' then if exists(select 1 from customers c where c.business_id=bid and lower(btrim(c.name))=lower(btrim(r.normalized_data->>'name'))) then update import_rows set validation_status='skipped' where id=r.id;continue;end if;select coalesce(max(nullif(regexp_replace(customer_number,'\D','','g'),'')::int),0)+1 into seq from customers where business_id=bid and customer_number ~ '[0-9]';contact:=case when coalesce(nullif(btrim(r.normalized_data->>'email'),''),nullif(btrim(r.normalized_data->>'phone'),'')) is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'name',r.normalized_data->>'name','designation','','phone',coalesce(r.normalized_data->>'phone',''),'mobile',coalesce(r.normalized_data->>'mobile',''),'email',coalesce(r.normalized_data->>'email',''),'dob','','billing',true)) end;insert into customers(business_id,customer_number,customer_type,name,address,contacts,custom_fields) values(bid,'C'||lpad(seq::text,4,'0'),'individual',btrim(r.normalized_data->>'name'),nullif(btrim(r.normalized_data->>'address'),''),contact,'[]') returning id into rid;
elsif r.record_type='suppliers' then if exists(select 1 from suppliers s where s.business_id=bid and lower(btrim(s.supplier_name))=lower(btrim(r.normalized_data->>'name')) and not s.archived) then update import_rows set validation_status='skipped' where id=r.id;continue;end if;insert into suppliers(business_id,supplier_name,contact_person,address,phone,mobile,email,registration_number,tax_number,default_gst_treatment,payment_terms_days) values(bid,btrim(r.normalized_data->>'name'),nullif(btrim(r.normalized_data->>'contact_person'),''),nullif(btrim(r.normalized_data->>'address'),''),nullif(btrim(r.normalized_data->>'phone'),''),nullif(btrim(r.normalized_data->>'mobile'),''),nullif(btrim(r.normalized_data->>'email'),''),nullif(btrim(r.normalized_data->>'registration_number'),''),nullif(btrim(r.normalized_data->>'tax_number'),''),'gst',0) returning id into rid;else continue;end if;
insert into import_record_links(business_id,batch_id,import_row_id,record_type,record_id,source_hash) values(bid,p_batch,r.id,r.record_type,rid,r.source_hash);update import_rows set validation_status='imported',imported_record_type=r.record_type,imported_record_id=rid where id=r.id;n:=n+1;end loop;
update import_batches set status='completed',imported_rows=n,warning_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='warning'),rejected_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='rejected'),completed_at=now(),updated_at=now() where id=p_batch;return v6171b_import_get(p_batch);end$function$
;

CREATE OR REPLACE FUNCTION public.v6171b_import_get(p_batch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare bid uuid:=current_business_id();b import_batches;begin
 if not public.v6223_import_batch_access(p_batch,false) then raise exception 'You need permission for every type of record in this import.' using errcode='42501'; end if;
 if bid is null then raise exception 'No active business';end if;select * into b from import_batches where id=p_batch and business_id=bid;if not found then raise exception 'Import batch not found' using errcode='42501';end if;return jsonb_build_object('batch',to_jsonb(b),'sheets',(select coalesce(jsonb_agg(to_jsonb(s) order by sheet_index),'[]') from import_sheets s where s.batch_id=b.id),'mappings',(select coalesce(jsonb_agg(to_jsonb(m) order by source_column),'[]') from import_mappings m where m.batch_id=b.id),'rows',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'sheet_id',r.sheet_id,'source_row_number',r.source_row_number,'record_type',r.record_type,'validation_status',r.validation_status,'validation_messages',r.validation_messages,'normalized_data',r.normalized_data) order by r.source_row_number) filter(where r.validation_status in('warning','rejected')),'[]') from import_rows r where r.batch_id=b.id));end$function$
;

CREATE OR REPLACE FUNCTION public.v6171b_import_history()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'filename',b.filename,'source_type',b.source_type,'status',b.status,'created_at',b.created_at,'completed_at',b.completed_at,'total_rows',b.total_rows,'imported_rows',b.imported_rows,'warning_rows',b.warning_rows,'rejected_rows',b.rejected_rows,'cutover_date',b.cutover_date,'migration_mode',b.migration_mode) order by b.created_at desc),'[]'::jsonb) from import_batches b where b.business_id=current_business_id() and public.v6223_import_batch_access(b.id,false);$function$
;

CREATE OR REPLACE FUNCTION public.v6215_confirm_import(p_batch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bid uuid:=current_business_id();v_batch import_batches;v_r import_records;v_n jsonb;v_id uuid;v_existing uuid;
  v_seq integer;v_contact jsonb;v_number text;v_items jsonb;v_total numeric;v_gst numeric;v_subtotal numeric;v_outstanding numeric;
begin
 if not public.v6223_import_batch_access(p_batch,true) then raise exception 'You need permission for every type of record in this import.' using errcode='42501'; end if;

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
end$function$
;

CREATE OR REPLACE FUNCTION public.v6215_import_get(p_batch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bid uuid:=current_business_id();v_batch import_batches;
begin
 if not public.v6223_import_batch_access(p_batch,false) then raise exception 'You need permission for every type of record in this import.' using errcode='42501'; end if;

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
end$function$
;

CREATE OR REPLACE FUNCTION public.v6215_set_record_action(p_record uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bid uuid:=current_business_id();v_record import_records;
begin
  if v_bid is null or not v6147_can_write_area(v_bid,'core') then raise exception 'Import access denied' using errcode='42501'; end if;
  if p_action not in ('create','skip','update_safe','historical_reference') then raise exception 'Invalid import action'; end if;
  select * into v_record from import_records where id=p_record and business_id=v_bid for update;
  if not found then raise exception 'Import record not found'; end if;
  if not public.v6223_import_batch_access(v_record.batch_id,true) then raise exception 'You need permission for every type of record in this import.' using errcode='42501'; end if;
  if exists(select 1 from import_batches where id=v_record.batch_id and status in ('importing','completed')) then raise exception 'Completed imports cannot be changed'; end if;
  if p_action='update_safe' and v_record.record_type not in ('customers','suppliers') then raise exception 'Only contact details support safe update'; end if;
  if p_action='historical_reference' and v_record.record_type not in ('invoices','expenses') then raise exception 'Only financial documents support historical reference'; end if;
  update import_records set duplicate_action=p_action,commit_mode=case when p_action='historical_reference' then 'historical_reference' else commit_mode end,updated_at=now() where id=p_record;
  return v6215_import_get(v_record.batch_id);
end$function$
;

CREATE POLICY v6223_import_domain_read ON public.import_batches AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_batch_access(id,false));

CREATE POLICY v6223_import_domain_read ON public.import_sheets AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_batch_access(batch_id,false));

CREATE POLICY v6223_import_domain_read ON public.import_mappings AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_batch_access(batch_id,false));

CREATE POLICY v6223_import_domain_read ON public.import_rows AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_batch_access(batch_id,false));

CREATE POLICY v6223_import_domain_read ON public.import_records AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_batch_access(batch_id,false));

CREATE POLICY v6223_import_domain_read ON public.import_record_members AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_batch_access(batch_id,false));

CREATE POLICY v6223_import_domain_read ON public.import_commit_events AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_batch_access(batch_id,false));

CREATE POLICY v6223_import_domain_read ON public.import_record_links AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_batch_access(batch_id,false));

CREATE POLICY v6223_import_domain_read ON public.import_mapping_profiles AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_type_access(business_id,record_type,false));

CREATE POLICY v6223_import_domain_read ON public.migration_historical_documents AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_type_access(business_id,CASE document_type WHEN 'invoice' THEN 'invoices' WHEN 'expense' THEN 'expenses' END,false));

CREATE POLICY v6223_import_domain_read ON public.payroll_migration_history AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_type_access(business_id,'payroll_history',false));

CREATE POLICY v6223_import_domain_read ON public.payroll_migration_opening_balances AS RESTRICTIVE FOR SELECT TO authenticated USING (public.v6223_import_type_access(business_id,'employees',false));
