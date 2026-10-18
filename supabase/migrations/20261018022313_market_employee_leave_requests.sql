-- Market only. No existing membership, payroll or entitlement is modified.
DO $$ BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only'; END IF;
END $$;
CREATE TABLE public.payroll_employee_portal_links (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), business_id uuid NOT NULL REFERENCES public.businesses(id),
 employee_id uuid NOT NULL UNIQUE REFERENCES public.payroll_employees(id),
 user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL, active boolean NOT NULL DEFAULT true,
 revision bigint NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(business_id,user_id)
);
CREATE TABLE public.payroll_leave_requests (
 id uuid PRIMARY KEY, business_id uuid NOT NULL REFERENCES public.businesses(id),
 link_id uuid NOT NULL REFERENCES public.payroll_employee_portal_links(id), employee_id uuid NOT NULL REFERENCES public.payroll_employees(id),
 requested_by uuid NOT NULL, leave_type_id uuid NOT NULL REFERENCES public.payroll_leave_types(id), leave_name text NOT NULL,
 date_from date NOT NULL, date_to date NOT NULL, quantity numeric(8,2) NOT NULL CHECK(quantity>0 AND quantity<=10000),
 unit text NOT NULL CHECK(unit IN ('hours','days','weeks')), status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','declined','cancelled')),
 revision bigint NOT NULL DEFAULT 1, decided_by uuid, decision_note text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(isfinite(date_from) AND isfinite(date_to) AND date_from>='1900-01-01' AND date_to<='2100-12-31' AND date_to>=date_from AND date_to-date_from<=366)
);
CREATE INDEX payroll_leave_requests_employee_dates ON public.payroll_leave_requests(employee_id,date_from,date_to) WHERE status IN ('pending','approved');
CREATE INDEX payroll_leave_requests_business_status ON public.payroll_leave_requests(business_id,status,created_at DESC,id);
CREATE TABLE public.payroll_leave_request_operations (
 id uuid PRIMARY KEY, actor_id uuid NOT NULL, business_id uuid NOT NULL REFERENCES public.businesses(id),
 payload jsonb NOT NULL, result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.payroll_employee_portal_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_leave_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_leave_request_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_employee_portal_links,public.payroll_leave_requests,public.payroll_leave_request_operations FROM PUBLIC,anon,authenticated;
-- Deliberately no raw-table grants/policies. Narrow authenticated commands return allowlisted fields.
CREATE FUNCTION public.v6229_portal_business_active(p_business_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=p_business_id AND b.status='active')
 AND EXISTS(SELECT 1 FROM public.modules WHERE slug='payroll' AND is_active)
 AND NOT EXISTS(SELECT 1 FROM public.business_modules bm JOIN public.modules m ON m.id=bm.module_id WHERE bm.business_id=p_business_id AND m.slug='payroll' AND bm.status IN ('suspended','canceled'))
 AND (EXISTS(SELECT 1 FROM public.business_modules bm JOIN public.modules m ON m.id=bm.module_id WHERE bm.business_id=p_business_id AND m.slug='payroll' AND (bm.status='active' OR (bm.status='trialing' AND (bm.trial_ends_at IS NULL OR bm.trial_ends_at>now()))))
 OR EXISTS(SELECT 1 FROM public.subscriptions s JOIN public.plans p ON p.id=s.plan_id WHERE s.business_id=p_business_id AND 'payroll'=ANY(p.included_modules)
 AND (s.status='active' OR (s.status='trialing' AND (s.trial_ends_at IS NULL OR s.trial_ends_at>now()))) AND (s.cancel_at IS NULL OR s.cancel_at>now()) AND (NOT coalesce(s.cancel_at_period_end,false) OR s.current_period_end IS NULL OR s.current_period_end>now())));
$$;
REVOKE ALL ON FUNCTION public.v6229_portal_business_active(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.v6229_leave_manager_read(p_status text DEFAULT 'pending',p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE b uuid:=public.current_business_id();out jsonb;
BEGIN
 IF auth.uid() IS NULL OR b IS NULL OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_read_area(b,'payroll') THEN RAISE EXCEPTION 'Payroll access required' USING ERRCODE='42501';END IF;
 IF p_status IS NULL OR p_status NOT IN ('pending','approved','declined','cancelled','all') OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid request page' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.payroll_employees WHERE business_id=b AND NOT archived)>1000 THEN RAISE EXCEPTION 'Employee access list requires a paged export; no partial list returned';END IF;
 SELECT jsonb_build_object('business_id',b,'can_review',public.v6147_can_write_area(b,'payroll'),
 'can_link',public.v6147_can_write_area(b,'payroll') AND public.v6147_can_write_area(b,'team'),
 'employees',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'name',concat_ws(' ',e.first_name,e.last_name),'status',e.employment_status,'link_id',l.id,'link_revision',l.revision,'linked_email',u.email,'active',l.active) ORDER BY e.first_name,e.last_name,e.id) FROM public.payroll_employees e LEFT JOIN public.payroll_employee_portal_links l ON l.employee_id=e.id AND l.business_id=b LEFT JOIN auth.users u ON u.id=l.user_id WHERE e.business_id=b AND NOT e.archived),'[]'::jsonb),
 'requests',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at,s.id) FROM (SELECT r.*,concat_ws(' ',e.first_name,e.last_name) employee_name FROM public.payroll_leave_requests r JOIN public.payroll_employees e ON e.id=r.employee_id WHERE r.business_id=b AND (p_status='all' OR r.status=p_status) ORDER BY r.created_at,r.id LIMIT 100 OFFSET p_offset) s),'[]'::jsonb),
 'total',(SELECT count(*) FROM public.payroll_leave_requests r WHERE r.business_id=b AND (p_status='all' OR r.status=p_status)), 'offset',p_offset) INTO out;
 RETURN out;
