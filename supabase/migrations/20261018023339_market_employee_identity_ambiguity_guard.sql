-- Reject ambiguous confirmed identities, including possible SSO/email-case duplicates.
CREATE OR REPLACE FUNCTION public.v6229_set_employee_portal_link(p_employee uuid,p_email text,p_active boolean,p_expected_revision bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b uuid:=public.current_business_id();e public.payroll_employees;old public.payroll_employee_portal_links;r public.payroll_employee_portal_links;u uuid;candidates uuid[];target_email text;
BEGIN
 IF auth.uid() IS NULL OR b IS NULL OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_write_area(b,'payroll') OR NOT public.v6147_can_write_area(b,'team') THEN RAISE EXCEPTION 'Owner/admin with Payroll write access required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_employee::text,62290));
 SELECT * INTO e FROM public.payroll_employees WHERE id=p_employee AND business_id=b FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Employee unavailable' USING ERRCODE='42501';END IF;
 IF p_active IS NULL THEN RAISE EXCEPTION 'Choose access status' USING ERRCODE='22023';END IF;
 SELECT * INTO old FROM public.payroll_employee_portal_links WHERE employee_id=e.id FOR UPDATE;
 IF NOT public.v55_payroll_access(b) OR NOT public.v6147_can_write_area(b,'payroll') OR NOT public.v6147_can_write_area(b,'team') OR b IS DISTINCT FROM public.current_business_id() THEN RAISE EXCEPTION 'Access changed while waiting. Reload before saving.' USING ERRCODE='42501';END IF;
 -- A lost response may be retried with the same intended state. Do not silently replace a different link.
 target_email:=lower(btrim(coalesce(p_email,'')));
 IF old.id IS NOT NULL AND old.active=p_active AND (NOT p_active OR EXISTS(SELECT 1 FROM auth.users WHERE id=old.user_id AND lower(auth.users.email)=target_email AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL AND (banned_until IS NULL OR banned_until<=now()))) THEN RETURN jsonb_build_object('id',old.id,'revision',old.revision,'active',old.active);END IF;
 IF old.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'Employee access changed. Reload before saving.' USING ERRCODE='40001';END IF;
 IF p_active THEN
  IF e.archived OR e.employment_status NOT IN ('active','on_leave') THEN RAISE EXCEPTION 'Activate the employee before linking access' USING ERRCODE='22023';END IF;
  SELECT array_agg(a.id) INTO candidates FROM auth.users a WHERE lower(a.email)=target_email AND a.email_confirmed_at IS NOT NULL AND a.deleted_at IS NULL AND (a.banned_until IS NULL OR a.banned_until<=now());
  IF cardinality(candidates) IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'Exactly one confirmed active account must match that email. Contact support to resolve duplicate identities.' USING ERRCODE='22023';END IF;
  u:=candidates[1];
  IF u IS NULL OR target_email='' THEN RAISE EXCEPTION 'A confirmed existing account with that exact email is required' USING ERRCODE='22023';END IF;
 ELSE
  IF old.id IS NULL THEN RAISE EXCEPTION 'No access link exists' USING ERRCODE='22023';END IF;u:=old.user_id;
 END IF;
 INSERT INTO public.payroll_employee_portal_links(business_id,employee_id,user_id,active) VALUES(b,e.id,u,p_active)
 ON CONFLICT(employee_id) DO UPDATE SET user_id=excluded.user_id,active=excluded.active,revision=payroll_employee_portal_links.revision+1,updated_at=clock_timestamp() RETURNING * INTO r;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(b,'employee_portal_link',r.id,CASE WHEN p_active THEN 'linked' ELSE 'revoked' END,jsonb_build_object('user_id',old.user_id,'active',old.active),jsonb_build_object('employee_id',e.id,'user_id',u,'active',p_active),auth.uid());
 RETURN jsonb_build_object('id',r.id,'revision',r.revision,'active',r.active);
END $$;

