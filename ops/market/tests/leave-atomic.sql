DO $test$
DECLARE u uuid;bid uuid:=gen_random_uuid();plan uuid;emp uuid:=gen_random_uuid();lt uuid:=gen_random_uuid();lt2 uuid:=gen_random_uuid();req uuid:=gen_random_uuid();payload jsonb;rev timestamptz;r jsonb;denied boolean;before_count bigint;
BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;
 SELECT id INTO u FROM auth.users a WHERE NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=a.id) ORDER BY id LIMIT 1;
 SELECT id INTO plan FROM public.plans WHERE 'payroll'=ANY(included_modules) ORDER BY cardinality(included_modules) DESC NULLS LAST LIMIT 1;
 IF u IS NULL OR plan IS NULL THEN RAISE EXCEPTION 'Fixture prerequisites missing';END IF;
 BEGIN
  INSERT INTO public.businesses(id,name) VALUES(bid,'Market leave transaction fixture');
  INSERT INTO public.profiles(id,business_id,active_business_id,full_name,role,is_super_admin) VALUES(u,bid,bid,'Leave fixture','owner',false);
  INSERT INTO public.business_memberships(business_id,user_id,role,status) VALUES(bid,u,'owner','active');
  INSERT INTO public.subscriptions(business_id,plan_id,status,current_period_end,trial_ends_at) VALUES(bid,plan,'trialing',now()+interval '30 days',now()+interval '30 days');
  INSERT INTO public.payroll_employees(id,business_id,employee_number,first_name,last_name) VALUES(emp,bid,'FIXTURE','Leave','Fixture');
  INSERT INTO public.payroll_leave_types(id,business_id,name) VALUES(lt,bid,'Fixture hours'),(lt2,bid,'Other fixture hours');
  PERFORM set_config('request.jwt.claim.sub',u::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  payload:=jsonb_build_array(jsonb_build_object('mode','entry','leave_type_id',lt,'type','accrual','hours','12.5','date','2026-10-01','notes','Fixture accrual'));
  r:=public.v6226_apply_leave_hours(emp,req,payload);
  IF (r->0->>'balance_hours')::numeric<>12.5 OR (SELECT count(*) FROM public.payroll_leave_transactions WHERE employee_id=emp)<>1 THEN RAISE EXCEPTION 'Accrual not atomic';END IF;
  PERFORM public.v6226_apply_leave_hours(emp,req,payload);
  IF (SELECT count(*) FROM public.payroll_leave_transactions WHERE employee_id=emp)<>1 OR (SELECT count(*) FROM public.payroll_audit_log WHERE entity_id=emp)<>1 THEN RAISE EXCEPTION 'Retry duplicated entry or audit';END IF;
  denied:=false;BEGIN PERFORM public.v6226_apply_leave_hours(emp,req,jsonb_set(payload,'{0,hours}','"20"'));EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Reused identifier accepted different payload';END IF;
  PERFORM public.v6226_apply_leave_hours(emp,gen_random_uuid(),jsonb_set(jsonb_set(payload,'{0,type}','"taken"'),'{0,hours}','"2.5"'));
  IF (SELECT balance_hours FROM public.payroll_employee_leave WHERE employee_id=emp AND leave_type_id=lt)<>10 THEN RAISE EXCEPTION 'Taken balance incorrect';END IF;
  SELECT updated_at INTO rev FROM public.payroll_employee_leave WHERE employee_id=emp AND leave_type_id=lt;
  payload:=jsonb_build_array(jsonb_build_object('mode','balance','leave_type_id',lt,'hours','15','date','2026-10-01','notes','Correct opening record','expected_updated_at',rev));
  PERFORM public.v6226_apply_leave_hours(emp,gen_random_uuid(),payload);
  denied:=false;BEGIN PERFORM public.v6226_apply_leave_hours(emp,gen_random_uuid(),payload);EXCEPTION WHEN serialization_failure THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Stale absolute balance accepted';END IF;
  SELECT count(*) INTO before_count FROM public.payroll_leave_transactions WHERE employee_id=emp;
  denied:=false;BEGIN
   PERFORM public.v6226_apply_leave_hours(emp,gen_random_uuid(),jsonb_build_array(
    jsonb_build_object('mode','entry','leave_type_id',lt,'type','accrual','hours','1','date','2026-10-01'),
    jsonb_build_object('mode','entry','leave_type_id',lt2,'type','taken','hours','500','date','2026-10-01')));
  EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;
  IF NOT denied OR (SELECT count(*) FROM public.payroll_leave_transactions WHERE employee_id=emp)<>before_count OR (SELECT balance_hours FROM public.payroll_employee_leave WHERE employee_id=emp AND leave_type_id=lt)<>15 THEN RAISE EXCEPTION 'Failed multi-balance save left partial history';END IF;
  denied:=false;BEGIN UPDATE public.payroll_employee_leave SET balance_hours=100 WHERE employee_id=emp;EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Direct hours overwrite allowed';END IF;
  denied:=false;BEGIN INSERT INTO public.payroll_leave_transactions(business_id,employee_id,leave_type_id,transaction_type,hours) VALUES(bid,emp,lt,'accrual',100);EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Old browser split write allowed';END IF;
  PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  denied:=false;BEGIN PERFORM public.v6226_apply_leave_hours(emp,gen_random_uuid(),payload);EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Foreign caller changed leave';END IF;
  PERFORM set_config('request.jwt.claim.sub',u::text,true);
  EXECUTE 'RESET ROLE';
  UPDATE public.payroll_employee_leave SET statutory_quantity=3,statutory_unit='days',statutory_leave_code='sick_leave' WHERE employee_id=emp AND leave_type_id=lt;
  EXECUTE 'SET LOCAL ROLE authenticated';
  denied:=false;BEGIN PERFORM public.v6226_apply_leave_hours(emp,gen_random_uuid(),payload);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Hours writer changed statutory entitlement';END IF;
  IF (SELECT statutory_quantity FROM public.payroll_employee_leave WHERE employee_id=emp AND leave_type_id=lt)<>3 THEN RAISE EXCEPTION 'Statutory quantity changed';END IF;
  -- v62.30 routes supported confirmed statutory entries through their complete bundle.
  denied:=false;BEGIN INSERT INTO public.payroll_leave_transactions(business_id,employee_id,leave_type_id,transaction_type,hours,statutory_quantity,statutory_unit,statutory_leave_code) VALUES(bid,emp,lt,'taken',8,1,'days','sick_leave');EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Old split statutory writer allowed';END IF;
  EXECUTE 'RESET ROLE';
  IF has_function_privilege('anon','public.v6226_apply_leave_hours(uuid,uuid,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous hours API';END IF;
  RAISE EXCEPTION USING ERRCODE='P6226',MESSAGE='Rollback leave fixtures';
 EXCEPTION WHEN SQLSTATE 'P6226' THEN NULL;END;
 IF EXISTS(SELECT 1 FROM public.businesses WHERE id=bid) THEN RAISE EXCEPTION 'Fixture leaked';END IF;
 RAISE NOTICE 'Leave atomic fixtures passed; all changes rolled back';
END;$test$;
