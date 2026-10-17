CREATE TABLE public.payroll_review_settings (
 business_id uuid PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
 enabled boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_by uuid
);
CREATE TABLE public.payroll_run_operations (
 id uuid PRIMARY KEY,
 business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
 actor_id uuid NOT NULL,
 request_hash text NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.payroll_run_reviews (
 pay_run_id uuid PRIMARY KEY REFERENCES public.payroll_pay_runs(id) ON DELETE CASCADE,
 business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
 requested_by uuid NOT NULL,
 requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 source_hash text NOT NULL,
 status text NOT NULL CHECK(status IN ('pending','approved')),
 approved_by uuid,
 approved_at timestamptz,
 CHECK((status='pending' AND approved_by IS NULL AND approved_at IS NULL) OR (status='approved' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND approved_by<>requested_by))
);
ALTER TABLE public.payroll_review_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_run_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_run_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_review_settings,public.payroll_run_operations,public.payroll_run_reviews FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.payroll_review_settings,public.payroll_run_reviews TO authenticated;
CREATE POLICY payroll_review_settings_read ON public.payroll_review_settings FOR SELECT TO authenticated USING(business_id=public.current_business_id() AND public.v55_payroll_access(business_id));
CREATE POLICY payroll_run_reviews_read ON public.payroll_run_reviews FOR SELECT TO authenticated USING(business_id=public.current_business_id() AND public.v55_payroll_access(business_id));

CREATE FUNCTION public.v6226_payroll_fingerprint(p_run uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 SELECT encode(sha256(convert_to(jsonb_build_object(
 'run',to_jsonb(r)-ARRAY['status','updated_at','updated_by','finalised_at','finalised_by'],
 'employees',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.id),'[]') FROM public.payroll_pay_run_employees e WHERE e.pay_run_id=r.id),
 'lines',(SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.id),'[]') FROM public.payroll_pay_run_lines l JOIN public.payroll_pay_run_employees e ON e.id=l.pay_run_employee_id WHERE e.pay_run_id=r.id),
 'payslips',(SELECT coalesce(jsonb_agg(to_jsonb(p)-ARRAY['emailed_at','emailed_to'] ORDER BY p.id),'[]') FROM public.payroll_payslips p WHERE p.pay_run_id=r.id),
 'financial',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]') FROM public.payroll_financial_transactions t WHERE t.pay_run_id=r.id)
 )::text,'UTF8')),'hex') FROM public.payroll_pay_runs r WHERE r.id=p_run;
