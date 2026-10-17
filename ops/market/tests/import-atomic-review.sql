DO $test$
DECLARE u uuid;bid uuid:=gen_random_uuid();plan uuid;batch uuid:=gen_random_uuid();s1 uuid:=gen_random_uuid();s2 uuid:=gen_random_uuid();raw1 uuid:=gen_random_uuid();raw2 uuid:=gen_random_uuid();old1 uuid:=gen_random_uuid();old2 uuid:=gen_random_uuid();rev timestamptz;payload jsonb;bad jsonb;r jsonb;denied boolean;rid uuid;n bigint;tab text;batch2 uuid:=gen_random_uuid();s3 uuid:=gen_random_uuid();raw3 uuid:=gen_random_uuid();rev2 timestamptz;payload2 jsonb;
BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;
 SELECT id INTO u FROM auth.users a WHERE NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=a.id) ORDER BY id LIMIT 1;
 SELECT id INTO plan FROM public.plans ORDER BY cardinality(included_modules) DESC NULLS LAST LIMIT 1;
 BEGIN
  INSERT INTO public.import_migration_settings(id,enabled,ai_mapping_enabled) VALUES(true,true,false) ON CONFLICT(id) DO UPDATE SET enabled=true;
  INSERT INTO public.businesses(id,name) VALUES(bid,'Market atomic import fixture');
  INSERT INTO public.profiles(id,business_id,active_business_id,full_name,role,is_super_admin) VALUES(u,bid,bid,'Atomic fixture','owner',false);
  INSERT INTO public.business_memberships(business_id,user_id,role,status) VALUES(bid,u,'owner','active');
  INSERT INTO public.subscriptions(business_id,plan_id,status,current_period_end,trial_ends_at) VALUES(bid,plan,'trialing',now()+interval '30 days',now()+interval '30 days');
  INSERT INTO public.import_batches(id,business_id,user_id,filename,source_type,file_sha256,status,total_rows) VALUES(batch,bid,u,'atomic.csv','csv',batch::text,'analysed',2) RETURNING updated_at INTO rev;
  INSERT INTO public.import_sheets(id,batch_id,business_id,sheet_index,sheet_name,detected_record_type,headers,row_count) VALUES(s1,batch,bid,0,'One','customers','["Name"]',1),(s2,batch,bid,1,'Two','customers','["Name"]',1);
  INSERT INTO public.import_rows(id,batch_id,sheet_id,business_id,source_row_number,source_hash,source_data,record_type) VALUES(raw1,batch,s1,bid,2,'one','{"Name":"One"}','customers'),(raw2,batch,s2,bid,2,'two','{"Name":"Two"}','customers');
  INSERT INTO public.import_mappings(batch_id,sheet_id,business_id,source_column,suggested_target) VALUES(batch,s1,bid,'Name','name'),(batch,s2,bid,'Name','name');
  INSERT INTO public.import_records(id,batch_id,sheet_id,business_id,record_type,group_key,canonical_hash,display_label,normalized_data,commit_mode) VALUES(old1,batch,s1,bid,'customers','oldone','oldone','Original One','{"name":"Old One"}','native_master'),(old2,batch,s2,bid,'customers','oldtwo','oldtwo','Original Two','{"name":"Old Two"}','native_master');
  payload:=jsonb_build_array(
   jsonb_build_object('id',s1,'record_type','customers','mapping',jsonb_build_object('Name','name'),'header_signature',repeat('c',64),'records',jsonb_build_array(jsonb_build_object('record_type','customers','group_key','one','canonical_hash',repeat('a',64),'display_label','One','normalized_data',jsonb_build_object('name','One'),'commit_mode','native_master','validation_status','ready','validation_messages','[]'::jsonb,'member_ids',jsonb_build_array(raw1)))),
   jsonb_build_object('id',s2,'record_type','customers','mapping',jsonb_build_object('Name','name'),'header_signature',repeat('c',64),'records',jsonb_build_array(jsonb_build_object('record_type','customers','group_key','two','canonical_hash',repeat('b',64),'display_label','Two','normalized_data',jsonb_build_object('name','Two'),'commit_mode','native_master','validation_status','ready','validation_messages','[]'::jsonb,'member_ids',jsonb_build_array(raw2)))));
  PERFORM set_config('request.jwt.claim.sub',u::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  denied:=false;BEGIN PERFORM public.v6225_replace_import_review(batch,rev,'2026-10-01','continue_today',payload);EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Foreign caller remapped review';END IF;
  denied:=false;BEGIN PERFORM public.v6225_confirm_import_review(batch,rev,'[]');EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Foreign caller confirmed review';END IF;
  PERFORM set_config('request.jwt.claim.sub',u::text,true);
  bad:=jsonb_set(payload,'{1,records,0,member_ids}',jsonb_build_array(raw1));denied:=false;
  BEGIN PERFORM public.v6225_replace_import_review(batch,rev,'2026-10-01','continue_today',bad);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Cross-sheet evidence accepted';END IF;
  IF (SELECT count(*) FROM public.import_records WHERE id IN(old1,old2))<>2 OR (SELECT updated_at FROM public.import_batches WHERE id=batch)<>rev OR EXISTS(SELECT 1 FROM public.import_mapping_profiles WHERE business_id=bid) THEN RAISE EXCEPTION 'Failed second sheet left partial writes';END IF;
  denied:=false;BEGIN PERFORM public.v6225_replace_import_review(batch,rev-interval '1 second','2026-10-01','continue_today',payload);EXCEPTION WHEN serialization_failure THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Stale review accepted';END IF;
  denied:=false;BEGIN PERFORM public.v6171b_apply_mapping(batch,s1,'customers','[]','2026-10-01','continue_today');EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Legacy mapper changed smart batch';END IF;
  r:=public.v6225_replace_import_review(batch,rev,'2026-10-01','continue_today',payload);
  IF r->'batch'->>'status'<>'reviewed' OR jsonb_array_length(r->'records')<>2 OR (SELECT count(*) FROM public.import_record_members WHERE batch_id=batch)<>2 THEN RAISE EXCEPTION 'Atomic replacement incomplete';END IF;
  denied:=false;BEGIN PERFORM public.v6225_replace_import_review(batch,rev,'2026-10-01','continue_today',payload);EXCEPTION WHEN serialization_failure THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Repeated stale replacement accepted';END IF;
  rev:=(r->'batch'->>'updated_at')::timestamptz;
  SELECT id INTO rid FROM public.import_records WHERE sheet_id=s1;
  denied:=false;BEGIN PERFORM public.v6225_confirm_import_review(batch,rev,jsonb_build_array(jsonb_build_object('id',rid,'action','skip'),jsonb_build_object('id',gen_random_uuid(),'action','skip')));EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;
  IF NOT denied OR (SELECT duplicate_action FROM public.import_records WHERE id=rid)<>'create' OR (SELECT updated_at FROM public.import_batches WHERE id=batch)<>rev THEN RAISE EXCEPTION 'Failed decision changed earlier record';END IF;
  EXECUTE 'RESET ROLE';
  BEGIN
   DELETE FROM public.import_record_members WHERE import_row_id=raw2;
   EXECUTE 'SET LOCAL ROLE authenticated';
   denied:=false;BEGIN PERFORM public.v6225_confirm_import_review(batch,rev,'[]');EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;
   IF NOT denied THEN RAISE EXCEPTION 'Incomplete source evidence accepted';END IF;
   EXECUTE 'RESET ROLE';
   RAISE EXCEPTION USING ERRCODE='P6226',MESSAGE='Restore evidence fixture';
  EXCEPTION WHEN SQLSTATE 'P6226' THEN NULL;END;
  EXECUTE 'SET LOCAL ROLE authenticated';
  r:=public.v6225_confirm_import_review(batch,rev,'[]');
  IF r->'batch'->>'status'<>'completed' OR (SELECT count(*) FROM public.customers WHERE business_id=bid AND name IN('One','Two'))<>2 THEN RAISE EXCEPTION 'Atomic confirmation failed';END IF;
  PERFORM public.v6225_confirm_import_review(batch,rev,'[]');
  IF (SELECT count(*) FROM public.customers WHERE business_id=bid AND name IN('One','Two'))<>2 THEN RAISE EXCEPTION 'Retry duplicated contacts';END IF;
  EXECUTE 'RESET ROLE';
  -- Duplicate identity comes from completed database evidence, not an Edge lookup.
  INSERT INTO public.import_batches(id,business_id,user_id,filename,source_type,file_sha256,status,total_rows) VALUES(batch2,bid,u,'repeat.csv','csv',batch2::text,'analysed',1) RETURNING updated_at INTO rev2;
  INSERT INTO public.import_sheets(id,batch_id,business_id,sheet_index,sheet_name,detected_record_type,headers,row_count) VALUES(s3,batch2,bid,0,'Repeat','customers','["Name"]',1);
  INSERT INTO public.import_rows(id,batch_id,sheet_id,business_id,source_row_number,source_hash,source_data,record_type) VALUES(raw3,batch2,s3,bid,2,'one','{"Name":"One"}','customers');
  INSERT INTO public.import_mappings(batch_id,sheet_id,business_id,source_column,suggested_target) VALUES(batch2,s3,bid,'Name','name');
  payload2:=jsonb_build_array(jsonb_set(jsonb_set(payload->0,'{id}',to_jsonb(s3)),'{records,0,member_ids}',jsonb_build_array(raw3)));
  EXECUTE 'SET LOCAL ROLE authenticated';
  r:=public.v6225_replace_import_review(batch2,rev2,'2026-10-01','continue_today',payload2);
  IF r->'records'->0->>'duplicate_status'<>'exact' OR r->'records'->0->>'duplicate_action'<>'skip' OR r->'records'->0->>'validation_status'<>'warning' THEN RAISE EXCEPTION 'Completed duplicate not detected by database';END IF;
  PERFORM public.v6225_confirm_import_review(batch2,(r->'batch'->>'updated_at')::timestamptz,'[]');
  IF (SELECT count(*) FROM public.customers WHERE business_id=bid AND name='One')<>1 THEN RAISE EXCEPTION 'Duplicate imported again';END IF;
  EXECUTE 'RESET ROLE';
  -- Even privileged old service mutations cannot rewrite completed evidence.
  FOREACH tab IN ARRAY ARRAY['import_batches','import_sheets','import_rows','import_mappings','import_records','import_record_members','import_commit_events'] LOOP
   denied:=false;BEGIN
    IF tab='import_batches' THEN EXECUTE format('UPDATE public.%I SET status=status WHERE id=$1',tab) USING batch;
    ELSE EXECUTE format('DELETE FROM public.%I WHERE batch_id=$1',tab) USING batch;END IF;
   EXCEPTION WHEN object_not_in_prerequisite_state THEN denied:=true;END;
   IF NOT denied THEN RAISE EXCEPTION 'Completed evidence writable: %',tab;END IF;
  END LOOP;
  denied:=false;BEGIN UPDATE public.import_batches SET status='reviewed' WHERE id=batch;EXCEPTION WHEN object_not_in_prerequisite_state THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Completed batch reopened';END IF;
  IF has_function_privilege('anon','public.v6225_replace_import_review(uuid,timestamptz,date,text,jsonb)','EXECUTE') OR has_function_privilege('authenticated','public.v6225_guard_import_evidence()','EXECUTE') THEN RAISE EXCEPTION 'Unsafe function grant';END IF;
  -- Existing unrelated financial-audit deletion trigger may reject the business
  -- cascade. The evidence guard must not add its own 55000 failure to that path.
  BEGIN
   DELETE FROM public.businesses WHERE id=bid;
  EXCEPTION WHEN foreign_key_violation THEN
   IF SQLERRM NOT LIKE '%financial_audit_log_business_id_fkey%' THEN RAISE;END IF;
  END;
  RAISE EXCEPTION USING ERRCODE='P6225',MESSAGE='Rollback atomic import fixtures';
 EXCEPTION WHEN SQLSTATE 'P6225' THEN NULL;END;
 IF EXISTS(SELECT 1 FROM public.businesses WHERE id=bid) THEN RAISE EXCEPTION 'Fixture leaked';END IF;
 RAISE NOTICE 'Atomic import fixtures passed; all rows rolled back';
END;$test$;
