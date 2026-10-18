-- Market only. Retains the existing NZ calculation engine and historical records.
DO $$ BEGIN IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;END $$;
CREATE TABLE public.payroll_statutory_leave_operations (
 id uuid PRIMARY KEY, business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
 employee_id uuid NOT NULL REFERENCES public.payroll_employees(id),actor_id uuid NOT NULL,
 payload jsonb NOT NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.payroll_statutory_leave_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_statutory_leave_operations FROM PUBLIC,anon,authenticated;
CREATE INDEX payroll_statutory_leave_operations_business ON public.payroll_statutory_leave_operations(business_id,employee_id);
CREATE FUNCTION public.v6230_record_statutory_leave(p_employee uuid,p_request uuid,p_expected_owd_updated_at timestamptz,p_expected_entitlement_updated_at timestamptz,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b uuid:=public.current_business_id();e public.payroll_employees;lt public.payroll_leave_types;
 op public.payroll_statutory_leave_operations;owd public.payroll_owd_determinations;tx public.payroll_leave_transactions;calc public.payroll_statutory_leave_calculations;ep public.payroll_statutory_leave_entitlements;
 c jsonb;o jsonb;period jsonb;request_body jsonb;out jsonb;rules jsonb;expected_rules jsonb;d date;code text;confirmation text;qty numeric;display numeric;rate numeric;rdp numeric;adp numeric;grant_days numeric;carry numeric;start_date date;end_date date;v jsonb;
BEGIN
 IF auth.uid() IS NULL OR b IS NULL OR p_employee IS NULL OR p_request IS NULL OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_write_area(b,'payroll') THEN RAISE EXCEPTION 'Payroll write access required' USING ERRCODE='42501';END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR octet_length(p_payload::text)>1048576 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('calculation','owd','entitlement','display_hours','notes')) THEN RAISE EXCEPTION 'Invalid statutory leave bundle' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_employee::text,6230));
 SELECT * INTO e FROM public.payroll_employees WHERE id=p_employee AND business_id=b FOR UPDATE;
 IF NOT FOUND OR e.archived THEN RAISE EXCEPTION 'Employee unavailable' USING ERRCODE='42501';END IF;
 IF b IS DISTINCT FROM public.current_business_id() OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_write_area(b,'payroll') THEN RAISE EXCEPTION 'Payroll access changed' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.payroll_settings WHERE business_id=b AND country_code='NZ') THEN RAISE EXCEPTION 'This save supports NZ statutory leave only' USING ERRCODE='22023';END IF;
 request_body:=jsonb_build_object('employee',p_employee,'owd_revision',p_expected_owd_updated_at,'entitlement_revision',p_expected_entitlement_updated_at,'values',p_payload);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request::text,62301));
 SELECT * INTO op FROM public.payroll_statutory_leave_operations WHERE id=p_request;
 IF FOUND THEN
  IF op.actor_id IS DISTINCT FROM auth.uid() OR op.business_id<>b OR op.employee_id<>e.id OR op.payload<>request_body THEN RAISE EXCEPTION 'Request identifier already used for different input' USING ERRCODE='22023';END IF;
  RETURN op.result;
 END IF;
 c:=p_payload->'calculation';o:=nullif(p_payload->'owd','null'::jsonb);period:=nullif(p_payload->'entitlement','null'::jsonb);
 IF jsonb_typeof(c) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Calculation evidence required' USING ERRCODE='22023';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(c) k WHERE k NOT IN ('business_id','employee_id','leave_type_id','leave_transaction_id','pay_run_id','owd_determination_id','statutory_leave_code','calculation_type','relevant_from','relevant_to','rule_version','rules_snapshot','input_snapshot','owd_evidence_snapshot','rdp_amount','adp_amount','selected_method','selected_amount','confirmation_state','explanation_snapshot')) OR c->>'business_id' IS DISTINCT FROM b::text OR c->>'employee_id' IS DISTINCT FROM e.id::text OR nullif(c->>'pay_run_id','') IS NOT NULL OR nullif(c->>'leave_transaction_id','') IS NOT NULL OR nullif(c->>'owd_determination_id','') IS NOT NULL THEN RAISE EXCEPTION 'Calculation context or fields invalid' USING ERRCODE='22023';END IF;
 code:=c->>'statutory_leave_code';confirmation:=c->>'confirmation_state';
 IF code IS NULL OR code NOT IN ('sick_leave','bereavement_leave','family_violence_leave') OR c->>'calculation_type' IS DISTINCT FROM code OR confirmation IS NULL OR confirmation NOT IN ('confirmed','needs_confirmation','not_required') OR c->>'rule_version' IS DISTINCT FROM 'V61.73-P4B.1' THEN RAISE EXCEPTION 'Unsupported statutory calculation' USING ERRCODE='22023';END IF;
 BEGIN
  d:=(c->>'relevant_from')::date;qty:=(c->'input_snapshot'->>'statutory_quantity')::numeric;display:=(p_payload->>'display_hours')::numeric;rate:=(c->>'selected_amount')::numeric;rdp:=(c->>'rdp_amount')::numeric;adp:=(c->>'adp_amount')::numeric;
  SELECT * INTO lt FROM public.payroll_leave_types WHERE id=(c->>'leave_type_id')::uuid AND business_id=b AND NOT archived;
 EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow OR numeric_value_out_of_range THEN RAISE EXCEPTION 'Invalid statutory dates or amounts' USING ERRCODE='22023';END;
 IF d IS NULL OR NOT isfinite(d) OR d<'1900-01-01' OR d>'2100-12-31' OR c->>'relevant_to' IS DISTINCT FROM d::text OR lt.id IS NULL OR (lt.statutory_leave_code IS NOT NULL AND lt.statutory_leave_code<>code) THEN RAISE EXCEPTION 'Valid date and matching employee leave type required' USING ERRCODE='22023';END IF;
 IF jsonb_typeof(c->'rules_snapshot') IS DISTINCT FROM 'object' OR jsonb_typeof(c->'input_snapshot') IS DISTINCT FROM 'object' OR jsonb_typeof(c->'explanation_snapshot') IS DISTINCT FROM 'object' OR jsonb_typeof(c->'owd_evidence_snapshot') IS DISTINCT FROM 'object' OR c->'input_snapshot'->>'leave_code' IS DISTINCT FROM code THEN RAISE EXCEPTION 'Complete calculation evidence required' USING ERRCODE='22023';END IF;
 -- Confirm the saved rule evidence corresponds to the currently effective rules loaded by Payroll.
 SELECT coalesce(jsonb_agg(x ORDER BY x),'[]'::jsonb) INTO rules FROM (SELECT jsonb_build_object('type',rule_type,'key',rule_key,'numeric_value',numeric_value,'text_value',text_value,'json_value',json_value,'effective_from',effective_from,'effective_to',effective_to,'source_note',source_note) x FROM public.country_payroll_rules WHERE country_code='NZ' AND active AND effective_from<=d AND (effective_to IS NULL OR effective_to>=d)) s;
 IF jsonb_typeof(c->'rules_snapshot'->'rules') IS DISTINCT FROM 'array' OR c->'rules_snapshot'->>'country' IS DISTINCT FROM 'NZ' THEN RAISE EXCEPTION 'Effective rule evidence required' USING ERRCODE='22023';END IF;
 SELECT coalesce(jsonb_agg(x ORDER BY x),'[]'::jsonb) INTO expected_rules FROM jsonb_array_elements(c->'rules_snapshot'->'rules') x;
 IF rules<>expected_rules OR jsonb_array_length(rules)=0 THEN RAISE EXCEPTION 'Payroll rules changed or could not be verified. Reload before calculating.' USING ERRCODE='40001';END IF;
 FOR v IN SELECT value FROM jsonb_each(jsonb_build_object('quantity',qty,'display_hours',display,'selected_amount',rate,'rdp_amount',rdp,'adp_amount',adp)) LOOP
  IF v<>'null'::jsonb AND ((v#>>'{}')::numeric::text IN ('NaN','Infinity','-Infinity') OR (v#>>'{}')::numeric<0 OR (v#>>'{}')::numeric>100000000 OR round((v#>>'{}')::numeric,2)<>(v#>>'{}')::numeric) THEN RAISE EXCEPTION 'Amounts must be finite, nonnegative and have at most two decimals' USING ERRCODE='22023';END IF;
 END LOOP;
 IF length(coalesce(p_payload->>'notes',''))>2000 THEN RAISE EXCEPTION 'Leave note is too long' USING ERRCODE='22023';END IF;
 IF o IS NOT NULL THEN
  IF jsonb_typeof(o)<>'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(o) k WHERE k NOT IN ('determination','method','evidence_snapshot','employer_reason')) OR o->>'determination' IS NULL OR o->>'determination' NOT IN ('yes','no','needs_confirmation') OR o->>'method' IS NULL OR o->>'method' NOT IN ('system_supported','employer_determined') OR jsonb_typeof(o->'evidence_snapshot') IS DISTINCT FROM 'object' OR length(coalesce(o->>'employer_reason',''))>2000 THEN RAISE EXCEPTION 'Working-day evidence invalid' USING ERRCODE='22023';END IF;
  IF c->'owd_evidence_snapshot' IS DISTINCT FROM o->'evidence_snapshot' THEN RAISE EXCEPTION 'Working-day evidence does not match calculation' USING ERRCODE='22023';END IF;
  SELECT * INTO owd FROM public.payroll_owd_determinations WHERE business_id=b AND employee_id=e.id AND relevant_date=d FOR UPDATE;
  IF owd.updated_at IS DISTINCT FROM p_expected_owd_updated_at THEN RAISE EXCEPTION 'Working-day evidence changed. Reload before saving.' USING ERRCODE='40001';END IF;
 END IF;
 IF confirmation='confirmed' THEN
  IF qty IS NULL OR qty<=0 OR qty>1000 OR c->'input_snapshot'->>'statutory_unit' IS DISTINCT FROM 'days' OR rate IS NULL OR c->>'selected_method' IS NULL OR c->>'selected_method' NOT IN ('rdp','adp') OR (c->>'selected_method'='rdp' AND rate IS DISTINCT FROM rdp) OR (c->>'selected_method'='adp' AND rate IS DISTINCT FROM adp) OR o IS NULL OR o->>'determination' IS DISTINCT FROM 'yes' OR c->'input_snapshot'->'eligibility'->>'status' IS DISTINCT FROM 'eligible' OR c->'input_snapshot'->'entitlement'->>'status' IS DISTINCT FROM 'calculated' OR c->'explanation_snapshot'->>'status' IS DISTINCT FROM 'calculated' OR jsonb_typeof(c->'explanation_snapshot'->'reasons') IS DISTINCT FROM 'array' OR jsonb_array_length(c->'explanation_snapshot'->'reasons')<>0 THEN RAISE EXCEPTION 'Confirmed leave requires matching complete calculation and eligibility evidence' USING ERRCODE='22023';END IF;
  IF d<e.start_date OR (e.end_date IS NOT NULL AND d>e.end_date) THEN RAISE EXCEPTION 'Confirmed leave must fall within employment' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT 1 FROM public.payroll_statutory_leave_calculations WHERE business_id=b AND employee_id=e.id AND relevant_from=d AND statutory_leave_code=code AND confirmation_state='confirmed') THEN RAISE EXCEPTION 'Confirmed leave already exists for this employee, date and leave type. Review the existing record.' USING ERRCODE='23505';END IF;
  IF code IN ('sick_leave','family_violence_leave') THEN
   IF period IS NULL OR jsonb_typeof(period)<>'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(period) k WHERE k NOT IN ('period_start','period_end','grant_days','carry_forward_days')) THEN RAISE EXCEPTION 'Confirmed leave requires a reviewed entitlement period' USING ERRCODE='22023';END IF;
   BEGIN start_date:=(period->>'period_start')::date;end_date:=(period->>'period_end')::date;grant_days:=(period->>'grant_days')::numeric;carry:=(period->>'carry_forward_days')::numeric;EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow THEN RAISE EXCEPTION 'Entitlement period invalid' USING ERRCODE='22023';END;
   IF start_date IS NULL OR end_date IS NULL OR NOT isfinite(start_date) OR NOT isfinite(end_date) OR start_date<'1900-01-01' OR end_date>'2100-12-31' OR d<start_date OR d>end_date OR end_date-start_date>366 OR grant_days IS NULL OR carry IS NULL OR grant_days::text IN ('NaN','Infinity','-Infinity') OR carry::text IN ('NaN','Infinity','-Infinity') OR grant_days<0 OR carry<0 OR grant_days+carry>1000 OR round(grant_days,2)<>grant_days OR round(carry,2)<>carry THEN RAISE EXCEPTION 'Entitlement period or reviewed quantities invalid' USING ERRCODE='22023';END IF;
   SELECT * INTO ep FROM public.payroll_statutory_leave_entitlements WHERE business_id=b AND employee_id=e.id AND statutory_leave_code=code AND period_start=start_date FOR UPDATE;
   IF ep.updated_at IS DISTINCT FROM p_expected_entitlement_updated_at THEN RAISE EXCEPTION 'Entitlement changed. Reload before saving.' USING ERRCODE='40001';END IF;
   IF ep.id IS NOT NULL AND (ep.period_end<>end_date OR ep.grant_days<>grant_days OR ep.carry_forward_days<>carry) THEN RAISE EXCEPTION 'Existing entitlement grant or period must be reviewed separately' USING ERRCODE='22023';END IF;
   IF ep.id IS NULL AND EXISTS(SELECT 1 FROM public.payroll_statutory_leave_entitlements WHERE business_id=b AND employee_id=e.id AND statutory_leave_code=code AND period_start<=end_date AND period_end>=start_date) THEN RAISE EXCEPTION 'Entitlement periods overlap; review existing periods' USING ERRCODE='22023';END IF;
   IF coalesce(ep.used_days,0)+qty>grant_days+carry THEN RAISE EXCEPTION 'Requested leave exceeds the saved reviewed entitlement' USING ERRCODE='22023';END IF;
  END IF;
 END IF;
 -- Writes deliberately start only after all validations and revision checks.
 IF o IS NOT NULL THEN
  INSERT INTO public.payroll_owd_determinations(business_id,employee_id,relevant_date,determination,method,evidence_snapshot,employer_reason,determined_by,determined_at,updated_at) VALUES(b,e.id,d,o->>'determination',o->>'method',o->'evidence_snapshot',CASE WHEN code='family_violence_leave' THEN NULL ELSE nullif(o->>'employer_reason','') END,auth.uid(),clock_timestamp(),clock_timestamp()) ON CONFLICT(business_id,employee_id,relevant_date) DO UPDATE SET determination=excluded.determination,method=excluded.method,evidence_snapshot=excluded.evidence_snapshot,employer_reason=excluded.employer_reason,determined_by=excluded.determined_by,determined_at=excluded.determined_at,updated_at=excluded.updated_at RETURNING * INTO owd;
 END IF;
 IF confirmation='confirmed' THEN
  INSERT INTO public.payroll_leave_transactions(business_id,employee_id,leave_type_id,transaction_date,transaction_type,hours,notes,statutory_quantity,statutory_unit,display_hours,statutory_leave_code,created_by) VALUES(b,e.id,lt.id,d,'taken',coalesce(display,0),CASE WHEN code='family_violence_leave' THEN NULL ELSE nullif(p_payload->>'notes','') END,qty,'days',display,code,auth.uid()) RETURNING * INTO tx;
 END IF;
 INSERT INTO public.payroll_statutory_leave_calculations(business_id,employee_id,leave_type_id,leave_transaction_id,owd_determination_id,statutory_leave_code,calculation_type,relevant_from,relevant_to,rule_version,rules_snapshot,input_snapshot,owd_evidence_snapshot,rdp_amount,adp_amount,selected_method,selected_amount,confirmation_state,explanation_snapshot,created_by,updated_by) VALUES(b,e.id,lt.id,tx.id,owd.id,code,code,d,d,c->>'rule_version',c->'rules_snapshot',c->'input_snapshot',c->'owd_evidence_snapshot',rdp,adp,c->>'selected_method',rate,confirmation,c->'explanation_snapshot',auth.uid(),auth.uid()) RETURNING * INTO calc;
 IF confirmation='confirmed' AND code IN ('sick_leave','family_violence_leave') THEN
  INSERT INTO public.payroll_statutory_leave_entitlements(business_id,employee_id,statutory_leave_code,period_start,period_end,grant_days,carry_forward_days,used_days,rule_version,rules_snapshot,updated_at,updated_by) VALUES(b,e.id,code,start_date,end_date,grant_days,carry,qty,c->>'rule_version',c->'rules_snapshot',clock_timestamp(),auth.uid()) ON CONFLICT(business_id,employee_id,statutory_leave_code,period_start) DO UPDATE SET used_days=payroll_statutory_leave_entitlements.used_days+excluded.used_days,updated_at=excluded.updated_at,updated_by=excluded.updated_by RETURNING * INTO ep;
 END IF;
 out:=jsonb_build_object('business_id',b,'employee_id',e.id,'owd',CASE WHEN owd.id IS NULL THEN NULL ELSE to_jsonb(owd) END,'transaction',CASE WHEN tx.id IS NULL THEN NULL ELSE to_jsonb(tx) END,'calculation',to_jsonb(calc),'entitlement',CASE WHEN ep.id IS NULL THEN NULL ELSE to_jsonb(ep) END);
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by) VALUES(b,'statutory_leave',calc.id,'recorded',jsonb_build_object('employee_id',e.id,'confirmation_state',confirmation,'transaction_id',tx.id),auth.uid());
 INSERT INTO public.payroll_statutory_leave_operations(id,business_id,employee_id,actor_id,payload,result) VALUES(p_request,b,e.id,auth.uid(),request_body,out);
 RETURN out;
