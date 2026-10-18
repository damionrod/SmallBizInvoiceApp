-- Market-only employee self-service. Existing manager approval and pay-run logic remain authoritative.
DO $$ BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only'; END IF;
END $$;

ALTER TABLE public.payroll_employee_portal_links ADD COLUMN timesheets_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.payroll_timesheets
 ADD COLUMN portal_link_id uuid REFERENCES public.payroll_employee_portal_links(id) ON DELETE SET NULL,
 ADD COLUMN portal_revision bigint NOT NULL DEFAULT 1;
CREATE INDEX payroll_timesheets_portal_lookup_idx ON public.payroll_timesheets(portal_link_id,work_date DESC,id DESC) WHERE portal_link_id IS NOT NULL;

CREATE TABLE public.payroll_employee_timesheet_operations(
 id uuid PRIMARY KEY, actor_id uuid NOT NULL, business_id uuid NOT NULL REFERENCES public.businesses(id),
 payload jsonb NOT NULL, result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.payroll_employee_timesheet_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_employee_timesheet_operations FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.v6233_timesheet_revision_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF OLD.portal_link_id IS NOT NULL AND NEW.portal_link_id IS DISTINCT FROM OLD.portal_link_id THEN RAISE EXCEPTION 'Employee timesheet origin cannot be changed' USING ERRCODE='22023'; END IF;
 NEW.portal_revision:=OLD.portal_revision+1;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.v6233_timesheet_revision_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER payroll_timesheets_portal_revision BEFORE UPDATE ON public.payroll_timesheets FOR EACH ROW EXECUTE FUNCTION public.v6233_timesheet_revision_guard();

CREATE OR REPLACE FUNCTION public.v6231_reset_employee_payslip_access() RETURNS trigger
LANGUAGE plpgsql SET search_path TO '' AS $$
BEGIN
 IF NEW.user_id IS DISTINCT FROM OLD.user_id OR NOT NEW.active OR (NOT OLD.active AND NEW.active) THEN
  NEW.payslips_enabled:=false; NEW.timesheets_enabled:=false;
 END IF;
 RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.v6229_leave_manager_read(p_status text DEFAULT 'pending',p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE b uuid:=public.current_business_id();out jsonb;
BEGIN
 IF auth.uid() IS NULL OR b IS NULL OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_read_area(b,'payroll') THEN RAISE EXCEPTION 'Payroll access required' USING ERRCODE='42501';END IF;
 IF p_status IS NULL OR p_status NOT IN ('pending','approved','declined','cancelled','all') OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid request page' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.payroll_employees WHERE business_id=b AND NOT archived)>1000 THEN RAISE EXCEPTION 'Employee access list requires a paged export; no partial list returned';END IF;
 SELECT jsonb_build_object('business_id',b,'can_review',public.v6147_can_write_area(b,'payroll'),'can_link',public.v6147_can_write_area(b,'payroll') AND public.v6147_can_write_area(b,'team'),
 'employees',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'name',concat_ws(' ',e.first_name,e.last_name),'status',e.employment_status,'link_id',l.id,'link_revision',l.revision,'linked_email',u.email,'active',l.active,'payslips_enabled',coalesce(l.payslips_enabled,false),'timesheets_enabled',coalesce(l.timesheets_enabled,false)) ORDER BY e.first_name,e.last_name,e.id) FROM public.payroll_employees e LEFT JOIN public.payroll_employee_portal_links l ON l.employee_id=e.id AND l.business_id=b LEFT JOIN auth.users u ON u.id=l.user_id WHERE e.business_id=b AND NOT e.archived),'[]'::jsonb),
 'requests',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at,s.id) FROM (SELECT r.*,concat_ws(' ',e.first_name,e.last_name) employee_name FROM public.payroll_leave_requests r JOIN public.payroll_employees e ON e.id=r.employee_id WHERE r.business_id=b AND (p_status='all' OR r.status=p_status) ORDER BY r.created_at,r.id LIMIT 100 OFFSET p_offset) s),'[]'::jsonb),
 'total',(SELECT count(*) FROM public.payroll_leave_requests r WHERE r.business_id=b AND (p_status='all' OR r.status=p_status)),'offset',p_offset) INTO out;
 RETURN out;
END $$;

