DO $test$
DECLARE u uuid;bid uuid:=gen_random_uuid();emp uuid:=gen_random_uuid();lt uuid:=gen_random_uuid();plan uuid;tx uuid:=gen_random_uuid();calc uuid:=gen_random_uuid();locked_tx uuid:=gen_random_uuid();locked_calc uuid:=gen_random_uuid();run uuid:=gen_random_uuid();op uuid:=gen_random_uuid();rev timestamptz;r jsonb;denied boolean;
BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;
 SELECT id INTO u FROM auth.users a WHERE NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=a.id) ORDER BY id LIMIT 1;
 SELECT id INTO plan FROM public.plans WHERE 'payroll'=ANY(included_modules) ORDER BY cardinality(included_modules) DESC NULLS LAST LIMIT 1;
 IF u IS NULL OR plan IS NULL THEN RAISE EXCEPTION 'Fixture prerequisites missing';END IF;
 BEGIN
  INSERT INTO public.businesses(id,name) VALUES(bid,'Market statutory correction fixture');
  INSERT INTO public.profiles(id,business_id,active_business_id,full_name,role,is_super_admin) VALUES(u,bid,bid,'Statutory correction fixture','owner',false);
  INSERT INTO public.business_memberships(business_id,user_id,role,status) VALUES(bid,u,'owner','active');
  INSERT INTO public.subscriptions(business_id,plan_id,status,current_period_end,trial_ends_at) VALUES(bid,plan,'trialing',now()+interval '30 days',now()+interval '30 days');
  INSERT INTO public.payroll_settings(business_id,country_code) VALUES(bid,'NZ');
  INSERT INTO public.payroll_employees(id,business_id,employee_number,first_name,last_name,start_date) VALUES(emp,bid,'SC-1','Correction','Fixture','2020-01-01');
  INSERT INTO public.payroll_leave_types(id,business_id,name,paid,statutory_leave_code) VALUES(lt,bid,'Sick leave fixture',true,'sick_leave');
  INSERT INTO public.payroll_statutory_leave_entitlements(business_id,employee_id,statutory_leave_code,period_start,period_end,grant_days,carry_forward_days,used_days,rule_version,rules_snapshot,updated_by) VALUES(bid,emp,'sick_leave','2026-01-01','2026-12-31',10,0,2,'fixture','{}',u);
  INSERT INTO public.payroll_leave_transactions(id,business_id,employee_id,leave_type_id,transaction_date,transaction_type,hours,statutory_quantity,statutory_unit,display_hours,statutory_leave_code,created_by) VALUES(tx,bid,emp,lt,'2026-10-01','taken',8,1,'days',8,'sick_leave',u);
  INSERT INTO public.payroll_statutory_leave_calculations(id,business_id,employee_id,leave_type_id,leave_transaction_id,statutory_leave_code,calculation_type,relevant_from,relevant_to,rule_version,rules_snapshot,input_snapshot,owd_evidence_snapshot,rdp_amount,selected_method,selected_amount,confirmation_state,explanation_snapshot,created_by,updated_by) VALUES(calc,bid,emp,lt,tx,'sick_leave','sick_leave','2026-10-01','2026-10-01','fixture','{}','{"statutory_quantity":1}','{}',200,'rdp',200,'confirmed','{}',u,u) RETURNING updated_at INTO rev;
  INSERT INTO public.payroll_pay_runs(id,business_id,pay_run_number,pay_frequency,period_start,period_end,pay_date,status,created_by,updated_by) VALUES(run,bid,'SC-RUN','weekly','2026-10-05','2026-10-11','2026-10-12','draft',u,u);
  INSERT INTO public.payroll_leave_transactions(id,business_id,employee_id,leave_type_id,transaction_date,transaction_type,hours,statutory_quantity,statutory_unit,display_hours,statutory_leave_code,created_by) VALUES(locked_tx,bid,emp,lt,'2026-10-06','taken',8,1,'days',8,'sick_leave',u);
  INSERT INTO public.payroll_statutory_leave_calculations(id,business_id,employee_id,leave_type_id,leave_transaction_id,pay_run_id,statutory_leave_code,calculation_type,relevant_from,relevant_to,rule_version,rules_snapshot,input_snapshot,owd_evidence_snapshot,rdp_amount,selected_method,selected_amount,confirmation_state,explanation_snapshot,created_by,updated_by) VALUES(locked_calc,bid,emp,lt,locked_tx,run,'sick_leave','sick_leave','2026-10-06','2026-10-06','fixture','{}','{"statutory_quantity":1}','{}',200,'rdp',200,'confirmed','{}',u,u);
  PERFORM set_config('request.jwt.claim.sub',u::text,true);PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);EXECUTE 'SET LOCAL ROLE authenticated';
  r:=public.v6235_correct_statutory_leave(calc,rev,'Recorded against the wrong day',op);
  IF r->'calculation'->>'confirmation_state'<>'needs_confirmation' OR r->'calculation'->>'correction_reason'<>'Recorded against the wrong day' OR (r->'entitlement'->>'used_days')::numeric<>1 OR (r->'correction_transaction'->>'hours')::numeric<>-8 THEN RAISE EXCEPTION 'Correction result wrong';END IF;
  IF public.v6235_correct_statutory_leave(calc,rev,'Recorded against the wrong day',op)<>r THEN RAISE EXCEPTION 'Correction replay failed';END IF;
  EXECUTE 'RESET ROLE';IF (SELECT count(*) FROM public.payroll_statutory_leave_correction_operations WHERE id=op)<>1 THEN RAISE EXCEPTION 'Correction replay duplicated its operation evidence';END IF;EXECUTE 'SET LOCAL ROLE authenticated';
  denied:=false;BEGIN PERFORM public.v6235_correct_statutory_leave(calc,rev,'Another reason',op);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Changed retry accepted';END IF;
  denied:=false;BEGIN PERFORM public.v6235_correct_statutory_leave(locked_calc,(SELECT updated_at FROM public.payroll_statutory_leave_calculations WHERE id=locked_calc),'Should be blocked',gen_random_uuid());EXCEPTION WHEN object_not_in_prerequisite_state THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Pay-run leave correction accepted';END IF;
  denied:=false;BEGIN UPDATE public.payroll_statutory_leave_calculations SET corrected_at=now() WHERE id=locked_calc;EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Direct confirmed calculation correction accepted';END IF;
  EXECUTE 'RESET ROLE';INSERT INTO public.business_member_access_overrides(business_id,membership_id,area,can_read,can_write) SELECT bid,id,'payroll',true,false FROM public.business_memberships WHERE business_id=bid AND user_id=u;EXECUTE 'SET LOCAL ROLE authenticated';
  denied:=false;BEGIN PERFORM public.v6235_correct_statutory_leave(locked_calc,(SELECT updated_at FROM public.payroll_statutory_leave_calculations WHERE id=locked_calc),'Read only',gen_random_uuid());EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Read-only correction accepted';END IF;
  EXECUTE 'RESET ROLE';
  IF has_function_privilege('anon','public.v6235_correct_statutory_leave(uuid,timestamp with time zone,text,uuid)','EXECUTE') OR has_table_privilege('authenticated','public.payroll_statutory_leave_correction_operations','SELECT') THEN RAISE EXCEPTION 'Unsafe correction grants';END IF;
  RAISE EXCEPTION USING ERRCODE='P6235',MESSAGE='Rollback statutory correction fixture';
 EXCEPTION WHEN SQLSTATE 'P6235' THEN NULL;END;
 IF EXISTS(SELECT 1 FROM public.businesses WHERE id=bid) OR EXISTS(SELECT 1 FROM public.payroll_statutory_leave_correction_operations WHERE id=op) THEN RAISE EXCEPTION 'Correction fixture leaked';END IF;
 RAISE NOTICE 'Statutory correction fixture passed; all data rolled back';
END;$test$;
