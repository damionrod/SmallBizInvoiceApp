-- Market rollout. One transaction owns the hours ledger, balance and audit.
CREATE TABLE public.payroll_leave_operations (
 id uuid PRIMARY KEY,
 business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
 employee_id uuid NOT NULL REFERENCES public.payroll_employees(id) ON DELETE RESTRICT,
 actor_id uuid NOT NULL,
 request jsonb NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.payroll_leave_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_leave_operations FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.payroll_leave_operations TO authenticated;
CREATE POLICY payroll_leave_operations_read ON public.payroll_leave_operations FOR SELECT TO authenticated
 USING(business_id=public.current_business_id() AND public.v6147_can_write_area(business_id,'payroll'));
CREATE INDEX payroll_leave_operations_employee ON public.payroll_leave_operations(business_id,employee_id,created_at DESC);

CREATE FUNCTION public.v6226_apply_leave_hours(p_employee uuid,p_request uuid,p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE bid uuid:=public.current_business_id();actor uuid:=auth.uid(); prior public.payroll_leave_operations%ROWTYPE;
 item jsonb;bal public.payroll_employee_leave%ROWTYPE; lt uuid; mode text;kind text;quantity numeric;next_balance numeric;delta numeric;day date;note text;tx uuid; result jsonb:='[]';old_data jsonb;
BEGIN
 IF actor IS NULL OR bid IS NULL OR NOT public.v6147_can_write_area(bid,'payroll') THEN RAISE EXCEPTION 'Payroll write access is required.' USING ERRCODE='42501';END IF;
 IF p_request IS NULL OR p_employee IS NULL OR jsonb_typeof(p_changes) IS DISTINCT FROM 'array' OR jsonb_array_length(p_changes) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Choose valid leave changes.' USING ERRCODE='22023';END IF;
 -- Every new hours operation locks the employee before reading balances.
 PERFORM 1 FROM public.payroll_employees WHERE id=p_employee AND business_id=bid AND NOT archived FOR UPDATE;
 IF NOT FOUND OR bid IS DISTINCT FROM public.current_business_id() OR NOT public.v6147_can_write_area(bid,'payroll') THEN RAISE EXCEPTION 'Employee is unavailable or Payroll access changed.' USING ERRCODE='42501';END IF;
 SELECT * INTO prior FROM public.payroll_leave_operations WHERE id=p_request;
 IF FOUND THEN
  IF prior.business_id<>bid OR prior.employee_id<>p_employee OR prior.actor_id<>actor OR prior.request IS DISTINCT FROM p_changes THEN RAISE EXCEPTION 'This save identifier was already used for another change.' USING ERRCODE='22023';END IF;
  RETURN prior.result;
 END IF;
 IF (SELECT count(DISTINCT x->>'leave_type_id') FROM jsonb_array_elements(p_changes)x)<>jsonb_array_length(p_changes) THEN RAISE EXCEPTION 'Review each leave type once per save.' USING ERRCODE='22023';END IF;
 FOR item IN SELECT x FROM jsonb_array_elements(p_changes)x ORDER BY x->>'leave_type_id' LOOP
  lt:=(item->>'leave_type_id')::uuid;mode:=item->>'mode';kind:=item->>'type';
  IF mode IS NULL OR mode NOT IN ('entry','balance') THEN RAISE EXCEPTION 'Invalid leave change.' USING ERRCODE='22023';END IF;
  PERFORM 1 FROM public.payroll_leave_types WHERE id=lt AND business_id=bid AND NOT archived;
  IF NOT FOUND THEN RAISE EXCEPTION 'Leave type is unavailable in this business.' USING ERRCODE='42501';END IF;
  SELECT * INTO bal FROM public.payroll_employee_leave WHERE employee_id=p_employee AND leave_type_id=lt AND business_id=bid FOR UPDATE;
  old_data:=CASE WHEN FOUND THEN to_jsonb(bal) ELSE NULL END;
  IF bal.statutory_quantity IS NOT NULL OR bal.statutory_unit IS NOT NULL OR bal.statutory_leave_code IS NOT NULL THEN RAISE EXCEPTION 'Use the statutory leave workflow for this entitlement; an hours correction cannot change it.' USING ERRCODE='22023';END IF;
  IF coalesce(item->>'hours','') !~ '^-?[0-9]+([.][0-9]{1,2})?$' THEN RAISE EXCEPTION 'Enter hours with no more than two decimal places.' USING ERRCODE='22023';END IF;
  quantity:=(item->>'hours')::numeric;
  IF abs(quantity)>1000000 THEN RAISE EXCEPTION 'Check the hours amount.' USING ERRCODE='22023';END IF;
  day:=(item->>'date')::date;note:=nullif(btrim(item->>'notes'),'');
  IF day IS NULL OR NOT isfinite(day) OR length(coalesce(note,''))>2000 THEN RAISE EXCEPTION 'Check the leave date and notes.' USING ERRCODE='22023';END IF;
  IF mode='balance' THEN
   IF NOT item ? 'expected_updated_at' OR (item->>'expected_updated_at')::timestamptz IS DISTINCT FROM bal.updated_at THEN RAISE EXCEPTION 'Leave changed since this screen opened. Reload the balances before saving.' USING ERRCODE='40001';END IF;
   IF quantity<0 THEN RAISE EXCEPTION 'A corrected balance cannot be negative.' USING ERRCODE='22023';END IF;
   IF note IS NULL THEN RAISE EXCEPTION 'Enter a reason for the balance correction.' USING ERRCODE='22023';END IF;
   next_balance:=quantity;delta:=quantity-coalesce(bal.balance_hours,0);kind:='adjustment';quantity:=delta;
  ELSE
   IF kind IS NULL OR kind NOT IN ('taken','accrual','adjustment') OR quantity=0 OR (kind<>'adjustment' AND quantity<0) THEN RAISE EXCEPTION 'Enter valid hours and an entry type.' USING ERRCODE='22023';END IF;
   IF kind='adjustment' AND note IS NULL THEN RAISE EXCEPTION 'Enter a reason for the adjustment.' USING ERRCODE='22023';END IF;
   delta:=CASE WHEN kind='taken' THEN -quantity ELSE quantity END;next_balance:=coalesce(bal.balance_hours,0)+delta;
   IF next_balance<0 THEN RAISE EXCEPTION 'This entry exceeds the recorded hours balance. Review the balance first.' USING ERRCODE='22023';END IF;
  END IF;
  IF delta<>0 THEN
   INSERT INTO public.payroll_leave_transactions(business_id,employee_id,leave_type_id,transaction_date,transaction_type,hours,notes,created_by)
    VALUES(bid,p_employee,lt,day,kind,quantity,note,actor) RETURNING id INTO tx;
   INSERT INTO public.payroll_employee_leave(business_id,employee_id,leave_type_id,balance_hours,updated_at)
    VALUES(bid,p_employee,lt,next_balance,clock_timestamp())
    ON CONFLICT(employee_id,leave_type_id) DO UPDATE SET balance_hours=excluded.balance_hours,updated_at=excluded.updated_at RETURNING * INTO bal;
   INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by)
    VALUES(bid,'leave',p_employee,kind,old_data,to_jsonb(bal)||jsonb_build_object('transaction_id',tx,'request_id',p_request),actor);
  END IF;
  result:=result||jsonb_build_array(jsonb_build_object('leave_type_id',lt,'balance_hours',coalesce(bal.balance_hours,0),'updated_at',bal.updated_at));
 END LOOP;
 INSERT INTO public.payroll_leave_operations(id,business_id,employee_id,actor_id,request,result) VALUES(p_request,bid,p_employee,actor,p_changes,result);
 RETURN result;
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_apply_leave_hours(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6226_apply_leave_hours(uuid,uuid,jsonb) TO authenticated;

-- Old browser hours writes must fail before producing a one-sided history entry.
-- Statutory day/week writers retain their existing paths and units.
CREATE FUNCTION public.v6226_guard_leave_hours_writer() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $fn$
BEGIN
 IF current_user IN ('anon','authenticated') AND
  ((TG_OP<>'INSERT' AND OLD.statutory_unit IS NULL AND OLD.statutory_quantity IS NULL AND OLD.statutory_leave_code IS NULL)
   OR (TG_OP<>'DELETE' AND NEW.statutory_unit IS NULL AND NEW.statutory_quantity IS NULL AND NEW.statutory_leave_code IS NULL)) THEN
  RAISE EXCEPTION 'Refresh Frindly and use the leave save action so history and balance stay together.' USING ERRCODE='42501';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END;$fn$;
REVOKE ALL ON FUNCTION public.v6226_guard_leave_hours_writer() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER v6226_leave_hours_writer BEFORE INSERT OR UPDATE OR DELETE ON public.payroll_leave_transactions
 FOR EACH ROW EXECUTE FUNCTION public.v6226_guard_leave_hours_writer();
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.payroll_employee_leave FROM PUBLIC,anon,authenticated;