$fn$;
REVOKE ALL ON FUNCTION public.v6226_payroll_fingerprint(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.v6226_set_payroll_review(p_enabled boolean,p_expected_revision bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid:=public.current_business_id();cfg public.payroll_review_settings%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR bid IS NULL OR NOT coalesce(public.v6147_can_write_area(bid,'payroll'),false) OR coalesce(public.v6147_current_business_role(bid),'') NOT IN ('owner','admin') THEN RAISE EXCEPTION 'Only an owner or admin with Payroll access can change this setting.' USING ERRCODE='42501';END IF;
 IF p_enabled IS NULL OR p_expected_revision IS NULL THEN RAISE EXCEPTION 'Reload the approval setting.' USING ERRCODE='22023';END IF;
 INSERT INTO public.payroll_review_settings(business_id) VALUES(bid) ON CONFLICT DO NOTHING;
 SELECT * INTO cfg FROM public.payroll_review_settings WHERE business_id=bid FOR UPDATE;
 IF cfg.revision<>p_expected_revision THEN RAISE EXCEPTION 'The approval setting changed. Reload before saving.' USING ERRCODE='40001';END IF;
 UPDATE public.payroll_review_settings SET enabled=p_enabled,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid() WHERE business_id=bid RETURNING * INTO cfg;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by) VALUES(bid,'payroll_review_setting',bid,'changed',to_jsonb(cfg),auth.uid());
 RETURN to_jsonb(cfg);
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_set_payroll_review(boolean,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6226_set_payroll_review(boolean,bigint) TO authenticated;

CREATE FUNCTION public.v6226_payroll_child_lock() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE old_run uuid;new_run uuid;rid uuid;stage text;before_row jsonb:=CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END;after_row jsonb:=CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END;
BEGIN
 IF TG_TABLE_NAME='payroll_pay_run_lines' THEN
  SELECT pay_run_id INTO old_run FROM public.payroll_pay_run_employees WHERE id=(before_row->>'pay_run_employee_id')::uuid;
  SELECT pay_run_id INTO new_run FROM public.payroll_pay_run_employees WHERE id=(after_row->>'pay_run_employee_id')::uuid;
 ELSE old_run:=(before_row->>'pay_run_id')::uuid;new_run:=(after_row->>'pay_run_id')::uuid;END IF;
 FOR rid IN SELECT DISTINCT x FROM unnest(ARRAY[old_run,new_run])x WHERE x IS NOT NULL ORDER BY x LOOP
  SELECT status INTO stage FROM public.payroll_pay_runs WHERE id=rid FOR UPDATE;
  IF stage IN ('finalised','reversed') THEN
   IF TG_TABLE_NAME='payroll_payslips' AND TG_OP='UPDATE' AND (before_row-ARRAY['emailed_at','emailed_to']) IS NOT DISTINCT FROM (after_row-ARRAY['emailed_at','emailed_to']) THEN CONTINUE;END IF;
   RAISE EXCEPTION 'Finalised or reversed payroll detail is locked.' USING ERRCODE='55000';
  END IF;
  -- Direct old-browser edits also change the revision used by the new save API.
  UPDATE public.payroll_pay_runs SET updated_at=clock_timestamp() WHERE id=rid AND status NOT IN ('finalised','reversed');
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_payroll_child_lock() FROM PUBLIC,anon,authenticated;
DO $triggers$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['payroll_pay_run_employees','payroll_pay_run_lines','payroll_payslips','payroll_financial_transactions'] LOOP
  EXECUTE format('CREATE TRIGGER v6226_parent_lock BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.v6226_payroll_child_lock()',t);
 END LOOP;
END;$triggers$;

CREATE FUNCTION public.v6226_payroll_finalisation_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE required boolean;review public.payroll_run_reviews%ROWTYPE;
BEGIN
 IF TG_OP='INSERT' AND NEW.status IN ('finalised','reversed') THEN RAISE EXCEPTION 'Save and review a calculated pay run before finalising.' USING ERRCODE='42501';END IF;
 IF TG_OP='UPDATE' AND NEW.status='finalised' AND OLD.status IS DISTINCT FROM 'finalised' THEN
  -- All finalisers, including cached clients, participate in this duplicate-pay lock.
  PERFORM pg_advisory_xact_lock(hashtextextended('payroll-finalise:'||NEW.business_id::text,0));
  INSERT INTO public.payroll_review_settings(business_id) VALUES(NEW.business_id) ON CONFLICT DO NOTHING;
  SELECT enabled INTO required FROM public.payroll_review_settings WHERE business_id=NEW.business_id FOR SHARE;
  IF coalesce(required,false) THEN
   SELECT * INTO review FROM public.payroll_run_reviews WHERE pay_run_id=NEW.id AND business_id=NEW.business_id;
   IF NOT FOUND OR review.status<>'approved' OR review.approved_by=review.requested_by OR review.source_hash IS DISTINCT FROM public.v6226_payroll_fingerprint(NEW.id) THEN RAISE EXCEPTION 'This pay run needs approval of its current saved figures before finalising.' USING ERRCODE='42501';END IF;
  END IF;
 END IF;
 RETURN NEW;
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_payroll_finalisation_guard() FROM PUBLIC,anon,authenticated;
-- Run before the pre-existing duplicate check, so concurrent finalisations serialize.
CREATE TRIGGER a6226_finalisation_review BEFORE INSERT OR UPDATE ON public.payroll_pay_runs FOR EACH ROW EXECUTE FUNCTION public.v6226_payroll_finalisation_guard();

CREATE FUNCTION public.v6226_save_pay_run(p_request uuid,p_run_id uuid,p_expected_updated_at timestamptz,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid:=public.current_business_id();actor uuid:=auth.uid();run public.payroll_pay_runs%ROWTYPE;prior public.payroll_run_operations%ROWTYPE;hash text;body jsonb:=p_payload->'run';bundle jsonb;line jsonb;tx jsonb;pre uuid;employee uuid;finished boolean;requires_review boolean;result jsonb;old_data jsonb;field text;
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
 INSERT INTO public.payroll_pay_run_lines(business_id,pay_run_employee_id,pay_item_id,timesheet_id,line_type,description,quantity,rate,amount,job_costing_id,expense_category_id,taxable) SELECT bid,pre,x.pay_item_id,x.timesheet_id,x.line_type,x.description,x.quantity,x.rate,x.amount,x.job_costing_id,x.expense_category_id,x.taxable FROM jsonb_populate_record(NULL::public.payroll_pay_run_lines,line)x;
 END LOOP;
 IF finished THEN
   IF jsonb_typeof(bundle->'payslip') IS DISTINCT FROM 'object' OR jsonb_typeof(bundle->'payslip'->'data') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Every employee needs a payslip before finalising.' USING ERRCODE='22023';END IF;
   INSERT INTO public.payroll_payslips(business_id,pay_run_id,pay_run_employee_id,employee_id,payslip_number,payslip_data)
    VALUES(bid,run.id,pre,employee,bundle->'payslip'->>'number',bundle->'payslip'->'data');
  END IF;
 END LOOP;
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

CREATE FUNCTION public.v6226_approve_pay_run(p_run uuid,p_expected_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid:=public.current_business_id();actor uuid:=auth.uid();run public.payroll_pay_runs%ROWTYPE;review public.payroll_run_reviews%ROWTYPE;
BEGIN
 IF actor IS NULL OR bid IS NULL OR NOT coalesce(public.v6147_can_write_area(bid,'payroll'),false) THEN RAISE EXCEPTION 'Payroll write access is required.' USING ERRCODE='42501';END IF;
 SELECT * INTO run FROM public.payroll_pay_runs WHERE id=p_run AND business_id=bid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Pay run not found.' USING ERRCODE='42501';END IF;
 SELECT * INTO review FROM public.payroll_run_reviews WHERE pay_run_id=p_run AND business_id=bid FOR UPDATE;
 IF NOT FOUND OR p_expected_hash IS NULL OR review.source_hash IS DISTINCT FROM p_expected_hash OR public.v6226_payroll_fingerprint(p_run) IS DISTINCT FROM p_expected_hash THEN RAISE EXCEPTION 'The saved figures changed. Request a fresh review.' USING ERRCODE='40001';END IF;
 IF review.requested_by=actor THEN RAISE EXCEPTION 'Another Payroll user must review this pay run.' USING ERRCODE='42501';END IF;
 IF run.status='finalised' AND review.status='approved' THEN RETURN to_jsonb(run);END IF;
 IF run.status<>'calculated' OR review.status<>'pending' THEN RAISE EXCEPTION 'This pay run is not waiting for approval.' USING ERRCODE='55000';END IF;
 IF NOT coalesce(public.frindly_payroll_period_ready(bid,run.pay_date),false) OR NOT coalesce(public.v6147_can_write_area(bid,'payroll'),false) THEN RAISE EXCEPTION 'Payroll access or accounting-period readiness changed.' USING ERRCODE='42501';END IF;
 UPDATE public.payroll_run_reviews SET status='approved',approved_by=actor,approved_at=clock_timestamp() WHERE pay_run_id=p_run;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by) VALUES(bid,'pay_run',p_run,'approved',jsonb_build_object('source_hash',p_expected_hash,'requested_by',review.requested_by),actor);
 UPDATE public.payroll_pay_runs SET status='finalised',finalised_at=clock_timestamp(),finalised_by=actor,updated_at=clock_timestamp(),updated_by=actor WHERE id=p_run RETURNING * INTO run;
 RETURN to_jsonb(run);
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_approve_pay_run(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6226_approve_pay_run(uuid,text) TO authenticated;

CREATE FUNCTION public.v6226_get_payroll_review(p_run uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid:=public.current_business_id();r public.payroll_pay_runs%ROWTYPE;review public.payroll_run_reviews%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR bid IS NULL OR NOT coalesce(public.v55_payroll_access(bid),false) THEN RAISE EXCEPTION 'Payroll access is required.' USING ERRCODE='42501';END IF;
 SELECT * INTO r FROM public.payroll_pay_runs WHERE id=p_run AND business_id=bid FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Pay run not found.' USING ERRCODE='42501';END IF;
 SELECT * INTO review FROM public.payroll_run_reviews WHERE pay_run_id=p_run AND business_id=bid;
 IF NOT FOUND THEN RAISE EXCEPTION 'This pay run has not been submitted for approval.' USING ERRCODE='55000';END IF;
 RETURN jsonb_build_object('can_approve',coalesce(public.v6147_can_write_area(bid,'payroll'),false),'run',to_jsonb(r),'review',to_jsonb(review),'current',review.source_hash=public.v6226_payroll_fingerprint(p_run),
 'employees',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.employee_snapshot->>'name'),'[]') FROM public.payroll_pay_run_employees e WHERE e.pay_run_id=p_run),
 'lines',(SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.id),'[]') FROM public.payroll_pay_run_lines l JOIN public.payroll_pay_run_employees e ON e.id=l.pay_run_employee_id WHERE e.pay_run_id=p_run));
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_get_payroll_review(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6226_get_payroll_review(uuid) TO authenticated;

CREATE FUNCTION public.v6226_payroll_review_state() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid:=public.current_business_id();cfg public.payroll_review_settings%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR bid IS NULL OR NOT coalesce(public.v55_payroll_access(bid),false) THEN RAISE EXCEPTION 'Payroll access is required.' USING ERRCODE='42501';END IF;
 SELECT * INTO cfg FROM public.payroll_review_settings WHERE business_id=bid;
 RETURN jsonb_build_object('enabled',coalesce(cfg.enabled,false),'revision',coalesce(cfg.revision,0),'can_manage',coalesce(public.v6147_current_business_role(bid) IN ('owner','admin') AND public.v6147_can_write_area(bid,'payroll'),false),
 'reviews',(SELECT coalesce(jsonb_agg(to_jsonb(r)),'[]') FROM public.payroll_run_reviews r WHERE r.business_id=bid));
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_payroll_review_state() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6226_payroll_review_state() TO authenticated;

-- Keep the legacy lock; only inspect payslip fields for payslip rows.
CREATE OR REPLACE FUNCTION public.v55_lock_finalised_payroll_child()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rid uuid;
begin
  if tg_op='DELETE' then
    if tg_table_name='payroll_pay_run_employees' then rid=old.pay_run_id;
    elsif tg_table_name='payroll_pay_run_lines' then select pay_run_id into rid from public.payroll_pay_run_employees where id=old.pay_run_employee_id;
    else rid=old.pay_run_id; end if;
    if exists(select 1 from public.payroll_pay_runs where id=rid and status in ('finalised','reversed')) then
      raise exception 'Finalised or reversed payroll detail is an accounting record and cannot be deleted.';
    end if;
    return old;
  end if;
  if tg_table_name='payroll_pay_run_employees' then rid=new.pay_run_id;
  elsif tg_table_name='payroll_pay_run_lines' then select pay_run_id into rid from public.payroll_pay_run_employees where id=new.pay_run_employee_id;
  else rid=new.pay_run_id; end if;
  if exists(select 1 from public.payroll_pay_runs where id=rid and status in ('finalised','reversed')) then
    if tg_table_name='payroll_payslips' and tg_op='UPDATE' then
      if new.id=old.id and new.business_id=old.business_id and new.pay_run_id=old.pay_run_id
       and new.pay_run_employee_id=old.pay_run_employee_id and new.employee_id=old.employee_id
       and new.payslip_number=old.payslip_number and new.payslip_data is not distinct from old.payslip_data
       and new.generated_at=old.generated_at then return new; end if;
    end if;
    raise exception 'Finalised or reversed payroll detail is locked.';
  end if;
  return new;
end $function$;