CREATE OR REPLACE FUNCTION public.v6229_employee_leave_read(p_link uuid DEFAULT NULL,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE l public.payroll_employee_portal_links;links jsonb;out jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=auth.uid() AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL AND (banned_until IS NULL OR banned_until<=now())) THEN RAISE EXCEPTION 'A confirmed active account is required' USING ERRCODE='42501';END IF;
 IF p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid request page' USING ERRCODE='22023';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',x.id,'business_name',x.business_name,'employee_name',x.employee_name,'payslips_enabled',x.payslips_enabled,'timesheets_enabled',x.timesheets_enabled) ORDER BY x.business_name,x.id),'[]'::jsonb) INTO links FROM (SELECT a.id,b.name business_name,concat_ws(' ',e.first_name,e.last_name) employee_name,a.payslips_enabled,a.timesheets_enabled FROM public.payroll_employee_portal_links a JOIN public.payroll_employees e ON e.id=a.employee_id AND e.business_id=a.business_id JOIN public.businesses b ON b.id=a.business_id WHERE a.user_id=auth.uid() AND a.active AND NOT e.archived AND e.employment_status IN ('active','on_leave') AND public.v6229_portal_business_active(a.business_id)) x;
 IF p_link IS NULL THEN RETURN jsonb_build_object('links',links,'requests','[]'::jsonb);END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(links) v WHERE v->>'id'=p_link::text) THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link;
 SELECT jsonb_build_object('links',links,'selected',l.id,'leave_types',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name) ORDER BY name,id) FROM public.payroll_leave_types WHERE business_id=l.business_id AND NOT archived),'[]'::jsonb),'requests',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC,s.id) FROM (SELECT id,leave_name,date_from,date_to,quantity,unit,status,revision,decision_note,created_at FROM public.payroll_leave_requests WHERE link_id=l.id AND employee_id=l.employee_id AND business_id=l.business_id ORDER BY created_at DESC,id LIMIT 100 OFFSET p_offset) s),'[]'::jsonb),'total',(SELECT count(*) FROM public.payroll_leave_requests WHERE link_id=l.id AND employee_id=l.employee_id AND business_id=l.business_id),'offset',p_offset) INTO out;
 RETURN out;
END $$;

CREATE FUNCTION public.v6233_set_employee_timesheet_access(p_link uuid,p_enabled boolean,p_expected_revision bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b uuid:=public.current_business_id();l public.payroll_employee_portal_links;e public.payroll_employees;r public.payroll_employee_portal_links;
BEGIN
 IF auth.uid() IS NULL OR b IS NULL OR NOT public.v55_payroll_access(b) OR NOT public.v6147_can_write_area(b,'payroll') OR NOT public.v6147_can_write_area(b,'team') THEN RAISE EXCEPTION 'Owner/admin with Payroll write access required' USING ERRCODE='42501';END IF;
 IF p_link IS NULL OR p_enabled IS NULL OR p_expected_revision IS NULL THEN RAISE EXCEPTION 'Reload employee access before saving' USING ERRCODE='22023';END IF;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link AND business_id=b;
 IF NOT FOUND THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(l.employee_id::text,62290));
 SELECT * INTO e FROM public.payroll_employees WHERE id=l.employee_id AND business_id=b FOR UPDATE;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link AND business_id=b FOR UPDATE;
 IF e.id IS NULL OR l.id IS NULL OR l.revision<>p_expected_revision THEN RAISE EXCEPTION 'Employee access changed. Reload before saving.' USING ERRCODE='40001';END IF;
 IF NOT l.active OR e.archived OR e.employment_status NOT IN ('active','on_leave') THEN RAISE EXCEPTION 'Active employee access is required' USING ERRCODE='22023';END IF;
 IF l.timesheets_enabled=p_enabled THEN RETURN jsonb_build_object('id',l.id,'revision',l.revision,'timesheets_enabled',l.timesheets_enabled);END IF;
 UPDATE public.payroll_employee_portal_links SET timesheets_enabled=p_enabled,revision=revision+1,updated_at=clock_timestamp() WHERE id=l.id RETURNING * INTO r;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(b,'employee_portal_link',r.id,CASE WHEN p_enabled THEN 'timesheets_enabled' ELSE 'timesheets_disabled' END,jsonb_build_object('timesheets_enabled',l.timesheets_enabled),jsonb_build_object('employee_id',e.id,'timesheets_enabled',r.timesheets_enabled),auth.uid());
 RETURN jsonb_build_object('id',r.id,'revision',r.revision,'timesheets_enabled',r.timesheets_enabled);
END $$;

