-- Atomic preview replacement and immutable completed evidence. Market rollout only.
CREATE FUNCTION public.v6225_guard_import_evidence() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid; tenant uuid; stage text; before_row jsonb; after_row jsonb;
BEGIN
 before_row:=CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END;
 after_row:=CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END;
 -- Preserve the existing whole-business deletion cascade. A standalone import
 -- deletion cannot use this exception while its business still exists.
 IF TG_OP='DELETE' AND NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=(before_row->>'business_id')::uuid) THEN RETURN OLD;END IF;
 IF TG_TABLE_NAME='import_batches' THEN
  IF TG_OP<>'INSERT' AND OLD.status='completed' THEN RAISE EXCEPTION 'Completed import evidence cannot be changed.' USING ERRCODE='55000';END IF;
  IF TG_OP='UPDATE' AND (before_row-ARRAY['status','cutover_date','migration_mode','mapping_version','valid_rows','warning_rows','rejected_rows','imported_rows','total_rows','error_summary','updated_at','completed_at']) IS DISTINCT FROM (after_row-ARRAY['status','cutover_date','migration_mode','mapping_version','valid_rows','warning_rows','rejected_rows','imported_rows','total_rows','error_summary','updated_at','completed_at']) THEN
   RAISE EXCEPTION 'Import source identity cannot be changed.' USING ERRCODE='55000';
  END IF;
 ELSE
  bid:=coalesce(after_row->>'batch_id',before_row->>'batch_id')::uuid;
  SELECT business_id,status INTO tenant,stage FROM public.import_batches WHERE id=bid FOR UPDATE;
  IF NOT FOUND THEN
   -- Preserve the existing FK cascade when an uncompleted parent is removed.
   IF TG_OP='DELETE' THEN RETURN OLD;END IF;
   RAISE EXCEPTION 'Import batch not found.' USING ERRCODE='23503';
  END IF;
  IF stage='completed' THEN RAISE EXCEPTION 'Completed import evidence cannot be changed.' USING ERRCODE='55000';END IF;
  IF coalesce(after_row->>'business_id',before_row->>'business_id')::uuid IS DISTINCT FROM tenant THEN RAISE EXCEPTION 'Import evidence belongs to another business.' USING ERRCODE='42501';END IF;
  IF TG_OP='UPDATE' AND (before_row->>'batch_id' IS DISTINCT FROM after_row->>'batch_id' OR before_row->>'business_id' IS DISTINCT FROM after_row->>'business_id' OR before_row->>'sheet_id' IS DISTINCT FROM after_row->>'sheet_id') THEN
   RAISE EXCEPTION 'Import evidence cannot move between batches or sheets.' USING ERRCODE='55000';
  END IF;
  IF TG_TABLE_NAME='import_rows' AND TG_OP='UPDATE' AND (before_row-ARRAY['record_type','normalized_data','validation_status','validation_messages','imported_record_type','imported_record_id']) IS DISTINCT FROM (after_row-ARRAY['record_type','normalized_data','validation_status','validation_messages','imported_record_type','imported_record_id']) THEN
   RAISE EXCEPTION 'Original source rows cannot be changed.' USING ERRCODE='55000';
  END IF;
  IF TG_TABLE_NAME='import_sheets' AND TG_OP='UPDATE' AND (before_row-ARRAY['detected_record_type','ai_suggested_type','ai_confidence']) IS DISTINCT FROM (after_row-ARRAY['detected_record_type','ai_suggested_type','ai_confidence']) THEN
   RAISE EXCEPTION 'Original source sheet cannot be changed.' USING ERRCODE='55000';
  END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;
 RETURN NEW;
END;$fn$;
REVOKE ALL ON FUNCTION public.v6225_guard_import_evidence() FROM PUBLIC,anon,authenticated;
DO $triggers$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['import_batches','import_sheets','import_rows','import_mappings','import_records','import_record_members','import_commit_events','import_record_links'] LOOP
  EXECUTE format('CREATE TRIGGER v6225_immutable_import_evidence BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.v6225_guard_import_evidence()',t);
 END LOOP;
END;$triggers$;

