ALTER TABLE public.payroll_employee_portal_links
  ADD COLUMN payslips_enabled boolean NOT NULL DEFAULT false;

CREATE INDEX payroll_payslips_employee_finalised_lookup_idx
  ON public.payroll_payslips(business_id,employee_id,pay_run_id,id);

CREATE OR REPLACE FUNCTION public.v6231_reset_employee_payslip_access()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $function$
BEGIN
 IF NEW.user_id IS DISTINCT FROM OLD.user_id OR NOT NEW.active OR (NOT OLD.active AND NEW.active) THEN
  NEW.payslips_enabled:=false;
 END IF;
 RETURN NEW;
END $function$;
REVOKE ALL ON FUNCTION public.v6231_reset_employee_payslip_access() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER payroll_employee_portal_links_reset_payslips
BEFORE UPDATE ON public.payroll_employee_portal_links
FOR EACH ROW EXECUTE FUNCTION public.v6231_reset_employee_payslip_access();

CREATE OR REPLACE FUNCTION public.v6231_set_employee_payslip_access(p_link uuid,p_enabled boolean,p_expected_revision bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE b uuid:=public.current_business_id();l public.payroll_employee_portal_links;e public.payroll_employees;r public.payroll_employee_portal_links;
BEGIN
 IF auth.uid() IS NULL OR b IS NULL OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_write_area(b,'payroll') OR NOT public.v6147_can_write_area(b,'team') THEN RAISE EXCEPTION 'Owner/admin with Payroll write access required' USING ERRCODE='42501';END IF;
 IF p_link IS NULL OR p_enabled IS NULL OR p_expected_revision IS NULL THEN RAISE EXCEPTION 'Reload employee access before saving' USING ERRCODE='22023';END IF;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link AND business_id=b;
 IF NOT FOUND THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(l.employee_id::text,62290));
 SELECT * INTO e FROM public.payroll_employees WHERE id=l.employee_id AND business_id=b FOR UPDATE;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link AND business_id=b FOR UPDATE;
 IF e.id IS NULL OR l.id IS NULL OR b IS DISTINCT FROM public.current_business_id() OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_write_area(b,'payroll') OR NOT public.v6147_can_write_area(b,'team') THEN RAISE EXCEPTION 'Access changed while waiting. Reload before saving.' USING ERRCODE='42501';END IF;
 IF l.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'Employee access changed. Reload before saving.' USING ERRCODE='40001';END IF;
 IF NOT l.active OR e.archived OR e.employment_status NOT IN ('active','on_leave') OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=l.user_id AND u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL AND (u.banned_until IS NULL OR u.banned_until<=now())) THEN RAISE EXCEPTION 'Active employee access with a confirmed account is required' USING ERRCODE='22023';END IF;
 IF l.payslips_enabled=p_enabled THEN RETURN jsonb_build_object('id',l.id,'revision',l.revision,'payslips_enabled',l.payslips_enabled);END IF;
 UPDATE public.payroll_employee_portal_links SET payslips_enabled=p_enabled,revision=revision+1,updated_at=clock_timestamp() WHERE id=l.id RETURNING * INTO r;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(b,'employee_portal_link',r.id,CASE WHEN p_enabled THEN 'payslips_enabled' ELSE 'payslips_disabled' END,jsonb_build_object('payslips_enabled',l.payslips_enabled),jsonb_build_object('employee_id',e.id,'payslips_enabled',r.payslips_enabled),auth.uid());
 RETURN jsonb_build_object('id',r.id,'revision',r.revision,'payslips_enabled',r.payslips_enabled);