CREATE FUNCTION public.v6233_employee_work_read(p_link uuid,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.payroll_employee_portal_links;
BEGIN
 IF auth.uid() IS NULL OR p_link IS NULL OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid employee work request' USING ERRCODE='22023';END IF;
 SELECT a.* INTO l FROM public.payroll_employee_portal_links a JOIN public.payroll_employees e ON e.id=a.employee_id AND e.business_id=a.business_id WHERE a.id=p_link AND a.user_id=auth.uid() AND a.active AND NOT e.archived AND e.employment_status IN ('active','on_leave') AND public.v6229_portal_business_active(a.business_id);
 IF l.id IS NULL THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('link_id',l.id,'timesheets_enabled',l.timesheets_enabled,
  'balances',coalesce((SELECT jsonb_agg(jsonb_build_object('leave_name',t.name,'balance_hours',b.balance_hours,'quantity',b.statutory_quantity,'unit',b.statutory_unit,'display_hours',b.display_hours,'updated_at',b.updated_at) ORDER BY t.name,t.id) FROM public.payroll_employee_leave b JOIN public.payroll_leave_types t ON t.id=b.leave_type_id AND t.business_id=l.business_id WHERE b.business_id=l.business_id AND b.employee_id=l.employee_id),'[]'::jsonb),
  'leave_history',coalesce((SELECT jsonb_agg(jsonb_build_object('id',x.id,'leave_name',x.leave_name,'date',x.transaction_date,'type',x.transaction_type,'hours',x.hours,'quantity',x.statutory_quantity,'unit',x.statutory_unit,'display_hours',x.display_hours) ORDER BY x.transaction_date DESC,x.id DESC) FROM (SELECT q.*,t.name leave_name FROM public.payroll_leave_transactions q JOIN public.payroll_leave_types t ON t.id=q.leave_type_id AND t.business_id=l.business_id WHERE q.business_id=l.business_id AND q.employee_id=l.employee_id ORDER BY q.transaction_date DESC,q.id DESC LIMIT 100) x),'[]'::jsonb),
  'timesheets',CASE WHEN l.timesheets_enabled THEN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.work_date DESC,x.id DESC) FROM (SELECT id,work_date,start_time,finish_time,break_minutes,total_hours,pay_type,notes,status,portal_revision,created_at,updated_at FROM public.payroll_timesheets WHERE business_id=l.business_id AND employee_id=l.employee_id AND portal_link_id=l.id ORDER BY work_date DESC,id DESC LIMIT 100 OFFSET p_offset) x),'[]'::jsonb) ELSE '[]'::jsonb END,
  'timesheet_total',CASE WHEN l.timesheets_enabled THEN (SELECT count(*) FROM public.payroll_timesheets WHERE business_id=l.business_id AND employee_id=l.employee_id AND portal_link_id=l.id) ELSE 0 END,'offset',p_offset);
END $$;