CREATE FUNCTION public.v6225_replace_import_review(p_batch uuid,p_expected_updated_at timestamptz,p_cutover date,p_mode text,p_sheets jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE b public.import_batches%ROWTYPE;s public.import_sheets%ROWTYPE;change jsonb;r jsonb;mapping jsonb;rid uuid;typ text;mode text;status text;messages jsonb;duplicate boolean;member_count integer;source_count integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.v6223_import_batch_access(p_batch,true) THEN RAISE EXCEPTION 'You need permission for every type of record in this import.' USING ERRCODE='42501';END IF;
 SELECT * INTO b FROM public.import_batches WHERE id=p_batch AND business_id=public.current_business_id() FOR UPDATE;
 IF NOT FOUND OR NOT public.v6223_import_batch_access(p_batch,true) THEN RAISE EXCEPTION 'Import access changed. Reopen the import.' USING ERRCODE='42501';END IF;
 IF b.status NOT IN ('analysed','reviewed') THEN RAISE EXCEPTION 'Import is no longer available for remapping.' USING ERRCODE='55000';END IF;
 IF p_expected_updated_at IS NULL OR p_expected_updated_at IS DISTINCT FROM b.updated_at THEN RAISE EXCEPTION 'This import changed in another session. Reopen its latest review.' USING ERRCODE='40001';END IF;
 IF NOT coalesce((SELECT enabled FROM public.import_migration_settings WHERE id=true),false) THEN RAISE EXCEPTION 'Import and Migration is disabled.' USING ERRCODE='42501';END IF;
 IF p_mode IS NULL OR p_mode NOT IN ('continue_today','historical_reference') OR p_cutover IS NULL OR NOT isfinite(p_cutover) THEN RAISE EXCEPTION 'Choose the migration approach and cutover date.' USING ERRCODE='22023';END IF;
 IF p_sheets IS NULL OR jsonb_typeof(p_sheets)<>'array' OR jsonb_array_length(p_sheets)=0 OR octet_length(p_sheets::text)>67108864 THEN RAISE EXCEPTION 'The review must contain sheets and fit within 64 MB.' USING ERRCODE='22023';END IF;
 -- Require the whole workbook: a changed cutover date must never leave old sheets behind.
 IF jsonb_array_length(p_sheets)<>(SELECT count(*) FROM public.import_sheets WHERE batch_id=p_batch) OR (SELECT count(DISTINCT x->>'id') FROM jsonb_array_elements(p_sheets) x)<>jsonb_array_length(p_sheets) THEN RAISE EXCEPTION 'Review every sheet exactly once.' USING ERRCODE='22023';END IF;
 FOR change IN SELECT * FROM jsonb_array_elements(p_sheets) LOOP
  SELECT * INTO s FROM public.import_sheets WHERE id=(change->>'id')::uuid AND batch_id=p_batch AND business_id=b.business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sheet does not belong to this import.' USING ERRCODE='42501';END IF;
  typ:=change->>'record_type';mapping:=change->'mapping';
  IF typ IS NULL OR NOT public.v6223_import_type_access(b.business_id,typ,true) THEN RAISE EXCEPTION 'You cannot import this record type.' USING ERRCODE='42501';END IF;
  IF jsonb_typeof(mapping) IS DISTINCT FROM 'object' OR jsonb_typeof(change->'records') IS DISTINCT FROM 'array' OR coalesce(change->>'header_signature','') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid mapping review.' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_each_text(mapping) m WHERE NOT s.headers ? m.key OR NOT EXISTS(SELECT 1 FROM public.import_mappings im WHERE im.sheet_id=s.id AND im.source_column=m.key)) THEN RAISE EXCEPTION 'Mapping references a missing source column.' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT 1 FROM public.import_records WHERE sheet_id=s.id AND (validation_status='imported' OR imported_record_id IS NOT NULL)) THEN RAISE EXCEPTION 'Imported records cannot be remapped.' USING ERRCODE='55000';END IF;
  DELETE FROM public.import_record_members WHERE batch_id=p_batch AND import_record_id IN(SELECT id FROM public.import_records WHERE sheet_id=s.id);
  DELETE FROM public.import_records WHERE sheet_id=s.id;
  UPDATE public.import_mappings SET confirmed_target=NULL,confirmed_by=NULL,confirmed_at=NULL WHERE sheet_id=s.id;
  UPDATE public.import_mappings im SET confirmed_target=m.value,confirmed_by=auth.uid(),confirmed_at=clock_timestamp() FROM jsonb_each_text(mapping) m WHERE im.sheet_id=s.id AND im.source_column=m.key;
  UPDATE public.import_sheets SET detected_record_type=typ WHERE id=s.id;
  FOR r IN SELECT * FROM jsonb_array_elements(change->'records') LOOP
   status:=r->>'validation_status';messages:=r->'validation_messages';mode:=r->>'commit_mode';
   IF r->>'record_type' IS DISTINCT FROM typ OR status IS NULL OR status NOT IN ('ready','warning','rejected') OR jsonb_typeof(r->'normalized_data') IS DISTINCT FROM 'object' OR jsonb_typeof(messages) IS DISTINCT FROM 'array' OR jsonb_typeof(r->'member_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(r->'member_ids')=0 OR coalesce(r->>'canonical_hash','') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid logical record in review.' USING ERRCODE='22023';END IF;
   IF NOT coalesce(CASE typ WHEN 'customers' THEN mode='native_master' WHEN 'suppliers' THEN mode='native_master' WHEN 'invoices' THEN mode IN ('native_opening','historical_reference') WHEN 'expenses' THEN mode IN ('native_opening','historical_reference') WHEN 'quotes' THEN mode='native_quote' WHEN 'stock' THEN mode='native_stock' WHEN 'equipment' THEN mode='native_asset' WHEN 'employees' THEN mode='native_employee' WHEN 'payroll_history' THEN mode='payroll_history' ELSE false END,false) THEN RAISE EXCEPTION 'Invalid import destination for this record type.' USING ERRCODE='22023';END IF;
   SELECT EXISTS(SELECT 1 FROM public.import_records old WHERE old.business_id=b.business_id AND old.batch_id<>p_batch AND old.record_type=typ AND old.canonical_hash=r->>'canonical_hash' AND old.validation_status='imported') INTO duplicate;
   IF duplicate THEN
    IF status<>'rejected' THEN status:='warning';END IF;
    messages:=messages||jsonb_build_array('This logical record was imported previously and will be skipped unless you choose another safe action.');
   END IF;
   INSERT INTO public.import_records(batch_id,sheet_id,business_id,record_type,source_external_id,group_key,canonical_hash,display_label,normalized_data,validation_status,validation_messages,duplicate_status,duplicate_action,commit_mode)
    VALUES(p_batch,s.id,b.business_id,typ,r->>'source_external_id',r->>'group_key',r->>'canonical_hash',r->>'display_label',r->'normalized_data',status,messages,CASE WHEN duplicate THEN 'exact' ELSE 'new' END,CASE WHEN duplicate THEN 'skip' WHEN mode='historical_reference' THEN 'historical_reference' ELSE 'create' END,mode) RETURNING id INTO rid;
   IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(r->'member_ids') x WHERE NOT EXISTS(SELECT 1 FROM public.import_rows ir WHERE ir.id=x.value::uuid AND ir.batch_id=p_batch AND ir.sheet_id=s.id AND ir.business_id=b.business_id)) THEN RAISE EXCEPTION 'A source row is missing or belongs to another sheet.' USING ERRCODE='22023';END IF;
   INSERT INTO public.import_record_members(business_id,batch_id,import_record_id,import_row_id,member_role)
    SELECT b.business_id,p_batch,rid,x.value::uuid,'source' FROM jsonb_array_elements_text(r->'member_ids') x;
  END LOOP;
  SELECT count(*) INTO source_count FROM public.import_rows WHERE sheet_id=s.id AND batch_id=p_batch;
  SELECT count(*) INTO member_count FROM public.import_record_members m JOIN public.import_records ir ON ir.id=m.import_record_id WHERE ir.sheet_id=s.id AND m.batch_id=p_batch;
  IF member_count<>source_count OR member_count<>(SELECT count(DISTINCT m.import_row_id) FROM public.import_record_members m JOIN public.import_records ir ON ir.id=m.import_record_id WHERE ir.sheet_id=s.id AND m.batch_id=p_batch) THEN RAISE EXCEPTION 'The review must account for every source row exactly once.' USING ERRCODE='22023';END IF;
  INSERT INTO public.import_mapping_profiles(business_id,source_adapter,record_type,header_signature,mapping,confirmed_by,updated_at)
   VALUES(b.business_id,s.source_adapter,typ,change->>'header_signature',jsonb_build_object('version','v62.25','columns',mapping),auth.uid(),clock_timestamp())
   ON CONFLICT(business_id,source_adapter,record_type,header_signature) DO UPDATE SET mapping=excluded.mapping,confirmed_by=excluded.confirmed_by,updated_at=excluded.updated_at;
 END LOOP;
 UPDATE public.import_batches SET cutover_date=p_cutover,migration_mode=p_mode,mapping_version='v62.25',status='reviewed',updated_at=clock_timestamp(),
  valid_rows=(SELECT count(*) FROM public.import_records WHERE batch_id=p_batch AND validation_status='ready'),
  warning_rows=(SELECT count(*) FROM public.import_records WHERE batch_id=p_batch AND validation_status='warning'),
  rejected_rows=(SELECT count(*) FROM public.import_records WHERE batch_id=p_batch AND validation_status='rejected') WHERE id=p_batch;
 RETURN public.v6215_import_get(p_batch);
END;$fn$;
REVOKE ALL ON FUNCTION public.v6225_replace_import_review(uuid,timestamptz,date,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6225_replace_import_review(uuid,timestamptz,date,text,jsonb) TO authenticated;

CREATE FUNCTION public.v6225_confirm_import_review(p_batch uuid,p_expected_updated_at timestamptz,p_decisions jsonb DEFAULT '[]')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE b public.import_batches%ROWTYPE;d jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.v6223_import_batch_access(p_batch,true) THEN RAISE EXCEPTION 'Import access denied.' USING ERRCODE='42501';END IF;
 SELECT * INTO b FROM public.import_batches WHERE id=p_batch AND business_id=public.current_business_id() FOR UPDATE;
 IF NOT FOUND OR NOT public.v6223_import_batch_access(p_batch,true) THEN RAISE EXCEPTION 'Import access changed.' USING ERRCODE='42501';END IF;
 IF b.status='completed' THEN RETURN public.v6215_import_get(p_batch);END IF;
 IF b.status NOT IN ('analysed','reviewed') OR p_expected_updated_at IS NULL OR p_expected_updated_at IS DISTINCT FROM b.updated_at THEN RAISE EXCEPTION 'The review changed. Reopen it before confirming.' USING ERRCODE='40001';END IF;
 IF NOT coalesce((SELECT enabled FROM public.import_migration_settings WHERE id=true),false) THEN RAISE EXCEPTION 'Import and Migration is disabled.' USING ERRCODE='42501';END IF;
 IF p_decisions IS NULL OR jsonb_typeof(p_decisions)<>'array' OR jsonb_array_length(p_decisions)>(SELECT count(*) FROM public.import_records WHERE batch_id=p_batch) OR (SELECT count(DISTINCT x->>'id') FROM jsonb_array_elements(p_decisions) x)<>jsonb_array_length(p_decisions) THEN RAISE EXCEPTION 'Invalid review decisions.' USING ERRCODE='22023';END IF;
 FOR d IN SELECT * FROM jsonb_array_elements(p_decisions) LOOP
  IF NOT EXISTS(SELECT 1 FROM public.import_records WHERE id=(d->>'id')::uuid AND batch_id=p_batch AND business_id=b.business_id) THEN RAISE EXCEPTION 'Record does not belong to this import.' USING ERRCODE='42501';END IF;
  PERFORM public.v6215_set_record_action((d->>'id')::uuid,d->>'action');
 END LOOP;
 RETURN public.v6215_confirm_import(p_batch);
END;$fn$;
REVOKE ALL ON FUNCTION public.v6225_confirm_import_review(uuid,timestamptz,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6225_confirm_import_review(uuid,timestamptz,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.v6171b_apply_mapping(p_batch uuid, p_sheet uuid, p_record_type text, p_mapping jsonb, p_cutover date DEFAULT CURRENT_DATE, p_mode text DEFAULT 'continue_today'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare bid uuid:=current_business_id();r record;m jsonb;norm jsonb;msgs jsonb;st text;nm text;target text;begin
if not public.v6223_import_batch_access(p_batch,true) then raise exception 'Import access denied' using errcode='42501';end if;
perform 1 from public.import_batches where id=p_batch and business_id=bid for update;
if not found or not public.v6223_import_batch_access(p_batch,true) then raise exception 'Import access changed' using errcode='42501';end if;
if p_record_type<>'unknown' and not public.v6223_import_type_access(bid,p_record_type,true) then raise exception 'Record type access denied' using errcode='42501';end if;
if exists(select 1 from public.import_records where batch_id=p_batch) then raise exception 'Use Smart Migration to remap this batch.' using errcode='22023';end if;
if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Import access denied' using errcode='42501';end if;if p_record_type not in('customers','suppliers','invoices','expenses','employees','unknown') then raise exception 'Invalid record type';end if;if p_mode not in('continue_today','historical_reference') then raise exception 'Invalid migration mode';end if;if not exists(select 1 from import_batches where id=p_batch and business_id=bid and status in('analysed','reviewed')) then raise exception 'Import batch is not ready for mapping';end if;if not exists(select 1 from import_sheets where id=p_sheet and batch_id=p_batch and business_id=bid) then raise exception 'Import sheet not found';end if;update import_sheets set detected_record_type=p_record_type where id=p_sheet;
for m in select * from jsonb_array_elements(coalesce(p_mapping,'[]'::jsonb)) loop update import_mappings set confirmed_target=nullif(m->>'target','skip'),confirmed_by=auth.uid(),confirmed_at=now() where sheet_id=p_sheet and source_column=m->>'source';end loop;
for r in select * from import_rows where sheet_id=p_sheet order by source_row_number loop norm:='{}'::jsonb;msgs:='[]'::jsonb;st:='ready';for m in select to_jsonb(x) from import_mappings x where x.sheet_id=p_sheet and x.confirmed_target is not null loop target:=m->>'confirmed_target';norm:=norm||jsonb_build_object(target,coalesce(r.source_data->>(m->>'source_column'),''));end loop;
if p_record_type='customers' then nm:=btrim(coalesce(norm->>'name',''));if nm='' then st:='rejected';msgs:=msgs||jsonb_build_array('Customer name is required.');end if;if nm<>'' and exists(select 1 from customers c where c.business_id=bid and lower(btrim(c.name))=lower(nm)) then st:='warning';msgs:=msgs||jsonb_build_array('A customer with this name already exists and will be skipped.');end if;
elsif p_record_type='suppliers' then nm:=btrim(coalesce(norm->>'name',''));if nm='' then st:='rejected';msgs:=msgs||jsonb_build_array('Supplier name is required.');end if;if nm<>'' and exists(select 1 from suppliers s where s.business_id=bid and lower(btrim(s.supplier_name))=lower(nm) and not s.archived) then st:='warning';msgs:=msgs||jsonb_build_array('A supplier with this name already exists and will be skipped.');end if;
elsif p_record_type in('invoices','expenses') then st:='rejected';msgs:=jsonb_build_array('V61.71B does not import historical financial transactions because the protected lifecycle would create native accounting/tax semantics. This row was not written to Finlo financial records.');
elsif p_record_type='employees' then st:='rejected';msgs:=jsonb_build_array('Employee import is deferred because creating an employee applies payroll/tax defaults that cannot be safely inferred from basic contact data.');
else st:='rejected';msgs:=jsonb_build_array('Choose what this sheet contains before importing.');end if;update import_rows set record_type=p_record_type,normalized_data=norm,validation_status=st,validation_messages=msgs where id=r.id;end loop;
update import_batches set cutover_date=p_cutover,migration_mode=p_mode,status='reviewed',updated_at=now(),valid_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='ready'),warning_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='warning'),rejected_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='rejected') where id=p_batch;return v6171b_import_get(p_batch);end$function$
;

CREATE OR REPLACE FUNCTION public.v6171b_confirm_import(p_batch uuid, p_duplicate_action text DEFAULT 'skip'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare bid uuid:=current_business_id();b import_batches;r record;rid uuid;n integer:=0;seq integer;contact jsonb;begin
 if not public.v6223_import_batch_access(p_batch,true) then raise exception 'You need permission for every type of record in this import.' using errcode='42501'; end if;

if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Import access denied' using errcode='42501';end if;if p_duplicate_action<>'skip' then raise exception 'V61.71B only supports safe Skip existing behaviour. Existing financial records are never overwritten.';end if;select * into b from import_batches where id=p_batch and business_id=bid for update;if not found then raise exception 'Import batch not found';end if;if not public.v6223_import_batch_access(p_batch,true) then raise exception 'Import access changed' using errcode='42501';end if;
if b.status='completed' then return v6171b_import_get(p_batch);end if;if exists(select 1 from public.import_records where batch_id=p_batch and business_id=bid) then raise exception 'This is a Smart Migration batch. Confirm it through the Smart Migration review.' using errcode='22023';end if;if b.status<>'reviewed' then raise exception 'Review and confirm mappings before importing.';end if;update import_batches set status='importing',updated_at=now() where id=p_batch;perform pg_advisory_xact_lock(hashtext('v6171b-import-'||bid::text));
for r in select * from import_rows where batch_id=p_batch and validation_status in('ready','warning') order by sheet_id,source_row_number loop
if exists(select 1 from import_record_links l where l.business_id=bid and l.source_hash=r.source_hash and l.record_type=r.record_type) then update import_rows set validation_status='skipped',validation_messages=validation_messages||jsonb_build_array('Already imported from an earlier batch.') where id=r.id;continue;end if;
if r.record_type='customers' then if exists(select 1 from customers c where c.business_id=bid and lower(btrim(c.name))=lower(btrim(r.normalized_data->>'name'))) then update import_rows set validation_status='skipped' where id=r.id;continue;end if;select coalesce(max(nullif(regexp_replace(customer_number,'\D','','g'),'')::int),0)+1 into seq from customers where business_id=bid and customer_number ~ '[0-9]';contact:=case when coalesce(nullif(btrim(r.normalized_data->>'email'),''),nullif(btrim(r.normalized_data->>'phone'),'')) is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'name',r.normalized_data->>'name','designation','','phone',coalesce(r.normalized_data->>'phone',''),'mobile',coalesce(r.normalized_data->>'mobile',''),'email',coalesce(r.normalized_data->>'email',''),'dob','','billing',true)) end;insert into customers(business_id,customer_number,customer_type,name,address,contacts,custom_fields) values(bid,'C'||lpad(seq::text,4,'0'),'individual',btrim(r.normalized_data->>'name'),nullif(btrim(r.normalized_data->>'address'),''),contact,'[]') returning id into rid;
elsif r.record_type='suppliers' then if exists(select 1 from suppliers s where s.business_id=bid and lower(btrim(s.supplier_name))=lower(btrim(r.normalized_data->>'name')) and not s.archived) then update import_rows set validation_status='skipped' where id=r.id;continue;end if;insert into suppliers(business_id,supplier_name,contact_person,address,phone,mobile,email,registration_number,tax_number,default_gst_treatment,payment_terms_days) values(bid,btrim(r.normalized_data->>'name'),nullif(btrim(r.normalized_data->>'contact_person'),''),nullif(btrim(r.normalized_data->>'address'),''),nullif(btrim(r.normalized_data->>'phone'),''),nullif(btrim(r.normalized_data->>'mobile'),''),nullif(btrim(r.normalized_data->>'email'),''),nullif(btrim(r.normalized_data->>'registration_number'),''),nullif(btrim(r.normalized_data->>'tax_number'),''),'gst',0) returning id into rid;else continue;end if;
insert into import_record_links(business_id,batch_id,import_row_id,record_type,record_id,source_hash) values(bid,p_batch,r.id,r.record_type,rid,r.source_hash);update import_rows set validation_status='imported',imported_record_type=r.record_type,imported_record_id=rid where id=r.id;n:=n+1;end loop;
update import_batches set status='completed',imported_rows=n,warning_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='warning'),rejected_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='rejected'),completed_at=now(),updated_at=now() where id=p_batch;return v6171b_import_get(p_batch);end$function$
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
if not public.v6223_import_batch_access(p_batch,true) then raise exception 'Import access changed' using errcode='42501';end if;
  if v_batch.status='completed' then return v6215_import_get(p_batch); end if;
  if not exists(select 1 from public.import_records where batch_id=p_batch and business_id=v_bid) then raise exception 'This batch has no Smart Migration records. Analyse a file with data or use its original import review.' using errcode='22023';end if;
  if v_batch.status not in ('analysed','reviewed') then raise exception 'Review this import before confirming it'; end if;
  perform pg_advisory_xact_lock(hashtext('v6215-import-'||v_bid::text));
  perform public.v6223_validate_import_documents(p_batch);
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
      if exists(select 1 from invoices where business_id=v_bid and lower(btrim(invoice_number))=lower(btrim(v_n->>'number'))) then raise exception 'Invoice number % already exists. Choose Skip or keep it as historical reference; existing invoices are not replaced.',v_n->>'number' using errcode='23505';
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
      if exists(select 1 from expenses where business_id=v_bid and lower(btrim(expense_number))=lower(btrim(v_number))) then raise exception 'Expense number % already exists. Choose Skip or keep it as historical reference; existing expenses are not replaced.',v_number using errcode='23505';
      else insert into expenses(business_id,expense_number,supplier_name,supplier_reference,invoice_date,due_date,description,amount_type,gst_treatment,gst_rate,gst_override,ex_gst,gst_amount,total_amount,amount_paid,outstanding_balance,payment_status,currency,is_split,archived,business_use_percent,business_use_amount,private_use_amount,business_ex_gst,business_gst_amount,allocation_method,allocation_basis,updated_by)
        values(v_bid,v_number,nullif(v_n->>'party_name',''),nullif(v_n->>'reference',''),(v_n->>'date')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'description',''),'Imported opening payable'),'inclusive',case when v_gst>0 then 'gst' else 'no_gst' end,case when v_gst>0 then 15 else 0 end,true,v_subtotal,v_gst,v_total,greatest(0,v_total-v_outstanding),v_outstanding,case when v_outstanding<v_total then 'part_paid' else 'unpaid' end,upper(coalesce(nullif(v_n->>'currency',''),'NZD'))::char(3),false,false,100,v_total,0,v_subtotal,v_gst,'percentage','Imported opening payable',auth.uid()) returning id into v_id; end if;

    elsif v_r.record_type='quotes' then
      v_total:=coalesce((v_n->>'total')::numeric,0);v_gst:=coalesce((v_n->>'gst')::numeric,0);v_subtotal:=coalesce((v_n->>'subtotal')::numeric,v_total-v_gst);
      if exists(select 1 from quotes where business_id=v_bid and lower(btrim(quote_number))=lower(btrim(v_n->>'number'))) then raise exception 'Quote number % already exists. Choose Skip; existing quotes are not replaced.',v_n->>'number' using errcode='23505';
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
CREATE OR REPLACE FUNCTION public.v6215_set_record_action(p_record uuid,p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid:=public.current_business_id();r public.import_records%ROWTYPE;b public.import_batches%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR bid IS NULL OR NOT public.v6147_can_write_area(bid,'core') THEN RAISE EXCEPTION 'Import access denied' USING ERRCODE='42501';END IF;
 IF p_action IS NULL OR p_action NOT IN ('create','skip','update_safe','historical_reference') THEN RAISE EXCEPTION 'Invalid import action' USING ERRCODE='22023';END IF;
 SELECT * INTO r FROM public.import_records WHERE id=p_record AND business_id=bid;
 IF NOT FOUND THEN RAISE EXCEPTION 'Import record not found';END IF;
 -- All paths acquire the batch lock before any child lock.
 SELECT * INTO b FROM public.import_batches WHERE id=r.batch_id AND business_id=bid FOR UPDATE;
 IF NOT FOUND OR NOT public.v6223_import_batch_access(b.id,true) THEN RAISE EXCEPTION 'Import access changed' USING ERRCODE='42501';END IF;
 IF b.status NOT IN ('analysed','reviewed') THEN RAISE EXCEPTION 'Completed imports cannot be changed' USING ERRCODE='55000';END IF;
 SELECT * INTO r FROM public.import_records WHERE id=p_record AND batch_id=b.id AND business_id=bid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'The review changed. Reopen the import.' USING ERRCODE='40001';END IF;
 IF p_action='update_safe' AND r.record_type NOT IN ('customers','suppliers') THEN RAISE EXCEPTION 'Only contact details support safe update';END IF;
 IF p_action='historical_reference' AND r.record_type NOT IN ('invoices','expenses') THEN RAISE EXCEPTION 'Only financial documents support historical reference';END IF;
 UPDATE public.import_records SET duplicate_action=p_action,commit_mode=CASE WHEN p_action='historical_reference' THEN 'historical_reference' ELSE commit_mode END,updated_at=clock_timestamp() WHERE id=p_record;
 UPDATE public.import_batches SET updated_at=clock_timestamp() WHERE id=b.id;
 RETURN public.v6215_import_get(b.id);
END;$fn$;
