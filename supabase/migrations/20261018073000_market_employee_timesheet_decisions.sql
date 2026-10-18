-- v62.34 Market: atomic manager decisions for employee-submitted timesheets.
ALTER TABLE public.payroll_timesheets
 ADD COLUMN decision_note text,
 ADD COLUMN decided_at timestamptz,
 ADD COLUMN decided_by uuid REFERENCES auth.users(id);

CREATE TABLE public.payroll_timesheet_decision_operations(
 id uuid PRIMARY KEY,
 actor_id uuid NOT NULL REFERENCES auth.users(id),
 business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
 payload jsonb NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.payroll_timesheet_decision_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_timesheet_decision_operations FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.v6234_portal_timesheet_decision_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF OLD.portal_link_id IS NOT NULL AND OLD.status='submitted' AND
   (NEW.status IS DISTINCT FROM OLD.status OR NEW.employee_id IS DISTINCT FROM OLD.employee_id OR
    NEW.business_id IS DISTINCT FROM OLD.business_id OR NEW.work_date IS DISTINCT FROM OLD.work_date OR
    NEW.start_time IS DISTINCT FROM OLD.start_time OR NEW.finish_time IS DISTINCT FROM OLD.finish_time OR
    NEW.break_minutes IS DISTINCT FROM OLD.break_minutes OR NEW.total_hours IS DISTINCT FROM OLD.total_hours OR
    NEW.pay_type IS DISTINCT FROM OLD.pay_type OR NEW.notes IS DISTINCT FROM OLD.notes OR
    NEW.job_costing_id IS DISTINCT FROM OLD.job_costing_id OR NEW.customer_id IS DISTINCT FROM OLD.customer_id) AND
   current_setting('frindly.v6234_timesheet_decision',true) IS DISTINCT FROM OLD.id::text THEN
  RAISE EXCEPTION 'Use the timesheet review action for employee submissions' USING ERRCODE='42501';
 END IF;
 IF OLD.portal_link_id IS NOT NULL AND OLD.status='rejected' AND NEW.status IN ('draft','submitted') THEN
  NEW.decision_note:=NULL;NEW.decided_at:=NULL;NEW.decided_by:=NULL;NEW.approved_at:=NULL;NEW.approved_by:=NULL;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.v6234_portal_timesheet_decision_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER payroll_portal_timesheet_decision_guard BEFORE UPDATE ON public.payroll_timesheets
 FOR EACH ROW EXECUTE FUNCTION public.v6234_portal_timesheet_decision_guard();

CREATE FUNCTION public.v6234_decide_employee_timesheets(p_timesheet_ids uuid[],p_action text,p_reason text,p_operation uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=auth.uid();bid uuid:=public.current_business_id();ids uuid[];n integer;note text:=nullif(btrim(p_reason),'');op public.payroll_timesheet_decision_operations;payload jsonb;result jsonb;r record;
BEGIN
 IF actor IS NULL OR bid IS NULL OR p_operation IS NULL OR p_action NOT IN ('approve','reject') OR p_timesheet_ids IS NULL THEN RAISE EXCEPTION 'Invalid timesheet decision' USING ERRCODE='22023';END IF;
 IF NOT public.v55_payroll_access(bid) OR NOT public.v6147_can_write_area(bid,'payroll') THEN RAISE EXCEPTION 'Payroll write access required' USING ERRCODE='42501';END IF;
 SELECT array_agg(x ORDER BY x),count(*) INTO ids,n FROM (SELECT DISTINCT unnest(p_timesheet_ids) x) s;
 IF n IS NULL OR n<1 OR n>100 OR n<>coalesce(array_length(p_timesheet_ids,1),0) THEN RAISE EXCEPTION 'Choose between 1 and 100 distinct timesheets' USING ERRCODE='22023';END IF;
 IF length(note)>500 OR (p_action='reject' AND note IS NULL) OR (p_action='approve' AND note IS NOT NULL) THEN RAISE EXCEPTION 'Sending a timesheet back needs a short explanation (up to 500 characters)' USING ERRCODE='22023';END IF;
 payload:=jsonb_build_object('ids',to_jsonb(ids),'action',p_action,'reason',note);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_operation::text,6234));
 SELECT * INTO op FROM public.payroll_timesheet_decision_operations WHERE id=p_operation;
 IF FOUND THEN
  IF op.actor_id IS DISTINCT FROM actor OR op.business_id IS DISTINCT FROM bid OR op.payload<>payload THEN RAISE EXCEPTION 'Decision identifier already used for different input' USING ERRCODE='22023';END IF;
  RETURN op.result;
 END IF;
 PERFORM 1 FROM public.payroll_timesheets t WHERE t.id=ANY(ids) ORDER BY t.id FOR UPDATE;
 IF (SELECT count(*) FROM public.payroll_timesheets t WHERE t.id=ANY(ids) AND t.business_id=bid AND t.portal_link_id IS NOT NULL AND t.status='submitted')<>n THEN RAISE EXCEPTION 'One or more employee timesheets changed. Reload before deciding.' USING ERRCODE='40001';END IF;
 IF EXISTS(SELECT 1 FROM public.payroll_timesheets t JOIN public.payroll_employee_portal_links l ON l.id=t.portal_link_id WHERE t.id=ANY(ids) AND l.user_id=actor) THEN RAISE EXCEPTION 'Another payroll manager must review your own timesheet' USING ERRCODE='42501';END IF;
 FOR r IN SELECT t.* FROM public.payroll_timesheets t WHERE t.id=ANY(ids) ORDER BY t.id LOOP
  PERFORM set_config('frindly.v6234_timesheet_decision',r.id::text,true);
  UPDATE public.payroll_timesheets SET status=CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END,
   approved_at=CASE WHEN p_action='approve' THEN clock_timestamp() ELSE NULL END,
   approved_by=CASE WHEN p_action='approve' THEN actor ELSE NULL END,
   decision_note=note,decided_at=clock_timestamp(),decided_by=actor,
   updated_at=clock_timestamp(),updated_by=actor WHERE id=r.id;
  INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by)
   VALUES(bid,'timesheet',r.id,CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END,
    jsonb_build_object('status',r.status,'portal_revision',r.portal_revision),
    jsonb_build_object('status',CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END,'reason',note),actor);
 END LOOP;
 result:=jsonb_build_object('action',p_action,'count',n,'ids',to_jsonb(ids));
 INSERT INTO public.payroll_timesheet_decision_operations(id,actor_id,business_id,payload,result) VALUES(p_operation,actor,bid,payload,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.v6234_decide_employee_timesheets(uuid[],text,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6234_decide_employee_timesheets(uuid[],text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.v6233_employee_work_read(p_link uuid,p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.payroll_employee_portal_links;
BEGIN
 IF auth.uid() IS NULL OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid employee work request' USING ERRCODE='22023';END IF;
 SELECT * INTO l FROM public.payroll_employee_portal_links WHERE id=p_link;
 IF NOT FOUND OR l.user_id IS DISTINCT FROM auth.uid() OR NOT l.active OR NOT public.v6229_portal_business_active(l.business_id) OR NOT EXISTS(SELECT 1 FROM public.payroll_employees e WHERE e.id=l.employee_id AND e.business_id=l.business_id AND NOT e.archived AND e.employment_status IN ('active','on_leave')) THEN RAISE EXCEPTION 'Employee access unavailable' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('link_id',l.id,'timesheets_enabled',l.timesheets_enabled,
  'balances',coalesce((SELECT jsonb_agg(jsonb_build_object('leave_name',t.name,'balance_hours',b.balance_hours,'quantity',b.statutory_quantity,'unit',b.statutory_unit,'display_hours',b.display_hours,'updated_at',b.updated_at) ORDER BY t.name,t.id) FROM public.payroll_employee_leave b JOIN public.payroll_leave_types t ON t.id=b.leave_type_id AND t.business_id=l.business_id WHERE b.business_id=l.business_id AND b.employee_id=l.employee_id),'[]'::jsonb),
  'leave_history',coalesce((SELECT jsonb_agg(jsonb_build_object('id',x.id,'leave_name',x.leave_name,'date',x.transaction_date,'type',x.transaction_type,'hours',x.hours,'quantity',x.statutory_quantity,'unit',x.statutory_unit,'display_hours',x.display_hours) ORDER BY x.transaction_date DESC,x.id DESC) FROM (SELECT q.*,t.name leave_name FROM public.payroll_leave_transactions q JOIN public.payroll_leave_types t ON t.id=q.leave_type_id AND t.business_id=l.business_id WHERE q.business_id=l.business_id AND q.employee_id=l.employee_id ORDER BY q.transaction_date DESC,q.id DESC LIMIT 100) x),'[]'::jsonb),
  'timesheets',CASE WHEN l.timesheets_enabled THEN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.work_date DESC,x.id DESC) FROM (SELECT id,work_date,start_time,finish_time,break_minutes,total_hours,pay_type,notes,status,portal_revision,decision_note,decided_at,created_at,updated_at FROM public.payroll_timesheets WHERE business_id=l.business_id AND employee_id=l.employee_id AND portal_link_id=l.id ORDER BY work_date DESC,id DESC LIMIT 100 OFFSET p_offset) x),'[]'::jsonb) ELSE '[]'::jsonb END,
  'timesheet_total',CASE WHEN l.timesheets_enabled THEN (SELECT count(*) FROM public.payroll_timesheets WHERE business_id=l.business_id AND employee_id=l.employee_id AND portal_link_id=l.id) ELSE 0 END,'offset',p_offset);
END $$;
REVOKE ALL ON FUNCTION public.v6233_employee_work_read(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6233_employee_work_read(uuid,integer) TO authenticated;
