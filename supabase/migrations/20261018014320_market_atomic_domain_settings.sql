-- Market: one canonical, atomic settings writer. Existing records/history retained.
CREATE TABLE public.payroll_settings_operations (
 id uuid PRIMARY KEY,business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
 actor_id uuid NOT NULL,request jsonb NOT NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.payroll_settings_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_settings_operations FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.v6227_settings_revision() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $f$
BEGIN
 IF TG_TABLE_NAME IN ('payroll_settings','bank_reconciliation_settings') THEN
  NEW.updated_at:=clock_timestamp();RETURN NEW;
 END IF;
 IF TG_OP='UPDATE' AND NEW.business_id IS DISTINCT FROM OLD.business_id THEN RAISE EXCEPTION 'Settings cannot move between businesses.' USING ERRCODE='42501';END IF;
 UPDATE public.payroll_settings SET updated_at=clock_timestamp() WHERE business_id=CASE WHEN TG_OP='DELETE' THEN OLD.business_id ELSE NEW.business_id END;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END;$f$;
REVOKE ALL ON FUNCTION public.v6227_settings_revision() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER z6227_revision BEFORE INSERT OR UPDATE ON public.payroll_settings FOR EACH ROW EXECUTE FUNCTION public.v6227_settings_revision();
CREATE TRIGGER z6227_revision BEFORE INSERT OR UPDATE ON public.bank_reconciliation_settings FOR EACH ROW EXECUTE FUNCTION public.v6227_settings_revision();
DO $t$ DECLARE tbl text;BEGIN
 FOREACH tbl IN ARRAY ARRAY['payroll_pay_items','payroll_leave_types','payroll_document_types'] LOOP
  EXECUTE format('CREATE TRIGGER z6227_revision AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.v6227_settings_revision()',tbl);
 END LOOP;
END;$t$;

CREATE FUNCTION public.v6227_get_payroll_settings() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $f$
 SELECT jsonb_build_object('settings',to_jsonb(s),
 'pay_items',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.item_type,i.name,i.id),'[]') FROM public.payroll_pay_items i WHERE i.business_id=s.business_id AND NOT i.archived),
 'leave_types',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.name,i.id),'[]') FROM public.payroll_leave_types i WHERE i.business_id=s.business_id AND NOT i.archived),
 'document_types',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.sort_order,i.id),'[]') FROM public.payroll_document_types i WHERE i.business_id=s.business_id AND NOT i.archived))
 FROM public.payroll_settings s WHERE auth.uid() IS NOT NULL AND s.business_id=public.current_business_id() AND public.v55_payroll_access(s.business_id);
$f$;
REVOKE ALL ON FUNCTION public.v6227_get_payroll_settings() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6227_get_payroll_settings() TO authenticated;