END $$;

CREATE FUNCTION public.v6229_set_employee_portal_link(p_employee uuid,p_email text,p_active boolean,p_expected_revision bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b uuid:=public.current_business_id();e public.payroll_employees;old public.payroll_employee_portal_links;r public.payroll_employee_portal_links;u uuid;target_email text;
BEGIN
 IF auth.uid() IS NULL OR b IS NULL OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_write_area(b,'payroll') OR NOT public.v6147_can_write_area(b,'team') THEN RAISE EXCEPTION 'Owner/admin with Payroll write access required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_employee::text,62290));
 SELECT * INTO e FROM public.payroll_employees WHERE id=p_employee AND business_id=b FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Employee unavailable' USING ERRCODE='42501';END IF;
 IF p_active IS NULL THEN RAISE EXCEPTION 'Choose access status' USING ERRCODE='22023';END IF;
 SELECT * INTO old FROM public.payroll_employee_portal_links WHERE employee_id=e.id FOR UPDATE;
 -- A lost response may be retried with the same intended state. Do not silently replace a different link.
 target_email:=lower(btrim(coalesce(p_email,'')));
 IF old.id IS NOT NULL AND old.active=p_active AND (NOT p_active OR EXISTS(SELECT 1 FROM auth.users WHERE id=old.user_id AND lower(auth.users.email)=target_email AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL AND (banned_until IS NULL OR banned_until<=now()))) THEN RETURN jsonb_build_object('id',old.id,'revision',old.revision,'active',old.active);END IF;
 IF old.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'Employee access changed. Reload before saving.' USING ERRCODE='40001';END IF;
 IF p_active THEN
  IF e.archived OR e.employment_status NOT IN ('active','on_leave') THEN RAISE EXCEPTION 'Activate the employee before linking access' USING ERRCODE='22023';END IF;
  SELECT id INTO u FROM auth.users a WHERE lower(a.email)=target_email AND a.email_confirmed_at IS NOT NULL AND a.deleted_at IS NULL AND (a.banned_until IS NULL OR a.banned_until<=now());
  IF u IS NULL OR target_email='' THEN RAISE EXCEPTION 'A confirmed existing account with that exact email is required' USING ERRCODE='22023';END IF;
 ELSE
  IF old.id IS NULL THEN RAISE EXCEPTION 'No access link exists' USING ERRCODE='22023';END IF;u:=old.user_id;
 END IF;
 INSERT INTO public.payroll_employee_portal_links(business_id,employee_id,user_id,active) VALUES(b,e.id,u,p_active)
 ON CONFLICT(employee_id) DO UPDATE SET user_id=excluded.user_id,active=excluded.active,revision=payroll_employee_portal_links.revision+1,updated_at=clock_timestamp() RETURNING * INTO r;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(b,'employee_portal_link',r.id,CASE WHEN p_active THEN 'linked' ELSE 'revoked' END,jsonb_build_object('user_id',old.user_id,'active',old.active),jsonb_build_object('employee_id',e.id,'user_id',u,'active',p_active),auth.uid());
 RETURN jsonb_build_object('id',r.id,'revision',r.revision,'active',r.active);
END $$;

CREATE FUNCTION public.v6229_employee_leave_read(p_link uuid DEFAULT NULL,p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.payroll_employee_portal_links;links jsonb;out jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=auth.uid() AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL AND (banned_until IS NULL OR banned_until<=now())) THEN RAISE EXCEPTION 'A confirmed active account is required' USING ERRCODE='42501';END IF;
 IF p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid request page' USING ERRCODE='22023';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',x.id,'business_name',x.business_name,'employee_name',x.employee_name) ORDER BY x.business_name,x.id),'[]'::jsonb) INTO links FROM (SELECT a.id,b.name business_name,concat_ws(' ',e.first_name,e.last_name) employee_name FROM public.payroll_employee_portal_links a JOIN public.payroll_employees e ON e.id=a.employee_id AND e.business_id=a.business_id JOIN public.businesses b ON b.id=a.business_id WHERE a.user_id=auth.uid() AND a.active AND NOT e.archived AND e.employment_status IN ('active','on_leave') AND public.v6229_portal_business_active(a.business_id)) x;
 IF p_link IS NULL THEN RETURN jsonb_build_object('links',links,'requests','[]'::jsonb);END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(links) v WHERE v->>'id'=p_link::text) THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link;
 SELECT jsonb_build_object('links',links,'selected',l.id,'leave_types',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name) ORDER BY name,id) FROM public.payroll_leave_types WHERE business_id=l.business_id AND NOT archived),'[]'::jsonb),
 'requests',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC,s.id) FROM (SELECT id,leave_name,date_from,date_to,quantity,unit,status,revision,decision_note,created_at FROM public.payroll_leave_requests WHERE link_id=l.id AND employee_id=l.employee_id AND business_id=l.business_id ORDER BY created_at DESC,id LIMIT 100 OFFSET p_offset) s),'[]'::jsonb),
 'total',(SELECT count(*) FROM public.payroll_leave_requests WHERE link_id=l.id AND employee_id=l.employee_id AND business_id=l.business_id),'offset',p_offset) INTO out;
 RETURN out;
