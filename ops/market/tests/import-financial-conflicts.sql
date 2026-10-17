-- Market only: conflicting financial numbers never become false successful imports.
DO $test$
DECLARE u uuid;bid uuid:=gen_random_uuid();plan uuid;batch uuid;sheet uuid;rid uuid;typ text;mode text;source jsonb;result jsonb;denied boolean;n bigint;
BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;
 SELECT id INTO u FROM auth.users a WHERE NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=a.id) ORDER BY id LIMIT 1;
 SELECT id INTO plan FROM public.plans ORDER BY cardinality(included_modules) DESC NULLS LAST LIMIT 1;
 IF u IS NULL OR plan IS NULL THEN RAISE EXCEPTION 'Fixture prerequisites missing';END IF;
 BEGIN
  INSERT INTO public.businesses(id,name) VALUES(bid,'Market financial import fixture');
  INSERT INTO public.profiles(id,business_id,active_business_id,full_name,role,is_super_admin) VALUES(u,bid,bid,'Import fixture','owner',false);
  INSERT INTO public.business_memberships(business_id,user_id,role,status) VALUES(bid,u,'owner','active');
  INSERT INTO public.subscriptions(business_id,plan_id,status,current_period_end,trial_ends_at) VALUES(bid,plan,'trialing',now()+interval '30 days',now()+interval '30 days');
  PERFORM set_config('request.jwt.claim.sub',u::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u::text,'role','authenticated')::text,true);
  FOREACH typ IN ARRAY ARRAY['invoices','expenses','quotes'] LOOP
   mode:=CASE WHEN typ='quotes' THEN 'native_quote' ELSE 'native_opening' END;
   source:=jsonb_build_object('number','MARKET-FIN-'||typ,'party_name','Original fixture','date','2026-09-30','due_date','2026-10-20','subtotal',100,'gst',15,'total',115,'paid_amount',0,'outstanding_amount',115,'currency','NZD','items',jsonb_build_array(jsonb_build_object('description','Fixture','quantity',1,'rate',100,'amount',100)));
   batch:=gen_random_uuid();sheet:=gen_random_uuid();rid:=gen_random_uuid();
   INSERT INTO public.import_batches(id,business_id,user_id,filename,source_type,file_sha256,status) VALUES(batch,bid,u,'financial.csv','csv',batch::text,'analysed');
   INSERT INTO public.import_sheets(id,batch_id,business_id,sheet_index,sheet_name,detected_record_type,headers,sample_rows,row_count) VALUES(sheet,batch,bid,0,typ,typ,'[]','[]',1);
   INSERT INTO public.import_records(id,batch_id,sheet_id,business_id,record_type,group_key,canonical_hash,display_label,normalized_data,commit_mode) VALUES(rid,batch,sheet,bid,typ,rid::text,rid::text,'Financial fixture',source,mode);
   EXECUTE 'SET LOCAL ROLE authenticated';result:=public.v6215_confirm_import(batch);EXECUTE 'RESET ROLE';
   IF result->'batch'->>'status'<>'completed' THEN RAISE EXCEPTION 'Permitted financial import failed: %',typ;END IF;
   -- A different source document with the same number must stop atomically.
   batch:=gen_random_uuid();sheet:=gen_random_uuid();rid:=gen_random_uuid();source:=source||'{"party_name":"Different fixture","subtotal":200,"gst":30,"total":230,"paid_amount":0,"outstanding_amount":230}'::jsonb;
   INSERT INTO public.import_batches(id,business_id,user_id,filename,source_type,file_sha256,status) VALUES(batch,bid,u,'conflict.csv','csv',batch::text,'analysed');
   INSERT INTO public.import_sheets(id,batch_id,business_id,sheet_index,sheet_name,detected_record_type,headers,sample_rows,row_count) VALUES(sheet,batch,bid,0,typ,typ,'[]','[]',2);
   INSERT INTO public.import_records(id,batch_id,sheet_id,business_id,record_type,group_key,canonical_hash,display_label,normalized_data,commit_mode) VALUES(rid,batch,sheet,bid,typ,rid::text,rid::text,'Z conflict',source,mode);
   INSERT INTO public.import_records(batch_id,sheet_id,business_id,record_type,group_key,canonical_hash,display_label,normalized_data,commit_mode) VALUES(batch,sheet,bid,'customers','customer',batch::text,'A rolls back',jsonb_build_object('name','Must roll back '||typ),'native_master');
   EXECUTE 'SET LOCAL ROLE authenticated';denied:=false;
   BEGIN PERFORM public.v6215_confirm_import(batch);EXCEPTION WHEN unique_violation THEN denied:=true;END;
   EXECUTE 'RESET ROLE';IF NOT denied THEN RAISE EXCEPTION 'Financial collision silently accepted: %',typ;END IF;
   IF (SELECT status FROM public.import_batches WHERE id=batch)<>'analysed' OR EXISTS(SELECT 1 FROM public.import_commit_events WHERE batch_id=batch) OR EXISTS(SELECT 1 FROM public.customers WHERE business_id=bid AND name='Must roll back '||typ) THEN RAISE EXCEPTION 'Conflict left partial writes';END IF;
   -- Invalid source currency and unbalanced amounts fail before commit.
   UPDATE public.import_records SET normalized_data=source||'{"number":"NEW-UNIQUE","currency":"USD"}' WHERE id=rid;
   EXECUTE 'SET LOCAL ROLE authenticated';denied:=false;BEGIN PERFORM public.v6215_confirm_import(batch);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;EXECUTE 'RESET ROLE';IF NOT denied THEN RAISE EXCEPTION 'Unsupported currency accepted';END IF;
   UPDATE public.import_records SET normalized_data=source||'{"number":"NEW-UNIQUE","subtotal":199}' WHERE id=rid;
   EXECUTE 'SET LOCAL ROLE authenticated';denied:=false;BEGIN PERFORM public.v6215_confirm_import(batch);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;EXECUTE 'RESET ROLE';IF NOT denied THEN RAISE EXCEPTION 'Unbalanced amount accepted';END IF;
   IF typ<>'quotes' THEN
    UPDATE public.import_records SET normalized_data=source||'{"number":"NEW-UNIQUE","paid_amount":80,"outstanding_amount":150}' WHERE id=rid;
    EXECUTE 'SET LOCAL ROLE authenticated';denied:=false;BEGIN PERFORM public.v6215_confirm_import(batch);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;EXECUTE 'RESET ROLE';IF NOT denied THEN RAISE EXCEPTION 'Unsafe partial opening accepted';END IF;
   END IF;
   -- Skip remains a safe, explicit resolution.
   EXECUTE 'SET LOCAL ROLE authenticated';result:=public.v6215_set_record_action(rid,'skip');result:=public.v6215_confirm_import(batch);EXECUTE 'RESET ROLE';
   IF result->'batch'->>'status'<>'completed' THEN RAISE EXCEPTION 'Skip resolution failed';END IF;
  END LOOP;
  SELECT count(*) INTO n FROM public.invoices WHERE business_id=bid AND total=115 AND balance_due=115;IF n<>1 THEN RAISE EXCEPTION 'Original invoice changed';END IF;
  SELECT count(*) INTO n FROM public.expenses WHERE business_id=bid AND total_amount=115 AND outstanding_balance=115;IF n<>1 THEN RAISE EXCEPTION 'Original expense changed';END IF;
  SELECT count(*) INTO n FROM public.quotes WHERE business_id=bid AND total_incl_gst=115;IF n<>1 THEN RAISE EXCEPTION 'Original quote changed';END IF;
  RAISE EXCEPTION USING ERRCODE='P6223',MESSAGE='Financial conflict fixtures passed';
 EXCEPTION WHEN SQLSTATE 'P6223' THEN NULL;
 END;
 IF EXISTS(SELECT 1 FROM public.businesses WHERE id=bid) THEN RAISE EXCEPTION 'Fixture leaked';END IF;
 RAISE NOTICE 'Financial conflict fixtures passed; every fixture rolled back';
END$test$;