CREATE FUNCTION public.v6227_save_payroll_settings(p_business_id uuid,p_expected_updated_at timestamptz,p_values jsonb,p_pay_items jsonb,p_leave_types jsonb,p_document_types jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $f$
DECLARE cfg public.payroll_settings%ROWTYPE;part jsonb;row jsonb;field text;rid uuid;
BEGIN
 IF auth.uid() IS NULL OR p_business_id IS DISTINCT FROM public.current_business_id() OR NOT coalesce(public.v55_payroll_access(p_business_id),false) OR NOT coalesce(public.v6147_can_write_area(p_business_id,'payroll'),false) THEN RAISE EXCEPTION 'Payroll write access is required.' USING ERRCODE='42501';END IF;
 IF jsonb_typeof(p_values) IS DISTINCT FROM 'object' OR octet_length(jsonb_build_array(p_values,p_pay_items,p_leave_types,p_document_types)::text)>2097152 THEN RAISE EXCEPTION 'Invalid payroll settings request.' USING ERRCODE='22023';END IF;
 FOREACH part IN ARRAY ARRAY[p_pay_items,p_leave_types,p_document_types] LOOP
  IF jsonb_typeof(part) IS DISTINCT FROM 'array' OR jsonb_array_length(part)>500 THEN RAISE EXCEPTION 'Invalid payroll settings list.' USING ERRCODE='22023';END IF;
  IF (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(part))<>jsonb_array_length(part) THEN RAISE EXCEPTION 'Settings IDs must be present and unique.' USING ERRCODE='22023';END IF;
 END LOOP;
 SELECT * INTO cfg FROM public.payroll_settings WHERE business_id=p_business_id FOR UPDATE;
 IF NOT FOUND OR p_expected_updated_at IS NULL OR cfg.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'Payroll settings changed. Reload before saving again.' USING ERRCODE='40001';END IF;
 IF NOT coalesce(public.v55_payroll_access(p_business_id),false) OR NOT coalesce(public.v6147_can_write_area(p_business_id,'payroll'),false) THEN RAISE EXCEPTION 'Payroll access changed.' USING ERRCODE='42501';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_values)k WHERE NOT(k=ANY(ARRAY['country_code','currency','default_pay_frequency','default_pay_day','week_start_day','default_weekly_hours','default_working_days','default_labour_classification','employee_prefix','payslip_note','employer_ird_number','payroll_contact_name','payroll_contact_phone','payroll_contact_email','paye_intermediary_ird_number','payroll_package_identifier']))) THEN RAISE EXCEPTION 'Use the dedicated editor for this setting.' USING ERRCODE='22023';END IF;
 FOREACH field IN ARRAY ARRAY['default_pay_day','week_start_day','default_weekly_hours','default_working_days'] LOOP
  IF jsonb_typeof(p_values->field) IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'Payroll defaults must be valid numbers.' USING ERRCODE='22023';END IF;
 END LOOP;
 IF (p_values->>'default_weekly_hours')::numeric NOT BETWEEN 0 AND 168 OR (p_values->>'default_working_days')::numeric NOT BETWEEN 0 AND 7 OR coalesce(p_values->>'default_pay_frequency','') NOT IN ('weekly','fortnightly','four-weekly','monthly') OR nullif(btrim(p_values->>'employee_prefix'),'') IS NULL THEN RAISE EXCEPTION 'Check the payroll frequency, hours, working days and employee prefix.' USING ERRCODE='22023';END IF;
 UPDATE public.payroll_settings s SET country_code=x.country_code,currency=x.currency,default_pay_frequency=x.default_pay_frequency,default_pay_day=x.default_pay_day,week_start_day=x.week_start_day,default_weekly_hours=x.default_weekly_hours,default_working_days=x.default_working_days,default_labour_classification=x.default_labour_classification,employee_prefix=x.employee_prefix,payslip_note=x.payslip_note,employer_ird_number=x.employer_ird_number,payroll_contact_name=x.payroll_contact_name,payroll_contact_phone=x.payroll_contact_phone,payroll_contact_email=x.payroll_contact_email,paye_intermediary_ird_number=x.paye_intermediary_ird_number,payroll_package_identifier=x.payroll_package_identifier,updated_by=auth.uid() FROM jsonb_populate_record(NULL::public.payroll_settings,p_values)x WHERE s.business_id=p_business_id;
 FOR row IN SELECT * FROM jsonb_array_elements(p_pay_items) LOOP
  IF jsonb_typeof(row) IS DISTINCT FROM 'object' OR nullif(btrim(row->>'name'),'') IS NULL OR length(row->>'name')>200 THEN RAISE EXCEPTION 'Each settings item needs a name of up to 200 characters.' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(row)k WHERE NOT(k=ANY(ARRAY['id','item_type','name','calculation_type','default_rate','taxable','statutory_earning_code','holidays_gross_earnings_mode','owp_inclusion_mode','rdp_inclusion_mode','adp_inclusion_mode']))) THEN RAISE EXCEPTION 'Unexpected settings item field.' USING ERRCODE='22023';END IF;
  IF jsonb_typeof(row->'default_rate') IS DISTINCT FROM 'number' OR jsonb_typeof(row->'taxable') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Invalid pay item values.' USING ERRCODE='22023';END IF;
  UPDATE public.payroll_pay_items i SET item_type=x.item_type,name=x.name,calculation_type=x.calculation_type,default_rate=x.default_rate,taxable=x.taxable,statutory_earning_code=x.statutory_earning_code,holidays_gross_earnings_mode=x.holidays_gross_earnings_mode,owp_inclusion_mode=x.owp_inclusion_mode,rdp_inclusion_mode=x.rdp_inclusion_mode,adp_inclusion_mode=x.adp_inclusion_mode FROM jsonb_populate_record(NULL::public.payroll_pay_items,row)x WHERE i.id=x.id AND i.business_id=p_business_id AND NOT i.archived;
  IF NOT FOUND THEN RAISE EXCEPTION 'A settings item was archived, removed or belongs to another business. Reload Settings.' USING ERRCODE='42501';END IF;
 END LOOP;
 FOR row IN SELECT * FROM jsonb_array_elements(p_leave_types) LOOP
  IF jsonb_typeof(row) IS DISTINCT FROM 'object' OR nullif(btrim(row->>'name'),'') IS NULL OR length(row->>'name')>200 THEN RAISE EXCEPTION 'Each settings item needs a name of up to 200 characters.' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(row)k WHERE NOT(k=ANY(ARRAY['id','name','paid']))) THEN RAISE EXCEPTION 'Unexpected settings item field.' USING ERRCODE='22023';END IF;
  IF jsonb_typeof(row->'paid') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Invalid settings choice.' USING ERRCODE='22023';END IF;
  UPDATE public.payroll_leave_types i SET name=x.name,paid=x.paid FROM jsonb_populate_record(NULL::public.payroll_leave_types,row)x WHERE i.id=x.id AND i.business_id=p_business_id AND NOT i.archived;
  IF NOT FOUND THEN RAISE EXCEPTION 'A settings item was archived, removed or belongs to another business. Reload Settings.' USING ERRCODE='42501';END IF;
 END LOOP;
 FOR row IN SELECT * FROM jsonb_array_elements(p_document_types) LOOP
  IF jsonb_typeof(row) IS DISTINCT FROM 'object' OR nullif(btrim(row->>'name'),'') IS NULL OR length(row->>'name')>200 THEN RAISE EXCEPTION 'Each settings item needs a name of up to 200 characters.' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(row)k WHERE NOT(k=ANY(ARRAY['id','name','required']))) THEN RAISE EXCEPTION 'Unexpected settings item field.' USING ERRCODE='22023';END IF;
  IF jsonb_typeof(row->'required') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Invalid settings choice.' USING ERRCODE='22023';END IF;
  UPDATE public.payroll_document_types i SET name=x.name,required=x.required FROM jsonb_populate_record(NULL::public.payroll_document_types,row)x WHERE i.id=x.id AND i.business_id=p_business_id AND NOT i.archived;
  IF NOT FOUND THEN RAISE EXCEPTION 'A settings item was archived, removed or belongs to another business. Reload Settings.' USING ERRCODE='42501';END IF;
 END LOOP;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by) VALUES(p_business_id,'payroll_settings',cfg.id,'settings_updated',jsonb_build_object('pay_items',jsonb_array_length(p_pay_items),'leave_types',jsonb_array_length(p_leave_types),'document_types',jsonb_array_length(p_document_types)),auth.uid());
 RETURN public.v6227_get_payroll_settings();
