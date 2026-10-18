DO $test$
DECLARE manager uuid;worker uuid;other_manager uuid;bid uuid:=gen_random_uuid();plan uuid;emp uuid:=gen_random_uuid();link uuid:=gen_random_uuid();ts uuid:=gen_random_uuid();op uuid:=gen_random_uuid();r jsonb;denied boolean;
BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;
 SELECT id INTO manager FROM auth.users WHERE email_confirmed_at IS NOT NULL ORDER BY id LIMIT 1;
 SELECT id INTO worker FROM auth.users WHERE email_confirmed_at IS NOT NULL AND id<>manager ORDER BY id LIMIT 1;
 SELECT id INTO other_manager FROM auth.users WHERE email_confirmed_at IS NOT NULL AND id NOT IN(manager,worker) ORDER BY id LIMIT 1;
 SELECT id INTO plan FROM public.plans WHERE 'payroll'=ANY(included_modules) ORDER BY cardinality(included_modules) DESC NULLS LAST LIMIT 1;
 IF manager IS NULL OR worker IS NULL OR other_manager IS NULL OR plan IS NULL THEN RAISE EXCEPTION 'Fixture prerequisites missing';END IF;
 BEGIN
  INSERT INTO public.businesses(id,name) VALUES(bid,'Market timesheet decision fixture');
  INSERT INTO public.profiles(id,business_id,active_business_id,full_name,role,is_super_admin) VALUES(manager,bid,bid,'Decision manager','owner',false);
  INSERT INTO public.business_memberships(business_id,user_id,role,status) VALUES(bid,manager,'owner','active');
  INSERT INTO public.subscriptions(business_id,plan_id,status,current_period_end,trial_ends_at) VALUES(bid,plan,'trialing',now()+interval '30 days',now()+interval '30 days');
  INSERT INTO public.payroll_employees(id,business_id,employee_number,first_name,last_name) VALUES(emp,bid,'DEC-1','Decision','Worker');
  INSERT INTO public.payroll_employee_portal_links(id,business_id,employee_id,user_id,active,timesheets_enabled) VALUES(link,bid,emp,worker,true,true);
  INSERT INTO public.payroll_timesheets(id,business_id,employee_id,work_date,start_time,finish_time,total_hours,status,submitted_at,portal_link_id,created_by) VALUES(ts,bid,emp,current_date,'08:00','16:00',8,'submitted',now(),link,worker);
  PERFORM set_config('request.jwt.claim.sub',manager::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',manager,'role','authenticated')::text,true);EXECUTE 'SET LOCAL ROLE authenticated';
  denied:=false;BEGIN UPDATE public.payroll_timesheets SET status='approved' WHERE id=ts;EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Direct portal decision remained open';END IF;
  denied:=false;BEGIN PERFORM public.v6234_decide_employee_timesheets(ARRAY[ts],'reject',NULL,gen_random_uuid());EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Reject without feedback accepted';END IF;
  r:=public.v6234_decide_employee_timesheets(ARRAY[ts],'reject','Please correct the finish time.',op);IF r->>'count'<>'1' OR (SELECT status FROM public.payroll_timesheets WHERE id=ts)<>'rejected' THEN RAISE EXCEPTION 'Reject failed';END IF;
  IF public.v6234_decide_employee_timesheets(ARRAY[ts],'reject','Please correct the finish time.',op)<>r THEN RAISE EXCEPTION 'Decision retry changed result';END IF;EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',worker::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated')::text,true);EXECUTE 'SET LOCAL ROLE authenticated';r:=public.v6233_employee_work_read(link,0);IF r#>>'{timesheets,0,decision_note}' IS DISTINCT FROM 'Please correct the finish time.' THEN RAISE EXCEPTION 'Employee feedback missing';END IF;r:=public.v6233_employee_timesheet_command(link,ts,gen_random_uuid(),'submit',(r#>>'{timesheets,0,portal_revision}')::bigint,jsonb_build_object('work_date',current_date,'start_time','08:00','finish_time','17:00','break_minutes',60,'pay_type','ordinary','notes','Corrected'));IF r->>'status'<>'submitted' OR (SELECT decision_note FROM public.payroll_timesheets WHERE id=ts) IS NOT NULL THEN RAISE EXCEPTION 'Corrected resubmission retained decision';END IF;EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',manager::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',manager,'role','authenticated')::text,true);EXECUTE 'SET LOCAL ROLE authenticated';r:=public.v6234_decide_employee_timesheets(ARRAY[ts],'approve',NULL,gen_random_uuid());IF (SELECT status FROM public.payroll_timesheets WHERE id=ts)<>'approved' OR (SELECT decided_by FROM public.payroll_timesheets WHERE id=ts)<>manager THEN RAISE EXCEPTION 'Approval evidence missing';END IF;EXECUTE 'RESET ROLE';
  IF has_table_privilege('authenticated','public.payroll_timesheet_decision_operations','SELECT') OR has_function_privilege('anon','public.v6234_decide_employee_timesheets(uuid[],text,text,uuid)','EXECUTE') THEN RAISE EXCEPTION 'Decision evidence exposed';END IF;
  RAISE EXCEPTION USING ERRCODE='P6234',MESSAGE='Rollback timesheet decision fixture';
 EXCEPTION WHEN SQLSTATE 'P6234' THEN NULL;END;
 IF EXISTS(SELECT 1 FROM public.businesses WHERE id=bid) OR EXISTS(SELECT 1 FROM public.payroll_timesheet_decision_operations WHERE business_id=bid) THEN RAISE EXCEPTION 'Decision fixture leaked';END IF;
 RAISE NOTICE 'Employee timesheet decision fixture passed; all data rolled back';
END;$test$;