END $function$;
REVOKE ALL ON FUNCTION public.v6231_set_employee_payslip_access(uuid,boolean,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6231_set_employee_payslip_access(uuid,boolean,bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.v6229_leave_manager_read(p_status text DEFAULT 'pending',p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE b uuid:=public.current_business_id();out jsonb;
BEGIN
 IF auth.uid() IS NULL OR b IS NULL OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_read_area(b,'payroll') THEN RAISE EXCEPTION 'Payroll access required' USING ERRCODE='42501';END IF;
 IF p_status IS NULL OR p_status NOT IN ('pending','approved','declined','cancelled','all') OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid request page' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.payroll_employees WHERE business_id=b AND NOT archived)>1000 THEN RAISE EXCEPTION 'Employee access list requires a paged export; no partial list returned';END IF;
 SELECT jsonb_build_object('business_id',b,'can_review',public.v6147_can_write_area(b,'payroll'),'can_link',public.v6147_can_write_area(b,'payroll') AND public.v6147_can_write_area(b,'team'),
 'employees',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'name',concat_ws(' ',e.first_name,e.last_name),'status',e.employment_status,'link_id',l.id,'link_revision',l.revision,'linked_email',u.email,'active',l.active,'payslips_enabled',coalesce(l.payslips_enabled,false)) ORDER BY e.first_name,e.last_name,e.id) FROM public.payroll_employees e LEFT JOIN public.payroll_employee_portal_links l ON l.employee_id=e.id AND l.business_id=b LEFT JOIN auth.users u ON u.id=l.user_id WHERE e.business_id=b AND NOT e.archived),'[]'::jsonb),
 'requests',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at,s.id) FROM (SELECT r.*,concat_ws(' ',e.first_name,e.last_name) employee_name FROM public.payroll_leave_requests r JOIN public.payroll_employees e ON e.id=r.employee_id WHERE r.business_id=b AND (p_status='all' OR r.status=p_status) ORDER BY r.created_at,r.id LIMIT 100 OFFSET p_offset) s),'[]'::jsonb),
 'total',(SELECT count(*) FROM public.payroll_leave_requests r WHERE r.business_id=b AND (p_status='all' OR r.status=p_status)),'offset',p_offset) INTO out;
 RETURN out;
END $function$;

CREATE OR REPLACE FUNCTION public.v6229_employee_leave_read(p_link uuid DEFAULT NULL,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE l public.payroll_employee_portal_links;links jsonb;out jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=auth.uid() AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL AND (banned_until IS NULL OR banned_until<=now())) THEN RAISE EXCEPTION 'A confirmed active account is required' USING ERRCODE='42501';END IF;
 IF p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid request page' USING ERRCODE='22023';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',x.id,'business_name',x.business_name,'employee_name',x.employee_name,'payslips_enabled',x.payslips_enabled) ORDER BY x.business_name,x.id),'[]'::jsonb) INTO links FROM (SELECT a.id,b.name business_name,concat_ws(' ',e.first_name,e.last_name) employee_name,a.payslips_enabled FROM public.payroll_employee_portal_links a JOIN public.payroll_employees e ON e.id=a.employee_id AND e.business_id=a.business_id JOIN public.businesses b ON b.id=a.business_id WHERE a.user_id=auth.uid() AND a.active AND NOT e.archived AND e.employment_status IN ('active','on_leave') AND public.v6229_portal_business_active(a.business_id)) x;
 IF p_link IS NULL THEN RETURN jsonb_build_object('links',links,'requests','[]'::jsonb);END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(links) v WHERE v->>'id'=p_link::text) THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link;
 SELECT jsonb_build_object('links',links,'selected',l.id,'leave_types',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name) ORDER BY name,id) FROM public.payroll_leave_types WHERE business_id=l.business_id AND NOT archived),'[]'::jsonb),'requests',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC,s.id) FROM (SELECT id,leave_name,date_from,date_to,quantity,unit,status,revision,decision_note,created_at FROM public.payroll_leave_requests WHERE link_id=l.id AND employee_id=l.employee_id AND business_id=l.business_id ORDER BY created_at DESC,id LIMIT 100 OFFSET p_offset) s),'[]'::jsonb),'total',(SELECT count(*) FROM public.payroll_leave_requests WHERE link_id=l.id AND employee_id=l.employee_id AND business_id=l.business_id),'offset',p_offset) INTO out;
 RETURN out;