CREATE FUNCTION public.v6233_employee_timesheet_command(p_link uuid,p_timesheet uuid,p_operation uuid,p_action text,p_expected_revision bigint,p_values jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.payroll_employee_portal_links;e public.payroll_employees;old public.payroll_timesheets;r public.payroll_timesheets;op public.payroll_employee_timesheet_operations;payload jsonb;result jsonb;d date;st time;ft time;br integer;hrs numeric;pt text;n text;
BEGIN
 IF auth.uid() IS NULL OR p_link IS NULL OR p_timesheet IS NULL OR p_operation IS NULL OR p_action NOT IN ('save_draft','submit','delete') OR p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR octet_length(p_values::text)>4000 THEN RAISE EXCEPTION 'Invalid timesheet command' USING ERRCODE='22023';END IF;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link;
 IF l.id IS NULL THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(l.employee_id::text,6233));
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link FOR SHARE;
 SELECT * INTO e FROM public.payroll_employees WHERE id=l.employee_id AND business_id=l.business_id FOR SHARE;
 IF l.user_id IS DISTINCT FROM auth.uid() OR NOT l.active OR NOT l.timesheets_enabled OR e.id IS NULL OR e.archived OR e.employment_status NOT IN ('active','on_leave') OR NOT public.v6229_portal_business_active(l.business_id) THEN RAISE EXCEPTION 'Timesheet access unavailable' USING ERRCODE='42501';END IF;
 payload:=jsonb_build_object('link',p_link,'timesheet',p_timesheet,'action',p_action,'revision',p_expected_revision,'values',p_values);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_operation::text,6233));SELECT * INTO op FROM public.payroll_employee_timesheet_operations WHERE id=p_operation;
 IF FOUND THEN IF op.actor_id<>auth.uid() OR op.business_id<>l.business_id OR op.payload<>payload THEN RAISE EXCEPTION 'Request identifier already used for different input' USING ERRCODE='22023';END IF;RETURN op.result;END IF;
 SELECT * INTO old FROM public.payroll_timesheets WHERE id=p_timesheet AND business_id=l.business_id AND employee_id=l.employee_id AND portal_link_id=l.id FOR UPDATE;
 IF p_action='delete' THEN
  IF old.id IS NULL THEN RAISE EXCEPTION 'Timesheet unavailable' USING ERRCODE='42501';END IF;
  IF old.portal_revision<>p_expected_revision THEN RAISE EXCEPTION 'Timesheet changed. Reload before deleting.' USING ERRCODE='40001';END IF;
  IF old.status NOT IN ('draft','rejected') THEN RAISE EXCEPTION 'Only a draft or rejected timesheet can be deleted' USING ERRCODE='22023';END IF;
  DELETE FROM public.payroll_timesheets WHERE id=old.id;result:=jsonb_build_object('id',old.id,'status','deleted');
 ELSE
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_values) k WHERE k NOT IN ('work_date','start_time','finish_time','break_minutes','pay_type','notes')) THEN RAISE EXCEPTION 'Invalid timesheet fields' USING ERRCODE='22023';END IF;
  BEGIN d:=(p_values->>'work_date')::date;st:=(p_values->>'start_time')::time;ft:=(p_values->>'finish_time')::time;br:=coalesce((p_values->>'break_minutes')::integer,0);EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter valid timesheet details' USING ERRCODE='22023';END;
  pt:=p_values->>'pay_type';n:=nullif(btrim(p_values->>'notes'),'');hrs:=round((extract(epoch FROM (ft-st))/3600-br/60.0)::numeric,2);
  IF d IS NULL OR NOT isfinite(d) OR d<current_date-366 OR d>current_date+31 OR st IS NULL OR ft IS NULL OR ft<=st OR br<0 OR br>720 OR hrs<=0 OR hrs>24 OR pt NOT IN ('ordinary','overtime') OR length(n)>500 THEN RAISE EXCEPTION 'Enter a valid date, start, finish and break. Total hours must be more than zero and no more than 24.' USING ERRCODE='22023';END IF;
  IF old.id IS NULL THEN
   IF p_expected_revision IS NOT NULL THEN RAISE EXCEPTION 'Reload before creating this timesheet' USING ERRCODE='40001';END IF;
   INSERT INTO public.payroll_timesheets(id,business_id,employee_id,work_date,start_time,finish_time,break_minutes,total_hours,pay_type,notes,status,submitted_at,created_by,updated_by,portal_link_id) VALUES(p_timesheet,l.business_id,l.employee_id,d,st,ft,br,hrs,pt,n,CASE WHEN p_action='submit' THEN 'submitted' ELSE 'draft' END,CASE WHEN p_action='submit' THEN clock_timestamp() END,auth.uid(),auth.uid(),l.id) RETURNING * INTO r;
  ELSE
   IF old.portal_revision<>p_expected_revision THEN RAISE EXCEPTION 'Timesheet changed. Reload before saving.' USING ERRCODE='40001';END IF;
   IF old.status NOT IN ('draft','rejected') THEN RAISE EXCEPTION 'Only a draft or rejected timesheet can be changed' USING ERRCODE='22023';END IF;
   UPDATE public.payroll_timesheets SET work_date=d,start_time=st,finish_time=ft,break_minutes=br,total_hours=hrs,pay_type=pt,notes=n,status=CASE WHEN p_action='submit' THEN 'submitted' ELSE 'draft' END,submitted_at=CASE WHEN p_action='submit' THEN clock_timestamp() ELSE NULL END,approved_at=NULL,approved_by=NULL,updated_at=clock_timestamp(),updated_by=auth.uid() WHERE id=old.id RETURNING * INTO r;
  END IF;
  result:=jsonb_build_object('id',r.id,'status',r.status,'revision',r.portal_revision,'total_hours',r.total_hours);
 END IF;
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(l.business_id,'employee_timesheet',p_timesheet,p_action,jsonb_build_object('status',old.status,'revision',old.portal_revision),result,auth.uid());
 INSERT INTO public.payroll_employee_timesheet_operations(id,actor_id,business_id,payload,result) VALUES(p_operation,auth.uid(),l.business_id,payload,result);
 RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.v6233_set_employee_timesheet_access(uuid,boolean,bigint),public.v6233_employee_work_read(uuid,integer),public.v6233_employee_timesheet_command(uuid,uuid,uuid,text,bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6233_set_employee_timesheet_access(uuid,boolean,bigint),public.v6233_employee_work_read(uuid,integer),public.v6233_employee_timesheet_command(uuid,uuid,uuid,text,bigint,jsonb) TO authenticated;