END;$f$;
REVOKE ALL ON FUNCTION public.v6227_save_payroll_settings(uuid,timestamptz,jsonb,jsonb,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6227_save_payroll_settings(uuid,timestamptz,jsonb,jsonb,jsonb,jsonb) TO authenticated;

CREATE FUNCTION public.v6227_payroll_catalog_command(p_business_id uuid,p_expected_updated_at timestamptz,p_request uuid,p_kind text,p_action text,p_id uuid,p_values jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $f$
DECLARE cfg public.payroll_settings%ROWTYPE;prior public.payroll_settings_operations%ROWTYPE;request jsonb:=jsonb_build_object('revision',p_expected_updated_at,'kind',p_kind,'action',p_action,'id',p_id,'values',p_values);tbl text;rid uuid;result jsonb;
BEGIN
 IF auth.uid() IS NULL OR p_business_id IS DISTINCT FROM public.current_business_id() OR NOT coalesce(public.v55_payroll_access(p_business_id),false) OR NOT coalesce(public.v6147_can_write_area(p_business_id,'payroll'),false) THEN RAISE EXCEPTION 'Payroll write access is required.' USING ERRCODE='42501';END IF;
 IF p_request IS NULL OR coalesce(p_kind,'') NOT IN ('pay_item','leave_type','document_type') OR coalesce(p_action,'') NOT IN ('add','archive') OR jsonb_typeof(p_values) IS DISTINCT FROM 'object' OR octet_length(p_values::text)>4096 THEN RAISE EXCEPTION 'Invalid payroll catalog command.' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('payroll-settings:'||p_request::text,0));
 SELECT * INTO prior FROM public.payroll_settings_operations WHERE id=p_request;
 IF FOUND THEN
  IF prior.business_id<>p_business_id OR prior.actor_id<>auth.uid() OR prior.request IS DISTINCT FROM request THEN RAISE EXCEPTION 'Save identifier belongs to another request.' USING ERRCODE='22023';END IF;RETURN prior.result;
 END IF;
 SELECT * INTO cfg FROM public.payroll_settings WHERE business_id=p_business_id FOR UPDATE;
 IF NOT FOUND OR p_expected_updated_at IS NULL OR cfg.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'Payroll settings changed. Reload before continuing.' USING ERRCODE='40001';END IF;
 IF NOT coalesce(public.v55_payroll_access(p_business_id),false) OR NOT coalesce(public.v6147_can_write_area(p_business_id,'payroll'),false) THEN RAISE EXCEPTION 'Payroll access changed.' USING ERRCODE='42501';END IF;
 tbl:=CASE p_kind WHEN 'pay_item' THEN 'payroll_pay_items' WHEN 'leave_type' THEN 'payroll_leave_types' ELSE 'payroll_document_types' END;
 IF p_action='archive' THEN
  IF p_id IS NULL OR p_values<>'{}' THEN RAISE EXCEPTION 'Invalid archive request.' USING ERRCODE='22023';END IF;
  EXECUTE format('UPDATE public.%I SET archived=true WHERE id=$1 AND business_id=$2 AND NOT archived RETURNING id',tbl) INTO rid USING p_id,p_business_id;
  IF rid IS NULL THEN RAISE EXCEPTION 'Settings item is unavailable in this business.' USING ERRCODE='42501';END IF;
 ELSE
  IF p_id IS NOT NULL OR nullif(btrim(p_values->>'name'),'') IS NULL OR length(p_values->>'name')>200 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_values)k WHERE k NOT IN ('name','item_type')) THEN RAISE EXCEPTION 'Enter a name of up to 200 characters.' USING ERRCODE='22023';END IF;
  IF p_kind='pay_item' THEN
   INSERT INTO public.payroll_pay_items(business_id,name,item_type,calculation_type,default_rate,taxable,statutory_earning_code,holidays_gross_earnings_mode,owp_inclusion_mode,rdp_inclusion_mode,adp_inclusion_mode)
    VALUES(p_business_id,btrim(p_values->>'name'),p_values->>'item_type','fixed',0,p_values->>'item_type'<>'reimbursement',CASE WHEN p_values->>'item_type'='reimbursement' THEN 'reimbursement' END,'needs_confirmation','needs_confirmation','needs_confirmation','needs_confirmation') RETURNING id INTO rid;
  ELSIF p_kind='leave_type' THEN INSERT INTO public.payroll_leave_types(business_id,name,paid) VALUES(p_business_id,btrim(p_values->>'name'),true) RETURNING id INTO rid;
  ELSE INSERT INTO public.payroll_document_types(business_id,name,required) VALUES(p_business_id,btrim(p_values->>'name'),false) RETURNING id INTO rid;END IF;
 END IF;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by) VALUES(p_business_id,p_kind,rid,p_action,jsonb_build_object('settings_revision',p_expected_updated_at),auth.uid());
 result:=jsonb_build_object('business_id',p_business_id,'id',rid);
 INSERT INTO public.payroll_settings_operations(id,business_id,actor_id,request,result) VALUES(p_request,p_business_id,auth.uid(),request,result);
 RETURN result;
