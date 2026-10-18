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
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(v_bid,'pay_run',p_pay_run_id,'reversed',to_jsonb(v_run),jsonb_build_object('status','reversed','reason',btrim(p_reason),'reversal_journal_id',v_reversal),auth.uid());
 RETURN v_reversal;
END $function$;
REVOKE ALL ON FUNCTION public.v61105_phase13b_reverse_pay_run(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v61105_phase13b_reverse_pay_run(uuid,text) TO authenticated;