END $$;

CREATE FUNCTION public.v6229_leave_request_command(p_link uuid,p_request uuid,p_operation uuid,p_action text,p_expected_revision bigint,p_values jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.payroll_employee_portal_links;e public.payroll_employees;old public.payroll_leave_requests;r public.payroll_leave_requests;op public.payroll_leave_request_operations;payload jsonb;result jsonb;d1 date;d2 date;q numeric;unit text;lt public.payroll_leave_types;note text;manager boolean;
BEGIN
 IF auth.uid() IS NULL OR p_operation IS NULL OR p_link IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'Authenticated request required' USING ERRCODE='42501';END IF;
 IF p_action IS NULL OR p_action NOT IN ('create','cancel','approve','decline') OR p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR octet_length(p_values::text)>4000 THEN RAISE EXCEPTION 'Invalid leave command' USING ERRCODE='22023';END IF;
 -- Common employee lock serialises linking/revocation, overlap checks and decisions.
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link;
 IF NOT FOUND THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(l.employee_id::text,62290));
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO e FROM public.payroll_employees WHERE id=l.employee_id AND business_id=l.business_id FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Employee unavailable' USING ERRCODE='42501';END IF;
 manager:=p_action IN ('approve','decline');
 IF manager THEN
  IF l.business_id IS DISTINCT FROM public.current_business_id() OR NOT public.v55_payroll_access(l.business_id) OR NOT public.v6147_can_write_area(l.business_id,'payroll') THEN RAISE EXCEPTION 'Payroll write access required' USING ERRCODE='42501';END IF;
 ELSE
  IF l.user_id IS DISTINCT FROM auth.uid() OR NOT l.active OR e.archived OR e.employment_status NOT IN ('active','on_leave') OR NOT public.v6229_portal_business_active(l.business_id) OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=auth.uid() AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL AND (banned_until IS NULL OR banned_until<=now())) THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 END IF;
 payload:=jsonb_build_object('link',p_link,'request',p_request,'action',p_action,'revision',p_expected_revision,'values',p_values);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_operation::text,6229));
 SELECT * INTO op FROM public.payroll_leave_request_operations WHERE id=p_operation;
 IF FOUND THEN
  IF op.actor_id IS DISTINCT FROM auth.uid() OR op.business_id<>l.business_id OR op.payload<>payload THEN RAISE EXCEPTION 'Request identifier already used for different input' USING ERRCODE='22023';END IF;
  RETURN op.result;
 END IF;
 IF p_action='create' THEN
  IF p_expected_revision IS NOT NULL OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_values) k WHERE k NOT IN ('leave_type_id','date_from','date_to','quantity','unit')) THEN RAISE EXCEPTION 'Invalid request fields' USING ERRCODE='22023';END IF;
  BEGIN
   d1:=(p_values->>'date_from')::date;d2:=(p_values->>'date_to')::date;q:=(p_values->>'quantity')::numeric;unit:=p_values->>'unit';
   SELECT * INTO lt FROM public.payroll_leave_types WHERE id=(p_values->>'leave_type_id')::uuid AND business_id=l.business_id AND NOT archived;
  EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow OR numeric_value_out_of_range THEN RAISE EXCEPTION 'Invalid leave dates or quantity' USING ERRCODE='22023';END;
  IF lt.id IS NULL OR d1 IS NULL OR d2 IS NULL OR NOT isfinite(d1) OR NOT isfinite(d2) OR d1<'1900-01-01' OR d2>'2100-12-31' OR d2<d1 OR d2-d1>366 OR q IS NULL OR q::text IN ('NaN','Infinity','-Infinity') OR q<=0 OR q>10000 OR round(q,2)<>q OR unit IS NULL OR unit NOT IN ('hours','days','weeks') THEN RAISE EXCEPTION 'Choose valid leave, dates and a positive quantity with at most two decimals' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT 1 FROM public.payroll_leave_requests WHERE employee_id=e.id AND status IN ('pending','approved') AND date_from<=d2 AND date_to>=d1) THEN RAISE EXCEPTION 'An overlapping pending or approved leave request already exists. Ask your manager to review it.' USING ERRCODE='23505';END IF;
  INSERT INTO public.payroll_leave_requests(id,business_id,link_id,employee_id,requested_by,leave_type_id,leave_name,date_from,date_to,quantity,unit) VALUES(p_request,l.business_id,l.id,e.id,auth.uid(),lt.id,lt.name,d1,d2,q,unit) RETURNING * INTO r;
 ELSE
  SELECT * INTO old FROM public.payroll_leave_requests WHERE id=p_request AND link_id=l.id AND business_id=l.business_id AND employee_id=e.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
  IF old.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'Request changed. Reload before deciding.' USING ERRCODE='40001';END IF;
  IF old.status<>'pending' THEN RAISE EXCEPTION 'Only a pending request can be changed' USING ERRCODE='22023';END IF;
  IF manager AND (old.requested_by=auth.uid() OR l.user_id=auth.uid()) THEN RAISE EXCEPTION 'Another payroll manager must review your own request' USING ERRCODE='42501';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_values) k WHERE k<>'note') THEN RAISE EXCEPTION 'Invalid decision fields' USING ERRCODE='22023';END IF;
  note:=nullif(btrim(p_values->>'note'),'');
  IF length(note)>500 OR (p_action='decline' AND note IS NULL) OR (p_action='cancel' AND note IS NOT NULL) THEN RAISE EXCEPTION 'A decline needs a short explanation (up to 500 characters)' USING ERRCODE='22023';END IF;
  IF p_action='approve' AND (NOT l.active OR e.archived OR e.employment_status NOT IN ('active','on_leave')) THEN RAISE EXCEPTION 'Employee access is inactive. Review this request before approving.' USING ERRCODE='22023';END IF;
  UPDATE public.payroll_leave_requests SET status=CASE p_action WHEN 'cancel' THEN 'cancelled' WHEN 'approve' THEN 'approved' ELSE 'declined' END,revision=revision+1,decided_by=CASE WHEN manager THEN auth.uid() ELSE NULL END,decision_note=CASE WHEN manager THEN note ELSE NULL END,updated_at=clock_timestamp() WHERE id=old.id RETURNING * INTO r;
 END IF;
 -- No entitlement, leave transaction, payslip or journal is written by this workflow.
 result:=jsonb_build_object('id',r.id,'business_id',r.business_id,'status',r.status,'revision',r.revision);
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(l.business_id,'leave_request',r.id,p_action,jsonb_build_object('status',old.status,'revision',old.revision),result,auth.uid());
 INSERT INTO public.payroll_leave_request_operations(id,actor_id,business_id,payload,result) VALUES(p_operation,auth.uid(),l.business_id,payload,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.v6229_leave_manager_read(text,integer),public.v6229_set_employee_portal_link(uuid,text,boolean,bigint),public.v6229_employee_leave_read(uuid,integer),public.v6229_leave_request_command(uuid,uuid,uuid,text,bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6229_leave_manager_read(text,integer),public.v6229_set_employee_portal_link(uuid,text,boolean,bigint),public.v6229_employee_leave_read(uuid,integer),public.v6229_leave_request_command(uuid,uuid,uuid,text,bigint,jsonb) TO authenticated;