END;$f$;
REVOKE ALL ON FUNCTION public.v6227_payroll_catalog_command(uuid,timestamptz,uuid,text,text,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6227_payroll_catalog_command(uuid,timestamptz,uuid,text,text,uuid,jsonb) TO authenticated;

CREATE FUNCTION public.v6227_save_bank_preferences(p_business_id uuid,p_expected_updated_at timestamptz,p_days integer,p_confidence integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $f$
DECLARE cfg public.bank_reconciliation_settings%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR p_business_id IS DISTINCT FROM public.current_business_id() OR NOT coalesce(public.v6147_can_write_area(p_business_id,'bank'),false) OR NOT coalesce(public.v6135_bank_module_enabled(p_business_id),false) THEN RAISE EXCEPTION 'Banking write access is required.' USING ERRCODE='42501';END IF;
 IF p_days IS NULL OR p_days NOT BETWEEN 0 AND 30 OR p_confidence IS NULL OR p_confidence NOT BETWEEN 50 AND 100 THEN RAISE EXCEPTION 'Use 0–30 days and a confidence percentage from 50 to 100.' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('bank-preferences:'||p_business_id::text,0));
 SELECT * INTO cfg FROM public.bank_reconciliation_settings WHERE business_id=p_business_id FOR UPDATE;
 IF cfg.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'Bank preferences changed. Reload before saving.' USING ERRCODE='40001';END IF;
 IF NOT coalesce(public.v6147_can_write_area(p_business_id,'bank'),false) OR NOT coalesce(public.v6135_bank_module_enabled(p_business_id),false) THEN RAISE EXCEPTION 'Banking access changed.' USING ERRCODE='42501';END IF;
 INSERT INTO public.bank_reconciliation_settings(business_id,date_tolerance_days,high_confidence_threshold,updated_by) VALUES(p_business_id,p_days,p_confidence,auth.uid())
 ON CONFLICT(business_id) DO UPDATE SET date_tolerance_days=excluded.date_tolerance_days,high_confidence_threshold=excluded.high_confidence_threshold,updated_by=excluded.updated_by RETURNING * INTO cfg;
 INSERT INTO public.bank_reconciliation_audit(business_id,action,details,created_by) VALUES(p_business_id,'preferences_updated',jsonb_build_object('date_tolerance_days',p_days,'high_confidence_threshold',p_confidence),auth.uid());
 RETURN to_jsonb(cfg);
END;$f$;
REVOKE ALL ON FUNCTION public.v6227_save_bank_preferences(uuid,timestamptz,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6227_save_bank_preferences(uuid,timestamptz,integer,integer) TO authenticated;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.payroll_settings,public.payroll_pay_items,public.payroll_leave_types,public.payroll_document_types,public.bank_reconciliation_settings FROM PUBLIC,anon,authenticated;