END $function$;

CREATE OR REPLACE FUNCTION public.v6231_employee_payslips(p_link uuid,p_payslip uuid DEFAULT NULL,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE l public.payroll_employee_portal_links;p public.payroll_payslips;r public.payroll_pay_runs;valid boolean;adjustments jsonb;work_details jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=auth.uid() AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL AND (banned_until IS NULL OR banned_until<=now())) THEN RAISE EXCEPTION 'A confirmed active account is required' USING ERRCODE='42501';END IF;
 IF p_link IS NULL OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid payslip request' USING ERRCODE='22023';END IF;
 SELECT a.* INTO l FROM public.payroll_employee_portal_links a JOIN public.payroll_employees e ON e.id=a.employee_id AND e.business_id=a.business_id WHERE a.id=p_link AND a.user_id=auth.uid() AND a.active AND a.payslips_enabled AND NOT e.archived AND e.employment_status IN ('active','on_leave') AND public.v6229_portal_business_active(a.business_id);
 IF l.id IS NULL THEN RAISE EXCEPTION 'Payslip access unavailable' USING ERRCODE='42501';END IF;
 IF p_payslip IS NULL THEN
  RETURN jsonb_build_object('mode','list','link_id',l.id,'payslips',coalesce((SELECT jsonb_agg(jsonb_build_object('id',s.id,'payslip_number',s.payslip_number,'period_start',s.period_start,'period_end',s.period_end,'pay_date',s.pay_date,'available',s.valid,'currency',CASE WHEN s.valid THEN s.currency END,'net',CASE WHEN s.valid THEN s.net END) ORDER BY s.pay_date DESC,s.id DESC) FROM (SELECT p.id,p.payslip_number,r.period_start,r.period_end,r.pay_date,(jsonb_typeof(p.payslip_data)='object' AND p.payslip_data#>>'{employee,id}'=l.employee_id::text AND p.payslip_data#>>'{run,number}'=r.pay_run_number AND p.payslip_data#>>'{run,period_start}'=r.period_start::text AND p.payslip_data#>>'{run,period_end}'=r.period_end::text AND p.payslip_data#>>'{run,pay_date}'=r.pay_date::text AND jsonb_typeof(p.payslip_data#>'{employee,name}')='string' AND jsonb_typeof(p.payslip_data#>'{pay,gross}')='number' AND jsonb_typeof(p.payslip_data#>'{pay,net}')='number' AND p.payslip_data->>'currency' ~ '^[A-Z]{3}$') valid,p.payslip_data->>'currency' currency,CASE WHEN jsonb_typeof(p.payslip_data#>'{pay,net}')='number' THEN (p.payslip_data#>>'{pay,net}')::numeric END net FROM public.payroll_payslips p JOIN public.payroll_pay_run_employees re ON re.id=p.pay_run_employee_id AND re.business_id=l.business_id AND re.employee_id=l.employee_id AND re.pay_run_id=p.pay_run_id JOIN public.payroll_pay_runs r ON r.id=p.pay_run_id AND r.business_id=l.business_id AND r.status='finalised' WHERE p.business_id=l.business_id AND p.employee_id=l.employee_id ORDER BY r.pay_date DESC,p.id DESC LIMIT 100 OFFSET p_offset) s),'[]'::jsonb),'total',(SELECT count(*) FROM public.payroll_payslips p JOIN public.payroll_pay_run_employees re ON re.id=p.pay_run_employee_id AND re.business_id=l.business_id AND re.employee_id=l.employee_id AND re.pay_run_id=p.pay_run_id JOIN public.payroll_pay_runs r ON r.id=p.pay_run_id AND r.business_id=l.business_id AND r.status='finalised' WHERE p.business_id=l.business_id AND p.employee_id=l.employee_id),'offset',p_offset);
 END IF;
 SELECT ps.* INTO p FROM public.payroll_payslips ps JOIN public.payroll_pay_run_employees pre ON pre.id=ps.pay_run_employee_id AND pre.business_id=l.business_id AND pre.employee_id=l.employee_id AND pre.pay_run_id=ps.pay_run_id JOIN public.payroll_pay_runs pr ON pr.id=ps.pay_run_id AND pr.business_id=l.business_id AND pr.status='finalised' WHERE ps.id=p_payslip AND ps.business_id=l.business_id AND ps.employee_id=l.employee_id;
 IF p.id IS NULL THEN RAISE EXCEPTION 'Payslip unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO r FROM public.payroll_pay_runs WHERE id=p.pay_run_id AND business_id=l.business_id AND status='finalised';
 valid:=jsonb_typeof(p.payslip_data)='object' AND p.payslip_data#>>'{employee,id}'=l.employee_id::text AND p.payslip_data#>>'{run,number}'=r.pay_run_number AND p.payslip_data#>>'{run,period_start}'=r.period_start::text AND p.payslip_data#>>'{run,period_end}'=r.period_end::text AND p.payslip_data#>>'{run,pay_date}'=r.pay_date::text AND jsonb_typeof(p.payslip_data#>'{employee,name}')='string' AND jsonb_typeof(p.payslip_data#>'{pay,gross}')='number' AND jsonb_typeof(p.payslip_data#>'{pay,net}')='number' AND p.payslip_data->>'currency' ~ '^[A-Z]{3}$';
 IF NOT valid THEN RETURN jsonb_build_object('mode','detail','link_id',l.id,'payslip',jsonb_build_object('id',p.id,'payslip_number',p.payslip_number,'available',false));END IF;
 adjustments:=coalesce(p.payslip_data#>'{pay,adjustments}','[]'::jsonb);work_details:=coalesce(p.payslip_data#>'{pay,work_details}','[]'::jsonb);
 IF jsonb_typeof(adjustments)<>'array' OR jsonb_typeof(work_details)<>'array' OR jsonb_array_length(adjustments)>2000 OR jsonb_array_length(work_details)>2000 THEN RAISE EXCEPTION 'Payslip details need employer review' USING ERRCODE='22023';END IF;
 RETURN jsonb_build_object('mode','detail','link_id',l.id,'payslip',jsonb_build_object('id',p.id,'payslip_number',p.payslip_number,'available',true,'employee_name',p.payslip_data#>>'{employee,name}','employee_number',p.payslip_data#>>'{employee,number}','period_start',r.period_start,'period_end',r.period_end,'pay_date',r.pay_date,'currency',p.payslip_data->>'currency','pay',jsonb_build_object('gross',p.payslip_data#>'{pay,gross}','paye',p.payslip_data#>'{pay,paye}','kiwisaver_employee',p.payslip_data#>'{pay,kiwisaver_employee}','student_loan',p.payslip_data#>'{pay,student_loan}','other_deductions',p.payslip_data#>'{pay,other_deductions}','net',p.payslip_data#>'{pay,net}','adjustments',(SELECT coalesce(jsonb_agg(jsonb_build_object('type',x->>'type','description',x->>'description','amount',x->'amount','taxable',x->'taxable')),'[]'::jsonb) FROM jsonb_array_elements(adjustments) x),'work_details',(SELECT coalesce(jsonb_agg(jsonb_build_object('date',x->>'date','job',x->>'job','hours',x->'hours','rate',x->'rate','amount',x->'amount','pay_type',x->>'pay_type')),'[]'::jsonb) FROM jsonb_array_elements(work_details) x))));
END $function$;
REVOKE ALL ON FUNCTION public.v6231_employee_payslips(uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6231_employee_payslips(uuid,uuid,integer) TO authenticated;
