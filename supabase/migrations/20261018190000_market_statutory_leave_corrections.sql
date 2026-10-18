-- v62.35 Market: append-only correction workflow for confirmed statutory leave.
ALTER TABLE public.payroll_statutory_leave_calculations
 ADD COLUMN corrected_at timestamptz,
 ADD COLUMN corrected_by uuid REFERENCES auth.users(id),
 ADD COLUMN correction_reason text;

CREATE TABLE public.payroll_statutory_leave_correction_operations(
 id uuid PRIMARY KEY,
 actor_id uuid NOT NULL REFERENCES auth.users(id),
 business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
 calculation_id uuid NOT NULL REFERENCES public.payroll_statutory_leave_calculations(id) ON DELETE RESTRICT,
 payload jsonb NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.payroll_statutory_leave_correction_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_statutory_leave_correction_operations FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.v6235_correct_statutory_leave(p_calculation uuid,p_expected_updated_at timestamptz,p_reason text,p_operation uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=auth.uid();bid uuid:=public.current_business_id();reason text:=nullif(btrim(p_reason),'');calc public.payroll_statutory_leave_calculations;tx public.payroll_leave_transactions;ent public.payroll_statutory_leave_entitlements;op public.payroll_statutory_leave_correction_operations;payload jsonb;result jsonb;qty numeric;offset_tx public.payroll_leave_transactions;
BEGIN
 IF actor IS NULL OR bid IS NULL OR p_calculation IS NULL OR p_operation IS NULL OR reason IS NULL OR length(reason)>500 THEN RAISE EXCEPTION 'A correction reason of up to 500 characters is required' USING ERRCODE='22023';END IF;
 IF NOT public.v55_payroll_access(bid) OR NOT public.v6147_can_write_area(bid,'payroll') THEN RAISE EXCEPTION 'Payroll write access required' USING ERRCODE='42501';END IF;
 payload:=jsonb_build_object('calculation_id',p_calculation,'expected_updated_at',p_expected_updated_at,'reason',reason);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_operation::text,6235));
 SELECT * INTO op FROM public.payroll_statutory_leave_correction_operations WHERE id=p_operation;
 IF FOUND THEN
  IF op.actor_id IS DISTINCT FROM actor OR op.business_id IS DISTINCT FROM bid OR op.calculation_id IS DISTINCT FROM p_calculation OR op.payload<>payload THEN RAISE EXCEPTION 'Correction identifier already used for different input' USING ERRCODE='22023';END IF;
  RETURN op.result;
 END IF;
 SELECT * INTO calc FROM public.payroll_statutory_leave_calculations WHERE id=p_calculation FOR UPDATE;
 IF calc.id IS NULL OR calc.business_id<>bid OR calc.statutory_leave_code NOT IN ('sick_leave','bereavement_leave','family_violence_leave') OR calc.confirmation_state<>'confirmed' OR calc.corrected_at IS NOT NULL THEN RAISE EXCEPTION 'This confirmed leave record is no longer available for correction' USING ERRCODE='40001';END IF;
 IF calc.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'The leave record changed. Reload before correcting it.' USING ERRCODE='40001';END IF;
 IF calc.pay_run_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.payroll_pay_run_lines WHERE statutory_calculation_id=calc.id) THEN RAISE EXCEPTION 'This leave is already included in a pay run. Reverse or correct the pay run first.' USING ERRCODE='55000';END IF;
 SELECT * INTO tx FROM public.payroll_leave_transactions WHERE id=calc.leave_transaction_id AND business_id=bid AND employee_id=calc.employee_id FOR UPDATE;
 IF tx.id IS NULL OR tx.transaction_type<>'taken' OR tx.statutory_leave_code IS DISTINCT FROM calc.statutory_leave_code OR tx.statutory_unit IS DISTINCT FROM 'days' OR tx.statutory_quantity IS NULL OR tx.statutory_quantity<=0 THEN RAISE EXCEPTION 'The original leave evidence is incomplete and needs payroll review' USING ERRCODE='55000';END IF;
 qty:=tx.statutory_quantity;
 IF calc.statutory_leave_code IN ('sick_leave','family_violence_leave') THEN
  SELECT * INTO ent FROM public.payroll_statutory_leave_entitlements WHERE business_id=bid AND employee_id=calc.employee_id AND statutory_leave_code=calc.statutory_leave_code AND period_start<=tx.transaction_date AND period_end>=tx.transaction_date ORDER BY period_start DESC LIMIT 1 FOR UPDATE;
  IF ent.id IS NULL OR ent.used_days<qty THEN RAISE EXCEPTION 'The statutory entitlement no longer reconciles with this leave' USING ERRCODE='55000';END IF;
  UPDATE public.payroll_statutory_leave_entitlements SET used_days=used_days-qty,updated_at=clock_timestamp(),updated_by=actor WHERE id=ent.id RETURNING * INTO ent;
 END IF;
 INSERT INTO public.payroll_leave_transactions(business_id,employee_id,leave_type_id,transaction_date,transaction_type,hours,notes,created_by)
 VALUES(bid,calc.employee_id,tx.leave_type_id,current_date,'adjustment',-coalesce(tx.display_hours,tx.hours,0),CASE WHEN calc.statutory_leave_code='family_violence_leave' THEN 'Confirmed statutory leave corrected' ELSE 'Correction of confirmed statutory leave: '||reason END,actor) RETURNING * INTO offset_tx;
 UPDATE public.payroll_statutory_leave_calculations SET confirmation_state='needs_confirmation',corrected_at=clock_timestamp(),corrected_by=actor,correction_reason=reason,updated_at=clock_timestamp(),updated_by=actor WHERE id=calc.id RETURNING * INTO calc;
 result:=jsonb_build_object('business_id',bid,'employee_id',calc.employee_id,'calculation',to_jsonb(calc),'correction_transaction',to_jsonb(offset_tx),'entitlement',CASE WHEN ent.id IS NULL THEN NULL ELSE to_jsonb(ent) END);
 INSERT INTO public.payroll_audit_log(business_id,entity_type,entity_id,action,before_data,after_data,created_by) VALUES(bid,'statutory_leave',calc.id,'corrected',jsonb_build_object('confirmation_state','confirmed','transaction_id',tx.id,'quantity',qty),jsonb_build_object('confirmation_state',calc.confirmation_state,'reason',reason,'correction_transaction_id',offset_tx.id),actor);
 INSERT INTO public.payroll_statutory_leave_correction_operations(id,actor_id,business_id,calculation_id,payload,result) VALUES(p_operation,actor,bid,calc.id,payload,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.v6235_correct_statutory_leave(uuid,timestamptz,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6235_correct_statutory_leave(uuid,timestamptz,text,uuid) TO authenticated;