END $$;
REVOKE ALL ON FUNCTION public.v6230_record_statutory_leave(uuid,uuid,timestamptz,timestamptz,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6230_record_statutory_leave(uuid,uuid,timestamptz,timestamptz,jsonb) TO authenticated;
-- Retain independent draft/calculation evidence and other statutory/annual workflows. Block old split confirmed writers.
CREATE FUNCTION public.v6230_guard_statutory_bundle() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF current_user IN ('anon','authenticated') THEN
  IF TG_TABLE_NAME='payroll_statutory_leave_calculations' THEN
   IF (TG_OP<>'INSERT' AND OLD.statutory_leave_code IN ('sick_leave','bereavement_leave','family_violence_leave') AND OLD.confirmation_state='confirmed') OR (TG_OP<>'DELETE' AND NEW.statutory_leave_code IN ('sick_leave','bereavement_leave','family_violence_leave') AND NEW.confirmation_state='confirmed') THEN RAISE EXCEPTION 'Use the complete statutory leave save so evidence and entitlement remain together.' USING ERRCODE='42501';END IF;
  ELSIF TG_TABLE_NAME='payroll_leave_transactions' THEN
   IF (TG_OP<>'INSERT' AND OLD.statutory_leave_code IN ('sick_leave','bereavement_leave','family_violence_leave')) OR (TG_OP<>'DELETE' AND NEW.statutory_leave_code IN ('sick_leave','bereavement_leave','family_violence_leave')) THEN RAISE EXCEPTION 'Use the complete statutory leave save.' USING ERRCODE='42501';END IF;
  END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.v6230_guard_statutory_bundle() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER v6230_statutory_bundle BEFORE INSERT OR UPDATE OR DELETE ON public.payroll_statutory_leave_calculations FOR EACH ROW EXECUTE FUNCTION public.v6230_guard_statutory_bundle();
CREATE TRIGGER v6230_statutory_bundle BEFORE INSERT OR UPDATE OR DELETE ON public.payroll_leave_transactions FOR EACH ROW EXECUTE FUNCTION public.v6230_guard_statutory_bundle();
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.payroll_statutory_leave_entitlements FROM PUBLIC,anon,authenticated;
