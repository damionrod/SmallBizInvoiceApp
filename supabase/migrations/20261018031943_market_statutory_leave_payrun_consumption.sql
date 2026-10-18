-- Market only: link confirmed statutory leave to one pay run at a time.
DO $$ BEGIN IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;END $$;
ALTER TABLE public.payroll_pay_run_lines ADD COLUMN statutory_calculation_id uuid NULL REFERENCES public.payroll_statutory_leave_calculations(id) ON DELETE RESTRICT;
CREATE INDEX payroll_pay_run_lines_statutory_calculation ON public.payroll_pay_run_lines(statutory_calculation_id) WHERE statutory_calculation_id IS NOT NULL;
CREATE TABLE public.payroll_statutory_leave_consumption_events(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,calculation_id uuid NOT NULL REFERENCES public.payroll_statutory_leave_calculations(id) ON DELETE RESTRICT,pay_run_id uuid NOT NULL REFERENCES public.payroll_pay_runs(id) ON DELETE CASCADE,action text NOT NULL CHECK(action IN ('reserved','released')),reason text NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL,UNIQUE(calculation_id,pay_run_id,action));
ALTER TABLE public.payroll_statutory_leave_consumption_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_statutory_leave_consumption_events FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.v6232_guard_statutory_pay_line() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$ BEGIN IF NEW.statutory_calculation_id IS NOT NULL AND current_setting('frindly.stat_leave_link',true) IS DISTINCT FROM 'allowed' THEN RAISE EXCEPTION 'Statutory leave pay lines must be saved through the atomic pay-run workflow.' USING ERRCODE='42501';END IF;RETURN NEW;END $$;
REVOKE ALL ON FUNCTION public.v6232_guard_statutory_pay_line() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER v6232_statutory_pay_line BEFORE INSERT OR UPDATE ON public.payroll_pay_run_lines FOR EACH ROW EXECUTE FUNCTION public.v6232_guard_statutory_pay_line();
CREATE OR REPLACE FUNCTION public.v6226_save_pay_run(p_request uuid,p_run_id uuid,p_expected_updated_at timestamptz,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid:=public.current_business_id();actor uuid:=auth.uid();run public.payroll_pay_runs%ROWTYPE;prior public.payroll_run_operations%ROWTYPE;hash text;body jsonb:=p_payload->'run';bundle jsonb;line jsonb;tx jsonb;pre uuid;employee uuid;finished boolean;requires_review boolean;result jsonb;old_data jsonb;field text;statcalc public.payroll_statutory_leave_calculations%ROWTYPE;stat_id uuid;stat_qty numeric;stat_amount numeric;
BEGIN
 IF actor IS NULL OR bid IS NULL OR NOT coalesce(public.v6147_can_write_area(bid,'payroll'),false) THEN RAISE EXCEPTION 'Payroll write access is required.' USING ERRCODE='42501';END IF;
 IF p_request IS NULL OR jsonb_typeof(body) IS DISTINCT FROM 'object' OR jsonb_typeof(p_payload->'employees') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'employees') NOT BETWEEN 1 AND 500 OR jsonb_typeof(p_payload->'financial') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload->'finalise') IS DISTINCT FROM 'boolean' OR octet_length(p_payload::text)>16777216 THEN RAISE EXCEPTION 'Invalid pay-run save request.' USING ERRCODE='22023';END IF;
 FOREACH field IN ARRAY ARRAY['gross_pay','total_deductions','net_pay','employer_contributions','total_employment_cost'] LOOP
  IF jsonb_typeof(body->field) IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'Pay-run amounts must be finite numbers.' USING ERRCODE='22023';END IF;
 END LOOP;
 IF NOT isfinite((body->>'period_start')::date) OR NOT isfinite((body->>'period_end')::date) OR NOT isfinite((body->>'pay_date')::date) OR (body->>'period_start')::date>(body->>'period_end')::date THEN RAISE EXCEPTION 'Invalid pay-run dates.' USING ERRCODE='22023';END IF;
 finished:=(p_payload->>'finalise')::boolean;
 hash:=encode(sha256(convert_to(jsonb_build_object('run_id',p_run_id,'expected',p_expected_updated_at,'payload',p_payload)::text,'UTF8')),'hex');
 -- Idempotency locks are scoped to this one save, not the whole business.
 PERFORM pg_advisory_xact_lock(hashtextextended('payroll-save:'||p_request::text,0));
 SELECT * INTO prior FROM public.payroll_run_operations WHERE id=p_request;
 IF FOUND THEN
  IF prior.business_id<>bid OR prior.actor_id<>actor OR prior.request_hash<>hash THEN RAISE EXCEPTION 'This save identifier belongs to a different request.' USING ERRCODE='22023';END IF;
  RETURN prior.result;
 END IF;
 IF (SELECT count(DISTINCT e->'employee'->>'employee_id') FROM jsonb_array_elements(p_payload->'employees')e)<>jsonb_array_length(p_payload->'employees') THEN RAISE EXCEPTION 'Each employee must appear once in this pay run.' USING ERRCODE='22023';END IF;
 IF p_run_id IS NOT NULL THEN
  SELECT * INTO run FROM public.payroll_pay_runs WHERE id=p_run_id AND business_id=bid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pay run not found in this business.' USING ERRCODE='42501';END IF;
  IF run.status IN ('finalised','reversed') THEN RAISE EXCEPTION 'Finalised or reversed pay runs cannot be edited.' USING ERRCODE='55000';END IF;
  IF p_expected_updated_at IS NULL OR run.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'This pay run changed. Reopen the latest saved version.' USING ERRCODE='40001';END IF;
  old_data:=to_jsonb(run);
 ELSE
  IF p_expected_updated_at IS NOT NULL THEN RAISE EXCEPTION 'A new pay run cannot have an existing revision.' USING ERRCODE='22023';END IF;
 END IF;
 IF NOT coalesce(public.v6147_can_write_area(bid,'payroll'),false) THEN RAISE EXCEPTION 'Payroll access changed.' USING ERRCODE='42501';END IF;
 IF finished THEN
  IF NOT coalesce(public.frindly_payroll_period_ready(bid,(body->>'pay_date')::date),false) THEN RAISE EXCEPTION 'An open accounting period must cover the pay date.' USING ERRCODE='22023';END IF;
 END IF;
 IF p_run_id IS NULL THEN
 INSERT INTO public.payroll_pay_runs(business_id,status,created_by,updated_by,updated_at,pay_run_number,pay_frequency,period_start,period_end,pay_date,country_code,currency,rules_snapshot,gross_pay,total_deductions,net_pay,employer_contributions,total_employment_cost) SELECT bid,'calculated',actor,actor,clock_timestamp(),x.pay_run_number,x.pay_frequency,x.period_start,x.period_end,x.pay_date,x.country_code,x.currency,x.rules_snapshot,x.gross_pay,x.total_deductions,x.net_pay,x.employer_contributions,x.total_employment_cost FROM jsonb_populate_record(NULL::public.payroll_pay_runs,body)x RETURNING * INTO run;
 ELSE
 UPDATE public.payroll_pay_runs r SET pay_run_number=x.pay_run_number,pay_frequency=x.pay_frequency,period_start=x.period_start,period_end=x.period_end,pay_date=x.pay_date,country_code=x.country_code,currency=x.currency,rules_snapshot=x.rules_snapshot,gross_pay=x.gross_pay,total_deductions=x.total_deductions,net_pay=x.net_pay,employer_contributions=x.employer_contributions,total_employment_cost=x.total_employment_cost,status='calculated',finalised_at=NULL,finalised_by=NULL,updated_by=actor,updated_at=clock_timestamp() FROM jsonb_populate_record(NULL::public.payroll_pay_runs,body)x WHERE r.id=p_run_id RETURNING r.* INTO run;
 END IF;
 DELETE FROM public.payroll_run_reviews WHERE pay_run_id=run.id;
 DELETE FROM public.payroll_payslips WHERE pay_run_id=run.id;
 DELETE FROM public.payroll_financial_transactions WHERE pay_run_id=run.id;
 DELETE FROM public.payroll_pay_run_employees WHERE pay_run_id=run.id;
 FOR bundle IN SELECT * FROM jsonb_array_elements(p_payload->'employees') LOOP
  employee:=(bundle->'employee'->>'employee_id')::uuid;
  PERFORM 1 FROM public.payroll_employees WHERE id=employee AND business_id=bid AND NOT archived;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee is unavailable in this business.' USING ERRCODE='42501';END IF;
  IF jsonb_typeof(bundle->'lines') IS DISTINCT FROM 'array' OR jsonb_typeof(bundle->'employee'->'calculation_snapshot') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Employee payroll evidence is incomplete.' USING ERRCODE='22023';END IF;
 FOREACH field IN ARRAY ARRAY['hours','rate','ordinary_earnings','holiday_pay','allowances','reimbursements','gross_pay','paye','kiwisaver_employee','student_loan','other_deductions','total_deductions','net_pay','kiwisaver_employer_gross','esct','employer_contributions','total_employment_cost'] LOOP
  IF jsonb_typeof(bundle->'employee'->field) IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'Employee pay amounts must be finite numbers.' USING ERRCODE='22023';END IF;
 END LOOP;
 INSERT INTO public.payroll_pay_run_employees(business_id,pay_run_id,employee_id,employee_snapshot,hours,rate,ordinary_earnings,holiday_pay,allowances,reimbursements,gross_pay,paye,kiwisaver_employee,student_loan,other_deductions,total_deductions,net_pay,kiwisaver_employer_gross,esct,employer_contributions,total_employment_cost,calculation_snapshot) SELECT bid,run.id,x.employee_id,x.employee_snapshot,x.hours,x.rate,x.ordinary_earnings,x.holiday_pay,x.allowances,x.reimbursements,x.gross_pay,x.paye,x.kiwisaver_employee,x.student_loan,x.other_deductions,x.total_deductions,x.net_pay,x.kiwisaver_employer_gross,x.esct,x.employer_contributions,x.total_employment_cost,x.calculation_snapshot FROM jsonb_populate_record(NULL::public.payroll_pay_run_employees,bundle->'employee')x RETURNING id INTO pre;
 FOR line IN SELECT * FROM jsonb_array_elements(bundle->'lines') LOOP
 FOREACH field IN ARRAY ARRAY['quantity','rate','amount'] LOOP
  IF jsonb_typeof(line->field) IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'Pay-line quantities and amounts must be finite numbers.' USING ERRCODE='22023';END IF;
 END LOOP;
 IF line->>'timesheet_id' IS NOT NULL THEN
  PERFORM 1 FROM public.payroll_timesheets WHERE id=(line->>'timesheet_id')::uuid AND business_id=bid AND employee_id=employee AND status='approved' AND work_date BETWEEN run.period_start AND run.period_end FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'A linked timesheet is not approved for this employee and pay period. Recalculate the pay run.' USING ERRCODE='22023';END IF;
 END IF;
 IF nullif(line->>'statutory_calculation_id','') IS NOT NULL THEN
  BEGIN stat_id:=(line->>'statutory_calculation_id')::uuid;EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'Invalid statutory leave reference.' USING ERRCODE='22023';END;
  SELECT * INTO statcalc FROM public.payroll_statutory_leave_calculations WHERE id=stat_id FOR UPDATE;
  stat_qty:=coalesce((SELECT statutory_quantity FROM public.payroll_leave_transactions WHERE id=statcalc.leave_transaction_id AND business_id=bid AND employee_id=employee),(statcalc.input_snapshot->>'statutory_quantity')::numeric);
  stat_amount:=round(statcalc.selected_amount*stat_qty,2);
  IF statcalc.id IS NULL OR statcalc.business_id<>bid OR statcalc.employee_id<>employee OR statcalc.confirmation_state<>'confirmed' OR statcalc.statutory_leave_code NOT IN ('sick_leave','bereavement_leave','family_violence_leave') OR statcalc.relevant_from NOT BETWEEN run.period_start AND run.period_end OR (statcalc.pay_run_id IS NOT NULL AND statcalc.pay_run_id<>run.id) OR stat_qty IS NULL OR stat_qty<=0 OR statcalc.selected_amount IS NULL OR line->>'line_type'<>'earning' OR (line->>'quantity')::numeric<>stat_qty OR (line->>'rate')::numeric<>statcalc.selected_amount OR (line->>'amount')::numeric<>stat_amount OR coalesce((line->>'taxable')::boolean,true) IS NOT TRUE OR nullif(line->>'timesheet_id','') IS NOT NULL THEN RAISE EXCEPTION 'Confirmed statutory leave changed, was already used, or does not match this pay line. Recalculate the pay run.' USING ERRCODE='40001';END IF;
  PERFORM set_config('frindly.stat_leave_link','allowed',true);
  IF statcalc.pay_run_id IS DISTINCT FROM run.id THEN
   UPDATE public.payroll_statutory_leave_calculations SET pay_run_id=run.id,updated_at=clock_timestamp(),updated_by=actor WHERE id=statcalc.id;
   INSERT INTO public.payroll_statutory_leave_consumption_events(business_id,calculation_id,pay_run_id,action,reason,created_by) VALUES(bid,statcalc.id,run.id,'reserved','Saved with pay run '||run.pay_run_number,actor) ON CONFLICT(calculation_id,pay_run_id,action) DO NOTHING;
  END IF;
 END IF;
 INSERT INTO public.payroll_pay_run_lines(business_id,pay_run_employee_id,pay_item_id,timesheet_id,statutory_calculation_id,line_type,description,quantity,rate,amount,job_costing_id,expense_category_id,taxable) SELECT bid,pre,x.pay_item_id,x.timesheet_id,x.statutory_calculation_id,x.line_type,x.description,x.quantity,x.rate,x.amount,x.job_costing_id,x.expense_category_id,x.taxable FROM jsonb_populate_record(NULL::public.payroll_pay_run_lines,line)x;
 END LOOP;
 IF finished THEN
   IF jsonb_typeof(bundle->'payslip') IS DISTINCT FROM 'object' OR jsonb_typeof(bundle->'payslip'->'data') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Every employee needs a payslip before finalising.' USING ERRCODE='22023';END IF;
   INSERT INTO public.payroll_payslips(business_id,pay_run_id,pay_run_employee_id,employee_id,payslip_number,payslip_data)
    VALUES(bid,run.id,pre,employee,bundle->'payslip'->>'number',bundle->'payslip'->'data');
  END IF;
 END LOOP;
 -- Editing a non-finalised run releases only statutory records removed from its replacement bundle.
 WITH released AS (
  UPDATE public.payroll_statutory_leave_calculations c SET pay_run_id=NULL,updated_at=clock_timestamp(),updated_by=actor
  WHERE c.business_id=bid AND c.pay_run_id=run.id AND NOT EXISTS(SELECT 1 FROM public.payroll_pay_run_lines l JOIN public.payroll_pay_run_employees e ON e.id=l.pay_run_employee_id WHERE e.pay_run_id=run.id AND l.statutory_calculation_id=c.id) RETURNING c.id
 ) INSERT INTO public.payroll_statutory_leave_consumption_events(business_id,calculation_id,pay_run_id,action,reason,created_by) SELECT bid,id,run.id,'released','Removed while editing pay run '||run.pay_run_number,actor FROM released ON CONFLICT(calculation_id,pay_run_id,action) DO NOTHING;
 IF finished THEN
  IF jsonb_array_length(p_payload->'financial')=0 THEN RAISE EXCEPTION 'Payroll financial entries are missing.' USING ERRCODE='22023';END IF;
  IF (SELECT count(DISTINCT value->>'type') FROM jsonb_array_elements(p_payload->'financial'))<>jsonb_array_length(p_payload->'financial') THEN RAISE EXCEPTION 'Duplicate payroll financial entry types.' USING ERRCODE='22023';END IF;
  FOR tx IN SELECT * FROM jsonb_array_elements(p_payload->'financial') LOOP
   IF jsonb_typeof(tx->'amount') IS DISTINCT FROM 'number' OR coalesce(tx->>'type','') NOT IN ('wage_expense','employer_contribution_expense','reimbursement_expense','paye_payable','kiwisaver_payable','net_wages_payable','total_employment_cost') THEN RAISE EXCEPTION 'Invalid payroll financial entry.' USING ERRCODE='22023';END IF;
   INSERT INTO public.payroll_financial_transactions(business_id,pay_run_id,transaction_type,amount,currency,reference) VALUES(bid,run.id,tx->>'type',(tx->>'amount')::numeric,run.currency,run.pay_run_number);
  END LOOP;
  INSERT INTO public.payroll_review_settings(business_id) VALUES(bid) ON CONFLICT DO NOTHING;
  SELECT enabled INTO requires_review FROM public.payroll_review_settings WHERE business_id=bid FOR SHARE;
  IF requires_review THEN
   INSERT INTO public.payroll_run_reviews(pay_run_id,business_id,requested_by,source_hash,status) VALUES(run.id,bid,actor,public.v6226_payroll_fingerprint(run.id),'pending');
   INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by) VALUES(bid,'pay_run',run.id,'approval_requested',jsonb_build_object('source_hash',public.v6226_payroll_fingerprint(run.id)),actor);
  ELSE
   UPDATE public.payroll_pay_runs SET status='finalised',finalised_at=clock_timestamp(),finalised_by=actor,updated_at=clock_timestamp(),updated_by=actor WHERE id=run.id RETURNING * INTO run;
  END IF;
 END IF;
 SELECT * INTO run FROM public.payroll_pay_runs WHERE id=run.id;
 result:=jsonb_build_object('run',to_jsonb(run),'needs_approval',coalesce(requires_review,false));
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(bid,'pay_run',run.id,CASE WHEN run.status='finalised' THEN 'finalised' ELSE 'calculated' END,old_data,to_jsonb(run),actor);
 INSERT INTO public.payroll_run_operations(id,business_id,actor_id,request_hash,result) VALUES(p_request,bid,actor,hash,result);
 RETURN result;
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_save_pay_run(uuid,uuid,timestamptz,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6226_save_pay_run(uuid,uuid,timestamptz,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.v61105_phase13b_reverse_pay_run(p_pay_run_id uuid,p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
DECLARE v_bid uuid;v_run public.payroll_pay_runs%ROWTYPE;v_journal uuid;v_reversal uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 IF coalesce(btrim(p_reason),'')='' THEN RAISE EXCEPTION 'A reversal reason is required';END IF;
 v_bid:=public.current_business_id();IF v_bid IS NULL THEN RAISE EXCEPTION 'No active authorised business';END IF;
 IF NOT public.v6147_can_write_area(v_bid,'payroll') THEN RAISE EXCEPTION 'Payroll write access denied';END IF;
 SELECT * INTO v_run FROM public.payroll_pay_runs WHERE id=p_pay_run_id AND business_id=v_bid FOR UPDATE;
 IF v_run.id IS NULL THEN RAISE EXCEPTION 'Pay run not found in active business';END IF;
 IF v_run.status='reversed' THEN SELECT reversed_by_journal_id INTO v_reversal FROM public.accounting_journals WHERE business_id=v_bid AND source_type='payroll' AND source_id=p_pay_run_id AND posting_version=1 LIMIT 1;IF v_reversal IS NULL THEN RAISE EXCEPTION 'Reversed payroll is missing its reversal journal';END IF;RETURN v_reversal;END IF;
 IF v_run.status<>'finalised' THEN RAISE EXCEPTION 'Only a finalised pay run can be reversed';END IF;
 SELECT id INTO v_journal FROM public.accounting_journals WHERE business_id=v_bid AND source_type='payroll' AND source_id=p_pay_run_id AND posting_version=1 AND status='posted' LIMIT 1;
 IF v_journal IS NULL THEN RAISE EXCEPTION 'This finalised pay run has no posted accounting journal. It was left unchanged for review.';END IF;
 v_reversal:=public.v6170a_reverse_journal(v_journal,'Payroll '||v_run.pay_run_number||': '||btrim(p_reason));
 PERFORM set_config('frindly.payroll_reversal','allowed',true);
 UPDATE public.payroll_pay_runs SET status='reversed',updated_at=now(),updated_by=auth.uid() WHERE id=p_pay_run_id AND business_id=v_bid AND status='finalised';IF NOT FOUND THEN RAISE EXCEPTION 'Payroll reversal status update failed';END IF;
 WITH released AS (UPDATE public.payroll_statutory_leave_calculations SET pay_run_id=NULL,updated_at=clock_timestamp(),updated_by=auth.uid() WHERE business_id=v_bid AND pay_run_id=p_pay_run_id RETURNING id)
 INSERT INTO public.payroll_statutory_leave_consumption_events(business_id,calculation_id,pay_run_id,action,reason,created_by) SELECT v_bid,id,p_pay_run_id,'released',btrim(p_reason),auth.uid() FROM released ON CONFLICT(calculation_id,pay_run_id,action) DO NOTHING;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,old_data,new_data,created_by) VALUES(v_bid,'pay_run',p_pay_run_id,'reversed',to_jsonb(v_run),jsonb_build_object('status','reversed','reason',btrim(p_reason),'reversal_journal_id',v_reversal),auth.uid());
 RETURN v_reversal;
END $function$;
REVOKE ALL ON FUNCTION public.v61105_phase13b_reverse_pay_run(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v61105_phase13b_reverse_pay_run(uuid,text) TO authenticated;
