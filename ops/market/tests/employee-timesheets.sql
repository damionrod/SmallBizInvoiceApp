DO $test$
DECLARE owner_id uuid;worker uuid;other_worker uuid;bid uuid:=gen_random_uuid();plan uuid;emp uuid:=gen_random_uuid();link uuid;lt uuid:=gen_random_uuid();ts uuid:=gen_random_uuid();op uuid:=gen_random_uuid();email text;r jsonb;rev bigint;tsrev bigint;denied boolean;
BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;
 SELECT id INTO owner_id FROM auth.users a WHERE email_confirmed_at IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=a.id) ORDER BY id LIMIT 1;
 SELECT id,a.email INTO worker,email FROM auth.users a WHERE email_confirmed_at IS NOT NULL AND id<>owner_id ORDER BY id LIMIT 1;
 SELECT id INTO other_worker FROM auth.users a WHERE email_confirmed_at IS NOT NULL AND id NOT IN(owner_id,worker) ORDER BY id LIMIT 1;
 SELECT id INTO plan FROM public.plans WHERE 'payroll'=ANY(included_modules) ORDER BY cardinality(included_modules) DESC NULLS LAST LIMIT 1;
 IF owner_id IS NULL OR worker IS NULL OR other_worker IS NULL OR plan IS NULL THEN RAISE EXCEPTION 'Fixture prerequisites missing';END IF;
 BEGIN
  INSERT INTO public.businesses(id,name) VALUES(bid,'Market employee timesheet fixture');
  INSERT INTO public.profiles(id,business_id,active_business_id,full_name,role,is_super_admin) VALUES(owner_id,bid,bid,'Timesheet owner fixture','owner',false);
  INSERT INTO public.business_memberships(business_id,user_id,role,status) VALUES(bid,owner_id,'owner','active');
  INSERT INTO public.subscriptions(business_id,plan_id,status,current_period_end,trial_ends_at) VALUES(bid,plan,'trialing',now()+interval '30 days',now()+interval '30 days');
  INSERT INTO public.payroll_employees(id,business_id,employee_number,first_name,last_name) VALUES(emp,bid,'TIME-1','Time','Worker');
  INSERT INTO public.payroll_leave_types(id,business_id,name,paid) VALUES(lt,bid,'Annual leave fixture',true);
  INSERT INTO public.payroll_employee_leave(business_id,employee_id,leave_type_id,balance_hours) VALUES(bid,emp,lt,16);
  INSERT INTO public.payroll_leave_transactions(business_id,employee_id,leave_type_id,transaction_date,transaction_type,hours,notes) VALUES(bid,emp,lt,current_date,'adjustment',16,'private fixture note');
  PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated')::text,true);EXECUTE 'SET LOCAL ROLE authenticated';
  r:=public.v6229_set_employee_portal_link(emp,email,true,NULL);link:=(r->>'id')::uuid;rev:=(r->>'revision')::bigint;
  r:=public.v6233_set_employee_timesheet_access(link,true,rev);rev:=(r->>'revision')::bigint;IF r->>'timesheets_enabled'<>'true' THEN RAISE EXCEPTION 'Timesheet enable failed';END IF;EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',worker::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated')::text,true);EXECUTE 'SET LOCAL ROLE authenticated';
  r:=public.v6233_employee_work_read(link,0);IF (r#>>'{balances,0,balance_hours}')::numeric<>16 OR r::text LIKE '%private fixture note%' THEN RAISE EXCEPTION 'Leave projection failed: %',r;END IF;
  r:=public.v6233_employee_timesheet_command(link,ts,op,'save_draft',NULL,jsonb_build_object('work_date',current_date,'start_time','08:00','finish_time','17:00','break_minutes',60,'pay_type','ordinary','notes','Fixture'));IF r->>'status'<>'draft' OR r->>'total_hours'<>'8.00' THEN RAISE EXCEPTION 'Draft save failed: %',r;END IF;
  IF public.v6233_employee_timesheet_command(link,ts,op,'save_draft',NULL,jsonb_build_object('work_date',current_date,'start_time','08:00','finish_time','17:00','break_minutes',60,'pay_type','ordinary','notes','Fixture'))<>r THEN RAISE EXCEPTION 'Idempotent retry changed result';END IF;
  tsrev:=(r->>'revision')::bigint;r:=public.v6233_employee_timesheet_command(link,ts,gen_random_uuid(),'submit',tsrev,jsonb_build_object('work_date',current_date,'start_time','08:00','finish_time','17:00','break_minutes',60,'pay_type','ordinary','notes','Fixture'));IF r->>'status'<>'submitted' THEN RAISE EXCEPTION 'Submit failed';END IF;
  denied:=false;BEGIN PERFORM public.v6233_employee_timesheet_command(link,ts,gen_random_uuid(),'save_draft',(r->>'revision')::bigint,jsonb_build_object('work_date',current_date,'start_time','08:00','finish_time','17:00','break_minutes',60,'pay_type','ordinary','notes','Changed'));EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Submitted timesheet remained editable';END IF;
  IF EXISTS(SELECT 1 FROM public.payroll_timesheets WHERE id=ts) THEN RAISE EXCEPTION 'Raw employee timesheet row visible';END IF;EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',other_worker::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',other_worker,'role','authenticated')::text,true);EXECUTE 'SET LOCAL ROLE authenticated';denied:=false;BEGIN PERFORM public.v6233_employee_work_read(link,0);EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Other account read employee work';END IF;EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated')::text,true);EXECUTE 'SET LOCAL ROLE authenticated';UPDATE public.payroll_timesheets SET status='approved',approved_at=now(),approved_by=owner_id WHERE id=ts;r:=public.v6229_set_employee_portal_link(emp,email,false,rev);EXECUTE 'RESET ROLE';
  IF (SELECT timesheets_enabled FROM public.payroll_employee_portal_links WHERE id=link) THEN RAISE EXCEPTION 'Revocation retained timesheet access';END IF;
  IF has_function_privilege('anon','public.v6233_employee_work_read(uuid,integer)','EXECUTE') OR has_function_privilege('anon','public.v6233_employee_timesheet_command(uuid,uuid,uuid,text,bigint,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Anon employee work APIs open';END IF;
  RAISE EXCEPTION USING ERRCODE='P6233',MESSAGE='Rollback employee timesheet fixture';
 EXCEPTION WHEN SQLSTATE 'P6233' THEN NULL;END;
 IF EXISTS(SELECT 1 FROM public.businesses WHERE id=bid) OR EXISTS(SELECT 1 FROM public.payroll_timesheets WHERE id=ts) THEN RAISE EXCEPTION 'Employee timesheet fixture leaked';END IF;
 RAISE NOTICE 'Employee timesheet fixture passed; all data rolled back';
END;$test$;
