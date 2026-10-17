-- Frindly Market: isolated project smvvevrtjqkflyqkyape only.
-- Production remains read-only. Preserve existing test records.
DO $market_guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='frindly_isolated_full_expense_rollback_test_v1') THEN
    RAISE EXCEPTION 'Market bootstrap requires the existing isolated-test project';
  END IF;
END;
$market_guard$;
SET LOCAL check_function_bodies = off;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '90s';

CREATE OR REPLACE FUNCTION public.frindly_edit_recorded_expense_due_date_v1(p_expense_id uuid, p_due_date date, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_bid uuid; v_actor uuid:=auth.uid(); v_old public.expenses%rowtype;
 v_new public.expenses%rowtype; v_existing public.expense_revisions%rowtype;
 v_revision uuid;
BEGIN
 v_bid:=public.current_business_id();
 IF v_actor IS NULL OR v_bid IS NULL OR NOT coalesce(public.v6147_can_write_area(v_bid,'core'),false)
 THEN RAISE EXCEPTION 'Expense edit permission denied' USING ERRCODE='42501'; END IF;
 IF p_request_id IS NULL OR p_expected_updated_at IS NULL OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 2000
 THEN RAISE EXCEPTION 'Request ID, expected version and reason are required' USING ERRCODE='22023'; END IF;
 SELECT * INTO v_old FROM public.expenses WHERE id=p_expense_id AND business_id=v_bid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Expense not found' USING ERRCODE='P0002'; END IF;
 SELECT * INTO v_existing FROM public.expense_revisions WHERE business_id=v_bid AND request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.expense_id IS DISTINCT FROM p_expense_id OR v_existing.change_class<>'nonfinancial'
   OR v_existing.metadata->>'operation' IS DISTINCT FROM 'due_date_v1'
   OR v_existing.metadata->>'requested_due_date' IS DISTINCT FROM coalesce(p_due_date::text,'__null__')
  THEN RAISE EXCEPTION 'Request ID already used for another correction' USING ERRCODE='23505'; END IF;
  RETURN jsonb_build_object('expense_id',p_expense_id,'revision_id',v_existing.id,'replayed',true);
 END IF;
 IF v_old.lifecycle_state IS DISTINCT FROM 'recorded' OR v_old.voided_at IS NOT NULL OR coalesce(v_old.archived,false)
 THEN RAISE EXCEPTION 'Only active recorded expenses can be corrected' USING ERRCODE='22023'; END IF;
 IF v_old.updated_at IS DISTINCT FROM p_expected_updated_at THEN
 RAISE EXCEPTION 'Expense changed; refresh and retry' USING ERRCODE='40001'; END IF;
 IF v_old.due_date IS NOT DISTINCT FROM p_due_date THEN RAISE EXCEPTION 'Due date is unchanged' USING ERRCODE='22023'; END IF;
 INSERT INTO public.frindly_expense_correction_authorizations
 (business_id,expense_id,actor_id,transaction_id,allowed_fields)
 VALUES(v_bid,p_expense_id,v_actor,txid_current(),ARRAY['due_date','updated_at','updated_by']::text[]);
 UPDATE public.expenses SET due_date=p_due_date,updated_at=clock_timestamp(),updated_by=v_actor
 WHERE id=p_expense_id AND business_id=v_bid RETURNING * INTO v_new;
 INSERT INTO public.expense_revisions(business_id,expense_id,request_id,changed_by,
 change_reason,change_class,before_snapshot,after_snapshot,metadata)
 VALUES(v_bid,p_expense_id,p_request_id,v_actor,btrim(p_reason),'nonfinancial',
 to_jsonb(v_old),to_jsonb(v_new),
 jsonb_build_object('operation','due_date_v1','requested_due_date',coalesce(p_due_date::text,'__null__')))
 RETURNING id INTO v_revision;
 DELETE FROM public.frindly_expense_correction_authorizations
 WHERE business_id=v_bid AND expense_id=p_expense_id AND transaction_id=txid_current() AND actor_id=v_actor;
 RETURN jsonb_build_object('expense_id',p_expense_id,'revision_id',v_revision,'updated_at',v_new.updated_at,'replayed',false);
END $function$
;

REVOKE ALL ON FUNCTION public."frindly_edit_recorded_expense_due_date_v1"(p_expense_id uuid, p_due_date date, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_edit_recorded_expense_due_date_v1"(p_expense_id uuid, p_due_date date, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."frindly_edit_recorded_expense_due_date_v1"(p_expense_id uuid, p_due_date date, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_edit_recorded_expense_metadata_v1(p_expense_id uuid, p_changes jsonb, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE bid uuid; actor uuid:=auth.uid(); old_e public.expenses%rowtype;
 new_e public.expenses%rowtype; existing public.expense_revisions%rowtype;
BEGIN
 bid:=public.current_business_id();
 IF actor IS NULL OR bid IS NULL OR NOT coalesce(public.v6147_can_write_area(bid,'core'),false)
 THEN RAISE EXCEPTION 'Expense edit permission denied' USING ERRCODE='42501'; END IF;
 IF p_request_id IS NULL OR p_expected_updated_at IS NULL OR
 length(btrim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 2000 OR
 p_changes IS NULL OR jsonb_typeof(p_changes)<>'object' OR
 (SELECT count(*) FROM jsonb_object_keys(p_changes))<>1 OR
 NOT (p_changes ? 'description') OR
 jsonb_typeof(p_changes->'description') NOT IN ('string','null')
 THEN RAISE EXCEPTION 'Only description-only edits are enabled until accounting guard compatibility is resolved' USING ERRCODE='22023'; END IF;
 SELECT * INTO old_e FROM public.expenses WHERE id=p_expense_id AND business_id=bid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Expense not found' USING ERRCODE='P0002'; END IF;
 SELECT * INTO existing FROM public.expense_revisions
 WHERE business_id=bid AND request_id=p_request_id;
 IF FOUND THEN
  IF existing.expense_id IS DISTINCT FROM p_expense_id
  OR existing.change_class<>'nonfinancial'
  OR existing.metadata->'requested_changes' IS DISTINCT FROM p_changes THEN
   RAISE EXCEPTION 'Request ID reused for a different edit' USING ERRCODE='23505';
  END IF;
  RETURN jsonb_build_object('expense_id',p_expense_id,'revision_id',existing.id,'replayed',true);
 END IF;
 IF old_e.lifecycle_state IS DISTINCT FROM 'recorded' OR old_e.voided_at IS NOT NULL
 OR coalesce(old_e.archived,false) THEN
  RAISE EXCEPTION 'Only active recorded expenses may be edited' USING ERRCODE='22023';
 END IF;
 IF old_e.updated_at IS DISTINCT FROM p_expected_updated_at THEN
  RAISE EXCEPTION 'Expense changed; refresh and retry' USING ERRCODE='40001';
 END IF;
 IF old_e.description IS NOT DISTINCT FROM p_changes->>'description' THEN
  RAISE EXCEPTION 'Description is unchanged' USING ERRCODE='22023';
 END IF;
 UPDATE public.expenses SET description=p_changes->>'description',
 updated_at=clock_timestamp(),updated_by=actor
 WHERE id=p_expense_id AND business_id=bid RETURNING * INTO new_e;
 INSERT INTO public.expense_revisions(business_id,expense_id,request_id,
 changed_by,change_reason,change_class,before_snapshot,after_snapshot,metadata)
 VALUES(bid,p_expense_id,p_request_id,actor,btrim(p_reason),'nonfinancial',
 to_jsonb(old_e),to_jsonb(new_e),jsonb_build_object('requested_changes',p_changes))
 RETURNING * INTO existing;
 RETURN jsonb_build_object('expense_id',p_expense_id,'revision_id',existing.id,
 'updated_at',new_e.updated_at,'replayed',false);
END $function$
;

REVOKE ALL ON FUNCTION public."frindly_edit_recorded_expense_metadata_v1"(p_expense_id uuid, p_changes jsonb, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_edit_recorded_expense_metadata_v1"(p_expense_id uuid, p_changes jsonb, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."frindly_edit_recorded_expense_metadata_v1"(p_expense_id uuid, p_changes jsonb, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_ensure_accounting_period(p_business_id uuid, p_on date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_month integer;v_day integer;v_year integer;v_start date;v_end date;v_id uuid;v_status text;
begin
 if p_business_id is null or p_on is null then raise exception 'Business and date required'; end if;
 if auth.uid() is null or not public.v6169a_accountant_centre_access(p_business_id,true) then raise exception 'Not authorised for accounting periods'; end if;
 if public.v6187_subscription_read_only(p_business_id) then raise exception 'Subscription is read only'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_business_id::text,0));
 select f.financial_year_start_month,f.financial_year_start_day into v_month,v_day from public.financial_settings f where f.business_id=p_business_id;
 if not found then raise exception 'Financial settings must be saved first'; end if;
 if v_month not between 1 and 12 or v_day not between 1 and 31 then raise exception 'Invalid financial year start'; end if;
 v_year:=extract(year from p_on)::integer;
 if (extract(month from p_on)::integer,extract(day from p_on)::integer)<(v_month,v_day) then v_year:=v_year-1;end if;
 if v_day>extract(day from (pg_catalog.make_date(v_year,v_month,1)+interval '1 month - 1 day'))::integer
 or v_day>extract(day from (pg_catalog.make_date(v_year+1,v_month,1)+interval '1 month - 1 day'))::integer
 then raise exception 'Financial year start cannot be represented in both years';end if;
 v_start:=pg_catalog.make_date(v_year,v_month,v_day);
 v_end:=pg_catalog.make_date(v_year+1,v_month,v_day)-1;
 select p.id,p.status into v_id,v_status from public.accounting_periods p where p.business_id=p_business_id and p_on between p.period_start and p.period_end order by p.period_start limit 1;
 if found then
  if v_status<>'open' then raise exception 'Accounting period is not open';end if;
  return v_id;
 end if;
 if exists(select 1 from public.accounting_periods p where p.business_id=p_business_id and p.period_start<=v_end and p.period_end>=v_start) then raise exception 'An existing accounting period overlaps the requested financial year';end if;
 insert into public.accounting_periods(business_id,period_start,period_end,financial_year,status)
 values(p_business_id,v_start,v_end,extract(year from v_end)::integer,'open') returning id into v_id;
 return v_id;
end;$function$
;

REVOKE ALL ON FUNCTION public."frindly_ensure_accounting_period"(p_business_id uuid, p_on date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_ensure_accounting_period"(p_business_id uuid, p_on date) TO "service_role";

GRANT EXECUTE ON FUNCTION public."frindly_ensure_accounting_period"(p_business_id uuid, p_on date) TO "authenticated";

CREATE OR REPLACE FUNCTION public.frindly_expense_amount_change_preflight_v1(p_expense_id uuid, p_new_total numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_bid uuid; v_exp public.expenses%rowtype; v_a jsonb; v_paid numeric; v_count integer; v_target text;
begin
 v_bid:=public.current_business_id();
 if auth.uid() is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'core'),false)
 or not coalesce(public.v6147_can_read_area(v_bid,'expenses'),false)
 or not coalesce(public.v6147_can_read_area(v_bid,'bank'),false)
 or not coalesce(public.v6147_can_read_area(v_bid,'financials'),false)
 or not coalesce(public.v6169a_accountant_centre_access(v_bid,false),false)
 then return jsonb_build_object('status','access_denied','financial_edit_enabled',false);end if;
 if p_new_total is null or p_new_total<0 or p_new_total>999999999.99 or round(p_new_total,2)<>p_new_total
 then return jsonb_build_object('status','invalid_amount','financial_edit_enabled',false);end if;
 select * into v_exp from public.expenses where id=p_expense_id and business_id=v_bid;
 if not found then return jsonb_build_object('status','expense_not_found','financial_edit_enabled',false);end if;
 v_a:=public.frindly_expense_assessment_combined_v1(p_expense_id);
 if coalesce(v_a->>'assessment_status','')<>'review_only'
 then return jsonb_build_object('status','verification_incomplete','financial_edit_enabled',false);end if;
 select coalesce(sum(amount),0),count(*) into v_paid,v_count from public.expense_payments where business_id=v_bid and expense_id=p_expense_id;
 v_target:=case when v_count=0 and coalesce(v_exp.amount_paid,0)=0 then 'unpaid' else 'paid_or_partially_paid' end;
 return jsonb_build_object('status','review_only','correction_class',v_target,'old_total',v_exp.total_amount,
 'proposed_total',p_new_total,'difference',p_new_total-coalesce(v_exp.total_amount,0),
 'recorded_payment_total',v_paid,'payment_count',v_count,
 'proposed_balance_before_other_adjustments',p_new_total-v_paid,'requires_gst_recalculation',true,
 'requires_journal_review',true,'requires_payment_review',v_count>0,
 'requires_reconciliation_review',coalesce((v_a->>'has_reconciliation_allocation')::boolean,false),
 'assessment',v_a,'financial_edit_enabled',false,'writes_performed',false,
 'reason','Preview only: financial correction posting and GST basis are not yet verified');
 exception when others then return jsonb_build_object('status','verification_incomplete','financial_edit_enabled',false,'writes_performed',false);
end $function$
;

REVOKE ALL ON FUNCTION public."frindly_expense_amount_change_preflight_v1"(p_expense_id uuid, p_new_total numeric) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_expense_amount_change_preflight_v1"(p_expense_id uuid, p_new_total numeric) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."frindly_expense_amount_change_preflight_v1"(p_expense_id uuid, p_new_total numeric) TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_expense_correction_assess_v1(p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
SELECT jsonb_build_object(
'expense_id',e.id,'assessment_only',true,'financial_edit_enabled',false,
'has_payments',EXISTS(SELECT 1 FROM public.expense_payments p WHERE p.expense_id=e.id AND p.business_id=e.business_id),
'has_reconciled_payment',EXISTS(SELECT 1 FROM public.expense_payments p WHERE p.expense_id=e.id AND p.business_id=e.business_id AND (coalesce(p.reconciled,false) OR p.reconciled_at IS NOT NULL)),
'has_reconciliation_allocation',EXISTS(SELECT 1 FROM public.bank_reconciliation_allocations a WHERE a.business_id=e.business_id AND (a.expense_id=e.id OR EXISTS(SELECT 1 FROM public.expense_payments p WHERE p.business_id=e.business_id AND p.expense_id=e.id AND p.id=a.expense_payment_id))),
'has_owner_funding',EXISTS(SELECT 1 FROM public.expense_payments p WHERE p.expense_id=e.id AND p.business_id=e.business_id AND p.funding_source='owner_personal'),
'has_owner_current_account_entry',EXISTS(SELECT 1 FROM public.owner_current_account_entries c WHERE c.business_id=e.business_id AND (c.source_id=e.id OR EXISTS(SELECT 1 FROM public.expense_payments p WHERE p.business_id=e.business_id AND p.expense_id=e.id AND c.source_id=p.id))),
'has_posted_journal',EXISTS(SELECT 1 FROM public.accounting_journals j WHERE j.business_id=e.business_id AND j.source_type='expense' AND j.source_id=e.id AND j.status IN ('posted','reversed')),
'has_supplier_payment_journal',EXISTS(SELECT 1 FROM public.accounting_journals j WHERE j.business_id=e.business_id AND j.source_type='supplier_payment' AND j.status IN ('posted','reversed') AND EXISTS(SELECT 1 FROM public.expense_payments p WHERE p.business_id=e.business_id AND p.expense_id=e.id AND p.id=j.source_id)),
'has_missing_accounting_period',NOT EXISTS(SELECT 1 FROM public.accounting_periods ap WHERE ap.business_id=e.business_id AND e.invoice_date BETWEEN ap.period_start AND ap.period_end),
'correction_decision','blocked_pending_complete_access_review',
'has_locked_period',EXISTS(SELECT 1 FROM public.accounting_periods a WHERE a.business_id=e.business_id AND e.invoice_date BETWEEN a.period_start AND a.period_end AND a.status IN ('closed','soft_locked')),
'has_finalised_gst_period',EXISTS(SELECT 1 FROM public.gst_returns g WHERE g.business_id=e.business_id AND e.invoice_date BETWEEN g.period_start AND g.period_end AND g.status='finalised')
) FROM public.expenses e WHERE e.id=p_expense_id AND e.business_id=public.current_business_id() AND coalesce(public.v6147_can_write_area(e.business_id,'core'),false)
$function$
;

REVOKE ALL ON FUNCTION public."frindly_expense_correction_assess_v1"(p_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_expense_correction_assess_v1"(p_expense_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_expense_correction_assess_v2(p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE bid uuid; access_ok boolean; details jsonb;
BEGIN
 bid:=public.current_business_id();
 IF auth.uid() IS NULL OR bid IS NULL OR NOT coalesce(public.v6147_can_write_area(bid,'core'),false) THEN RETURN jsonb_build_object('assessment_status','access_denied','financial_edit_enabled',false); END IF;
 IF NOT EXISTS(SELECT 1 FROM public.expenses e WHERE e.id=p_expense_id AND e.business_id=bid) THEN RETURN jsonb_build_object('assessment_status','expense_not_found','financial_edit_enabled',false); END IF;
 access_ok:=coalesce(public.v6147_can_read_area(bid,'expenses'),false)
 AND coalesce(public.v6147_can_read_area(bid,'bank'),false)
 AND coalesce(public.v6147_can_read_area(bid,'financials'),false)
 AND coalesce(public.v6169a_accountant_centre_access(bid,false),false)
 AND has_table_privilege(current_user,'public.owner_current_account_entries','SELECT');
 IF NOT access_ok THEN RETURN jsonb_build_object('expense_id',p_expense_id,'assessment_status','verification_incomplete','reason','insufficient_visibility_into_related_financial_records','financial_edit_enabled',false); END IF;
 details:=public.frindly_expense_correction_assess_v1(p_expense_id);
 IF details IS NULL THEN RETURN jsonb_build_object('expense_id',p_expense_id,'assessment_status','verification_incomplete','financial_edit_enabled',false); END IF;
 RETURN details || jsonb_build_object('assessment_status','review_only','financial_edit_enabled',false,'correction_decision','blocked_pending_complete_access_review');
END $function$
;

REVOKE ALL ON FUNCTION public."frindly_expense_correction_assess_v2"(p_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_expense_correction_assess_v2"(p_expense_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_expense_correction_is_authorized_v1(p_old expenses, p_new expenses)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE changed text[];
BEGIN
 IF p_old.business_id IS DISTINCT FROM p_new.business_id OR p_old.id IS DISTINCT FROM p_new.id
 OR p_old.lifecycle_state IS DISTINCT FROM 'recorded'
 OR p_new.lifecycle_state IS DISTINCT FROM 'recorded'
 OR auth.uid() IS NULL THEN RETURN false; END IF;
 SELECT array_agg(k ORDER BY k) INTO changed FROM (
 SELECT key AS k FROM jsonb_each(to_jsonb(p_old)) a
 WHERE (to_jsonb(p_old)->a.key) IS DISTINCT FROM (to_jsonb(p_new)->a.key)
 ) diff;
 IF changed IS NULL THEN RETURN false; END IF;
 RETURN EXISTS (
 SELECT 1 FROM public.frindly_expense_correction_authorizations x
 WHERE x.business_id=p_old.business_id AND x.expense_id=p_old.id
 AND x.actor_id=auth.uid() AND x.transaction_id=txid_current()
 AND changed <@ x.allowed_fields
 AND x.allowed_fields <@ ARRAY[
 'supplier_id','supplier_name','supplier_reference','invoice_date','due_date',
 'category_id','job_costing_id','amount_type','gst_treatment','gst_rate','gst_override',
 'ex_gst','gst_amount','total_amount','business_use_percent','business_use_amount',
 'private_use_amount','business_ex_gst','business_gst_amount','allocation_method',
 'allocation_basis','outstanding_balance','payment_status','updated_at','updated_by'
 ]::text[]);
END $function$
;

REVOKE ALL ON FUNCTION public."frindly_expense_correction_is_authorized_v1"(p_old expenses, p_new expenses) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_expense_correction_is_authorized_v1"(p_old expenses, p_new expenses) TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_expense_revisions_immutable_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 RAISE EXCEPTION 'Expense revision history is immutable' USING ERRCODE='55000';
END;
$function$
;

REVOKE ALL ON FUNCTION public."frindly_expense_revisions_immutable_v1"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_expense_revisions_immutable_v1"() TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_expense_submit_correction_request_v1(p_request_id uuid, p_expense_id uuid, p_proposed_total numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_bid uuid; v_exp public.expenses%rowtype; v_a jsonb; v_old public.frindly_expense_correction_requests_v1%rowtype; v_reason text;
begin
 v_bid:=public.current_business_id();v_reason:=trim(coalesce(p_reason,''));
 if auth.uid() is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'core'),false)
 or not coalesce(public.v6147_can_read_area(v_bid,'expenses'),false)
 or not coalesce(public.v6147_can_read_area(v_bid,'bank'),false)
 or not coalesce(public.v6147_can_read_area(v_bid,'financials'),false)
 or not coalesce(public.v6169a_accountant_centre_access(v_bid,false),false)
 then return jsonb_build_object('status','access_denied','financial_edit_enabled',false);end if;
 if p_request_id is null or p_expense_id is null or length(v_reason) not between 10 and 1000
 then return jsonb_build_object('status','invalid_request','financial_edit_enabled',false);end if;
 select * into v_old from public.frindly_expense_correction_requests_v1 where request_id=p_request_id;
 if found then
  if v_old.business_id=v_bid and v_old.expense_id=p_expense_id and v_old.requested_by=auth.uid()
  and v_old.proposed_total=p_proposed_total and v_old.change_reason=v_reason
  then return jsonb_build_object('status','already_submitted','request_id',p_request_id,'financial_edit_enabled',false,'expense_changed',false);end if;
  return jsonb_build_object('status','request_id_conflict','financial_edit_enabled',false);
 end if;
 select * into v_exp from public.expenses where id=p_expense_id and business_id=v_bid for update;
 if not found then return jsonb_build_object('status','expense_not_found','financial_edit_enabled',false);end if;
 if v_exp.lifecycle_state is distinct from 'recorded' then return jsonb_build_object('status','not_recorded','financial_edit_enabled',false);end if;
 v_a:=public.frindly_expense_amount_change_preflight_v1(p_expense_id,p_proposed_total);
 if v_a->>'status'<>'review_only' then return jsonb_build_object('status','preflight_blocked','preflight',v_a,'financial_edit_enabled',false);end if;
 if v_exp.total_amount is not distinct from p_proposed_total then return jsonb_build_object('status','no_amount_change','financial_edit_enabled',false);end if;
 insert into public.frindly_expense_correction_requests_v1(request_id,business_id,expense_id,requested_by,proposed_total,original_total,original_updated_at,change_reason,correction_class,assessment)
 values(p_request_id,v_bid,p_expense_id,auth.uid(),p_proposed_total,v_exp.total_amount,v_exp.updated_at,v_reason,v_a->>'correction_class',v_a);
 return jsonb_build_object('status','pending_review','request_id',p_request_id,'correction_class',v_a->>'correction_class','financial_edit_enabled',false,'expense_changed',false,'journals_changed',false,'gst_changed',false);
 exception when unique_violation then return jsonb_build_object('status','request_id_conflict','financial_edit_enabled',false);
end $function$
;

REVOKE ALL ON FUNCTION public."frindly_expense_submit_correction_request_v1"(p_request_id uuid, p_expense_id uuid, p_proposed_total numeric, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_expense_submit_correction_request_v1"(p_request_id uuid, p_expense_id uuid, p_proposed_total numeric, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."frindly_expense_submit_correction_request_v1"(p_request_id uuid, p_expense_id uuid, p_proposed_total numeric, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_get_expense_revisions_v1(p_expense_id uuid)
 RETURNS TABLE(revision_id uuid, changed_at timestamp with time zone, changed_by uuid, change_reason text, change_class text, before_snapshot jsonb, after_snapshot jsonb, reversed_journal_ids uuid[], created_journal_ids uuid[], metadata jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_bid uuid;
BEGIN
 v_bid:=public.current_business_id();
 IF auth.uid() IS NULL OR v_bid IS NULL OR NOT coalesce(public.v6147_can_read_area(v_bid,'core'),false) THEN
  RAISE EXCEPTION 'Expense history access denied' USING ERRCODE='42501';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM public.expenses e WHERE e.id=p_expense_id AND e.business_id=v_bid) THEN
  RAISE EXCEPTION 'Expense not found' USING ERRCODE='P0002';
 END IF;
 RETURN QUERY SELECT r.id,r.changed_at,r.changed_by,r.change_reason,r.change_class,
 r.before_snapshot,r.after_snapshot,r.reversed_journal_ids,r.created_journal_ids,r.metadata
 FROM public.expense_revisions r
 WHERE r.business_id=v_bid AND r.expense_id=p_expense_id
 ORDER BY r.changed_at DESC,r.id DESC LIMIT 250;
END $function$
;

REVOKE ALL ON FUNCTION public."frindly_get_expense_revisions_v1"(p_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_get_expense_revisions_v1"(p_expense_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."frindly_get_expense_revisions_v1"(p_expense_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.frindly_payroll_period_ready(p_business_id uuid, p_pay_date date)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or p_business_id is null or p_pay_date is null then return false; end if;
 if not public.is_super_admin() and p_business_id is distinct from public.current_business_id() then return false; end if;
 if not public.v55_payroll_access(p_business_id) then return false; end if;
 return public.v6170a_period_is_open(p_business_id,p_pay_date);
end;$function$
;

REVOKE ALL ON FUNCTION public."frindly_payroll_period_ready"(p_business_id uuid, p_pay_date date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."frindly_payroll_period_ready"(p_business_id uuid, p_pay_date date) TO "service_role";

GRANT EXECUTE ON FUNCTION public."frindly_payroll_period_ready"(p_business_id uuid, p_pay_date date) TO "authenticated";

CREATE OR REPLACE FUNCTION public.mark_quote_won_from_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 if new.source_quote_id is not null then
  update public.quotes
  set status='won', invoice_id=coalesce(invoice_id,new.id), updated_at=now()
  where id=new.source_quote_id and business_id=new.business_id;
 end if;
 return new;
end $function$
;

REVOKE ALL ON FUNCTION public."mark_quote_won_from_invoice"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."mark_quote_won_from_invoice"() TO "service_role";

CREATE OR REPLACE FUNCTION public.se_confirm_purchase(p_business_id uuid, p_expense_id uuid, p_expense_line_id uuid, p_kind text, p_item_name text, p_quantity numeric, p_existing_item_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare exp public.expenses%rowtype; ln public.expense_lines%rowtype;
 source_amount numeric(14,2); source_gst numeric(14,2); item_id uuid; movement_id uuid;
 review_id uuid; existing public.se_reviews%rowtype; asset_id uuid; v_selected_item uuid;
begin
 perform public.se_require_access(p_business_id,true);
 if p_kind not in ('stock','supplies','equipment','regular','needs_review') then raise exception 'Select how the purchase is used'; end if;
 select * into exp from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found then raise exception 'The supplier bill is unavailable'; end if;
 if exp.payment_status='draft' then raise exception 'Record the bill before classifying it'; end if;
 if p_expense_line_id is not null then
   select * into ln from public.expense_lines where id=p_expense_line_id and expense_id=exp.id;
   if not found then raise exception 'This line does not belong to the supplier bill'; end if;
   source_amount:=ln.ex_gst;source_gst:=ln.gst_amount;
 else
   if exp.is_split then raise exception 'Select an individual line for a split supplier bill'; end if;
   source_amount:=exp.ex_gst;source_gst:=exp.gst_amount;
 end if;
 if source_amount<0 then raise exception 'Use the return workflow for a supplier credit'; end if;
 select * into existing from public.se_reviews
 where business_id=p_business_id and expense_id=exp.id
 and expense_line_id is not distinct from p_expense_line_id for update;
 if found and existing.status='confirmed' then raise exception 'This purchase is already confirmed. Use a correction.'; end if;
 if p_kind in ('stock','supplies','equipment') then
   if p_quantity is null or p_quantity<=0 or trim(coalesce(p_item_name,''))='' then raise exception 'Enter an item and quantity'; end if;
   if p_existing_item_id is not null then
     select id into item_id from public.se_items where id=p_existing_item_id
       and business_id=p_business_id and kind=p_kind and not archived for update;
     if item_id is null then raise exception 'Select an item of the same type from this business'; end if;
   else
     item_id:=public.se_create_item(p_business_id,p_kind,p_item_name,null,'each',null);
     update public.se_items set origin_expense_id=exp.id,supplier_name=exp.supplier_name where id=item_id;
   end if;
   if p_kind='equipment' then
     if p_quantity<>1 or p_existing_item_id is not null then raise exception 'Record each piece of equipment separately'; end if;
     asset_id:=public.se_create_asset(p_business_id,item_id,
       case when upper(coalesce(public.v61105_effective_tax_status(exp.invoice_date)->>'jurisdiction',''))='NZ'
              and coalesce((public.v61105_effective_tax_status(exp.invoice_date)->>'gst_registered')::boolean,false)
            then source_amount else source_amount+source_gst end,
       case when upper(coalesce(public.v61105_effective_tax_status(exp.invoice_date)->>'jurisdiction',''))='NZ'
              and not coalesce((public.v61105_effective_tax_status(exp.invoice_date)->>'gst_registered')::boolean,false)
            then 0 else source_gst end,
       exp.invoice_date,exp.invoice_date,coalesce(exp.business_use_percent,100),
       'unknown','',null,null);
   else
     movement_id:=public.se_record_movement(p_business_id,item_id,'purchase',p_quantity,
       source_amount/p_quantity,exp.invoice_date,'Purchase from supplier bill',null,null);
     update public.se_movements set expense_id=exp.id where id=movement_id;
   end if;
 end if;
 v_selected_item:=item_id;
 if existing.id is null then
   insert into public.se_reviews(business_id,expense_id,expense_line_id,item_id,proposed_kind,
      source_description,source_ex_gst,source_gst,quantity,status,suggestion_source,confirmed_by,confirmed_at,purchase_movement_id)
   values(p_business_id,exp.id,p_expense_line_id,item_id,p_kind,
     coalesce(ln.description,exp.description),source_amount,source_gst,p_quantity,
     case when p_kind='needs_review' then 'needs_review' else 'confirmed' end,
     'owner_confirmation',auth.uid(),case when p_kind='needs_review' then null else now() end,movement_id)
   returning id into review_id;
 else
   update public.se_reviews set item_id=v_selected_item,purchase_movement_id=movement_id,proposed_kind=p_kind,
     source_ex_gst=source_amount,source_gst=source_gst,quantity=p_quantity,
     status=case when p_kind='needs_review' then 'needs_review' else 'confirmed' end,
     confirmed_by=auth.uid(),confirmed_at=case when p_kind='needs_review' then null else now() end
   where id=existing.id returning id into review_id;
 end if;
 insert into public.se_activity(business_id,actor,action,item_id,detail)
 values(p_business_id,auth.uid(),'purchase_review',item_id,
   jsonb_build_object('review_id',review_id,'expense_id',p_expense_id,'classification',p_kind));
 return review_id;
end $function$
;

REVOKE ALL ON FUNCTION public."se_confirm_purchase"(p_business_id uuid, p_expense_id uuid, p_expense_line_id uuid, p_kind text, p_item_name text, p_quantity numeric, p_existing_item_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."se_confirm_purchase"(p_business_id uuid, p_expense_id uuid, p_expense_line_id uuid, p_kind text, p_item_name text, p_quantity numeric, p_existing_item_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."se_confirm_purchase"(p_business_id uuid, p_expense_id uuid, p_expense_line_id uuid, p_kind text, p_item_name text, p_quantity numeric, p_existing_item_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.se_record_asset_event(p_business_id uuid, p_asset_id uuid, p_action text, p_event_date date, p_proceeds numeric, p_note text, p_assigned_to text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.se_assets%rowtype; i public.se_items%rowtype; v_action text:=lower(trim(coalesce(p_action,''))); v_date date:=coalesce(p_event_date,current_date); v_proceeds numeric:=coalesce(p_proceeds,0); v_reason text:=nullif(trim(coalesce(p_note,'')),''); v_tax jsonb; v_registered boolean:=false; v_rate numeric:=0; v_gst_output numeric:=0; v_gst_credit numeric:=0; v_ex_gst numeric:=0; v_business_ratio numeric:=1; v_private_gross numeric:=0; v_business_net_proceeds numeric:=0; v_fixed uuid; v_accum uuid; v_bank uuid; v_gst_payable uuid; v_owner uuid; v_gain uuid; v_loss uuid; v_capitalised numeric:=0; v_accum_depn numeric:=0; v_nbv numeric:=0; v_gain_amt numeric:=0; v_loss_amt numeric:=0; v_journal uuid; v_lines jsonb:='[]'::jsonb;
begin
 perform public.se_require_access(p_business_id,true);
 if public.current_business_id() is distinct from p_business_id then raise exception 'Choose the asset business before recording this event'; end if;
 select * into a from public.se_assets where id=p_asset_id and business_id=p_business_id for update; if a.id is null then raise exception 'Equipment is missing'; end if;
 select * into i from public.se_items where id=a.item_id and business_id=p_business_id;
 if v_action not in ('sold','disposed','lost','broken','note','accountant_review') then raise exception 'Unsupported equipment action'; end if;
 if v_action in ('note','accountant_review','lost','broken') then
  if v_reason is null then raise exception 'Enter a note'; end if;
  insert into public.se_activity(business_id,actor,action,item_id,detail) values(p_business_id,auth.uid(),case when v_action='accountant_review' then 'accountant_review_requested' when v_action in ('lost','broken') then 'tool_status_changed' else 'asset_note_added' end,a.item_id,jsonb_build_object('asset_id',a.id,'event',v_action,'date',v_date,'note',v_reason,'assigned_to',nullif(trim(coalesce(p_assigned_to,'')),'') ));
  return a.id;
 end if;
 if a.disposed_on is not null or a.disposal_journal_id is not null then raise exception 'Equipment is already disposed'; end if;
 if v_date<coalesce(a.purchased_on,v_date) then raise exception 'Disposal precedes purchase'; end if; if v_proceeds<0 then raise exception 'Proceeds cannot be negative'; end if;
 if v_action='disposed' and v_reason is null then v_reason:='Disposed'; end if; if v_action='sold' and v_reason is null then v_reason:='Sold'; end if;
 v_business_ratio:=greatest(0,least(1,coalesce(a.business_use_percent,100)/100));
 v_tax:=public.v61105_effective_tax_status(v_date); v_registered:=coalesce((v_tax->>'gst_registered')::boolean,false); v_rate:=case when v_registered then coalesce((v_tax->>'effective_rate_percent')::numeric,0) else 0 end;
 if v_registered and v_proceeds>0 and v_rate>0 then v_gst_output:=round(v_proceeds*v_rate/(100+v_rate),2); if coalesce(a.gst_amount,0)>0 then v_gst_credit:=round(v_gst_output*(1-v_business_ratio),2); end if; end if;
 v_ex_gst:=round(v_proceeds-v_gst_output,2); v_private_gross:=round(v_proceeds*(1-v_business_ratio),2); v_business_net_proceeds:=round(v_ex_gst*v_business_ratio,2);
 v_fixed:=public.v61105_account_role_id(p_business_id,'fixed_equipment'); v_accum:=public.v61105_account_role_id(p_business_id,'accum_depreciation'); v_bank:=public.v61105_account_role_id(p_business_id,'bank'); v_gst_payable:=public.v61105_account_role_id(p_business_id,'gst_output'); v_owner:=coalesce(public.v61105_account_role_id(p_business_id,'owner_drawings'),public.v61105_account_role_id(p_business_id,'owner_funds'));
 insert into public.accounting_accounts(business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by) values
 (p_business_id,'206','Gain on Disposal of Assets','other_income','credit','income','asset_disposal_gain','4900','OTHERINCOME','Book gain on disposal of business assets.',true,false,auth.uid(),auth.uid()),
 (p_business_id,'430','Loss on Disposal of Assets','other_expense','debit','operating_expenses','asset_disposal_loss','6900','EXPENSE','Book loss on disposal of business assets.',true,false,auth.uid(),auth.uid()) on conflict (business_id,account_code) do nothing;
 v_gain:=public.v6192_account_id(p_business_id,'asset_disposal_gain','206'); v_loss:=public.v6192_account_id(p_business_id,'asset_disposal_loss','430');
 if v_bank is null or v_gst_payable is null or v_owner is null or v_gain is null or v_loss is null then raise exception 'Asset disposal accounting accounts are incomplete'; end if;
 if coalesce(a.tracking_treatment,'depreciable')='low_value' then v_capitalised:=0;v_accum_depn:=0;v_nbv:=0;
 else
  if v_fixed is null or v_accum is null then raise exception 'Fixed-asset accounts are incomplete'; end if;
  if i.origin_expense_id is null then
   select round(coalesce(sum(l.debit-l.credit),0),2) into v_capitalised from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.business_id=p_business_id and j.source_type='opening_asset' and j.source_id=a.id and j.status='posted' and l.account_id=v_fixed;
   if v_capitalised<=0 then raise exception 'Opening equipment has no posted opening-balance asset journal yet. Review and post its opening balance before disposal.'; end if;
  else
   select round(coalesce(sum(l.debit-l.credit),0),2) into v_capitalised from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.business_id=p_business_id and j.source_type='expense' and j.source_id=i.origin_expense_id and j.status='posted' and l.account_id=v_fixed;
  end if;
  if v_capitalised<=0 then raise exception 'This equipment is not yet capitalised in the formal ledger. Post/review its supplier bill before disposal.'; end if;
  select round(coalesce(sum(l.credit-l.debit),0),2) into v_accum_depn from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.business_id=p_business_id and j.source_type='depreciation' and j.source_id=a.id and j.status='posted' and j.journal_date<=v_date and l.account_id=v_accum;
  v_accum_depn:=least(v_capitalised,greatest(0,v_accum_depn));v_nbv:=round(v_capitalised-v_accum_depn,2);
 end if;
 v_gain_amt:=greatest(round(v_business_net_proceeds-v_nbv,2),0);v_loss_amt:=greatest(round(v_nbv-v_business_net_proceeds,2),0);
 v_lines:=jsonb_build_array(jsonb_build_object('account_id',v_bank,'description','Asset disposal proceeds','debit',round(v_proceeds,2),'credit',0,'tax_code',case when v_registered then 'GST' else 'NO_GST' end,'tax_rate',v_rate,'tax_amount',0));
 if v_accum_depn>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_accum,'description','Clear accumulated depreciation','debit',v_accum_depn,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0));end if;
 if v_loss_amt>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_loss,'description','Loss on asset disposal','debit',v_loss_amt,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0));end if;
 if v_capitalised>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_fixed,'description','Remove disposed asset','debit',0,'credit',v_capitalised,'tax_code','NO_GST','tax_rate',0,'tax_amount',0));end if;
 if round(v_gst_output-v_gst_credit,2)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_gst_payable,'description','Net GST on asset disposal','debit',0,'credit',round(v_gst_output-v_gst_credit,2),'tax_code','GST','tax_rate',v_rate,'tax_amount',round(v_gst_output-v_gst_credit,2)));end if;
 if v_private_gross>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_owner,'description','Private share of disposal proceeds','debit',0,'credit',v_private_gross,'tax_code','NO_GST','tax_rate',0,'tax_amount',0));end if;
 if v_gain_amt>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_gain,'description','Gain on asset disposal','debit',0,'credit',v_gain_amt,'tax_code','NO_GST','tax_rate',0,'tax_amount',0));end if;
 v_journal:=public.v6192_create_posted_journal(p_business_id,v_date,'manual','asset_disposal',a.id,'ASSET-'||left(a.id::text,8),'Asset disposal',v_lines);
 update public.se_assets set disposed_on=v_date,disposal_proceeds=v_proceeds,disposal_ex_gst=v_ex_gst,disposal_gst_output=v_gst_output,disposal_gst_credit_adjustment=v_gst_credit,disposal_journal_id=v_journal,disposal_reason=v_reason,disposal_accounted_at=now() where id=a.id and business_id=p_business_id;
 insert into public.se_activity(business_id,actor,action,item_id,detail) values(p_business_id,auth.uid(),case when v_action='sold' then 'equipment_sold' else 'equipment_disposed' end,a.item_id,jsonb_build_object('asset_id',a.id,'proceeds',v_proceeds,'date',v_date,'reason',v_reason,'journal_id',v_journal,'gst_output',v_gst_output,'gst_credit_adjustment',v_gst_credit,'business_use_percent',a.business_use_percent));
 return a.id;
end $function$
;

REVOKE ALL ON FUNCTION public."se_record_asset_event"(p_business_id uuid, p_asset_id uuid, p_action text, p_event_date date, p_proceeds numeric, p_note text, p_assigned_to text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."se_record_asset_event"(p_business_id uuid, p_asset_id uuid, p_action text, p_event_date date, p_proceeds numeric, p_note text, p_assigned_to text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."se_record_asset_event"(p_business_id uuid, p_asset_id uuid, p_action text, p_event_date date, p_proceeds numeric, p_note text, p_assigned_to text) TO "service_role";

CREATE OR REPLACE FUNCTION public.se_require_access(p_business_id uuid, p_write boolean DEFAULT true)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text;
begin
  if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
    raise exception 'No access to this business';
  end if;
  select m.role into v_role from public.business_memberships m
  where m.business_id=p_business_id and m.user_id=auth.uid() and m.status='active';
  if v_role is null then raise exception 'Active membership required'; end if;
  if p_write then
    if not public.v6147_can_write_area(p_business_id,'expenses') then
      raise exception 'Expense editor access and an active subscription are required';
    end if;
    if not public.v6200_stock_module_enabled(p_business_id) then
      raise exception 'Stock & Equipment is not enabled for this business';
    end if;
  end if;
end
$function$
;

REVOKE ALL ON FUNCTION public."se_require_access"(p_business_id uuid, p_write boolean) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."se_require_access"(p_business_id uuid, p_write boolean) TO "service_role";

CREATE OR REPLACE FUNCTION public.se_review_invoice(p_business_id uuid, p_expense_id uuid, p_expected_revision integer, p_rows jsonb, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.expenses%rowtype; previous public.se_invoice_reviews%rowtype;
 line jsonb; old_line jsonb; result_rows jsonb:='[]'::jsonb;
 v_kind text; v_name text; v_quantity numeric; v_ex numeric; v_gst numeric;
 v_total_ex numeric:=0; v_total_gst numeric:=0; v_item uuid; v_movement uuid;
 v_asset uuid; v_review uuid; v_available date; v_life integer; v_residual numeric;
 v_item_row public.se_items%rowtype; v_move_row public.se_movements%rowtype;
begin
 perform public.se_require_access(p_business_id,true);
 select * into e from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found or e.payment_status='draft' or coalesce(e.archived,false) or
    coalesce(to_jsonb(e)->>'lifecycle_state','recorded') not in ('recorded','') then
   raise exception 'Record an active supplier bill before review'; end if;
 select * into previous from public.se_invoice_reviews where business_id=p_business_id
   and expense_id=e.id order by revision desc limit 1 for update;
 if coalesce(previous.revision,0)<>coalesce(p_expected_revision,-1) then
   raise exception 'Invoice review has changed; reload it before saving'; end if;
 if exists(select 1 from public.se_reviews where business_id=p_business_id and expense_id=e.id
   and status='confirmed') then raise exception 'This bill has legacy confirmed purchase lines; correct them first'; end if;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 150 then
   raise exception 'Review between 1 and 150 invoice items'; end if;
 if previous.id is not null and nullif(trim(coalesce(p_reason,'')),'') is null then
   raise exception 'Explain why this confirmed invoice is changing'; end if;

 -- Roll back earlier operational events only when nothing depends on them.
 if previous.id is not null then
  for old_line in select value from jsonb_array_elements(previous.rows) loop
   if old_line->>'movement_id' is not null then
     select * into v_move_row from public.se_movements where id=(old_line->>'movement_id')::uuid
       and business_id=p_business_id and expense_id=e.id;
     if not found then raise exception 'Earlier movement missing; accountant review required'; end if;
     select * into v_item_row from public.se_items where id=v_move_row.item_id
       and business_id=p_business_id for update;
     if exists(select 1 from public.se_movements where business_id=p_business_id
       and item_id=v_item_row.id and created_at>v_move_row.created_at)
       then raise exception 'Stock has moved since review; accountant review required'; end if;
     if v_item_row.quantity<v_move_row.quantity_delta or v_item_row.value_ex_gst<v_move_row.value_delta then
       raise exception 'Stock quantities need accountant review'; end if;
     update public.se_items set quantity=quantity-v_move_row.quantity_delta,
       value_ex_gst=value_ex_gst-v_move_row.value_delta where id=v_item_row.id;
     insert into public.se_movements(business_id,item_id,kind,quantity_delta,value_delta,
       quantity_after,value_after,occurred_on,expense_id,reason,created_by)
     values(p_business_id,v_item_row.id,'correction',-v_move_row.quantity_delta,
       -v_move_row.value_delta,v_item_row.quantity-v_move_row.quantity_delta,
       v_item_row.value_ex_gst-v_move_row.value_delta,current_date,e.id,p_reason,auth.uid());
     update public.se_items set archived=true where id=v_item_row.id and origin_expense_id=e.id;
   elsif old_line->>'asset_id' is not null then
     select item_id into v_item from public.se_assets where id=(old_line->>'asset_id')::uuid
       and business_id=p_business_id and voided_at is null and disposed_on is null for update;
     if not found then raise exception 'Equipment changed since review; accountant review required'; end if;
     update public.se_assets set voided_at=now() where id=(old_line->>'asset_id')::uuid;
     update public.se_items set archived=true where id=v_item;
   end if;
  end loop;
 end if;
 for line in select value from jsonb_array_elements(p_rows) loop
   v_kind:=line->>'kind';v_name:=trim(coalesce(line->>'description',''));
   if v_kind is null or v_kind not in ('regular','stock','supplies','equipment','low_value_equipment') or
      v_name='' or length(v_name)>500 or (line->>'ex_gst') is null or
      (line->>'gst') is null or (line->>'quantity') is null then
     raise exception 'Complete every item and select a use'; end if;
   begin
     v_ex:=(line->>'ex_gst')::numeric;v_gst:=(line->>'gst')::numeric;
     v_quantity:=(line->>'quantity')::numeric;
   exception when invalid_text_representation or numeric_value_out_of_range then
     raise exception 'Use valid numeric item amounts and quantities'; end;
   if v_ex<0 or v_gst<0 or v_quantity<=0 or v_quantity>1000000 or
      round(v_ex,2)<>v_ex or round(v_gst,2)<>v_gst then
     raise exception 'Check item amounts and quantities'; end if;
   v_total_ex:=v_total_ex+v_ex;v_total_gst:=v_total_gst+v_gst;
   v_item:=null;v_movement:=null;v_asset:=null;
   if v_kind in ('stock','supplies','equipment','low_value_equipment') then
     if v_ex<=0 then raise exception 'Tracked items need a positive cost'; end if;
     if v_kind in ('equipment','low_value_equipment') and v_quantity<>1 then
       raise exception 'Enter equipment as one row per item'; end if;
     v_item:=public.se_create_item(p_business_id,
       case when v_kind='low_value_equipment' then 'equipment' else v_kind end,v_name,null,'each',null);
     update public.se_items set origin_expense_id=e.id,supplier_name=e.supplier_name where id=v_item;
     if v_kind in ('equipment','low_value_equipment') then
       v_available:=nullif(line->>'available_on','')::date;
       if v_kind='equipment' then
         v_life:=nullif(line->>'life_months','')::integer;
         v_residual:=coalesce(nullif(line->>'residual_value','')::numeric,0);
         if v_available is null or coalesce(line->>'book_method','') not in ('SL','DV') or
            v_life is null or v_life<1 or v_life>1200 or
            v_available<e.invoice_date or v_residual<0 or v_residual>v_ex then
           raise exception 'Check equipment ready date, useful life and residual value'; end if;
       else v_available:=coalesce(v_available,e.invoice_date); end if;
       v_asset:=public.se_create_asset(p_business_id,v_item,
         case when upper(coalesce(public.v61105_effective_tax_status(e.invoice_date)->>'jurisdiction',''))='NZ'
                and coalesce((public.v61105_effective_tax_status(e.invoice_date)->>'gst_registered')::boolean,false)
              then v_ex else v_ex+v_gst end,
         case when upper(coalesce(public.v61105_effective_tax_status(e.invoice_date)->>'jurisdiction',''))='NZ'
                and not coalesce((public.v61105_effective_tax_status(e.invoice_date)->>'gst_registered')::boolean,false)
              then 0 else v_gst end,
         e.invoice_date,v_available,coalesce(e.business_use_percent,100),'unknown','',null,null);
       if v_kind='low_value_equipment' then
         update public.se_assets set tracking_treatment='low_value' where id=v_asset;
       end if;
     else
       v_movement:=public.se_record_movement(p_business_id,v_item,'purchase',v_quantity,
         v_ex/v_quantity,e.invoice_date,'Reviewed invoice item',null,null);
       update public.se_movements set expense_id=e.id where id=v_movement;
     end if;
   end if;
   result_rows:=result_rows||jsonb_build_array(line||jsonb_build_object(
     'item_id',v_item,'movement_id',v_movement,'asset_id',v_asset));
 end loop;
 if v_total_ex<>e.ex_gst or v_total_gst<>e.gst_amount then
   raise exception 'Item totals must equal bill ex GST and GST totals'; end if;
 insert into public.se_invoice_reviews(business_id,expense_id,revision,rows,
   source_ex_gst,source_gst,reviewed_by,reason)
 values(p_business_id,e.id,coalesce(previous.revision,0)+1,result_rows,e.ex_gst,
   e.gst_amount,auth.uid(),nullif(trim(p_reason),'')) returning id into v_review;
 insert into public.se_activity(business_id,actor,action,detail) values
 (p_business_id,auth.uid(),'invoice_review',jsonb_build_object('expense_id',e.id,
  'revision',coalesce(previous.revision,0)+1,'review_id',v_review));
 return v_review;
end $function$
;

REVOKE ALL ON FUNCTION public."se_review_invoice"(p_business_id uuid, p_expense_id uuid, p_expected_revision integer, p_rows jsonb, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."se_review_invoice"(p_business_id uuid, p_expense_id uuid, p_expected_revision integer, p_rows jsonb, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."se_review_invoice"(p_business_id uuid, p_expense_id uuid, p_expected_revision integer, p_rows jsonb, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.se_save_document_items(p_business_id uuid, p_expense_id uuid, p_attachment_id uuid, p_filename text, p_items jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.expenses%rowtype; a public.expense_attachments%rowtype; line jsonb;
begin
 perform public.se_require_access(p_business_id,true);
 select * into e from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found then raise exception 'Supplier bill unavailable'; end if;
 if p_attachment_id is not null then
   select * into a from public.expense_attachments where id=p_attachment_id and
     expense_id=e.id and business_id=p_business_id;
   if not found then raise exception 'Attachment does not belong to this bill'; end if;
 end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>150 then
   raise exception 'The scan contains too many item proposals'; end if;
 if exists(select 1 from public.se_invoice_reviews where business_id=p_business_id and expense_id=e.id)
   then raise exception 'A reviewed invoice cannot have its AI proposals replaced'; end if;
 for line in select value from jsonb_array_elements(p_items) loop
   if jsonb_typeof(line)<>'object' or jsonb_typeof(line->'description') not in ('string','null')
      or length(coalesce(line->>'description',''))>500 then raise exception 'Invalid item description'; end if;
 end loop;
 insert into public.se_document_items(business_id,expense_id,attachment_id,proposals,source_filename,saved_by)
 values(p_business_id,e.id,p_attachment_id,p_items,left(p_filename,180),auth.uid())
 on conflict(expense_id) do update set proposals=excluded.proposals,
   attachment_id=excluded.attachment_id,source_filename=excluded.source_filename,
   scanned_at=now(),saved_by=excluded.saved_by;
end $function$
;

REVOKE ALL ON FUNCTION public."se_save_document_items"(p_business_id uuid, p_expense_id uuid, p_attachment_id uuid, p_filename text, p_items jsonb) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."se_save_document_items"(p_business_id uuid, p_expense_id uuid, p_attachment_id uuid, p_filename text, p_items jsonb) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."se_save_document_items"(p_business_id uuid, p_expense_id uuid, p_attachment_id uuid, p_filename text, p_items jsonb) TO "service_role";

CREATE OR REPLACE FUNCTION public.support_touch_thread()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin update public.support_threads set updated_at=now(),last_message_at=now(),status=case when new.sender_role='support' then 'waiting' else 'open' end where id=new.thread_id; return new; end;$function$
;

REVOKE ALL ON FUNCTION public."support_touch_thread"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."support_touch_thread"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v34_admin_get_payment_providers()
 RETURNS TABLE(provider text, display_name text, enabled boolean, mode text, public_config jsonb, has_secret boolean, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;

  return query
  select p.provider,p.display_name,p.enabled,p.mode,p.public_config,(p.secret_id is not null),p.updated_at
  from public.payment_provider_settings p
  order by case p.provider
    when 'stripe' then 1
    when 'blinkpay' then 2
    when 'akahu' then 3
    when 'paypal' then 4
    when 'mollie' then 5
    else 99
  end,p.provider;
end $function$
;

REVOKE ALL ON FUNCTION public."v34_admin_get_payment_providers"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v34_admin_get_payment_providers"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v34_admin_get_payment_providers"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v34_admin_save_payment_provider(p_provider text, p_enabled boolean, p_mode text, p_display_name text, p_public_config jsonb, p_secret_patch jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
declare
  v_provider text := lower(trim(coalesce(p_provider,'')));
  v_secret_id uuid;
  v_existing_secret jsonb := '{}'::jsonb;
  v_merged_secret jsonb := '{}'::jsonb;
  v_secret_name text;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;
  if v_provider not in ('stripe','blinkpay','akahu','paypal','mollie','other') then
    raise exception 'Unsupported payment provider';
  end if;
  if p_mode not in ('test','live') then
    raise exception 'Mode must be test or live';
  end if;
  -- Stripe, BlinkPay and Akahu have active adapters. Other credentials can be stored safely now.
  if coalesce(p_enabled,false) and v_provider not in ('stripe','blinkpay','akahu') then
    raise exception '% checkout is not enabled in this version yet', initcap(v_provider);
  end if;

  select secret_id into v_secret_id
  from public.payment_provider_settings
  where provider=v_provider;

  v_secret_name := 'smallbiz_payment_' || v_provider;
  if v_secret_id is null then
    select id into v_secret_id from vault.secrets where name=v_secret_name limit 1;
  end if;

  if p_secret_patch is not null and p_secret_patch <> '{}'::jsonb then
    if v_secret_id is not null then
      begin
        select decrypted_secret::jsonb into v_existing_secret
        from vault.decrypted_secrets where id=v_secret_id;
      exception when others then
        v_existing_secret := '{}'::jsonb;
      end;
    end if;
    v_merged_secret := coalesce(v_existing_secret,'{}'::jsonb) || p_secret_patch;

    if v_secret_id is null then
      select vault.create_secret(v_merged_secret::text,v_secret_name,'SaaS payment gateway credentials for '||v_provider)
      into v_secret_id;
    else
      perform vault.update_secret(v_secret_id,v_merged_secret::text,v_secret_name,'SaaS payment gateway credentials for '||v_provider);
    end if;
  end if;

  insert into public.payment_provider_settings(provider,display_name,enabled,mode,public_config,secret_id,updated_at)
  values(v_provider,coalesce(nullif(trim(p_display_name),''),initcap(v_provider)),coalesce(p_enabled,false),p_mode,coalesce(p_public_config,'{}'::jsonb),v_secret_id,now())
  on conflict(provider) do update set
    display_name=excluded.display_name,
    enabled=excluded.enabled,
    mode=excluded.mode,
    public_config=excluded.public_config,
    secret_id=coalesce(excluded.secret_id,public.payment_provider_settings.secret_id),
    updated_at=now();
end $function$
;

REVOKE ALL ON FUNCTION public."v34_admin_save_payment_provider"(p_provider text, p_enabled boolean, p_mode text, p_display_name text, p_public_config jsonb, p_secret_patch jsonb) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v34_admin_save_payment_provider"(p_provider text, p_enabled boolean, p_mode text, p_display_name text, p_public_config jsonb, p_secret_patch jsonb) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v34_admin_save_payment_provider"(p_provider text, p_enabled boolean, p_mode text, p_display_name text, p_public_config jsonb, p_secret_patch jsonb) TO "service_role";

CREATE OR REPLACE FUNCTION public.v36_admin_delete_business(p_business_id uuid, p_confirmation_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_business_name text;
  v_user_ids uuid[];
  v_user_count integer := 0;
begin
  if not public.is_super_admin() then
    raise exception 'Super Admin access required';
  end if;

  select name into v_business_name
  from public.businesses
  where id = p_business_id;

  if v_business_name is null then
    raise exception 'Business not found';
  end if;

  if trim(coalesce(p_confirmation_name, '')) <> trim(v_business_name) then
    raise exception 'Business name confirmation does not match';
  end if;

  if exists (
    select 1
    from public.profiles
    where business_id = p_business_id
      and id = auth.uid()
  ) then
    raise exception 'You cannot delete the business account you are currently logged into';
  end if;

  select coalesce(array_agg(id), '{}'::uuid[]), count(*)::integer
    into v_user_ids, v_user_count
  from public.profiles
  where business_id = p_business_id;

  delete from public.google_calendar_sync_log where business_id = p_business_id;
  delete from public.google_calendar_event_links where business_id = p_business_id;
  delete from public.google_calendar_connections where business_id = p_business_id;
  delete from public.job_schedule_assignments where business_id = p_business_id;
  delete from public.job_schedules where business_id = p_business_id;
  delete from public.job_recurrence_series where business_id = p_business_id;
  delete from public.referrals
   where referring_business_id = p_business_id
      or referred_business_id = p_business_id;

  if exists (
    select 1
    from public.accounting_journals
    where business_id = p_business_id
      and status in ('posted', 'reversed')
  ) then
    raise exception 'This business has posted accounting journals and cannot be deleted. Suspend or close it instead.';
  end if;
  delete from public.accounting_journal_lines where business_id = p_business_id;
  delete from public.accounting_journals where business_id = p_business_id;
  delete from public.accounting_accounts where business_id = p_business_id;
  delete from public.accounting_periods where business_id = p_business_id;
  delete from public.accounting_migration_exceptions where business_id = p_business_id;

  delete from public.financial_budget_month_values where business_id = p_business_id;
  delete from public.financial_budget_lines where business_id = p_business_id;
  delete from public.financial_budgets where business_id = p_business_id;
  delete from public.financial_category_mappings where business_id = p_business_id;
  delete from public.gst_returns where business_id = p_business_id;
  delete from public.financial_settings where business_id = p_business_id;
  delete from public.financial_audit_log where business_id = p_business_id;
  delete from public.accounting_audit_log where business_id = p_business_id;

  delete from public.businesses
  where id = p_business_id;

  if coalesce(array_length(v_user_ids, 1), 0) > 0 then
    delete from auth.users
    where id = any(v_user_ids);
  end if;

  return jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'business_name', v_business_name,
    'users_deleted', v_user_count
  );
end
$function$
;

REVOKE ALL ON FUNCTION public."v36_admin_delete_business"(p_business_id uuid, p_confirmation_name text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v36_admin_delete_business"(p_business_id uuid, p_confirmation_name text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v36_admin_delete_business"(p_business_id uuid, p_confirmation_name text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v55_lock_finalised_pay_run()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op='DELETE' and old.status in ('finalised','reversed') then
    raise exception 'Finalised or reversed pay runs are accounting records and cannot be deleted. Reverse a finalised pay run instead.';
  end if;
  if tg_op='UPDATE' and old.status in ('finalised','reversed') then
    if old.status='finalised' and new.status='reversed'
       and current_setting('frindly.payroll_reversal',true)='allowed'
       and (to_jsonb(new)-'status'-'updated_at'-'updated_by') is not distinct from (to_jsonb(old)-'status'-'updated_at'-'updated_by') then
      return new;
    end if;
    raise exception 'Finalised or reversed pay runs are locked accounting records.';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end $function$
;

REVOKE ALL ON FUNCTION public."v55_lock_finalised_pay_run"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v55_lock_finalised_pay_run"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v55_lock_finalised_payroll_child()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rid uuid;
begin
  if tg_op='DELETE' then
    if tg_table_name='payroll_pay_run_employees' then rid=old.pay_run_id;
    elsif tg_table_name='payroll_pay_run_lines' then select pay_run_id into rid from public.payroll_pay_run_employees where id=old.pay_run_employee_id;
    else rid=old.pay_run_id; end if;
    if exists(select 1 from public.payroll_pay_runs where id=rid and status in ('finalised','reversed')) then
      raise exception 'Finalised or reversed payroll detail is an accounting record and cannot be deleted.';
    end if;
    return old;
  end if;
  if tg_table_name='payroll_pay_run_employees' then rid=new.pay_run_id;
  elsif tg_table_name='payroll_pay_run_lines' then select pay_run_id into rid from public.payroll_pay_run_employees where id=new.pay_run_employee_id;
  else rid=new.pay_run_id; end if;
  if exists(select 1 from public.payroll_pay_runs where id=rid and status in ('finalised','reversed')) then
    if tg_table_name='payroll_payslips' and tg_op='UPDATE'
       and new.id=old.id and new.business_id=old.business_id and new.pay_run_id=old.pay_run_id
       and new.pay_run_employee_id=old.pay_run_employee_id and new.employee_id=old.employee_id
       and new.payslip_number=old.payslip_number and new.payslip_data is not distinct from old.payslip_data
       and new.generated_at=old.generated_at then return new; end if;
    raise exception 'Finalised or reversed payroll detail is locked.';
  end if;
  return new;
end $function$
;

REVOKE ALL ON FUNCTION public."v55_lock_finalised_payroll_child"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v55_lock_finalised_payroll_child"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v55_payroll_access(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else public.v6147_can_read_area(p_business_id,'payroll')
      and exists(select 1 from public.modules where slug='payroll' and is_active)
      and not exists(
        select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
        where bm.business_id=p_business_id and m.slug='payroll' and bm.status in ('suspended','canceled')
      )
      and (
        exists(
          select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
          where bm.business_id=p_business_id and m.slug='payroll'
            and (bm.status='active' or (bm.status='trialing' and (bm.trial_ends_at is null or bm.trial_ends_at>=now())))
        )
        or exists(
          select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
          where s.business_id=p_business_id
            and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
            and (s.cancel_at is null or s.cancel_at>now())
            and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
            and 'payroll'=any(coalesce(p.included_modules,'{}'::text[]))
        )
      )
  end
$function$
;

REVOKE ALL ON FUNCTION public."v55_payroll_access"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v55_payroll_access"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v55_payroll_access"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v55_validate_payroll_refs()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_table_name in ('payroll_timesheets','payroll_employee_leave','payroll_leave_transactions','payroll_employee_documents','payroll_pay_run_employees','payroll_payslips') then
    if new.employee_id is not null and not exists(select 1 from payroll_employees e where e.id=new.employee_id and e.business_id=new.business_id) then raise exception 'Employee does not belong to this business'; end if;
  end if;
  if tg_table_name='payroll_timesheets' then
    if new.job_costing_id is not null and not exists(select 1 from job_costings j where j.id=new.job_costing_id and j.business_id=new.business_id) then raise exception 'Job does not belong to this business'; end if;
    if new.customer_id is not null and not exists(select 1 from customers c where c.id=new.customer_id and c.business_id=new.business_id) then raise exception 'Customer does not belong to this business'; end if;
    if new.pay_item_id is not null and not exists(select 1 from payroll_pay_items p where p.id=new.pay_item_id and p.business_id=new.business_id) then raise exception 'Pay item does not belong to this business'; end if;
  elsif tg_table_name='payroll_employee_leave' then
    if not exists(select 1 from payroll_leave_types l where l.id=new.leave_type_id and l.business_id=new.business_id) then raise exception 'Leave type does not belong to this business'; end if;
  elsif tg_table_name='payroll_leave_transactions' then
    if not exists(select 1 from payroll_leave_types l where l.id=new.leave_type_id and l.business_id=new.business_id) then raise exception 'Leave type does not belong to this business'; end if;
    if new.pay_run_id is not null and not exists(select 1 from payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
  elsif tg_table_name='payroll_employee_documents' then
    if new.document_type_id is not null and not exists(select 1 from payroll_document_types d where d.id=new.document_type_id and d.business_id=new.business_id) then raise exception 'Document type does not belong to this business'; end if;
  elsif tg_table_name='payroll_pay_run_employees' then
    if not exists(select 1 from payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
  elsif tg_table_name='payroll_pay_run_lines' then
    if not exists(select 1 from payroll_pay_run_employees e where e.id=new.pay_run_employee_id and e.business_id=new.business_id) then raise exception 'Pay run employee does not belong to this business'; end if;
    if new.pay_item_id is not null and not exists(select 1 from payroll_pay_items p where p.id=new.pay_item_id and p.business_id=new.business_id) then raise exception 'Pay item does not belong to this business'; end if;
    if new.job_costing_id is not null and not exists(select 1 from job_costings j where j.id=new.job_costing_id and j.business_id=new.business_id) then raise exception 'Job does not belong to this business'; end if;
    if new.expense_category_id is not null and not exists(select 1 from expense_categories c where c.id=new.expense_category_id and c.business_id=new.business_id) then raise exception 'Expense category does not belong to this business'; end if;
  elsif tg_table_name='payroll_payslips' then
    if not exists(select 1 from payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
    if not exists(select 1 from payroll_pay_run_employees e where e.id=new.pay_run_employee_id and e.business_id=new.business_id and e.pay_run_id=new.pay_run_id and e.employee_id=new.employee_id) then raise exception 'Payslip references do not belong together in this business'; end if;
  elsif tg_table_name='payroll_financial_transactions' then
    if not exists(select 1 from payroll_pay_runs r where r.id=new.pay_run_id and r.business_id=new.business_id) then raise exception 'Pay run does not belong to this business'; end if;
    if new.expense_category_id is not null and not exists(select 1 from expense_categories c where c.id=new.expense_category_id and c.business_id=new.business_id) then raise exception 'Expense category does not belong to this business'; end if;
  end if;
  return new;
end
$function$
;

REVOKE ALL ON FUNCTION public."v55_validate_payroll_refs"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v55_validate_payroll_refs"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v58_financials_access(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else public.v6147_can_read_area(p_business_id,'financials')
      and exists(select 1 from public.modules where slug='financials' and is_active)
      and not exists(
        select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
        where bm.business_id=p_business_id and m.slug='financials' and bm.status in ('suspended','canceled')
      )
      and (
        exists(
          select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
          where bm.business_id=p_business_id and m.slug='financials'
            and (bm.status='active' or (bm.status='trialing' and (bm.trial_ends_at is null or bm.trial_ends_at>=now())))
        )
        or exists(
          select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
          where s.business_id=p_business_id
            and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
            and (s.cancel_at is null or s.cancel_at>now())
            and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
            and 'financials'=any(coalesce(p.included_modules,'{}'::text[]))
        )
      )
  end
$function$
;

REVOKE ALL ON FUNCTION public."v58_financials_access"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v58_financials_access"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v58_financials_access"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61101f_late_expense_status(p_business_id uuid, p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.expenses%rowtype; cfg jsonb; basis text; gr public.gst_returns%rowtype; ap public.accounting_periods%rowtype; pay_date date; tax_date date; existing public.late_transaction_adjustments%rowtype; eligible boolean:=false; why text;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id or not public.v6147_can_read_area(p_business_id,'expenses') then raise exception 'Expense access denied'; end if;
 select * into e from public.expenses where id=p_expense_id and business_id=p_business_id; if not found then raise exception 'Expense not found'; end if;
 cfg:=public.v6170e_gst_settings(e.invoice_date); basis:=coalesce(cfg->>'accounting_basis','invoice');
 select * into ap from public.accounting_periods where business_id=p_business_id and status='closed' and e.invoice_date between period_start and period_end order by period_end desc limit 1;
 if basis='invoice' then tax_date:=e.invoice_date; else select min(payment_date) into pay_date from public.expense_payments where business_id=p_business_id and expense_id=e.id; tax_date:=pay_date; end if;
 if tax_date is not null then select * into gr from public.gst_returns where business_id=p_business_id and status='finalised' and tax_date between period_start and period_end order by period_end desc limit 1; end if;
 select * into existing from public.late_transaction_adjustments where business_id=p_business_id and expense_id=e.id;
 if gr.id is not null and coalesce(e.gst_amount,0)<>0 and current_date-e.invoice_date<=730 then eligible:=true; why:='IRD permits unclaimed purchases or expenses to be claimed in a next return in specified cases, including a clear mistake or simple oversight, subject to the applicable time limit.';
 elsif gr.id is not null then why:='This GST amount relates to a finalised return and should be reviewed for amendment or other IRD correction treatment.';
 elsif basis in ('payments','hybrid') and tax_date is null then why:='No GST correction is currently required because purchase GST is attributed using payment information and no payment has been recorded yet.';
 else why:='No finalised GST return is affected by the currently available transaction/payment dates.'; end if;
 return jsonb_build_object('expense_id',e.id,'invoice_date',e.invoice_date,'entered_at',coalesce(e.upload_date,e.created_at),'gst_basis',basis,'gst_amount',coalesce(e.gst_amount,0),'tax_date',tax_date,'accounting_period_closed',ap.id is not null,'accounting_period_start',ap.period_start,'accounting_period_end',ap.period_end,'gst_return_finalised',gr.id is not null,'gst_return_id',gr.id,'gst_period_start',gr.period_start,'gst_period_end',gr.period_end,'eligible_current_period',eligible,'explanation',why,'existing_status',existing.status,'existing_treatment',existing.treatment);
end $function$
;

REVOKE ALL ON FUNCTION public."v61101f_late_expense_status"(p_business_id uuid, p_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61101f_late_expense_status"(p_business_id uuid, p_expense_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61101f_late_expense_status"(p_business_id uuid, p_expense_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61101f_record_late_expense(p_business_id uuid, p_expense_id uuid, p_treatment text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s jsonb; e public.expenses%rowtype; adj uuid; corr uuid; st text;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id or not public.v6147_can_write_area(p_business_id,'expenses') then raise exception 'Expense access denied'; end if;
 if p_treatment not in ('current_period','prior_return_action','accounting_only') then raise exception 'Choose a valid late-transaction treatment'; end if;
 if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Enter a reason for the late transaction'; end if;
 s:=public.v61101f_late_expense_status(p_business_id,p_expense_id); select * into e from public.expenses where id=p_expense_id and business_id=p_business_id;
 if p_treatment='current_period' and not coalesce((s->>'eligible_current_period')::boolean,false) then raise exception 'This transaction is not eligible for automatic current-period GST correction'; end if;
 if p_treatment='current_period' and coalesce(e.gst_amount,0)<>0 then
  insert into public.gst_adjustments(business_id,adjustment_date,adjustment_type,direction,gst_amount,reason,reference,evidence,source_type,source_id,status,created_by,updated_by)
  values(p_business_id,current_date,'other_credit','credit',abs(e.gst_amount),trim(p_reason),e.expense_number,'Late supplier bill; original invoice date preserved.','expense',e.id,'active',auth.uid(),auth.uid()) returning id into adj;
  st:='approved_current_period';
 elsif p_treatment='prior_return_action' then st:='requires_prior_return_action'; else st:='accounting_only'; end if;
 if coalesce((s->>'gst_return_finalised')::boolean,false) then
  insert into public.gst_correction_items(business_id,affected_return_id,source_type,source_id,discovered_date,original_amount,corrected_amount,gst_difference,reason,resolution_status,resolution_notes,created_by)
  values(p_business_id,(s->>'gst_return_id')::uuid,'expense',e.id,current_date,0,e.gst_amount,e.gst_amount,trim(p_reason),
    case when p_treatment='current_period' then 'resolved' else 'review_required' end,
    case when p_treatment='current_period' then 'Correction recorded as a current-period GST adjustment. Original finalised return snapshot is unchanged.' else 'Original finalised return snapshot is unchanged; previous return requires review.' end,
    auth.uid()) returning id into corr;
 end if;
 insert into public.late_transaction_adjustments(business_id,expense_id,original_invoice_date,original_gst_return_id,original_gst_period_start,original_gst_period_end,original_return_status,accounting_period_id,gst_basis,gst_amount,treatment,adjustment_date,adjustment_reason,rule_version,status,gst_adjustment_id,correction_item_id,created_by,updated_by)
 values(p_business_id,e.id,e.invoice_date,nullif(s->>'gst_return_id','')::uuid,nullif(s->>'gst_period_start','')::date,nullif(s->>'gst_period_end','')::date,case when coalesce((s->>'gst_return_finalised')::boolean,false) then 'finalised' end,(select id from public.accounting_periods where business_id=p_business_id and status='closed' and e.invoice_date between period_start and period_end order by period_end desc limit 1),s->>'gst_basis',coalesce(e.gst_amount,0),p_treatment,case when p_treatment='current_period' then current_date end,trim(p_reason),'NZ-IRD-fixing-mistakes-2026-09-29',st,adj,corr,auth.uid(),auth.uid())
 on conflict(business_id,expense_id) do update set treatment=excluded.treatment,adjustment_date=excluded.adjustment_date,adjustment_reason=excluded.adjustment_reason,rule_version=excluded.rule_version,status=excluded.status,gst_adjustment_id=coalesce(excluded.gst_adjustment_id,late_transaction_adjustments.gst_adjustment_id),correction_item_id=coalesce(excluded.correction_item_id,late_transaction_adjustments.correction_item_id),updated_at=now(),updated_by=auth.uid();
 return jsonb_build_object('ok',true,'status',st,'gst_adjustment_id',adj,'correction_item_id',corr);
end $function$
;

REVOKE ALL ON FUNCTION public."v61101f_record_late_expense"(p_business_id uuid, p_expense_id uuid, p_treatment text, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61101f_record_late_expense"(p_business_id uuid, p_expense_id uuid, p_treatment text, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61101f_record_late_expense"(p_business_id uuid, p_expense_id uuid, p_treatment text, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_account_role_id(p_business_id uuid, p_role text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_role text:=lower(trim(coalesce(p_role,'')));v_id uuid;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id then raise exception 'Business access denied';end if;
 if not public.v6169a_accountant_centre_access(p_business_id,false) then raise exception 'Accounting access denied';end if;
 select a.id into v_id from public.accounting_accounts a where a.business_id=p_business_id and coalesce(a.archived,false)=false and
 case v_role
 when 'bank' then a.system_key in('bank_main','bank') or a.account_code in('090','1000')
 when 'accounts_receivable' then a.system_key='accounts_receivable' or a.account_code in('120','1100')
 when 'accounts_payable' then a.system_key='accounts_payable' or a.account_code='2000'
 when 'gst_output' then a.system_key in('gst_collected','gst_payable') or a.account_code in('260','2100')
 when 'gst_input' then a.system_key in('gst_paid','gst_receivable') or a.account_code in('261','1200')
 when 'fixed_equipment' then a.system_key in('fixed_assets_equipment','fixed_assets') or a.account_code in('150','1500')
 when 'accum_depreciation' then a.system_key in('accum_depn_equipment','accumulated_depreciation') or a.account_code in('155','1590')
 when 'depreciation_expense' then a.system_key in('depreciation_expense','depreciation') or a.account_code in('315','6200')
 when 'owner_drawings' then a.system_key='owner_drawings' or a.account_code in('800','3100')
 when 'owner_funds' then a.system_key in('owner_funds','opening_balance_equity') or a.account_code in('3000','859')
 when 'sales' then a.system_key='sales' or a.account_code in('200','4000')
 when 'general_expense' then a.system_key in('general_expenses','business_expenses') or a.account_code in('429','6000')
 when 'payroll_liability' then a.system_key='payroll_liability' or a.account_code='265'
 else false end
 order by case
 when v_role='bank' and a.system_key='bank_main' then 0 when v_role='bank' and a.system_key='bank' then 1
 when v_role='gst_output' and a.system_key='gst_collected' then 0 when v_role='gst_output' and a.system_key='gst_payable' then 1
 when v_role='gst_input' and a.system_key='gst_paid' then 0 when v_role='gst_input' and a.system_key='gst_receivable' then 1
 when v_role='fixed_equipment' and a.system_key='fixed_assets_equipment' then 0 when v_role='fixed_equipment' and a.system_key='fixed_assets' then 1
 when v_role='accum_depreciation' and a.system_key='accum_depn_equipment' then 0 when v_role='accum_depreciation' and a.system_key='accumulated_depreciation' then 1
 when v_role='depreciation_expense' and a.system_key='depreciation_expense' then 0 when v_role='depreciation_expense' and a.system_key='depreciation' then 1
 when v_role='general_expense' and a.system_key='general_expenses' then 0 when v_role='general_expense' and a.system_key='business_expenses' then 1
 else 2 end,a.account_code limit 1;
 return v_id;
end $function$
;

REVOKE ALL ON FUNCTION public."v61105_account_role_id"(p_business_id uuid, p_role text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_account_role_id"(p_business_id uuid, p_role text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_account_role_id"(p_business_id uuid, p_role text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_effective_tax_status(p_on date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  bid uuid := public.current_business_id(); d date := coalesce(p_on,current_date); v_jurisdiction text;
  h public.gst_settings_history%rowtype; f public.financial_settings%rowtype;
  registered boolean; statutory_rate numeric; effective_rate numeric; effective_from date;
  tax_identifier text; basis text; frequency text; settings_source text;
begin
  if bid is null or not public.v6147_can_read_area(bid,'core') then raise exception 'Tax status access denied' using errcode='42501'; end if;
  v_jurisdiction := public.v6170f_business_country();
  if v_jurisdiction not in ('NZ','AU') then raise exception 'Tax status is not configured for jurisdiction %',v_jurisdiction using errcode='22023'; end if;
  select * into h from public.gst_settings_history x
   where x.business_id=bid and upper(coalesce(x.jurisdiction,'NZ'))=v_jurisdiction and x.effective_from<=d
   order by x.effective_from desc limit 1;
  if found then
    registered:=h.gst_registered; effective_from:=h.effective_from; tax_identifier:=coalesce(h.tax_identifier,h.gst_number);
    basis:=h.accounting_basis; frequency:=h.filing_frequency; settings_source:='gst_settings_history';
  else
    select * into f from public.financial_settings x where x.business_id=bid limit 1;
    if v_jurisdiction='AU' then
      registered:=coalesce(f.gst_registered,false);
      tax_identifier:=coalesce((select b.settings->>'abn' from public.businesses b where b.id=bid),f.gst_number);
      basis:=case when f.gst_accounting_basis='payments' then 'cash' else 'non_cash' end;
      frequency:=case when f.gst_filing_frequency='monthly' then 'monthly' when f.gst_filing_frequency='annual' then 'annual' else 'quarterly' end;
    else
      registered:=coalesce(f.gst_registered,true); tax_identifier:=f.gst_number;
      basis:=coalesce(f.gst_accounting_basis,'invoice'); frequency:=coalesce(f.gst_filing_frequency,'two_monthly');
    end if;
    effective_from:=null; settings_source:='financial_settings_fallback';
  end if;
  select r.numeric_value into statutory_rate from public.country_business_tax_rules r
   where r.country_code=v_jurisdiction and r.rule_type='gst' and r.rule_key='standard_rate_percent' and r.active=true
     and r.effective_from<=d and (r.effective_to is null or r.effective_to>=d)
   order by r.effective_from desc limit 1;
  if statutory_rate is null or statutory_rate<=0 then raise exception 'Authoritative % GST rate is unavailable for %',v_jurisdiction,d using errcode='22023'; end if;
  effective_rate:=case when registered then statutory_rate else 0 end;
  return jsonb_build_object('version','v61.105-phase1','business_id',bid,'as_of_date',d,'jurisdiction',v_jurisdiction,
   'gst_registered',registered,'statutory_rate_percent',statutory_rate,'effective_rate_percent',effective_rate,
   'default_tax_treatment',case when registered then 'standard_gst' when v_jurisdiction='AU' then 'out_of_scope_unregistered' else 'no_gst_unregistered' end,
   'registration_effective_from',effective_from,'tax_identifier',tax_identifier,'accounting_basis',basis,'filing_frequency',frequency,
   'settings_source',settings_source,'rate_source','country_business_tax_rules');
end; $function$
;

REVOKE ALL ON FUNCTION public."v61105_effective_tax_status"(p_on date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_effective_tax_status"(p_on date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_effective_tax_status"(p_on date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_gst_calculate_boundary(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  bid uuid:=public.current_business_id(); d date; isreg boolean; prevreg boolean:=false;
  seg_start date; seg_end date; part jsonb; cfg jsonb; basis text;
  sales_ex numeric:=0; sales_gst numeric:=0; purch_ex numeric:=0; purch_gst numeric:=0;
  debit_adj numeric:=0; credit_adj numeric:=0;
  sales_items jsonb:='[]'::jsonb; purchase_items jsonb:='[]'::jsonb;
  adjustment_items jsonb:='[]'::jsonb; review jsonb:='[]'::jsonb;
  windows jsonb:='[]'::jsonb; registered_days int:=0; total_days int;
begin
  if bid is null or not public.v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid GST period'; end if;
  total_days:=p_to-p_from+1;
  for d in select generate_series(p_from,p_to,interval '1 day')::date loop
    isreg:=coalesce((public.v6170e_gst_settings(d)->>'gst_registered')::boolean,false);
    if isreg then
      registered_days:=registered_days+1;
      if not prevreg then seg_start:=d; end if;
    end if;
    if prevreg and not isreg then
      seg_end:=d-1;
      part:=public.v6170e_gst_calculate(seg_start,seg_end);
      if cfg is null then cfg:=part->'settings'; basis:=part->>'basis'; end if;
      sales_ex:=sales_ex+coalesce((part->>'sales_ex_gst')::numeric,0);
      sales_gst:=sales_gst+coalesce((part->>'gst_collected')::numeric,0);
      purch_ex:=purch_ex+coalesce((part->>'purchases_ex_gst')::numeric,0);
      purch_gst:=purch_gst+coalesce((part->>'gst_paid')::numeric,0);
      debit_adj:=debit_adj+coalesce((part->>'debit_adjustments')::numeric,0);
      credit_adj:=credit_adj+coalesce((part->>'credit_adjustments')::numeric,0);
      sales_items:=sales_items||coalesce(part->'sales_items','[]'::jsonb);
      purchase_items:=purchase_items||coalesce(part->'purchase_items','[]'::jsonb);
      adjustment_items:=adjustment_items||coalesce(part->'adjustment_items','[]'::jsonb);
      review:=review||coalesce(part->'review_items','[]'::jsonb);
      windows:=windows||jsonb_build_array(jsonb_build_object('from',seg_start,'to',seg_end));
    end if;
    prevreg:=isreg;
  end loop;
  if prevreg then
    seg_end:=p_to;
    part:=public.v6170e_gst_calculate(seg_start,seg_end);
    if cfg is null then cfg:=part->'settings'; basis:=part->>'basis'; end if;
    sales_ex:=sales_ex+coalesce((part->>'sales_ex_gst')::numeric,0);
    sales_gst:=sales_gst+coalesce((part->>'gst_collected')::numeric,0);
    purch_ex:=purch_ex+coalesce((part->>'purchases_ex_gst')::numeric,0);
    purch_gst:=purch_gst+coalesce((part->>'gst_paid')::numeric,0);
    debit_adj:=debit_adj+coalesce((part->>'debit_adjustments')::numeric,0);
    credit_adj:=credit_adj+coalesce((part->>'credit_adjustments')::numeric,0);
    sales_items:=sales_items||coalesce(part->'sales_items','[]'::jsonb);
    purchase_items:=purchase_items||coalesce(part->'purchase_items','[]'::jsonb);
    adjustment_items:=adjustment_items||coalesce(part->'adjustment_items','[]'::jsonb);
    review:=review||coalesce(part->'review_items','[]'::jsonb);
    windows:=windows||jsonb_build_array(jsonb_build_object('from',seg_start,'to',seg_end));
  end if;
  if registered_days=0 then
    cfg:=public.v6170e_gst_settings(p_to);
    return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',cfg->>'accounting_basis','sales_ex_gst',0,'gst_collected',0,'purchases_ex_gst',0,'gst_paid',0,'debit_adjustments',0,'credit_adjustments',0,'gst_net',0,'sales_items','[]'::jsonb,'purchase_items','[]'::jsonb,'adjustment_items','[]'::jsonb,'registered_windows','[]'::jsonb,'review_items',jsonb_build_array(jsonb_build_object('severity','blocking','code','not_registered','message','Business is not GST registered for this period.')),'calculation_version','v61.105-phase9');
  end if;
  if registered_days<total_days then
    review:=review||jsonb_build_array(jsonb_build_object('severity','info','code','registration_boundary','message','This GST period crosses a GST registration boundary. Only dates when the business was GST registered are included.','registered_windows',windows));
  end if;
  return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',basis,'sales_ex_gst',round(sales_ex,2),'gst_collected',round(sales_gst,2),'purchases_ex_gst',round(purch_ex,2),'gst_paid',round(purch_gst,2),'debit_adjustments',round(debit_adj,2),'credit_adjustments',round(credit_adj,2),'gst_net',round(sales_gst+debit_adj-purch_gst-credit_adj,2),'sales_items',sales_items,'purchase_items',purchase_items,'adjustment_items',adjustment_items,'registered_windows',windows,'review_items',review,'calculation_version','v61.105-phase9');
end $function$
;

REVOKE ALL ON FUNCTION public."v61105_gst_calculate_boundary"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_gst_calculate_boundary"(p_from date, p_to date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_gst_calculate_boundary"(p_from date, p_to date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_ledger_reconciliation(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id();v jsonb;
begin
 if auth.uid() is null or b is null or p_from is null or p_to is null or p_from>p_to then raise exception 'Choose a business and valid reconciliation period';end if;
 if not public.v6169a_accountant_centre_access(b,false) then raise exception 'Accounting access denied';end if;
 with issues as(
 select 'invoice_missing_journal' type,i.id source_id,i.invoice_date event_date,i.invoice_number reference,round(i.total,2) amount,case when i.lifecycle_version is null then 'legacy_pre_lifecycle' else 'posting_pending' end reason from public.invoices i where i.business_id=b and i.invoice_date between p_from and p_to and i.lifecycle_state='issued' and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='invoice' and j.source_id=i.id and j.status in('posted','reversed'))
 union all select 'expense_missing_journal',e.id,e.invoice_date,e.expense_number,round(e.total_amount,2),case when e.lifecycle_version is null then 'legacy_pre_lifecycle' else 'posting_pending' end from public.expenses e where e.business_id=b and e.invoice_date between p_from and p_to and e.lifecycle_state='recorded' and coalesce(e.archived,false)=false and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='expense' and j.source_id=e.id and j.status in('posted','reversed'))
 union all select 'customer_payment_missing_journal',p.id,p.payment_date,coalesce(p.reference,''),round(p.amount,2),'posting_pending' from public.customer_payments p where p.business_id=b and p.payment_date between p_from and p_to and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_payment' and j.source_id=p.id and j.status in('posted','reversed'))
 union all select 'supplier_payment_missing_journal',p.id,p.payment_date,coalesce(p.reference,''),round(p.amount,2),'posting_pending' from public.expense_payments p where p.business_id=b and p.payment_date between p_from and p_to and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='supplier_payment' and j.source_id=p.id and j.status in('posted','reversed'))
 union all select 'payroll_missing_journal',p.id,p.pay_date,p.pay_run_number,round(p.total_employment_cost,2),case when p.finalised_at is not null and p.finalised_at<timestamp '2026-10-01' then 'legacy_payroll_unverified_cash_history' else 'review_required' end from public.payroll_pay_runs p where p.business_id=b and p.pay_date between p_from and p_to and p.status in('finalised','reversed') and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='payroll' and j.source_id=p.id and j.status in('posted','reversed')) and not exists(select 1 from lateral (select e.event_type from public.accounting_legacy_payroll_resolution_events e where e.business_id=b and e.pay_run_id=p.id order by e.created_at desc,e.id desc limit 1) lr where lr.event_type='resolve')
 union all select 'customer_credit_missing_journal',c.id,c.credit_date,c.credit_note_number,round(c.total_amount,2),case when exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='invoice' and j.source_id=c.original_invoice_id and j.status in('posted','reversed')) then 'review_required' else 'legacy_unposted_original' end from public.customer_credit_notes c where c.business_id=b and c.credit_date between p_from and p_to and c.lifecycle_state='issued' and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_credit_note' and j.source_id=c.id and j.status in('posted','reversed'))
 union all select 'supplier_credit_missing_journal',c.id,c.credit_date,c.credit_note_number,round(c.total_amount,2),case when exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='expense' and j.source_id=c.original_expense_id and j.status in('posted','reversed')) then 'review_required' else 'legacy_unposted_original' end from public.supplier_credits c where c.business_id=b and c.credit_date between p_from and p_to and c.lifecycle_state='recorded' and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='supplier_credit' and j.source_id=c.id and j.status in('posted','reversed'))
 union all select 'customer_refund_missing_journal',r.id,r.refund_date,r.refund_number,round(r.amount,2),case when exists(select 1 from public.customer_credit_notes c join public.accounting_journals j on j.business_id=c.business_id and j.source_type='customer_credit_note' and j.source_id=c.id and j.status in('posted','reversed') where c.business_id=b and c.customer_id=r.customer_id and c.lifecycle_state='issued') then 'review_required' else 'legacy_unposted_credit' end from public.customer_refunds r where r.business_id=b and r.refund_date between p_from and p_to and r.lifecycle_state='recorded' and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_refund' and j.source_id=r.id and j.status in('posted','reversed'))
 union all select 'supplier_refund_missing_journal',r.id,r.refund_date,r.refund_number,round(r.amount,2),case when exists(select 1 from public.supplier_refund_allocations a join public.accounting_journals j on j.business_id=a.business_id and j.source_type='supplier_credit' and j.source_id=a.supplier_credit_id and j.status in('posted','reversed') where a.business_id=b and a.supplier_refund_id=r.id) then case when public.v6170b_account(b,'payment_clearing') is null then 'refund_clearing_account_required' else 'review_required' end else 'legacy_unposted_credit' end from public.supplier_refunds r where r.business_id=b and r.refund_date between p_from and p_to and r.lifecycle_state='recorded' and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='supplier_refund' and j.source_id=r.id and j.status in('posted','reversed'))),
 dups as(select 'duplicate_journal' type,j.source_id,min(j.journal_date) event_date,j.source_type||':'||j.source_id::text reference,0::numeric amount,'duplicate_posting' reason from public.accounting_journals j where j.business_id=b and j.journal_date between p_from and p_to and j.status in('posted','reversed') and j.source_id is not null group by j.source_type,j.source_id,j.posting_version having count(*)>1),
 unbal as(select 'unbalanced_journal' type,j.id,j.journal_date,coalesce(j.source_reference,j.id::text),abs(round(sum(l.debit)-sum(l.credit),2)),'journal_not_balanced' from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.business_id=b and j.journal_date between p_from and p_to and j.status in('posted','reversed') group by j.id having round(sum(l.debit),2)<>round(sum(l.credit),2)),all_issues as(select * from issues union all select * from dups union all select * from unbal)
 select jsonb_build_object('version','v61.105-phase13m','business_id',b,'period_start',p_from,'period_end',p_to,'issue_count',count(*),'posting_pending_count',count(*)filter(where reason='posting_pending'),'legacy_review_count',count(*)filter(where reason like 'legacy%'),'review_required_count',count(*)filter(where reason='review_required'),'configuration_required_count',count(*)filter(where reason='refund_clearing_account_required'),'critical_integrity_count',count(*)filter(where type in('duplicate_journal','unbalanced_journal')),'issues',coalesce(jsonb_agg(jsonb_build_object('type',type,'source_id',source_id,'date',event_date,'reference',reference,'amount',amount,'reason',reason) order by event_date,type),'[]'::jsonb)) into v from all_issues;return v;
end $function$
;

REVOKE ALL ON FUNCTION public."v61105_ledger_reconciliation"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_ledger_reconciliation"(p_from date, p_to date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_ledger_reconciliation"(p_from date, p_to date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13a_payroll_finalise_posting_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.status='finalised' and old.status is distinct from 'finalised' then perform public.v61105_phase13a_post_payroll_journal(new.id); end if;
  return new;
end; $function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13a_payroll_finalise_posting_trigger"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13a_payroll_finalise_posting_trigger"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13a_post_payroll_journal(p_pay_run_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid;
  v_run public.payroll_pay_runs%rowtype;
  v_existing uuid;
  v_direct_wages uuid;
  v_indirect_wages uuid;
  v_direct_employer uuid;
  v_indirect_employer uuid;
  v_direct_reimb uuid;
  v_indirect_reimb uuid;
  v_net_payable uuid;
  v_liability uuid;
  v_lines jsonb := '[]'::jsonb;
  v_direct_gross numeric := 0;
  v_indirect_gross numeric := 0;
  v_direct_employer_cost numeric := 0;
  v_indirect_employer_cost numeric := 0;
  v_direct_reimb_cost numeric := 0;
  v_indirect_reimb_cost numeric := 0;
  v_net numeric := 0;
  v_total_cost numeric := 0;
  v_liability_credit numeric := 0;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_bid := public.current_business_id();
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'payroll') then raise exception 'Payroll write access denied'; end if;

  select * into v_run
  from public.payroll_pay_runs
  where id = p_pay_run_id
    and business_id = v_bid;

  if v_run.id is null then raise exception 'Pay run not found in active business'; end if;
  if v_run.status <> 'finalised' then raise exception 'Only finalised payroll can be posted'; end if;

  select id into v_existing
  from public.accounting_journals
  where business_id = v_bid
    and source_type = 'payroll'
    and source_id = p_pay_run_id
    and posting_version = 1
    and status in ('posted','reversed')
  limit 1;
  if v_existing is not null then return v_existing; end if;

  insert into public.accounting_accounts(
    business_id, account_code, account_name, account_type, account_subtype,
    normal_balance, tax_default, system_account_key, system_key,
    allow_manual_posting, report_section, is_system, is_control,
    xero_account_code, xero_account_type, xero_tax_type, description,
    created_by, updated_by
  ) values
    (v_bid,'266','Payroll Net Payable','liability','payroll','credit','NO_GST','payroll_net_payable','payroll_net_payable',false,'current_liabilities',true,true,'266','CURRLIAB','NONE','Net wages payable until the bank payment is reconciled.',auth.uid(),auth.uid()),
    (v_bid,'267','IRD / PAYE Payable','liability','payroll_tax','credit','NO_GST','payroll_liability','payroll_liability',false,'current_liabilities',true,true,'267','CURRLIAB','NONE','PAYE, KiwiSaver, ESCT and other payroll obligations payable to IRD or similar agencies.',auth.uid(),auth.uid()),
    (v_bid,'301','Direct Labour - Payroll','cost_of_sales',null,'debit','NO_GST','payroll_direct_wages','payroll_direct_wages',true,'cost_of_sales',true,false,'301','DIRECTCOSTS','NONE','Direct employee wages allocated to service/job delivery.',auth.uid(),auth.uid()),
    (v_bid,'470','Wages and Salaries','expense',null,'debit','NO_GST','payroll_indirect_wages','payroll_indirect_wages',true,'expense',true,false,'470','EXPENSE','NONE','Indirect employee wages and salaries.',auth.uid(),auth.uid()),
    (v_bid,'302','Direct Employer Payroll Costs','cost_of_sales',null,'debit','NO_GST','payroll_direct_employer_cost','payroll_direct_employer_cost',true,'cost_of_sales',true,false,'302','DIRECTCOSTS','NONE','Employer payroll costs for direct labour.',auth.uid(),auth.uid()),
    (v_bid,'471','Employer Payroll Costs','expense',null,'debit','NO_GST','payroll_indirect_employer_cost','payroll_indirect_employer_cost',true,'expense',true,false,'471','EXPENSE','NONE','Employer payroll costs for indirect labour.',auth.uid(),auth.uid()),
    (v_bid,'303','Direct Payroll Reimbursements','cost_of_sales',null,'debit','NO_GST','payroll_direct_reimbursements','payroll_direct_reimbursements',true,'cost_of_sales',true,false,'303','DIRECTCOSTS','NONE','Employee reimbursements and non-taxable allowances for direct labour.',auth.uid(),auth.uid()),
    (v_bid,'472','Payroll Reimbursements','expense',null,'debit','NO_GST','payroll_indirect_reimbursements','payroll_indirect_reimbursements',true,'expense',true,false,'472','EXPENSE','NONE','Employee reimbursements and non-taxable allowances for indirect labour.',auth.uid(),auth.uid())
  on conflict do nothing;

  select id into v_net_payable from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_net_payable' or system_key = 'payroll_net_payable' or account_code = '266') order by account_code limit 1;
  select id into v_liability from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_liability' or system_key = 'payroll_liability' or account_code in ('265','267')) order by case when account_code = '267' then 0 else 1 end, account_code limit 1;
  select id into v_direct_wages from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_direct_wages' and not archived limit 1;
  select id into v_indirect_wages from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_indirect_wages' and not archived limit 1;
  select id into v_direct_employer from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_direct_employer_cost' and not archived limit 1;
  select id into v_indirect_employer from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_indirect_employer_cost' and not archived limit 1;
  select id into v_direct_reimb from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_direct_reimbursements' and not archived limit 1;
  select id into v_indirect_reimb from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_indirect_reimbursements' and not archived limit 1;

  if v_net_payable is null or v_liability is null or v_direct_wages is null or v_indirect_wages is null or v_direct_employer is null or v_indirect_employer is null or v_direct_reimb is null or v_indirect_reimb is null then
    raise exception 'Payroll accounting accounts are not available; payroll was not posted';
  end if;

  with emp as (
    select
      pre.id,
      pre.employee_id,
      coalesce(pre.gross_pay, 0)::numeric gross,
      coalesce(pre.kiwisaver_employer_gross, 0)::numeric employer_gross,
      coalesce(pre.reimbursements, 0)::numeric reimbursements,
      coalesce(pre.total_employment_cost, 0)::numeric total_cost,
      case when coalesce(e.labour_classification, 'indirect') = 'direct' then 'direct' else 'indirect' end cls,
      coalesce((select sum(coalesce(l.amount,0)) from public.payroll_pay_run_lines l where l.pay_run_employee_id = pre.id and l.line_type = 'allowance' and coalesce(l.taxable,true) = false), 0)::numeric tax_free_allowances,
      coalesce((select sum(coalesce(l.amount,0)) from public.payroll_pay_run_lines l where l.pay_run_employee_id = pre.id and l.line_type = 'contribution'), 0)::numeric other_employer
    from public.payroll_pay_run_employees pre
    left join public.payroll_employees e
      on e.id = pre.employee_id
     and e.business_id = pre.business_id
    where pre.business_id = v_bid
      and pre.pay_run_id = p_pay_run_id
  )
  select
    coalesce(sum(gross) filter(where cls = 'direct'), 0),
    coalesce(sum(gross) filter(where cls = 'indirect'), 0),
    coalesce(sum(employer_gross + other_employer) filter(where cls = 'direct'), 0),
    coalesce(sum(employer_gross + other_employer) filter(where cls = 'indirect'), 0),
    coalesce(sum(reimbursements + tax_free_allowances) filter(where cls = 'direct'), 0),
    coalesce(sum(reimbursements + tax_free_allowances) filter(where cls = 'indirect'), 0),
    coalesce(sum(total_cost), 0)
  into v_direct_gross, v_indirect_gross, v_direct_employer_cost, v_indirect_employer_cost, v_direct_reimb_cost, v_indirect_reimb_cost, v_total_cost
  from emp;

  v_net := round(coalesce(v_run.net_pay, 0), 2);
  v_total_cost := round(v_total_cost, 2);
  v_liability_credit := round(v_total_cost - v_net, 2);

  if v_total_cost <= 0 or v_net < 0 or v_liability_credit < 0 then
    raise exception 'Payroll totals are invalid for accounting posting';
  end if;

  if round(v_direct_gross,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_direct_wages,'description','Direct payroll wages','debit',round(v_direct_gross,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_gross,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_indirect_wages,'description','Wages and salaries','debit',round(v_indirect_gross,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_direct_employer_cost,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_direct_employer,'description','Direct employer payroll costs','debit',round(v_direct_employer_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_employer_cost,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_indirect_employer,'description','Employer payroll costs','debit',round(v_indirect_employer_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_direct_reimb_cost,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_direct_reimb,'description','Direct payroll reimbursements','debit',round(v_direct_reimb_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_reimb_cost,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_indirect_reimb,'description','Payroll reimbursements','debit',round(v_indirect_reimb_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if v_net > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_net_payable,'description','Net wages payable','debit',0,'credit',v_net,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if v_liability_credit > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_liability,'description','Payroll deductions and employer obligations','debit',0,'credit',v_liability_credit,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;

  return public.v6192_create_posted_journal(v_bid, v_run.pay_date, 'payroll', 'payroll', p_pay_run_id, v_run.pay_run_number, 'Payroll ' || v_run.pay_run_number, v_lines);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13a_post_payroll_journal"(p_pay_run_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13a_post_payroll_journal"(p_pay_run_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_phase13a_post_payroll_journal"(p_pay_run_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13b_reverse_pay_run(p_pay_run_id uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_bid uuid; v_run public.payroll_pay_runs%rowtype; v_journal uuid; v_reversal uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if coalesce(btrim(p_reason),'')='' then raise exception 'A reversal reason is required'; end if;
  v_bid:=public.current_business_id();
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'payroll') then raise exception 'Payroll write access denied'; end if;
  select * into v_run from public.payroll_pay_runs where id=p_pay_run_id and business_id=v_bid for update;
  if v_run.id is null then raise exception 'Pay run not found in active business'; end if;
  if v_run.status='reversed' then
    select reversed_by_journal_id into v_reversal from public.accounting_journals
    where business_id=v_bid and source_type='payroll' and source_id=p_pay_run_id and posting_version=1 limit 1;
    if v_reversal is null then raise exception 'Reversed payroll is missing its reversal journal'; end if;
    return v_reversal;
  end if;
  if v_run.status<>'finalised' then raise exception 'Only a finalised pay run can be reversed'; end if;
  select id into v_journal from public.accounting_journals
  where business_id=v_bid and source_type='payroll' and source_id=p_pay_run_id and posting_version=1 and status='posted' limit 1;
  if v_journal is null then raise exception 'This finalised pay run has no posted accounting journal. It was left unchanged for review.'; end if;
  v_reversal:=public.v6170a_reverse_journal(v_journal,'Payroll '||v_run.pay_run_number||': '||btrim(p_reason));
  perform set_config('frindly.payroll_reversal','allowed',true);
  update public.payroll_pay_runs set status='reversed',updated_at=now(),updated_by=auth.uid()
  where id=p_pay_run_id and business_id=v_bid and status='finalised';
  if not found then raise exception 'Payroll reversal status update failed'; end if;
  insert into public.payroll_audit_log(business_id,entity_type,entity_id,action,old_data,new_data,created_by)
  values(v_bid,'pay_run',p_pay_run_id,'reversed',to_jsonb(v_run),jsonb_build_object('status','reversed','reason',btrim(p_reason),'reversal_journal_id',v_reversal),auth.uid());
  return v_reversal;
end $function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13b_reverse_pay_run"(p_pay_run_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13b_reverse_pay_run"(p_pay_run_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_phase13b_reverse_pay_run"(p_pay_run_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13c_capitalise_expense_lines(p_business_id uuid, p_expense_id uuid, p_business_ratio numeric, p_lines jsonb, p_fixed_assets uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_result jsonb:=coalesce(p_lines,'[]'::jsonb); r record;
begin
 if p_fixed_assets is null then return v_result; end if;
 for r in
  with latest as (select pr.rows from public.purchase_invoice_reviews pr where pr.business_id=p_business_id and pr.expense_id=p_expense_id order by pr.revision desc limit 1),
  rows as (select x.value row_data from latest l cross join lateral jsonb_array_elements(l.rows) x),
  cap as (
   select nullif(row_data->>'category_id','')::uuid category_id,
    round(sum(coalesce((row_data->>'ex_gst')::numeric,0))*greatest(0,least(1,coalesce(p_business_ratio,1))),2) amount
   from rows where row_data->>'kind'='equipment' or (row_data->>'kind'='discount' and row_data->>'discount_for'='equipment')
   group by nullif(row_data->>'category_id','')::uuid)
  select c.category_id,c.amount,coalesce(sm.account_id,public.v6192_account_id(p_business_id,'business_expenses','6000')) expense_account
  from cap c left join public.accounting_source_mappings sm on sm.business_id=p_business_id and sm.source_type='expense_category' and sm.source_id=c.category_id and sm.purpose='expense' and coalesce(sm.archived,false)=false
  where c.amount>0
 loop
  if r.expense_account is null then raise exception 'Expense account mapping is unavailable for equipment capitalisation'; end if;
  v_result:=v_result||jsonb_build_array(
   jsonb_build_object('account_id',p_fixed_assets,'description','Capital equipment from reviewed supplier bill','debit',r.amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
   jsonb_build_object('account_id',r.expense_account,'description','Reclassify reviewed equipment to fixed assets','debit',0,'credit',r.amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0));
 end loop;
 return v_result;
end $function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13c_capitalise_expense_lines"(p_business_id uuid, p_expense_id uuid, p_business_ratio numeric, p_lines jsonb, p_fixed_assets uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13c_capitalise_expense_lines"(p_business_id uuid, p_expense_id uuid, p_business_ratio numeric, p_lines jsonb, p_fixed_assets uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13h_post_credit_refund_ledger(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id();u uuid:=auth.uid();r record;orig uuid;lines jsonb;ratio numeric;posted int:=0;cc int:=0;sc int:=0;cr int:=0;sr int:=0;backed numeric;v_ar uuid;v_ap uuid;v_clear uuid;
begin
 if u is null or b is null or p_from is null or p_to is null or p_from>p_to then raise exception 'Choose a business and valid posting period';end if;
 if not public.v6169a_accountant_centre_access(b,true) then raise exception 'Accountant or owner access is required to post accounting journals';end if;
 v_ar:=public.v6170b_account(b,'accounts_receivable');v_ap:=public.v6170b_account(b,'accounts_payable');v_clear:=public.v6170b_account(b,'payment_clearing'); if exists(select 1 from public.accounting_periods p where p.business_id=b and p.status<>'open' and daterange(p.period_start,p.period_end,'[]')&&daterange(p_from,p_to,'[]')) then raise exception 'One or more accounting periods in this date range are locked';end if;
 for r in select c.* from public.customer_credit_notes c where c.business_id=b and c.lifecycle_state='issued' and c.credit_date between p_from and p_to and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_credit_note' and j.source_id=c.id and j.status in('posted','reversed')) and exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='invoice' and j.source_id=c.original_invoice_id and j.status in('posted','reversed')) order by c.credit_date,c.credit_note_number loop
  lines:=jsonb_build_array(jsonb_build_object('account_id',public.v6170b_account(b,'sales'),'debit',r.ex_gst,'credit',0,'customer_id',r.customer_id),jsonb_build_object('account_id',public.v6170b_account(b,'gst_payable'),'debit',r.gst_amount,'credit',0,'customer_id',r.customer_id,'tax_amount',r.gst_amount),jsonb_build_object('account_id',public.v6170b_account(b,'accounts_receivable'),'debit',0,'credit',r.total_amount,'customer_id',r.customer_id));
  select jsonb_agg(x) into lines from jsonb_array_elements(lines)x where coalesce((x->>'debit')::numeric,0)>0 or coalesce((x->>'credit')::numeric,0)>0;
  perform public.v6170a_post_journal(r.credit_date,'customer_credit_note',r.id,r.credit_note_number,'Customer credit note '||r.credit_note_number,'credit_note',lines,1,'v61.105-phase13h');cc:=cc+1;posted:=posted+1;
 end loop;
 for r in select c.*,e.total_amount original_total from public.supplier_credits c join public.expenses e on e.id=c.original_expense_id and e.business_id=c.business_id where c.business_id=b and c.lifecycle_state='recorded' and c.credit_date between p_from and p_to and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='supplier_credit' and j.source_id=c.id and j.status in('posted','reversed')) order by c.credit_date,c.credit_note_number loop
  select j.id into orig from public.accounting_journals j where j.business_id=b and j.source_type='expense' and j.source_id=r.original_expense_id and j.status in('posted','reversed') order by j.posting_version desc limit 1;
  if orig is not null then ratio:=r.total_amount/nullif(r.original_total,0);select jsonb_agg(jsonb_build_object('account_id',l.account_id,'debit',round(l.credit*ratio,2),'credit',round(l.debit*ratio,2),'tax_code',l.tax_code,'tax_rate',l.tax_rate,'tax_amount',round(coalesce(l.tax_amount,0)*ratio,2),'supplier_id',coalesce(l.supplier_id,r.supplier_id),'source_line_id',l.source_line_id)) into lines from public.accounting_journal_lines l where l.journal_id=orig and l.business_id=b and(l.debit<>0 or l.credit<>0);perform public.v6170a_post_journal(r.credit_date,'supplier_credit',r.id,r.credit_note_number,'Supplier credit '||r.credit_note_number,'supplier_credit',lines,1,'v61.105-phase13h');sc:=sc+1;posted:=posted+1;end if;
 end loop;
 for r in select x.* from public.customer_refunds x where x.business_id=b and x.lifecycle_state='recorded' and x.refund_date between p_from and p_to and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_refund' and j.source_id=x.id and j.status in('posted','reversed')) order by x.refund_date,x.refund_number loop
  select coalesce(sum(greatest(0,least(cn.total_amount,coalesce((select sum(cp.amount) from public.customer_payments cp where cp.business_id=i.business_id and cp.invoice_id=i.id),0)+cn.total_amount-i.total))),0) into backed from public.customer_credit_notes cn join public.invoices i on i.id=cn.original_invoice_id and i.business_id=cn.business_id where cn.business_id=b and cn.customer_id=r.customer_id and cn.lifecycle_state='issued' and exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='customer_credit_note' and j.source_id=cn.id and j.status in('posted','reversed'));
  if backed>=r.amount-0.005 and v_ar is not null and v_clear is not null then lines:=jsonb_build_array(jsonb_build_object('account_id',v_ar,'debit',r.amount,'credit',0),jsonb_build_object('account_id',v_clear,'debit',0,'credit',r.amount));perform public.v6170a_post_journal(r.refund_date,'customer_refund',r.id,r.refund_number,'Customer refund','customer_refund',lines,1,'v61.105-phase13h');cr:=cr+1;posted:=posted+1;end if;
 end loop;
 for r in select x.* from public.supplier_refunds x where x.business_id=b and x.lifecycle_state='recorded' and x.refund_date between p_from and p_to and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='supplier_refund' and j.source_id=x.id and j.status in('posted','reversed')) order by x.refund_date,x.refund_number loop
  select coalesce(sum(a.amount),0) into backed from public.supplier_refund_allocations a join public.accounting_journals j on j.business_id=a.business_id and j.source_type='supplier_credit' and j.source_id=a.supplier_credit_id and j.status in('posted','reversed') where a.business_id=b and a.supplier_refund_id=r.id;
  if backed>=r.amount-0.005 and v_ap is not null and v_clear is not null then lines:=jsonb_build_array(jsonb_build_object('account_id',v_clear,'debit',r.amount,'credit',0),jsonb_build_object('account_id',v_ap,'debit',0,'credit',r.amount,'supplier_id',r.supplier_id));perform public.v6170a_post_journal(r.refund_date,'supplier_refund',r.id,r.refund_number,'Supplier refund '||r.refund_number,'supplier_refund',lines,1,'v61.105-phase13h');sr:=sr+1;posted:=posted+1;end if;
 end loop;
 return jsonb_build_object('version','v61.105-phase13h','posted',posted,'customer_credits',cc,'supplier_credits',sc,'customer_refunds',cr,'supplier_refunds',sr,'period_start',p_from,'period_end',p_to);
end $function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13h_post_credit_refund_ledger"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13h_post_credit_refund_ledger"(p_from date, p_to date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_phase13h_post_credit_refund_ledger"(p_from date, p_to date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13i_accountant_handoff(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id();v_uid uuid:=auth.uid();v_gl_debit numeric:=0;v_gl_credit numeric:=0;v_tb_debit numeric:=0;v_tb_credit numeric:=0;v_revenue numeric:=0;v_cos numeric:=0;v_expenses numeric:=0;v_profit numeric:=0;v_assets numeric:=0;v_liabilities numeric:=0;v_equity numeric:=0;v_bs_profit numeric:=0;v_bs_balances boolean:=false;v_opening text;v_recon jsonb;v_gl_balanced boolean;v_tb_balanced boolean;v_pnl_formula boolean;v_bs_equation boolean;v_ready boolean;
begin
 if v_uid is null or b is null or p_from is null or p_to is null or p_from>p_to then raise exception 'Choose a business and valid handoff period';end if;
 if not public.v6169a_accountant_centre_access(b,false) then raise exception 'Accounting access denied';end if;
 select coalesce(round(sum(l.debit),2),0),coalesce(round(sum(l.credit),2),0) into v_gl_debit,v_gl_credit from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.business_id=b and j.status in('posted','reversed') and j.journal_date between p_from and p_to;
 select coalesce(round(sum(t.debits),2),0),coalesce(round(sum(t.credits),2),0) into v_tb_debit,v_tb_credit from public.v6170b_trial_balance(p_from,p_to)t;
 select coalesce(revenue,0),coalesce(cost_of_sales,0),coalesce(expenses,0),coalesce(net_profit,0) into v_revenue,v_cos,v_expenses,v_profit from public.v6170b_profit_loss(p_from,p_to);
 select coalesce(assets,0),coalesce(liabilities,0),coalesce(equity,0),coalesce(current_profit,0),coalesce(balances,false),opening_balance_message into v_assets,v_liabilities,v_equity,v_bs_profit,v_bs_balances,v_opening from public.v6170b_balance_sheet(p_to);
 v_recon:=public.v61105_ledger_reconciliation(p_from,p_to);
 v_gl_balanced:=v_gl_debit=v_gl_credit;
 v_tb_balanced:=v_tb_debit=v_tb_credit and v_tb_debit=v_gl_debit and v_tb_credit=v_gl_credit;
 v_pnl_formula:=round(v_revenue-v_cos-v_expenses,2)=round(v_profit,2);
 v_bs_equation:=round(v_assets,2)=round(v_liabilities+v_equity+v_bs_profit,2) and v_bs_balances;
 v_ready:=v_gl_balanced and v_tb_balanced and v_pnl_formula and v_bs_equation and coalesce((v_recon->>'critical_integrity_count')::int,0)=0 and coalesce((v_recon->>'posting_pending_count')::int,0)=0 and coalesce((v_recon->>'review_required_count')::int,0)=0 and coalesce((v_recon->>'configuration_required_count')::int,0)=0 and coalesce((v_recon->>'legacy_review_count')::int,0)=0;
 return jsonb_build_object('version','v61.105-phase13m','business_id',b,'period_start',p_from,'period_end',p_to,'handoff_ready',v_ready,'checks',jsonb_build_object('gl_balanced',v_gl_balanced,'trial_balance_matches_gl',v_tb_balanced,'pnl_formula_balanced',v_pnl_formula,'balance_sheet_balanced',v_bs_equation),'general_ledger',jsonb_build_object('debits',v_gl_debit,'credits',v_gl_credit),'trial_balance',jsonb_build_object('debits',v_tb_debit,'credits',v_tb_credit),'profit_and_loss',jsonb_build_object('revenue',v_revenue,'cost_of_sales',v_cos,'expenses',v_expenses,'net_profit',v_profit),'balance_sheet',jsonb_build_object('assets',v_assets,'liabilities',v_liabilities,'equity',v_equity,'current_profit',v_bs_profit,'opening_balance_message',v_opening),'exceptions',jsonb_build_object('issue_count',coalesce((v_recon->>'issue_count')::int,0),'posting_pending_count',coalesce((v_recon->>'posting_pending_count')::int,0),'legacy_review_count',coalesce((v_recon->>'legacy_review_count')::int,0),'review_required_count',coalesce((v_recon->>'review_required_count')::int,0),'configuration_required_count',coalesce((v_recon->>'configuration_required_count')::int,0),'critical_integrity_count',coalesce((v_recon->>'critical_integrity_count')::int,0)));
end $function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13i_accountant_handoff"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13i_accountant_handoff"(p_from date, p_to date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_phase13i_accountant_handoff"(p_from date, p_to date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13l_legacy_payroll_review(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id();v jsonb;
begin
 if auth.uid() is null or b is null or p_from is null or p_to is null or p_from>p_to then raise exception 'Choose a business and valid review period';end if;
 if not public.v6169a_accountant_centre_access(b,false) then raise exception 'Accounting access denied';end if;
 with runs as(
 select p.id,p.pay_run_number,p.pay_date,round(p.gross_pay,2) gross_pay,round(p.total_deductions,2) deductions,round(p.net_pay,2) net_pay,round(p.total_employment_cost,2) employment_cost,
 round(coalesce(sum(e.reimbursements),0),2) reimbursements,round(p.gross_pay-p.total_deductions+coalesce(sum(e.reimbursements),0),2) expected_net,count(e.id) employee_count,
 (select count(*) from public.bank_transactions bt where bt.business_id=b and bt.amount=-p.net_pay and bt.transaction_date between p.pay_date-7 and p.pay_date+7) exact_bank_candidates
 from public.payroll_pay_runs p left join public.payroll_pay_run_employees e on e.pay_run_id=p.id and e.business_id=p.business_id
 where p.business_id=b and p.pay_date between p_from and p_to and p.status in('finalised','reversed') and p.finalised_at<timestamp '2026-10-01'
 and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='payroll' and j.source_id=p.id and j.status in('posted','reversed')) group by p.id),
 enriched as(select r.*,lr.event_type resolution_event,lr.treatment resolution_treatment,lr.note resolution_note,lr.created_at resolved_at,lr.created_by resolved_by
 from runs r left join lateral(select e.event_type,e.treatment,e.note,e.created_at,e.created_by from public.accounting_legacy_payroll_resolution_events e where e.business_id=b and e.pay_run_id=r.id order by e.created_at desc,e.id desc limit 1)lr on true)
 select jsonb_build_object('version','v61.105-phase13m','business_id',b,'period_start',p_from,'period_end',p_to,'legacy_payroll_count',count(*),
 'resolved_count',count(*) filter(where resolution_event='resolve'),'unresolved_count',count(*) filter(where resolution_event is distinct from 'resolve'),
 'arithmetically_consistent_count',count(*) filter(where abs(net_pay-expected_net)<=0.005),'bank_evidence_found_count',count(*) filter(where exact_bank_candidates>0),
 'posting_recommendation','do_not_auto_post_without_independent_cash_evidence',
 'runs',coalesce(jsonb_agg(jsonb_build_object('pay_run_id',id,'pay_run_number',pay_run_number,'pay_date',pay_date,'gross_pay',gross_pay,'deductions',deductions,'reimbursements',reimbursements,'net_pay',net_pay,'expected_net',expected_net,'employment_cost',employment_cost,'employee_count',employee_count,'arithmetically_consistent',abs(net_pay-expected_net)<=0.005,'exact_bank_candidates',exact_bank_candidates,'resolved',resolution_event='resolve','resolution_treatment',resolution_treatment,'resolution_note',resolution_note,'resolved_at',resolved_at,'resolved_by',resolved_by,'classification',case when resolution_event='resolve' then 'legacy_payroll_resolved_by_documented_treatment' when abs(net_pay-expected_net)>0.005 then 'legacy_payroll_data_review' when exact_bank_candidates=0 then 'legacy_payroll_unverified_cash_history' else 'legacy_payroll_bank_evidence_available' end) order by pay_date,pay_run_number),'[]'::jsonb)) into v from enriched;
 return v;
end$function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13l_legacy_payroll_review"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13l_legacy_payroll_review"(p_from date, p_to date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_phase13l_legacy_payroll_review"(p_from date, p_to date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13m_reopen_legacy_payroll(p_pay_run_id uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id();u uuid:=auth.uid();p public.payroll_pay_runs;
begin
 if u is null or b is null then raise exception 'Choose a business and sign in';end if;
 if not public.v6169a_accountant_centre_access(b,false) then raise exception 'Accounting access denied';end if;
 if length(btrim(coalesce(p_note,'')))<10 then raise exception 'Add a clear reopen note (at least 10 characters)';end if;
 select * into p from public.payroll_pay_runs where id=p_pay_run_id and business_id=b;
 if p.id is null then raise exception 'Pay run not found in current business';end if;
 if not exists(select 1 from (select event_type from public.accounting_legacy_payroll_resolution_events where business_id=b and pay_run_id=p.id order by created_at desc,id desc limit 1)x where event_type='resolve') then raise exception 'This legacy payroll run is not currently resolved';end if;
 insert into public.accounting_legacy_payroll_resolution_events(business_id,pay_run_id,event_type,treatment,note,created_by) values(b,p.id,'reopen',null,btrim(p_note),u);
 return jsonb_build_object('resolved',false,'pay_run_id',p.id,'pay_run_number',p.pay_run_number,'journal_created',false,'payroll_changed',false);
end$function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13m_reopen_legacy_payroll"(p_pay_run_id uuid, p_note text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13m_reopen_legacy_payroll"(p_pay_run_id uuid, p_note text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_phase13m_reopen_legacy_payroll"(p_pay_run_id uuid, p_note text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13m_resolve_legacy_payroll(p_pay_run_id uuid, p_treatment text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id();u uuid:=auth.uid();p public.payroll_pay_runs;
begin
 if u is null or b is null then raise exception 'Choose a business and sign in';end if;
 if not public.v6169a_accountant_centre_access(b,false) then raise exception 'Accounting access denied';end if;
 if p_treatment not in('historical_record_acknowledged','handled_in_opening_balance','verified_outside_frindly') then raise exception 'Invalid legacy payroll treatment';end if;
 if length(btrim(coalesce(p_note,'')))<10 then raise exception 'Add a clear resolution note (at least 10 characters)';end if;
 select * into p from public.payroll_pay_runs where id=p_pay_run_id and business_id=b;
 if p.id is null then raise exception 'Pay run not found in current business';end if;
 if p.status not in('finalised','reversed') or p.finalised_at is null or p.finalised_at>=timestamp '2026-10-01' then raise exception 'Only pre-ledger legacy payroll runs can use this workflow';end if;
 if exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='payroll' and j.source_id=p.id and j.status in('posted','reversed')) then raise exception 'This payroll run already has a formal journal';end if;
 insert into public.accounting_legacy_payroll_resolution_events(business_id,pay_run_id,event_type,treatment,note,created_by) values(b,p.id,'resolve',p_treatment,btrim(p_note),u);
 return jsonb_build_object('resolved',true,'pay_run_id',p.id,'pay_run_number',p.pay_run_number,'treatment',p_treatment,'journal_created',false,'payroll_changed',false);
end$function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13m_resolve_legacy_payroll"(p_pay_run_id uuid, p_treatment text, p_note text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13m_resolve_legacy_payroll"(p_pay_run_id uuid, p_treatment text, p_note text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_phase13m_resolve_legacy_payroll"(p_pay_run_id uuid, p_treatment text, p_note text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61105_phase13n_sync_schedule_timesheets(p_schedule_id uuid, p_create_timesheets boolean DEFAULT true, p_break_minutes integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  b uuid:=public.current_business_id();
  u uuid:=auth.uid();
  s public.job_schedules%rowtype;
  a record;
  jc_id uuid;
  business_settings jsonb:='{}'::jsonb;
  prefix text:='JC';
  next_seq integer:=1;
  jc_no text;
  cust_name text:='';
  tz text;
  local_start timestamp;
  local_end timestamp;
  duration_mins integer;
  break_mins integer:=greatest(0,coalesce(p_break_minutes,0));
  total_hours_val numeric;
  created_count integer:=0;
  updated_count integer:=0;
  skipped_locked_count integer:=0;
  deleted_draft_count integer:=0;
  active_assignment_count integer:=0;
begin
  if u is null or b is null then
    raise exception 'Choose a business and sign in';
  end if;

  select * into s
  from public.job_schedules
  where id=p_schedule_id and business_id=b;

  if s.id is null then
    raise exception 'Schedule job not found in current business';
  end if;

  update public.job_schedules
  set payroll_create_timesheets=coalesce(p_create_timesheets,false),
      payroll_break_minutes=break_mins,
      updated_at=now(),
      updated_by=u
  where id=s.id and business_id=b
  returning * into s;

  if coalesce(p_create_timesheets,false)=false
     or s.start_at is null
     or s.end_at is null
     or s.status in ('unscheduled','cancelled') then
    delete from public.payroll_timesheets t
    where t.business_id=b
      and t.source_type='schedule'
      and t.source_schedule_id=s.id
      and t.status='draft';
    get diagnostics deleted_draft_count = row_count;
    return jsonb_build_object(
      'synced',true,
      'created',0,
      'updated',0,
      'deleted_draft',deleted_draft_count,
      'skipped_non_draft',0,
      'job_costing_created',false
    );
  end if;

  duration_mins:=greatest(0,floor(extract(epoch from (s.end_at-s.start_at))/60)::integer);
  if break_mins>=duration_mins then
    raise exception 'Break must be shorter than the scheduled duration';
  end if;

  select count(*) into active_assignment_count
  from public.job_schedule_assignments ax
  where ax.business_id=b
    and ax.schedule_id=s.id
    and ax.employee_id is not null
    and coalesce(ax.assignment_status,'assigned')<>'cancelled';

  if active_assignment_count=0 then
    delete from public.payroll_timesheets t
    where t.business_id=b
      and t.source_type='schedule'
      and t.source_schedule_id=s.id
      and t.status='draft';
    get diagnostics deleted_draft_count = row_count;
    return jsonb_build_object(
      'synced',true,
      'created',0,
      'updated',0,
      'deleted_draft',deleted_draft_count,
      'skipped_non_draft',0,
      'job_costing_created',false,
      'reason','no_assigned_employees'
    );
  end if;

  total_hours_val:=round((duration_mins-break_mins)::numeric/60,2);
  tz:=coalesce(nullif(s.timezone,''),'Pacific/Auckland');
  local_start:=s.start_at at time zone tz;
  local_end:=s.end_at at time zone tz;
  jc_id:=s.job_costing_id;

  select coalesce((
    select c.name
    from public.customers c
    where c.business_id=b and c.id=s.customer_id
  ), '') into cust_name;

  if jc_id is null then
    select coalesce(bs.settings,'{}'::jsonb) into business_settings
    from public.businesses bs
    where bs.id=b;

    prefix:=upper(regexp_replace(coalesce(business_settings#>>'{jobCostingSettings,costingPrefix}','JC'),'[^A-Za-z0-9]+','','g'));
    if prefix='' then prefix:='JC'; end if;

    select coalesce(max((m[1])::integer),0)+1 into next_seq
    from (
      select regexp_match(jc.costing_number,'^'||prefix||'-(\d+)$','i') m
      from public.job_costings jc
      where jc.business_id=b
    ) n
    where m is not null;

    jc_no:=prefix||'-'||lpad(next_seq::text,4,'0');

    insert into public.job_costings(
      business_id,costing_number,costing_date,customer_id,customer_name,job_description,notes,
      labour_items,variable_costs,direct_costs,custom_fields,job_address,job_duration_hours,
      total_labour,total_variable,total_direct,allocated_overhead,contingency_percent,contingency_amount,
      subtotal_job_cost,total_cost_ex_gst,margin_percent,recommended_price_ex_gst,proposed_quote_price_ex_gst,
      expected_profit,expected_margin_percent,costing_snapshot,current_estimate_snapshot,estimate_status,status,updated_at
    ) values (
      b,jc_no,(local_start::date),s.customer_id,cust_name,coalesce(s.title,s.service_type,'Scheduled job'),
      'Created automatically from Schedule so payroll time can be linked to a job number.',
      '[]'::jsonb,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,coalesce(s.service_address,''),round(duration_mins::numeric/60,2),
      0,0,0,0,0,0,0,0,0,0,0,0,0,
      jsonb_build_object('source','schedule','schedule_id',s.id,'created_for','draft_timesheets'),
      jsonb_build_object('source','schedule','schedule_id',s.id,'created_for','draft_timesheets'),
      'not_estimated','draft',now()
    )
    returning id into jc_id;

    update public.job_schedules
    set job_costing_id=jc_id,
        updated_at=now(),
        updated_by=u
    where id=s.id and business_id=b;
  end if;

  update public.job_costings jc
  set job_description=coalesce(s.title,s.service_type,'Scheduled job'),
      updated_at=now()
  where jc.id=jc_id
    and jc.business_id=b
    and jc.costing_snapshot->>'source'='schedule'
    and jc.costing_snapshot->>'created_for'='draft_timesheets'
    and jc.costing_snapshot->>'schedule_id'=s.id::text;

  delete from public.payroll_timesheets t
  where t.business_id=b
    and t.source_type='schedule'
    and t.source_schedule_id=s.id
    and t.status='draft'
    and not exists (
      select 1
      from public.job_schedule_assignments ax
      where ax.id=t.source_schedule_assignment_id
        and ax.business_id=b
        and ax.schedule_id=s.id
        and coalesce(ax.assignment_status,'assigned')<>'cancelled'
    );
  get diagnostics deleted_draft_count = row_count;

  for a in
    select jsa.*
    from public.job_schedule_assignments jsa
    where jsa.business_id=b
      and jsa.schedule_id=s.id
      and jsa.employee_id is not null
      and coalesce(jsa.assignment_status,'assigned')<>'cancelled'
  loop
    if exists (
      select 1
      from public.payroll_timesheets t
      where t.business_id=b
        and t.source_type='schedule'
        and t.source_schedule_assignment_id=a.id
        and t.status<>'draft'
    ) then
      skipped_locked_count:=skipped_locked_count+1;
      continue;
    end if;

    if exists (
      select 1
      from public.payroll_timesheets t
      where t.business_id=b
        and t.source_type='schedule'
        and t.source_schedule_assignment_id=a.id
        and t.status='draft'
    ) then
      update public.payroll_timesheets
      set employee_id=a.employee_id,
          work_date=local_start::date,
          job_costing_id=jc_id,
          customer_id=s.customer_id,
          start_time=local_start::time,
          finish_time=local_end::time,
          break_minutes=break_mins,
          total_hours=total_hours_val,
          pay_type='ordinary',
          notes='Draft time created from Schedule: '||coalesce(s.title,s.service_type,'Scheduled job'),
          updated_at=now(),
          updated_by=u
      where business_id=b
        and payroll_timesheets.source_type='schedule'
        and payroll_timesheets.source_schedule_assignment_id=a.id
        and payroll_timesheets.status='draft';
      updated_count:=updated_count+1;
    else
      insert into public.payroll_timesheets(
        business_id,employee_id,work_date,job_costing_id,customer_id,start_time,finish_time,
        break_minutes,total_hours,pay_type,notes,status,source_type,source_schedule_id,
        source_schedule_assignment_id,created_by,updated_at,updated_by
      ) values (
        b,a.employee_id,local_start::date,jc_id,s.customer_id,local_start::time,local_end::time,
        break_mins,total_hours_val,'ordinary',
        'Draft time created from Schedule: '||coalesce(s.title,s.service_type,'Scheduled job'),
        'draft','schedule',s.id,a.id,u,now(),u
      );
      created_count:=created_count+1;
    end if;
  end loop;

  return jsonb_build_object(
    'synced',true,
    'created',created_count,
    'updated',updated_count,
    'deleted_draft',deleted_draft_count,
    'skipped_non_draft',skipped_locked_count,
    'job_costing_created',s.job_costing_id is null,
    'job_costing_id',jc_id
  );
end$function$
;

REVOKE ALL ON FUNCTION public."v61105_phase13n_sync_schedule_timesheets"(p_schedule_id uuid, p_create_timesheets boolean, p_break_minutes integer) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61105_phase13n_sync_schedule_timesheets"(p_schedule_id uuid, p_create_timesheets boolean, p_break_minutes integer) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61105_phase13n_sync_schedule_timesheets"(p_schedule_id uuid, p_create_timesheets boolean, p_break_minutes integer) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61106_current_community_profile_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select cp.id
  from public.community_profiles cp
  where cp.user_id = auth.uid()
    and (
      public.v61106_is_super_admin()
      or exists (
        select 1 from public.business_memberships bm
        where bm.business_id = cp.business_id
          and bm.user_id = auth.uid()
          and bm.status = 'active'
      )
    )
  order by cp.updated_at desc nulls last, cp.created_at desc
  limit 1;
$function$
;

REVOKE ALL ON FUNCTION public."v61106_current_community_profile_id"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61106_current_community_profile_id"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61106_current_community_profile_id"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61106_is_super_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select p.is_super_admin from public.profiles p where p.id = auth.uid()), false);
$function$
;

REVOKE ALL ON FUNCTION public."v61106_is_super_admin"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61106_is_super_admin"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61106_is_super_admin"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61106_reject_blocked_community_text()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  combined text := '';
  item record;
begin
  if tg_table_name = 'community_profiles' then
    combined := coalesce(new.display_name,'') || ' ' || coalesce(new.region,'') || ' ' || coalesce(new.industry,'');
  elsif tg_table_name = 'community_posts' then
    combined := coalesce(new.title,'') || ' ' || coalesce(new.body,'');
  elsif tg_table_name = 'community_comments' or tg_table_name = 'community_messages' then
    combined := coalesce(new.body,'');
  elsif tg_table_name = 'community_ad_campaigns' then
    combined := coalesce(new.sponsor_name,'') || ' ' || coalesce(new.title,'') || ' ' || coalesce(new.body,'');
  end if;

  for item in select word, severity from public.community_blocked_words where active = true loop
    if length(trim(item.word)) > 0 and position(lower(trim(item.word)) in lower(combined)) > 0 then
      if item.severity = 'block' then
        raise exception 'Please edit your message. Some wording may not meet Frindly Community guidelines.';
      end if;
      if tg_table_name in ('community_posts','community_comments','community_messages','community_ad_campaigns') then
        new.status := case when tg_table_name = 'community_ad_campaigns' then 'pending_review' else 'hidden' end;
      end if;
    end if;
  end loop;
  new.updated_at := now();
  return new;
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61106_reject_blocked_community_text"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61106_reject_blocked_community_text"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61106e_reconcile_owner_equity_bank_transaction(p_bank_transaction_id uuid, p_equity_type text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_amount numeric;
  v_bank uuid;
  v_counterpart uuid;
  v_journal uuid;
  v_label text;
  v_lines jsonb := '[]'::jsonb;
  v_code text;
  v_is_short_chart boolean := false;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx
  from public.bank_transactions
  where id=p_bank_transaction_id and business_id=v_bid
  for update;
  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;

  v_amount := round(abs(coalesce(v_tx.amount,0)),2);
  if v_amount <= 0 then raise exception 'Bank transaction amount is invalid'; end if;

  if v_tx.amount > 0 and p_equity_type not in ('owner_funds_introduced','director_loan_received','capital_contribution') then
    raise exception 'Choose a money-in owner/equity type for this bank deposit';
  end if;
  if v_tx.amount < 0 and p_equity_type not in ('owner_drawings','repay_owner_loan','director_payment','dividend_distribution') then
    raise exception 'Choose a money-out owner/equity type for this bank payment';
  end if;

    -- Resolve the bank ledger from the actual imported bank transaction.
  v_bank := public.v61109_bank_accounting_account(v_bid, p_bank_transaction_id);
  if v_bank is null then raise exception 'A bank ledger account is not available for this bank transaction'; end if;

  if p_equity_type in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment') then
    -- Temporary owner/director funding is a liability, not permanent equity.
    select a.id into v_counterpart
    from public.accounting_accounts a
    where a.business_id=v_bid
      and not coalesce(a.archived,false)
      and a.account_type='liability'
      and (a.system_account_key='owner_director_loan' or a.system_key='owner_director_loan')
    order by a.account_code
    limit 1;

    if v_counterpart is null then
      select exists(
        select 1 from public.accounting_accounts a
        where a.business_id=v_bid and length(regexp_replace(coalesce(a.account_code,''),'[^0-9]','','g'))=3
      ) and not exists(
        select 1 from public.accounting_accounts a
        where a.business_id=v_bid and length(regexp_replace(coalesce(a.account_code,''),'[^0-9]','','g'))=4
      ) into v_is_short_chart;

      if v_is_short_chart then
        select lpad(gs::text,3,'0') into v_code
        from generate_series(270,279) gs
        where not exists (
          select 1 from public.accounting_accounts a
          where a.business_id=v_bid and a.account_code=lpad(gs::text,3,'0')
        )
        order by gs limit 1;
      else
        select gs::text into v_code
        from generate_series(2300,2399) gs
        where not exists (
          select 1 from public.accounting_accounts a
          where a.business_id=v_bid and a.account_code=gs::text
        )
        order by gs limit 1;
      end if;

      if v_code is null then raise exception 'No free owner/director loan liability account code is available'; end if;

      insert into public.accounting_accounts(
        business_id,account_code,account_name,account_type,account_subtype,normal_balance,tax_default,
        system_account_key,system_key,allow_manual_posting,report_section,is_system,is_control,
        xero_account_code,xero_account_type,xero_tax_type,description,created_by,updated_by
      ) values (
        v_bid,v_code,'Owner / Director Loan','liability','owner_loan','credit','NO_GST',
        'owner_director_loan','owner_director_loan',true,'current_liabilities',true,false,
        v_code,'CURRLIAB','NONE','Temporary funds introduced by, or repaid to, owners/directors. No GST.',v_uid,v_uid
      )
      returning id into v_counterpart;
    end if;

  elsif p_equity_type='capital_contribution' then
    -- Reuse the production permanent-equity account (3000 Owner funds / share capital).
    select a.id into v_counterpart
    from public.accounting_accounts a
    where a.business_id=v_bid
      and not coalesce(a.archived,false)
      and a.account_type='equity'
      and a.normal_balance='credit'
      and (
        a.system_account_key in ('owner_contributions','owner_funds','owner_capital')
        or a.system_key in ('owner_funds','owner_capital','opening_balance_equity')
        or a.account_subtype='capital'
        or a.account_code in ('859','3000')
      )
    order by case
      when a.system_account_key='owner_contributions' then 0
      when a.system_key='owner_funds' then 1
      when a.account_subtype='capital' then 2
      when a.account_code='3000' then 3
      else 4 end,
      a.account_code
    limit 1;
    if v_counterpart is null then
      raise exception 'Owner funds / share capital ledger account is not available for this business';
    end if;

  else
    -- Drawings/distributions reduce equity and therefore carry a debit normal balance.
    select a.id into v_counterpart
    from public.accounting_accounts a
    where a.business_id=v_bid
      and not coalesce(a.archived,false)
      and a.account_type='equity'
      and a.normal_balance='debit'
      and (
        a.system_account_key='owner_drawings'
        or a.system_key='owner_drawings'
        or a.account_subtype='drawings'
        or a.account_code in ('800','3100')
      )
    order by case
      when a.system_account_key='owner_drawings' then 0
      when a.system_key='owner_drawings' then 1
      when a.account_subtype='drawings' then 2
      when a.account_code='3100' then 3
      else 4 end,
      a.account_code
    limit 1;
    if v_counterpart is null then
      raise exception 'Owner drawings ledger account is not available for this business';
    end if;
  end if;

  if v_counterpart is null then raise exception 'Required owner/equity accounting account is not available'; end if;

  v_label := case p_equity_type
    when 'owner_funds_introduced' then 'Owner funds introduced'
    when 'director_loan_received' then 'Director/shareholder loan received'
    when 'capital_contribution' then 'Capital contribution'
    when 'owner_drawings' then 'Owner drawings'
    when 'repay_owner_loan' then 'Repay owner/director loan'
    when 'director_payment' then 'Director/shareholder payment'
    when 'dividend_distribution' then 'Dividend / distribution'
    else 'Owner / equity movement'
  end;

  if v_tx.amount > 0 then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id',v_bank,'description',v_label,'debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_counterpart,'description',v_label,'debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    );
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id',v_counterpart,'description',v_label,'debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_bank,'description',v_label,'debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    );
  end if;

  -- Hard accounting invariants: balanced journal and no GST on owner/equity movements.
  if round((select coalesce(sum((x->>'debit')::numeric),0) from jsonb_array_elements(v_lines) x),2)
     <> round((select coalesce(sum((x->>'credit')::numeric),0) from jsonb_array_elements(v_lines) x),2) then
    raise exception 'Owner/equity journal is not balanced';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_lines) x
    where coalesce(x->>'tax_code','') <> 'NO_GST'
       or coalesce((x->>'tax_rate')::numeric,0) <> 0
       or coalesce((x->>'tax_amount')::numeric,0) <> 0
  ) then
    raise exception 'Owner/equity journal must not contain GST';
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,v_tx.transaction_date,'bank','owner_equity',v_tx.id,
    coalesce(nullif(v_tx.reference,''),'BANK-'||left(v_tx.id::text,8)),v_label,v_lines
  );
  if v_journal is null then raise exception 'Owner/equity accounting journal was not created'; end if;

  insert into public.bank_reconciliation_allocations(
    business_id,bank_transaction_id,allocation_type,amount,equity_transaction_type,equity_note,accounting_journal_id,created_by
  ) values (
    v_bid,v_tx.id,'owner_equity',v_amount,p_equity_type,nullif(btrim(coalesce(p_note,'')),''),v_journal,v_uid
  );

  update public.bank_transactions
  set status='reconciled',reconciliation_type=p_equity_type,reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
  where id=v_tx.id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values (
    v_bid,v_tx.id,'owner_equity_reconciled',
    jsonb_build_object('equity_type',p_equity_type,'amount',v_amount,'journal_id',v_journal,'bank_account_id',v_bank,'counterpart_account_id',v_counterpart),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'equity_type',p_equity_type,'amount',v_amount,'bank_account_id',v_bank,'counterpart_account_id',v_counterpart);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61106e_reconcile_owner_equity_bank_transaction"(p_bank_transaction_id uuid, p_equity_type text, p_note text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61106e_reconcile_owner_equity_bank_transaction"(p_bank_transaction_id uuid, p_equity_type text, p_note text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61106e_reconcile_owner_equity_bank_transaction"(p_bank_transaction_id uuid, p_equity_type text, p_note text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61106e_undo_owner_equity_bank_transaction(p_bank_transaction_id uuid, p_reason text DEFAULT 'Undo owner/equity bank reconciliation'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_alloc record;
  v_reversal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select *
  into v_alloc
  from public.bank_reconciliation_allocations
  where business_id=v_bid
    and bank_transaction_id=p_bank_transaction_id
    and allocation_type='owner_equity'
  order by created_at desc
  limit 1;

  if v_alloc.bank_transaction_id is null then
    raise exception 'Owner/equity reconciliation was not found for this bank transaction';
  end if;

  if v_alloc.accounting_journal_id is not null then
    if to_regprocedure('public.v6170a_reverse_journal(uuid,text)') is null then
      raise exception 'Journal reversal function is not available; owner/equity reconciliation was not undone';
    end if;
    execute 'select public.v6170a_reverse_journal($1,$2)'
      into v_reversal
      using v_alloc.accounting_journal_id, coalesce(nullif(btrim(p_reason),''),'Undo owner/equity bank reconciliation');
  end if;

  delete from public.bank_reconciliation_allocations
  where business_id=v_bid and bank_transaction_id=p_bank_transaction_id and allocation_type='owner_equity';

  update public.bank_transactions
  set status='unreconciled',
      reconciliation_type=null,
      reconciled_at=null,
      reconciled_by=null,
      updated_at=now(),
      updated_by=v_uid
  where id=p_bank_transaction_id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(
    business_id,bank_transaction_id,action,details,created_by
  ) values (
    v_bid,
    p_bank_transaction_id,
    'owner_equity_undo',
    jsonb_build_object('journal_id',v_alloc.accounting_journal_id,'reversal_journal_id',v_reversal,'reason',p_reason),
    v_uid
  );

  return jsonb_build_object('ok',true,'reversal_journal_id',v_reversal);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61106e_undo_owner_equity_bank_transaction"(p_bank_transaction_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61106e_undo_owner_equity_bank_transaction"(p_bank_transaction_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61106e_undo_owner_equity_bank_transaction"(p_bank_transaction_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61106i_undo_created_expense_bank_reconciliation(p_bank_transaction_id uuid, p_reason text DEFAULT 'Undo bank reconciliation-created expense'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_alloc record;
  v_exp record;
  v_voided_ids uuid[] := array[]::uuid[];
  v_deleted_ids uuid[] := array[]::uuid[];
  v_payment_ids uuid[] := array[]::uuid[];
  v_count integer := 0;
  v_reason text := coalesce(nullif(btrim(p_reason),''),'Undo bank reconciliation-created expense');
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions
   where id=p_bank_transaction_id and business_id=v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction was not found for this business'; end if;

  if not exists (
    select 1 from public.bank_reconciliation_allocations
     where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
       and coalesce(created_expense,false)=true and expense_id is not null
  ) then raise exception 'This reconciliation did not create an expense'; end if;

  if exists (
    select 1 from public.bank_reconciliation_allocations
     where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
       and not (coalesce(created_expense,false)=true and expense_id is not null)
  ) then raise exception 'This bank transaction contains mixed allocations. No records were changed; review the reconciliation before undoing it.'; end if;

  for v_alloc in
    select * from public.bank_reconciliation_allocations
     where business_id=v_bid and bank_transaction_id=p_bank_transaction_id
       and coalesce(created_expense,false)=true and expense_id is not null
     order by created_at,id
  loop
    v_count:=v_count+1;
    select id,business_id,lifecycle_version,lifecycle_state into v_exp
      from public.expenses where id=v_alloc.expense_id and business_id=v_bid for update;
    if v_exp.id is null then raise exception 'The reconciliation-created expense % was not found. No records were changed.',v_alloc.expense_id; end if;

    -- The established void RPC requires all dependencies to be resolved first.
    -- Remove ONLY the payment/allocation created by this reconciliation. The whole
    -- function is transactional, so any later failure restores these rows automatically.
    if v_alloc.expense_payment_id is not null then
      delete from public.expense_payments
       where id=v_alloc.expense_payment_id and expense_id=v_alloc.expense_id and business_id=v_bid;
      if found then v_payment_ids:=array_append(v_payment_ids,v_alloc.expense_payment_id); end if;
    end if;

    delete from public.bank_reconciliation_allocations
     where id=v_alloc.id and business_id=v_bid and bank_transaction_id=p_bank_transaction_id
       and expense_id=v_alloc.expense_id and coalesce(created_expense,false)=true;
    if not found then raise exception 'The reconciliation allocation changed while Undo was running. No records were changed.'; end if;

    if v_exp.lifecycle_version is not null and lower(coalesce(v_exp.lifecycle_state,''))='recorded' then
      -- Canonical C1 path: this reverses the existing posted expense journal through
      -- v6170a_reverse_journal and performs the protected lifecycle transition itself.
      perform public.v6170c45_void_expense(v_alloc.expense_id,v_reason);
      v_voided_ids:=array_append(v_voided_ids,v_alloc.expense_id);
    elsif v_exp.lifecycle_version is not null and lower(coalesce(v_exp.lifecycle_state,''))='voided' then
      -- Already voided: keep the audit document and only finish detaching this bank match.
      v_voided_ids:=array_append(v_voided_ids,v_alloc.expense_id);
    elsif v_exp.lifecycle_version is null or lower(coalesce(v_exp.lifecycle_state,''))='draft' then
      -- Only a genuine draft/pre-C1 record that never became a protected financial
      -- document may retain the historical physical-delete behaviour.
      delete from public.expenses where id=v_alloc.expense_id and business_id=v_bid;
      if not found then raise exception 'Draft reconciliation-created expense could not be removed. No records were changed.'; end if;
      v_deleted_ids:=array_append(v_deleted_ids,v_alloc.expense_id);
    else
      raise exception 'This reconciliation-created expense is in lifecycle state % and was not changed.',coalesce(v_exp.lifecycle_state,'unknown');
    end if;
  end loop;

  update public.bank_transactions
     set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,
         excluded_reason=null,transfer_bank_account_id=null,updated_at=now(),updated_by=v_uid
   where id=p_bank_transaction_id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values(v_bid,p_bank_transaction_id,'created_expense_undo',jsonb_build_object(
    'reason',v_reason,'voided_expense_ids',to_jsonb(v_voided_ids),
    'deleted_unposted_expense_ids',to_jsonb(v_deleted_ids),
    'removed_reconciliation_payment_ids',to_jsonb(v_payment_ids),
    'accounting_safe',true,'void_path','v6170c45_void_expense'),v_uid);

  return jsonb_build_object('ok',true,'expense_count',v_count,
    'voided_expense_ids',to_jsonb(v_voided_ids),'deleted_unposted_expense_ids',to_jsonb(v_deleted_ids));
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61106i_undo_created_expense_bank_reconciliation"(p_bank_transaction_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61106i_undo_created_expense_bank_reconciliation"(p_bank_transaction_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61106i_undo_created_expense_bank_reconciliation"(p_bank_transaction_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aad_admin_delete_public_feature(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 if not public.is_super_admin() then raise exception 'Super Admin access required' using errcode='42501'; end if;
 delete from public.plan_public_features where id=p_id;
 return found;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aad_admin_delete_public_feature"(p_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aad_admin_delete_public_feature"(p_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107aad_admin_delete_public_feature"(p_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aad_admin_public_features()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 if not public.is_super_admin() then raise exception 'Super Admin access required' using errcode='42501'; end if;
 return jsonb_build_object(
   'features',coalesce((select jsonb_agg(to_jsonb(f) order by f.sort_order,f.title) from public.plan_public_features f),'[]'::jsonb),
   'modules',coalesce((select jsonb_agg(jsonb_build_object('slug',m.slug,'name',m.name,'is_active',m.is_active) order by m.name) from public.modules m),'[]'::jsonb)
 );
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aad_admin_public_features"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aad_admin_public_features"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107aad_admin_public_features"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aad_admin_save_public_feature(p_id uuid, p_feature_key text, p_title text, p_description text, p_feature_group text, p_module_slug text, p_value_source text, p_is_public boolean, p_sort_order integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rid uuid;
begin
 if not public.is_super_admin() then raise exception 'Super Admin access required' using errcode='42501'; end if;
 if nullif(btrim(p_feature_key),'') is null or nullif(btrim(p_title),'') is null then raise exception 'Feature key and title are required'; end if;
 if p_value_source not in ('module','core','invoice_limit','employee_limit') then raise exception 'Invalid value source'; end if;
 if p_value_source='module' and nullif(btrim(coalesce(p_module_slug,'')),'') is null then raise exception 'A module-backed feature requires a module slug'; end if;
 if p_value_source='module' and not exists(select 1 from public.modules where slug=btrim(p_module_slug)) then raise exception 'Unknown module slug'; end if;
 if p_id is null then
   insert into public.plan_public_features(feature_key,title,description,feature_group,module_slug,value_source,is_public,sort_order)
   values(lower(regexp_replace(btrim(p_feature_key),'[^a-zA-Z0-9_]+','_','g')),btrim(p_title),nullif(btrim(coalesce(p_description,'')),''),
          coalesce(nullif(btrim(p_feature_group),''),'Features'),case when p_value_source='module' then btrim(p_module_slug) else null end,
          p_value_source,coalesce(p_is_public,true),coalesce(p_sort_order,100))
   returning id into rid;
 else
   update public.plan_public_features set
    feature_key=lower(regexp_replace(btrim(p_feature_key),'[^a-zA-Z0-9_]+','_','g')),
    title=btrim(p_title),description=nullif(btrim(coalesce(p_description,'')),''),
    feature_group=coalesce(nullif(btrim(p_feature_group),''),'Features'),
    module_slug=case when p_value_source='module' then btrim(p_module_slug) else null end,
    value_source=p_value_source,is_public=coalesce(p_is_public,true),sort_order=coalesce(p_sort_order,100),updated_at=now()
   where id=p_id returning id into rid;
   if rid is null then raise exception 'Feature not found'; end if;
 end if;
 return rid;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aad_admin_save_public_feature"(p_id uuid, p_feature_key text, p_title text, p_description text, p_feature_group text, p_module_slug text, p_value_source text, p_is_public boolean, p_sort_order integer) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aad_admin_save_public_feature"(p_id uuid, p_feature_key text, p_title text, p_description text, p_feature_group text, p_module_slug text, p_value_source text, p_is_public boolean, p_sort_order integer) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107aad_admin_save_public_feature"(p_id uuid, p_feature_key text, p_title text, p_description text, p_feature_group text, p_module_slug text, p_value_source text, p_is_public boolean, p_sort_order integer) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aad_public_plans_features()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with public_plans as (
    select slug,name,description,monthly_price,annual_price,annual_saving_message,
           invoice_limit,employee_limit,included_modules,sort_order
    from public.plans
    where is_public=true
    order by sort_order,name
  ),
  features as (
    select feature_key,title,description,feature_group,module_slug,value_source,sort_order
    from public.plan_public_features
    where is_public=true
    order by sort_order,title
  )
  select jsonb_build_object(
    'plans',coalesce((select jsonb_agg(to_jsonb(p) order by p.sort_order,p.name) from public_plans p),'[]'::jsonb),
    'features',coalesce((select jsonb_agg(to_jsonb(f) order by f.sort_order,f.title) from features f),'[]'::jsonb)
  );
$function$
;

REVOKE ALL ON FUNCTION public."v61107aad_public_plans_features"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aad_public_plans_features"() TO "anon";

GRANT EXECUTE ON FUNCTION public."v61107aad_public_plans_features"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107aad_public_plans_features"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aaq_due_subscription_notifications()
 RETURNS TABLE(id uuid, email_to text, subject text, html_body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 insert into public.subscription_lifecycle_notifications(business_id,subscription_id,notification_key,event_type,event_at,due_at,email_to)
 select s.business_id,s.id,x.notification_key,x.event_type,x.event_at,x.due_at,p.email
 from public.subscriptions s
 join public.business_memberships bm on bm.business_id=s.business_id and bm.role='owner' and coalesce(bm.status,'active')='active'
 join public.profiles p on p.id=bm.user_id and p.email is not null
 cross join lateral (
  select 'trial_7d_'||s.trial_ends_at::text,'trial_ending',s.trial_ends_at,s.trial_ends_at-interval '7 days' where s.status='trialing' and s.trial_ends_at is not null and now()<s.trial_ends_at
  union all select 'trial_3d_'||s.trial_ends_at::text,'trial_ending',s.trial_ends_at,s.trial_ends_at-interval '3 days' where s.status='trialing' and s.trial_ends_at is not null and now()<s.trial_ends_at
  union all select 'trial_1d_'||s.trial_ends_at::text,'trial_ending',s.trial_ends_at,s.trial_ends_at-interval '1 day' where s.status='trialing' and s.trial_ends_at is not null and now()<s.trial_ends_at
  union all select 'trial_ended_'||s.trial_ends_at::text,'trial_ended',s.trial_ends_at,s.trial_ends_at where s.status='trialing' and s.trial_ends_at is not null and now()>=s.trial_ends_at
  union all select 'annual_30d_'||s.current_period_end::text,'annual_renewal',s.current_period_end,s.current_period_end-interval '30 days' where s.status='active' and s.billing_interval='annual' and s.renewal_preference='automatic' and coalesce(s.cancel_at_period_end,false)=false and s.cancel_at is null and s.current_period_end is not null and now()<s.current_period_end
  union all select 'annual_7d_'||s.current_period_end::text,'annual_renewal',s.current_period_end,s.current_period_end-interval '7 days' where s.status='active' and s.billing_interval='annual' and s.renewal_preference='automatic' and coalesce(s.cancel_at_period_end,false)=false and s.cancel_at is null and s.current_period_end is not null and now()<s.current_period_end
  union all select 'monthly_7d_'||s.current_period_end::text,'monthly_renewal',s.current_period_end,s.current_period_end-interval '7 days' where s.status='active' and s.billing_interval='monthly' and s.renewal_preference='automatic' and coalesce(s.cancel_at_period_end,false)=false and s.cancel_at is null and s.current_period_end is not null and now()<s.current_period_end
  union all select 'manual_30d_'||s.current_period_end::text,'manual_renewal',s.current_period_end,s.current_period_end-interval '30 days' where s.status='active' and s.billing_interval='annual' and s.renewal_preference='manual' and s.current_period_end is not null and now()<s.current_period_end
  union all select 'manual_7d_'||s.current_period_end::text,'manual_renewal',s.current_period_end,s.current_period_end-interval '7 days' where s.status='active' and s.renewal_preference='manual' and s.current_period_end is not null and now()<s.current_period_end
  union all select 'manual_1d_'||s.current_period_end::text,'manual_renewal',s.current_period_end,s.current_period_end-interval '1 day' where s.status='active' and s.renewal_preference='manual' and s.current_period_end is not null and now()<s.current_period_end
  union all select 'ending_7d_'||coalesce(s.cancel_at,s.current_period_end)::text,'subscription_ending',coalesce(s.cancel_at,s.current_period_end),coalesce(s.cancel_at,s.current_period_end)-interval '7 days' where s.status='active' and s.renewal_preference='cancelled' and coalesce(s.cancel_at,s.current_period_end) is not null and now()<coalesce(s.cancel_at,s.current_period_end)
  union all select 'ending_1d_'||coalesce(s.cancel_at,s.current_period_end)::text,'subscription_ending',coalesce(s.cancel_at,s.current_period_end),coalesce(s.cancel_at,s.current_period_end)-interval '1 day' where s.status='active' and s.renewal_preference='cancelled' and coalesce(s.cancel_at,s.current_period_end) is not null and now()<coalesce(s.cancel_at,s.current_period_end)
 ) x(notification_key,event_type,event_at,due_at) on conflict(subscription_id,notification_key) do nothing;
 return query select n.id,n.email_to,
 case n.event_type when 'trial_ending' then 'Your Frindly trial is ending soon' when 'trial_ended' then 'Your Frindly trial has ended' when 'annual_renewal' then 'Your Frindly annual subscription renews soon' when 'monthly_renewal' then 'Your Frindly subscription renews soon' when 'manual_renewal' then 'Your Frindly subscription is expiring soon' else 'Your Frindly subscription is ending soon' end,
 '<div style="font-family:Arial,sans-serif;max-width:600px;margin:auto;color:#172033"><h2 style="color:#171c3d">Frindly</h2><p>'||
 case n.event_type when 'trial_ending' then 'Your Frindly trial ends on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>. Choose a paid plan before then to keep uninterrupted access.'
 when 'trial_ended' then 'Your Frindly trial ended on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>. Choose a paid plan to continue using Frindly.'
 when 'annual_renewal' then 'Your annual Frindly subscription is set to renew automatically on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>.'
 when 'monthly_renewal' then 'Your Frindly subscription is set to renew automatically on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>.'
 when 'manual_renewal' then 'Auto renewal is off. Your Frindly subscription expires on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>. Open Subscription & Billing to renew or cancel.'
 else 'Your Frindly subscription is scheduled to end on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>. You can keep the subscription from Subscription & Billing before it ends.' end
 ||'</p><p><a href="https://frindly.co.nz/#settings/subscription" style="display:inline-block;background:#171c3d;color:white;padding:11px 18px;border-radius:8px;text-decoration:none">Open Subscription & Billing</a></p><p style="font-size:12px;color:#667085">Business, Made Easy.</p></div>'
 from public.subscription_lifecycle_notifications n where n.sent_at is null and n.due_at<=now()
 and ((n.event_type='trial_ending' and now()<n.event_at and n.due_at>=now()-interval '36 hours') or (n.event_type='trial_ended' and now()>=n.event_at and n.event_at>=now()-interval '36 hours') or (n.event_type in ('annual_renewal','monthly_renewal','manual_renewal','subscription_ending') and now()<n.event_at and n.due_at>=now()-interval '36 hours'))
 and (n.error_message is null or n.updated_at<now()-interval '1 hour') order by n.due_at limit 100;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aaq_due_subscription_notifications"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aaq_due_subscription_notifications"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aaq_mark_subscription_notification(p_id uuid, p_sent boolean, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 update public.subscription_lifecycle_notifications
 set sent_at=case when p_sent then now() else sent_at end,
     error_message=case when p_sent then null else left(coalesce(p_error,'Email failed'),2000) end,
     updated_at=now()
 where id=p_id;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aaq_mark_subscription_notification"(p_id uuid, p_sent boolean, p_error text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aaq_mark_subscription_notification"(p_id uuid, p_sent boolean, p_error text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aar_run_subscription_notification_scheduler()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  cfg public.subscription_notification_scheduler_config%rowtype;
  token text;
begin
  select * into cfg from public.subscription_notification_scheduler_config where singleton=true;
  if not found or not cfg.enabled then return; end if;
  select decrypted_secret into token from vault.decrypted_secrets where name=cfg.secret_name limit 1;
  if token is null then raise exception 'Subscription notification scheduler secret is not configured'; end if;
  perform net.http_post(
    url:=cfg.endpoint,
    headers:=jsonb_build_object('Content-Type','application/json','x-frindly-notification-secret',token),
    body:='{}'::jsonb,
    timeout_milliseconds:=30000
  );
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aar_run_subscription_notification_scheduler"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aar_run_subscription_notification_scheduler"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aas_verify_subscription_notification_secret(p_token text)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
 select coalesce(p_token=(select decrypted_secret from vault.decrypted_secrets where name='subscription_notification_secret' limit 1),false)
$function$
;

REVOKE ALL ON FUNCTION public."v61107aas_verify_subscription_notification_secret"(p_token text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aas_verify_subscription_notification_secret"(p_token text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aax_helper_subscription_access()
 RETURNS TABLE(allowed boolean, reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bid uuid;
  v_sub public.subscriptions%rowtype;
  v_now timestamptz := now();
begin
  v_bid := public.current_business_id();
  if v_bid is null then return query select false,'no_business'::text; return; end if;

  select * into v_sub from public.subscriptions
  where business_id=v_bid
  order by created_at desc limit 1;

  if not found then return query select false,'no_subscription'::text; return; end if;

  if v_sub.status='trialing' and v_sub.trial_ends_at is not null and v_sub.trial_ends_at>v_now then
    return query select true,'trial'::text; return;
  end if;

  if v_sub.status='active' then
    if (coalesce(v_sub.cancel_at_period_end,false) or v_sub.cancel_at is not null)
       and coalesce(v_sub.cancel_at,v_sub.current_period_end) is not null
       and coalesce(v_sub.cancel_at,v_sub.current_period_end)<=v_now then
      return query select false,'ended'::text; return;
    end if;
    return query select true,'active'::text; return;
  end if;

  if v_sub.status='past_due'
     and v_sub.current_period_end is not null
     and v_now < v_sub.current_period_end + interval '7 days' then
    return query select true,'payment_grace'::text; return;
  end if;

  return query select false,
    case when v_sub.status='trialing' then 'trial_ended' else coalesce(v_sub.status,'inactive') end::text;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aax_helper_subscription_access"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aax_helper_subscription_access"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107aax_helper_subscription_access"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aay_guard_quote_progress_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q public.quotes; allocated numeric:=0; this_amount numeric;
begin
 if new.source_quote_id is null then return new; end if;
 select * into q from public.quotes where id=new.source_quote_id and business_id=new.business_id;
 if not found then raise exception 'Linked quote was not found for this business'; end if;
 this_amount:=coalesce(new.quote_billing_ex_gst,new.subtotal,0);
 if this_amount<0 then raise exception 'Quote billing amount cannot be negative'; end if;
 select coalesce(sum(coalesce(i.quote_billing_ex_gst,i.subtotal,0)),0) into allocated
 from public.invoices i
 where i.business_id=new.business_id and i.source_quote_id=new.source_quote_id
   and i.id is distinct from new.id and coalesce(i.lifecycle_state,'draft')<>'voided';
 if round(allocated+this_amount,2)>round(coalesce(q.quoted_price_ex_gst,0),2)+0.01 then
   raise exception 'This invoice would exceed the remaining quote amount';
 end if;
 return new;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aay_guard_quote_progress_invoice"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aay_guard_quote_progress_invoice"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aay_lock_issued_quote_billing()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 if old.lifecycle_state in ('issued','voided') and (
   new.quote_billing_type is distinct from old.quote_billing_type or
   new.quote_stage_label is distinct from old.quote_stage_label or
   new.quote_billing_ex_gst is distinct from old.quote_billing_ex_gst or
   new.quote_original_ex_gst is distinct from old.quote_original_ex_gst or
   new.quote_previously_invoiced_ex_gst is distinct from old.quote_previously_invoiced_ex_gst or
   new.quote_remaining_ex_gst is distinct from old.quote_remaining_ex_gst
 ) then
   raise exception 'Issued invoice progress-billing details are locked';
 end if;
 return new;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aay_lock_issued_quote_billing"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aay_lock_issued_quote_billing"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107aaz_guard_direct_billing_series()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  allocated numeric:=0;
  agreed numeric;
  existing_agreed numeric;
  this_amount numeric;
begin
  if new.billing_series_id is null or new.source_quote_id is not null then return new; end if;
  agreed:=coalesce(new.quote_original_ex_gst,0);
  this_amount:=coalesce(new.quote_billing_ex_gst,new.subtotal,0);
  if agreed<=0 then raise exception 'Direct staged billing requires a positive agreed amount'; end if;
  if this_amount<0 then raise exception 'Billing amount cannot be negative'; end if;

  select max(i.quote_original_ex_gst) into existing_agreed
  from public.invoices i
  where i.business_id=new.business_id
    and i.billing_series_id=new.billing_series_id
    and i.id is distinct from new.id;

  if existing_agreed is not null and abs(existing_agreed-agreed)>0.01 then
    raise exception 'The agreed amount for an existing billing series cannot be changed';
  end if;

  select coalesce(sum(coalesce(i.quote_billing_ex_gst,i.subtotal,0)),0) into allocated
  from public.invoices i
  where i.business_id=new.business_id
    and i.billing_series_id=new.billing_series_id
    and i.id is distinct from new.id
    and coalesce(i.lifecycle_state,'draft')<>'voided';

  if round(allocated+this_amount,2)>round(agreed,2)+0.01 then
    raise exception 'This invoice would exceed the remaining agreed amount';
  end if;
  return new;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107aaz_guard_direct_billing_series"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107aaz_guard_direct_billing_series"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107i_reconcile_expense_deposit_refund(p_money_out_transaction_id uuid, p_refund_transaction_id uuid, p_expense_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_out public.bank_transactions%rowtype;
  v_ref public.bank_transactions%rowtype;
  v_exp public.expenses%rowtype;
  v_out_amt numeric;
  v_ref_amt numeric;
  v_net numeric;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_out from public.bank_transactions where id=p_money_out_transaction_id and business_id=v_bid for update;
  select * into v_ref from public.bank_transactions where id=p_refund_transaction_id and business_id=v_bid for update;
  if v_out.id is null or v_ref.id is null then raise exception 'Related bank transaction was not found in the active business'; end if;
  if v_out.id=v_ref.id then raise exception 'Choose two different bank transactions'; end if;
  if coalesce(v_out.status,'unreconciled')<>'unreconciled' or coalesce(v_ref.status,'unreconciled')<>'unreconciled' then raise exception 'Both bank transactions must be unreconciled'; end if;
  if v_out.amount >= 0 then raise exception 'The deposit/payment transaction must be money out'; end if;
  if v_ref.amount <= 0 then raise exception 'The refund transaction must be money in'; end if;

  v_out_amt := round(abs(v_out.amount),2);
  v_ref_amt := round(v_ref.amount,2);
  v_net := round(v_out_amt-v_ref_amt,2);
  if v_net <= 0 then raise exception 'Refund must be less than the original deposit/payment'; end if;

  select * into v_exp from public.expenses where id=p_expense_id and business_id=v_bid and not coalesce(archived,false);
  if v_exp.id is null then raise exception 'Expense not found in the active business'; end if;
  if abs(round(coalesce(v_exp.total_amount,0),2)-v_net) > 0.01 then
    raise exception 'Expense total (%) must equal the net bank cost (%)', round(coalesce(v_exp.total_amount,0),2), v_net;
  end if;

  insert into public.bank_reconciliation_allocations(
    business_id,bank_transaction_id,allocation_type,amount,expense_id,related_bank_transaction_id,note,created_by
  ) values
    (v_bid,v_out.id,'expense_deposit_refund',v_out_amt,v_exp.id,v_ref.id,nullif(btrim(coalesce(p_note,'')),''),v_uid),
    (v_bid,v_ref.id,'expense_deposit_refund',v_ref_amt,v_exp.id,v_out.id,nullif(btrim(coalesce(p_note,'')),''),v_uid);

  update public.bank_transactions
  set status='reconciled',reconciliation_type='expense_deposit_refund',reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
  where business_id=v_bid and id in (v_out.id,v_ref.id);

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values
    (v_bid,v_out.id,'expense_deposit_refund_reconciled',jsonb_build_object('expense_id',v_exp.id,'related_bank_transaction_id',v_ref.id,'money_out',v_out_amt,'refund',v_ref_amt,'net_expense',v_net),v_uid),
    (v_bid,v_ref.id,'expense_deposit_refund_reconciled',jsonb_build_object('expense_id',v_exp.id,'related_bank_transaction_id',v_out.id,'money_out',v_out_amt,'refund',v_ref_amt,'net_expense',v_net),v_uid);

  return jsonb_build_object('ok',true,'expense_id',v_exp.id,'money_out',v_out_amt,'refund',v_ref_amt,'net_expense',v_net);
end $function$
;

REVOKE ALL ON FUNCTION public."v61107i_reconcile_expense_deposit_refund"(p_money_out_transaction_id uuid, p_refund_transaction_id uuid, p_expense_id uuid, p_note text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107i_reconcile_expense_deposit_refund"(p_money_out_transaction_id uuid, p_refund_transaction_id uuid, p_expense_id uuid, p_note text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107i_reconcile_expense_deposit_refund"(p_money_out_transaction_id uuid, p_refund_transaction_id uuid, p_expense_id uuid, p_note text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107i_undo_expense_deposit_refund(p_bank_transaction_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_related uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select related_bank_transaction_id into v_related
  from public.bank_reconciliation_allocations
  where business_id=v_bid
    and bank_transaction_id=p_bank_transaction_id
    and allocation_type='expense_deposit_refund'
  limit 1;

  if v_related is null then raise exception 'Deposit/refund reconciliation was not found'; end if;

  delete from public.bank_reconciliation_allocations
  where business_id=v_bid
    and allocation_type='expense_deposit_refund'
    and bank_transaction_id in (p_bank_transaction_id,v_related);

  update public.bank_transactions
  set status='unreconciled', reconciliation_type=null, reconciled_at=null, reconciled_by=null,
      updated_at=now(), updated_by=v_uid
  where business_id=v_bid and id in (p_bank_transaction_id,v_related);

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values
    (v_bid,p_bank_transaction_id,'expense_deposit_refund_undone',jsonb_build_object('related_bank_transaction_id',v_related,'reason',coalesce(nullif(btrim(p_reason),''),'Undo deposit/refund reconciliation')),v_uid),
    (v_bid,v_related,'expense_deposit_refund_undone',jsonb_build_object('related_bank_transaction_id',p_bank_transaction_id,'reason',coalesce(nullif(btrim(p_reason),''),'Undo deposit/refund reconciliation')),v_uid);

  return jsonb_build_object('ok',true,'bank_transaction_id',p_bank_transaction_id,'related_bank_transaction_id',v_related);
end $function$
;

REVOKE ALL ON FUNCTION public."v61107i_undo_expense_deposit_refund"(p_bank_transaction_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107i_undo_expense_deposit_refund"(p_bank_transaction_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107i_undo_expense_deposit_refund"(p_bank_transaction_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107r_match_expense_bank_transaction(p_bank_transaction_id uuid, p_expense_id uuid, p_existing_payment_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid(); v_tx public.bank_transactions%rowtype; v_exp public.expenses%rowtype; v_pay public.expense_payments%rowtype; v_alloc public.bank_reconciliation_allocations%rowtype; v_amt numeric(14,2);
begin
 if v_uid is null then raise exception 'Authentication required'; end if;
 if v_bid is null then raise exception 'No active authorised business'; end if;
 if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;
 select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
 if v_tx.id is null or v_tx.amount>=0 then raise exception 'Expense bank transaction is not available'; end if;
 v_amt:=abs(v_tx.amount);
 if v_tx.status='reconciled' then return jsonb_build_object('ok',true,'result','already_reconciled'); end if;
 if v_tx.status<>'unreconciled' then raise exception 'Bank transaction is not unreconciled'; end if;
 select * into v_exp from public.expenses where id=p_expense_id and business_id=v_bid and coalesce(archived,false)=false and coalesce(lifecycle_state,'recorded')='recorded' for update;
 if v_exp.id is null then raise exception 'Active expense was not found'; end if;

 select * into v_alloc from public.bank_reconciliation_allocations where business_id=v_bid and bank_transaction_id=v_tx.id and expense_id=v_exp.id order by created_at desc limit 1;
 if v_alloc.id is not null then
   update public.bank_transactions set status='reconciled',reconciliation_type='expense',reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid where id=v_tx.id and business_id=v_bid;
   return jsonb_build_object('ok',true,'result','finished_existing_allocation','expense_number',v_exp.expense_number);
 end if;

 if p_existing_payment_id is not null then
   select * into v_pay from public.expense_payments where id=p_existing_payment_id and business_id=v_bid and expense_id=v_exp.id for update;
   if v_pay.id is null or abs(coalesce(v_pay.amount,0)-v_amt)>0.01 then raise exception 'Existing expense payment does not match the bank amount'; end if;
   if exists(select 1 from public.bank_reconciliation_allocations where business_id=v_bid and expense_payment_id=v_pay.id) then raise exception 'Existing expense payment is already linked to another bank transaction'; end if;
 else
   if coalesce(v_exp.outstanding_balance,0)+0.01 < v_amt then raise exception 'Bank amount exceeds the expense outstanding balance'; end if;
   insert into public.expense_payments(business_id,expense_id,payment_date,amount,payment_method,bank_account,reference,notes,reconciled,reconciled_at,reconciled_by,bank_transaction_reference,created_by)
   values(v_bid,v_exp.id,v_tx.transaction_date,v_amt,'Bank reconciliation',null,v_tx.reference,'Created by atomic bank reconciliation',true,now(),v_uid,coalesce(v_tx.bank_transaction_id,v_tx.reference),v_uid) returning * into v_pay;
 end if;

 insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,expense_id,expense_payment_id,created_expense,created_by)
 values(v_bid,v_tx.id,'expense',v_amt,v_exp.id,v_pay.id,false,v_uid);
 update public.expense_payments set reconciled=true,reconciled_at=now(),reconciled_by=v_uid,bank_transaction_reference=coalesce(v_tx.bank_transaction_id,v_tx.reference,v_tx.id::text) where id=v_pay.id and business_id=v_bid and expense_id=v_exp.id;

 update public.bank_transactions set status='reconciled',reconciliation_type='expense',reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid where id=v_tx.id and business_id=v_bid;

 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
 values(v_bid,v_tx.id,'expense_reconciled_atomic',jsonb_build_object('expense_id',v_exp.id,'payment_id',v_pay.id,'amount',v_amt,'existing_payment',p_existing_payment_id is not null,'atomic',true),v_uid);
 return jsonb_build_object('ok',true,'result','reconciled','expense_number',v_exp.expense_number);
end $function$
;

REVOKE ALL ON FUNCTION public."v61107r_match_expense_bank_transaction"(p_bank_transaction_id uuid, p_expense_id uuid, p_existing_payment_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107r_match_expense_bank_transaction"(p_bank_transaction_id uuid, p_expense_id uuid, p_existing_payment_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107r_match_expense_bank_transaction"(p_bank_transaction_id uuid, p_expense_id uuid, p_existing_payment_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107r_recover_or_finish_expense_bank_match(p_bank_transaction_id uuid, p_source_voided_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid();
  v_tx public.bank_transactions%rowtype; v_src public.expenses%rowtype;
  v_exp public.expenses%rowtype; v_pay public.expense_payments%rowtype;
  v_alloc public.bank_reconciliation_allocations%rowtype;
  v_num text; v_amt numeric(14,2);
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction was not found for this business'; end if;
  if v_tx.amount>=0 then raise exception 'Expense recovery requires money going out'; end if;
  v_amt:=abs(v_tx.amount);

  select * into v_src from public.expenses where id=p_source_voided_expense_id and business_id=v_bid;
  if v_src.id is null or v_src.lifecycle_state<>'voided' or coalesce(v_src.void_reason,'')<>'Bulk undo from Reconciled history' then
    raise exception 'Source expense is not an eligible TEST-cleanup voided expense';
  end if;
  if abs(coalesce(v_src.total_amount,0)-v_amt)>0.01 or v_src.invoice_date<>v_tx.transaction_date then
    raise exception 'Bank transaction does not exactly match the source expense amount and date';
  end if;

  if v_tx.status='reconciled' then
    return jsonb_build_object('ok',true,'result','already_reconciled');
  elsif v_tx.status<>'unreconciled' then
    raise exception 'Bank transaction is not available for reconciliation';
  end if;

  select a.* into v_alloc from public.bank_reconciliation_allocations a
   where a.business_id=v_bid and a.bank_transaction_id=v_tx.id and a.expense_id is not null
   order by a.created_at desc limit 1;

  if v_alloc.id is not null then
    select * into v_exp from public.expenses where id=v_alloc.expense_id and business_id=v_bid;
    if v_exp.id is null or coalesce(v_exp.lifecycle_state,'recorded')<>'recorded' then raise exception 'Existing bank allocation does not point to an active expense'; end if;
    update public.bank_transactions set status='reconciled',reconciliation_type=case when coalesce(v_alloc.created_expense,false) then 'created_expense' else 'expense' end,
      reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid where id=v_tx.id and business_id=v_bid;
    return jsonb_build_object('ok',true,'result','finished_existing_allocation','expense_id',v_exp.id,'expense_number',v_exp.expense_number);
  end if;

  select e.* into v_exp from public.expenses e
   where e.business_id=v_bid and e.id<>v_src.id and coalesce(e.archived,false)=false
     and coalesce(e.lifecycle_state,'recorded')='recorded'
     and e.invoice_date=v_tx.transaction_date and abs(coalesce(e.total_amount,0)-v_amt)<=0.01
     and regexp_replace(lower(coalesce(e.supplier_name,'')),'[^a-z0-9]','','g') =
         regexp_replace(lower(coalesce(v_src.supplier_name,'')),'[^a-z0-9]','','g')
   order by e.created_at desc limit 1 for update;

  if v_exp.id is not null then
    select p.* into v_pay from public.expense_payments p
      where p.business_id=v_bid and p.expense_id=v_exp.id and abs(coalesce(p.amount,0)-v_amt)<=0.01
        and not exists(select 1 from public.bank_reconciliation_allocations a where a.business_id=v_bid and a.expense_payment_id=p.id)
      order by p.created_at desc limit 1 for update;
    if v_pay.id is null then raise exception 'An active replacement expense exists but no unused matching payment is available'; end if;
    insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,expense_id,expense_payment_id,created_expense,created_by)
      values(v_bid,v_tx.id,'expense',v_amt,v_exp.id,v_pay.id,true,v_uid);
    update public.bank_transactions set status='reconciled',reconciliation_type='created_expense',reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
      where id=v_tx.id and business_id=v_bid;
    insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
      values(v_bid,v_tx.id,'recovery_existing_replacement_finished',jsonb_build_object('source_voided_expense_id',v_src.id,'replacement_expense_id',v_exp.id,'payment_id',v_pay.id,'amount',v_amt),v_uid);
    return jsonb_build_object('ok',true,'result','linked_existing_replacement','expense_id',v_exp.id,'expense_number',v_exp.expense_number);
  end if;

  v_num:=public.v51_next_expense_number();
  insert into public.expenses(business_id,expense_number,supplier_id,supplier_name,supplier_reference,invoice_date,due_date,description,category_id,job_costing_id,amount_type,gst_treatment,gst_rate,gst_override,ex_gst,gst_amount,total_amount,payment_status,currency,is_split,business_use_percent,business_use_amount,private_use_amount,business_ex_gst,business_gst_amount,allocation_method,allocation_basis,allocation_notes,created_by,updated_by)
  values(v_bid,v_num,v_src.supplier_id,coalesce(v_src.supplier_name,v_tx.payee),coalesce(v_src.supplier_reference,v_tx.reference),v_src.invoice_date,coalesce(v_src.due_date,v_src.invoice_date),coalesce(v_src.description,v_tx.payee,v_tx.description),v_src.category_id,v_src.job_costing_id,coalesce(v_src.amount_type,'inclusive'),coalesce(v_src.gst_treatment,'no_gst'),coalesce(v_src.gst_rate,0),coalesce(v_src.gst_override,false),v_src.ex_gst,v_src.gst_amount,v_src.total_amount,'unpaid',coalesce(v_src.currency,'NZD'),coalesce(v_src.is_split,false),v_src.business_use_percent,v_src.business_use_amount,v_src.private_use_amount,v_src.business_ex_gst,v_src.business_gst_amount,v_src.allocation_method,v_src.allocation_basis,v_src.allocation_notes,v_uid,v_uid)
  returning * into v_exp;

  insert into public.expense_payments(business_id,expense_id,payment_date,amount,payment_method,reference,notes,reconciled,reconciled_at,reconciled_by,bank_transaction_reference,created_by)
  values(v_bid,v_exp.id,v_tx.transaction_date,v_amt,'Bank reconciliation',v_tx.reference,'Recovered atomically after TEST-account reconciliation cleanup',true,now(),v_uid,coalesce(v_tx.bank_transaction_id,v_tx.reference),v_uid)
  returning * into v_pay;

  insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,expense_id,expense_payment_id,created_expense,created_by)
  values(v_bid,v_tx.id,'expense',v_amt,v_exp.id,v_pay.id,true,v_uid);

  update public.bank_transactions set status='reconciled',reconciliation_type='created_expense',reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
   where id=v_tx.id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values(v_bid,v_tx.id,'voided_expense_recovered_atomic',jsonb_build_object('source_voided_expense_id',v_src.id,'replacement_expense_id',v_exp.id,'payment_id',v_pay.id,'amount',v_amt,'atomic',true),v_uid);

  return jsonb_build_object('ok',true,'result','created_and_reconciled','expense_id',v_exp.id,'expense_number',v_exp.expense_number);
end $function$
;

REVOKE ALL ON FUNCTION public."v61107r_recover_or_finish_expense_bank_match"(p_bank_transaction_id uuid, p_source_voided_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107r_recover_or_finish_expense_bank_match"(p_bank_transaction_id uuid, p_source_voided_expense_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107r_recover_or_finish_expense_bank_match"(p_bank_transaction_id uuid, p_source_voided_expense_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107t_owner_current_balances(p_business_id uuid DEFAULT current_business_id())
 RETURNS TABLE(owner_id uuid, display_name text, balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
 select o.id,o.display_name,coalesce(sum(e.amount),0)::numeric
 from public.business_owners o left join public.owner_current_account_entries e on e.business_id=o.business_id and e.owner_id=o.id
 where o.business_id=p_business_id and public.v6145_has_active_business_membership(p_business_id)
 group by o.id,o.display_name order by o.display_name
$function$
;

REVOKE ALL ON FUNCTION public."v61107t_owner_current_balances"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107t_owner_current_balances"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107t_owner_current_balances"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107t_owner_entry_business_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
 if not exists(select 1 from public.business_owners o where o.id=new.owner_id and o.business_id=new.business_id) then raise exception 'Owner/shareholder does not belong to this business'; end if;
 if new.accounting_journal_id is not null and not exists(select 1 from public.accounting_journals j where j.id=new.accounting_journal_id and j.business_id=new.business_id) then raise exception 'Accounting journal does not belong to this business'; end if;
 if new.reversal_of_entry_id is not null and not exists(select 1 from public.owner_current_account_entries e where e.id=new.reversal_of_entry_id and e.business_id=new.business_id and e.owner_id=new.owner_id) then raise exception 'Reversal entry does not belong to this owner/business'; end if;
 return new;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107t_owner_entry_business_guard"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107t_owner_entry_business_guard"() TO PUBLIC;

GRANT EXECUTE ON FUNCTION public."v61107t_owner_entry_business_guard"() TO "anon";

GRANT EXECUTE ON FUNCTION public."v61107t_owner_entry_business_guard"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107t_owner_entry_business_guard"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107u_expense_payment_owner_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
 if new.funding_source='owner_personal' and not exists(select 1 from public.business_owners o where o.id=new.owner_id and o.business_id=new.business_id and o.status='active') then raise exception 'Active owner/shareholder does not belong to this business'; end if;
 return new;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107u_expense_payment_owner_guard"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107u_expense_payment_owner_guard"() TO PUBLIC;

GRANT EXECUTE ON FUNCTION public."v61107u_expense_payment_owner_guard"() TO "anon";

GRANT EXECUTE ON FUNCTION public."v61107u_expense_payment_owner_guard"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107u_expense_payment_owner_guard"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107u_record_owner_paid_expense(p_expense_id uuid, p_owner_id uuid, p_payment_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bid uuid;v_uid uuid;v_exp public.expenses%rowtype;v_owner public.business_owners%rowtype;v_remaining numeric;v_payment_id uuid;v_exp_journal uuid;v_pay_journal uuid;
begin
 v_uid:=auth.uid();v_bid:=public.current_business_id();
 if v_uid is null or v_bid is null then raise exception 'Authentication and an active business are required'; end if;
 if public.v6147_current_business_role(v_bid) not in ('owner','admin','bookkeeper') then raise exception 'You do not have permission to record an owner-funded expense'; end if;
 select * into v_exp from public.expenses where id=p_expense_id and business_id=v_bid for update;
 if not found then raise exception 'Expense not found in active business'; end if;
 if coalesce(v_exp.archived,false) or coalesce(v_exp.lifecycle_state,'recorded')='voided' or v_exp.payment_status='draft' then raise exception 'Only an active non-draft expense can be paid personally'; end if;
 if coalesce(v_exp.business_use_percent,100)<99.995 or coalesce(v_exp.private_use_amount,0)>0.005 then raise exception 'Owner-funded payment currently requires full business use. Record mixed/private-use bills separately.'; end if;
 select * into v_owner from public.business_owners where id=p_owner_id and business_id=v_bid and status='active';
 if not found then raise exception 'Active owner/shareholder not found in this business'; end if;
 select round(v_exp.total_amount-coalesce(sum(ep.amount),0),2) into v_remaining from public.expense_payments ep where ep.business_id=v_bid and ep.expense_id=v_exp.id;
 if v_remaining<=0.005 then raise exception 'This expense is already fully paid'; end if;
 insert into public.expense_payments(business_id,expense_id,payment_date,amount,payment_method,reference,notes,funding_source,owner_id,created_by) values(v_bid,v_exp.id,coalesce(p_payment_date,v_exp.invoice_date,current_date),v_remaining,'Owner/shareholder personal funds',v_exp.supplier_reference,'Paid personally by '||v_owner.display_name,'owner_personal',v_owner.id,v_uid) returning id into v_payment_id;
 v_exp_journal:=public.v6170b_post_source('expense',v_exp.id,'v61107u_owner_personal');
 v_pay_journal:=public.v6170b_post_source('supplier_payment',v_payment_id,'v61107u_owner_personal');
 insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,description,created_by) values(v_bid,v_owner.id,coalesce(p_payment_date,v_exp.invoice_date,current_date),'expense_paid_personally',v_remaining,'expense_payment',v_payment_id,v_exp.expense_number,v_pay_journal,'Personally paid business expense '||v_exp.expense_number,v_uid);
 return jsonb_build_object('ok',true,'expense_id',v_exp.id,'payment_id',v_payment_id,'expense_journal_id',v_exp_journal,'payment_journal_id',v_pay_journal,'owner_id',v_owner.id,'amount',v_remaining);
end $function$
;

REVOKE ALL ON FUNCTION public."v61107u_record_owner_paid_expense"(p_expense_id uuid, p_owner_id uuid, p_payment_date date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107u_record_owner_paid_expense"(p_expense_id uuid, p_owner_id uuid, p_payment_date date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107u_record_owner_paid_expense"(p_expense_id uuid, p_owner_id uuid, p_payment_date date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107v_owner_history_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
 if not exists(select 1 from public.business_owners o where o.id=new.owner_id and o.business_id=new.business_id) then raise exception 'Owner/shareholder does not belong to this business'; end if;
 return new;
end $function$
;

REVOKE ALL ON FUNCTION public."v61107v_owner_history_guard"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107v_owner_history_guard"() TO PUBLIC;

GRANT EXECUTE ON FUNCTION public."v61107v_owner_history_guard"() TO "anon";

GRANT EXECUTE ON FUNCTION public."v61107v_owner_history_guard"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107v_owner_history_guard"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107v_update_business_owner(p_owner_id uuid, p_display_name text, p_owner_type text, p_is_shareholder boolean, p_is_director boolean, p_ownership_percent numeric, p_share_class text, p_shares_held numeric, p_status text, p_director_appointed_on date, p_director_resigned_on date, p_effective_date date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bid uuid;v_old public.business_owners%rowtype;v_new public.business_owners%rowtype;v_change text:='details_corrected';
begin
 v_bid:=public.current_business_id();
 if auth.uid() is null or v_bid is null then raise exception 'Authentication and an active business are required'; end if;
 if public.v6147_current_business_role(v_bid) not in ('owner','admin','bookkeeper') then raise exception 'You do not have permission to edit owners/shareholders'; end if;
 select * into v_old from public.business_owners where id=p_owner_id and business_id=v_bid for update;
 if not found then raise exception 'Owner/shareholder not found'; end if;
 if nullif(trim(p_display_name),'') is null then raise exception 'Name is required'; end if;
 if p_owner_type not in ('owner','shareholder','director','partner','trustee','other') then raise exception 'Invalid owner type'; end if;
 if p_status not in ('active','inactive') then raise exception 'Invalid status'; end if;
 if p_ownership_percent is not null and (p_ownership_percent<0 or p_ownership_percent>100) then raise exception 'Ownership percentage must be between 0 and 100'; end if;
 if p_shares_held is not null and p_shares_held<0 then raise exception 'Shares held cannot be negative'; end if;
 if p_director_resigned_on is not null and p_director_appointed_on is not null and p_director_resigned_on<p_director_appointed_on then raise exception 'Director resignation cannot predate appointment'; end if;
 if v_old.is_director is distinct from p_is_director then v_change:=case when p_is_director then 'appointed_director' else 'resigned_director' end;
 elsif v_old.is_shareholder is distinct from p_is_shareholder or v_old.ownership_percent is distinct from p_ownership_percent or v_old.share_class is distinct from nullif(trim(p_share_class),'') or v_old.shares_held is distinct from p_shares_held then v_change:='shareholding_changed';
 elsif v_old.status is distinct from p_status then v_change:=case when p_status='active' then 'activated' else 'deactivated' end;
 elsif v_old.owner_type is distinct from p_owner_type then v_change:='role_changed'; end if;
 update public.business_owners set display_name=trim(p_display_name),owner_type=p_owner_type,is_shareholder=coalesce(p_is_shareholder,false),is_director=coalesce(p_is_director,false),ownership_percent=p_ownership_percent,share_class=nullif(trim(p_share_class),''),shares_held=p_shares_held,status=p_status,director_appointed_on=p_director_appointed_on,director_resigned_on=p_director_resigned_on,notes=coalesce(p_note,notes),updated_at=now(),updated_by=auth.uid() where id=p_owner_id returning * into v_new;
 insert into public.business_owner_history(business_id,owner_id,effective_date,change_type,before_data,after_data,note,created_by)
 values(v_bid,p_owner_id,coalesce(p_effective_date,current_date),v_change,to_jsonb(v_old),to_jsonb(v_new),p_note,auth.uid());
 return jsonb_build_object('ok',true,'owner_id',p_owner_id,'change_type',v_change);
end $function$
;

REVOKE ALL ON FUNCTION public."v61107v_update_business_owner"(p_owner_id uuid, p_display_name text, p_owner_type text, p_is_shareholder boolean, p_is_director boolean, p_ownership_percent numeric, p_share_class text, p_shares_held numeric, p_status text, p_director_appointed_on date, p_director_resigned_on date, p_effective_date date, p_note text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107v_update_business_owner"(p_owner_id uuid, p_display_name text, p_owner_type text, p_is_shareholder boolean, p_is_director boolean, p_ownership_percent numeric, p_share_class text, p_shares_held numeric, p_status text, p_director_appointed_on date, p_director_resigned_on date, p_effective_date date, p_note text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107v_update_business_owner"(p_owner_id uuid, p_display_name text, p_owner_type text, p_is_shareholder boolean, p_is_director boolean, p_ownership_percent numeric, p_share_class text, p_shares_held numeric, p_status text, p_director_appointed_on date, p_director_resigned_on date, p_effective_date date, p_note text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107w_owner_allocation_business_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.owner_id is not null then
    if new.allocation_type <> 'owner_equity' then
      raise exception 'Owner/shareholder can only be attached to an owner_equity allocation';
    end if;
    if not exists(
      select 1 from public.business_owners o
      where o.id=new.owner_id and o.business_id=new.business_id
    ) then
      raise exception 'Owner/shareholder does not belong to this business';
    end if;
  end if;
  return new;
end
$function$
;

REVOKE ALL ON FUNCTION public."v61107w_owner_allocation_business_guard"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107w_owner_allocation_business_guard"() TO PUBLIC;

GRANT EXECUTE ON FUNCTION public."v61107w_owner_allocation_business_guard"() TO "anon";

GRANT EXECUTE ON FUNCTION public."v61107w_owner_allocation_business_guard"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107w_owner_allocation_business_guard"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107w_owner_bank_candidates(p_bank_transaction_id uuid)
 RETURNS TABLE(owner_id uuid, display_name text, current_balance numeric, suggested_action text, transaction_amount numeric, confidence integer, reason text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 v_bid uuid;
 v_tx_amount numeric;
 v_payee text;
 v_description text;
 v_reference text;
 v_status text;
begin
 v_bid:=public.current_business_id();
 if v_bid is null or not public.v6145_has_active_business_membership(v_bid) then
   return;
 end if;

 select bt.amount,bt.payee,bt.description,bt.reference,bt.status
 into v_tx_amount,v_payee,v_description,v_reference,v_status
 from public.bank_transactions bt
 where bt.id=p_bank_transaction_id and bt.business_id=v_bid;

 if not found or coalesce(v_status,'unreconciled')<>'unreconciled' or coalesce(v_tx_amount,0)=0 then
   return;
 end if;

 return query
 with balances as (
   select o.id,o.display_name,coalesce(sum(e.amount),0)::numeric as balance
   from public.business_owners o
   left join public.owner_current_account_entries e
     on e.business_id=o.business_id and e.owner_id=o.id
   where o.business_id=v_bid and o.status='active'
   group by o.id,o.display_name
 ),
 scored as (
   select b.id,b.display_name,b.balance,
     case when v_tx_amount>0 then 'funds_introduced' else 'reimbursement' end as action_name,
     abs(v_tx_amount)::numeric as tx_amount,
     case
       when v_tx_amount<0 and b.balance>0 and round(b.balance,2)=round(abs(v_tx_amount),2) then 95
       when position(lower(b.display_name) in lower(coalesce(v_payee,'')||' '||coalesce(v_description,'')||' '||coalesce(v_reference,'')))>0 then 85
       when v_tx_amount<0 and b.balance>0 and b.balance>=abs(v_tx_amount) then 70
       else 0
     end as score,
     case
       when v_tx_amount<0 and b.balance>0 and round(b.balance,2)=round(abs(v_tx_amount),2) then 'Exact current-account balance'
       when position(lower(b.display_name) in lower(coalesce(v_payee,'')||' '||coalesce(v_description,'')||' '||coalesce(v_reference,'')))>0 then 'Owner/shareholder name appears on bank transaction'
       when v_tx_amount<0 and b.balance>0 and b.balance>=abs(v_tx_amount) then 'Amount is within current-account balance'
       else 'Manual owner/shareholder option'
     end as why
   from balances b
 )
 select s.id,s.display_name,s.balance,s.action_name,s.tx_amount,s.score,s.why
 from scored s
 where s.score>0
 order by s.score desc,s.display_name;
end
$function$
;

REVOKE ALL ON FUNCTION public."v61107w_owner_bank_candidates"(p_bank_transaction_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107w_owner_bank_candidates"(p_bank_transaction_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107w_owner_bank_candidates"(p_bank_transaction_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107w_reconcile_owner_current_account(p_bank_transaction_id uuid, p_owner_id uuid, p_action text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_bid uuid:=public.current_business_id();v_uid uuid:=auth.uid();v_tx public.bank_transactions%rowtype;v_owner public.business_owners%rowtype;v_amount numeric;v_balance numeric;v_result jsonb;v_alloc uuid;v_journal uuid;v_entry uuid;v_equity_type text;
begin
 if v_uid is null or v_bid is null then raise exception 'Authentication and active business required'; end if;
 if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;
 if p_action not in ('funds_introduced','reimbursement') then raise exception 'Unsupported owner current-account action'; end if;
 select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
 if v_tx.id is null then raise exception 'Bank transaction not found'; end if;
 select * into v_owner from public.business_owners where id=p_owner_id and business_id=v_bid;
 if v_owner.id is null then raise exception 'Owner/shareholder not found in active business'; end if;
 v_amount:=round(abs(v_tx.amount),2);
 if p_action='funds_introduced' then
   if v_tx.amount<=0 then raise exception 'Funds introduced requires a money-in transaction'; end if;
   v_equity_type:='owner_funds_introduced';
 else
   if v_tx.amount>=0 then raise exception 'Reimbursement requires a money-out transaction'; end if;
   select coalesce(sum(amount),0) into v_balance from public.owner_current_account_entries where business_id=v_bid and owner_id=p_owner_id;
   if round(v_balance,2)<v_amount then raise exception 'Reimbursement exceeds this owner current-account balance'; end if;
   v_equity_type:='repay_owner_loan';
 end if;
 v_result:=public.v61106e_reconcile_owner_equity_bank_transaction(v_tx.id,v_equity_type,coalesce(nullif(btrim(p_note),''),v_owner.display_name));
 select id,accounting_journal_id into v_alloc,v_journal from public.bank_reconciliation_allocations where business_id=v_bid and bank_transaction_id=v_tx.id and allocation_type='owner_equity' order by created_at desc limit 1;
 if v_alloc is null or v_journal is null then raise exception 'Owner/equity reconciliation did not create its allocation and journal'; end if;
 update public.bank_reconciliation_allocations set owner_id=p_owner_id where id=v_alloc and business_id=v_bid;
 insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,description,created_by)
 values(v_bid,p_owner_id,v_tx.transaction_date,case when p_action='funds_introduced' then 'funds_introduced' else 'reimbursement' end,case when p_action='funds_introduced' then v_amount else -v_amount end,'bank_reconciliation_allocation',v_alloc,coalesce(v_tx.reference,v_tx.description),v_journal,case when p_action='funds_introduced' then 'Funds introduced by ' else 'Reimbursement to ' end||v_owner.display_name,v_uid)
 returning id into v_entry;
 return v_result||jsonb_build_object('owner_id',p_owner_id,'owner_entry_id',v_entry,'allocation_id',v_alloc);
end $function$
;

REVOKE ALL ON FUNCTION public."v61107w_reconcile_owner_current_account"(p_bank_transaction_id uuid, p_owner_id uuid, p_action text, p_note text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107w_reconcile_owner_current_account"(p_bank_transaction_id uuid, p_owner_id uuid, p_action text, p_note text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107w_reconcile_owner_current_account"(p_bank_transaction_id uuid, p_owner_id uuid, p_action text, p_note text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61107w_undo_owner_current_account(p_bank_transaction_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_bid uuid:=public.current_business_id();v_uid uuid:=auth.uid();v_tx public.bank_transactions%rowtype;v_alloc public.bank_reconciliation_allocations%rowtype;v_entry public.owner_current_account_entries%rowtype;v_rev_journal uuid;
begin
 if v_uid is null or v_bid is null then raise exception 'Authentication and active business required'; end if;
 if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;
 select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
 if v_tx.id is null then raise exception 'Bank transaction not found'; end if;
 select * into v_alloc from public.bank_reconciliation_allocations where business_id=v_bid and bank_transaction_id=v_tx.id and allocation_type='owner_equity' and owner_id is not null order by created_at desc limit 1 for update;
 if v_alloc.id is null then raise exception 'Individual owner/shareholder reconciliation not found'; end if;
 select * into v_entry from public.owner_current_account_entries where business_id=v_bid and source_type='bank_reconciliation_allocation' and source_id=v_alloc.id order by created_at desc limit 1 for update;
 if v_entry.id is null then raise exception 'Owner current-account entry is missing; no changes made'; end if;
 if v_alloc.accounting_journal_id is not null then v_rev_journal:=public.v6170a_reverse_journal(v_alloc.accounting_journal_id,coalesce(nullif(btrim(p_reason),''),'Bank reconciliation undone')); end if;
 insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,reversal_of_entry_id,description,created_by)
 values(v_bid,v_entry.owner_id,current_date,'reversal',-v_entry.amount,'bank_reconciliation_undo',v_alloc.id,v_entry.source_reference,v_rev_journal,v_entry.id,'Reversal: '||coalesce(nullif(btrim(p_reason),''),'Bank reconciliation undone'),v_uid);
 delete from public.bank_reconciliation_allocations where id=v_alloc.id and business_id=v_bid;
 update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,updated_at=now(),updated_by=v_uid where id=v_tx.id and business_id=v_bid;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(v_bid,v_tx.id,'owner_current_account_undo',jsonb_build_object('owner_id',v_entry.owner_id,'allocation_id',v_alloc.id,'journal_id',v_alloc.accounting_journal_id,'reversal_journal_id',v_rev_journal,'reason',p_reason),v_uid);
 return jsonb_build_object('ok',true,'bank_transaction_id',v_tx.id,'owner_id',v_entry.owner_id,'reversal_journal_id',v_rev_journal);
end $function$
;

REVOKE ALL ON FUNCTION public."v61107w_undo_owner_current_account"(p_bank_transaction_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61107w_undo_owner_current_account"(p_bank_transaction_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61107w_undo_owner_current_account"(p_bank_transaction_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61108_admin_note_invoice_payment_exception(p_transaction_id uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_is_super_admin boolean := false;
  v_tx public.invoice_payment_transactions%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if v_uid is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(is_super_admin, false)
  into v_is_super_admin
  from public.profiles
  where id = v_uid;

  if not coalesce(v_is_super_admin, false) then
    raise exception 'Super Admin access required';
  end if;

  if v_note is null then
    raise exception 'Review note is required';
  end if;

  select * into v_tx
  from public.invoice_payment_transactions
  where id = p_transaction_id
  for update;

  if v_tx.id is null then
    raise exception 'Invoice payment transaction not found';
  end if;

  if coalesce(v_tx.status, '') not in ('needs_review','refunded','partially_refunded','disputed','failed') then
    raise exception 'Only exception payment statuses can be reviewed';
  end if;

  update public.invoice_payment_transactions
  set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'admin_review_note', v_note,
        'admin_reviewed_at', now(),
        'admin_reviewed_by', v_uid
      ),
      updated_at = now()
  where id = v_tx.id;

  return jsonb_build_object('ok', true, 'transaction_id', v_tx.id);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61108_admin_note_invoice_payment_exception"(p_transaction_id uuid, p_note text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61108_admin_note_invoice_payment_exception"(p_transaction_id uuid, p_note text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61108_admin_note_invoice_payment_exception"(p_transaction_id uuid, p_note text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61108_reconcile_stripe_payout_bank_transaction(p_bank_transaction_id uuid, p_transaction_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_bank uuid;
  v_clearing uuid;
  v_total numeric := 0;
  v_journal uuid;
  v_ids uuid[];
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select array(select distinct unnest(coalesce(p_transaction_ids,'{}'::uuid[]))) into v_ids;
  if coalesce(array_length(v_ids,1),0) = 0 then
    raise exception 'Choose at least one Stripe payment to match to this payout';
  end if;

  select * into v_tx
  from public.bank_transactions
  where id = p_bank_transaction_id and business_id = v_bid
  for update;

  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;
  if coalesce(v_tx.amount,0) <= 0 then raise exception 'Stripe payouts must be matched to a money-in bank transaction'; end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and v_tx.transaction_date between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this bank transaction is locked';
  end if;

  select coalesce(round(sum(
    coalesce(t.net_amount, t.gross_amount - coalesce(t.stripe_fee_amount,0), t.gross_amount)
  ),2),0)
  into v_total
  from public.invoice_payment_transactions t
  where t.business_id = v_bid
    and t.id = any(v_ids)
    and t.status = 'succeeded'
    and t.customer_payment_id is not null
    and not exists (
      select 1
      from public.bank_reconciliation_allocations a
      where a.business_id = v_bid
        and a.allocation_type = 'stripe_payout'
        and a.invoice_payment_transaction_id = t.id
    );

  if round(v_total,2) <> round(v_tx.amount,2) then
    raise exception 'Selected Stripe payments total %, but the bank payout is %', v_total, v_tx.amount;
  end if;

  v_bank := public.v61105_account_role_id(v_bid,'bank');
  v_clearing := coalesce(
    public.v6170b_account(v_bid,'payment_clearing'),
    (select id from public.accounting_accounts where business_id=v_bid and system_key='payment_clearing' and not coalesce(archived,false) order by account_code limit 1)
  );

  if v_bank is null or v_clearing is null then
    raise exception 'Bank or payment clearing account is not available';
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    v_tx.transaction_date,
    'bank',
    'stripe_payout',
    v_tx.id,
    coalesce(nullif(v_tx.reference,''),'Stripe payout'),
    'Stripe payout matched to online payments',
    jsonb_build_array(
      jsonb_build_object('account_id',v_bank,'description','Stripe payout received','debit',v_total,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_clearing,'description','Clear Stripe payment clearing','debit',0,'credit',v_total,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    )
  );

  insert into public.bank_reconciliation_allocations(
    business_id,
    bank_transaction_id,
    allocation_type,
    amount,
    invoice_payment_transaction_id,
    accounting_journal_id,
    created_by
  )
  select
    v_bid,
    v_tx.id,
    'stripe_payout',
    round(coalesce(t.net_amount, t.gross_amount - coalesce(t.stripe_fee_amount,0), t.gross_amount),2),
    t.id,
    v_journal,
    v_uid
  from public.invoice_payment_transactions t
  where t.business_id = v_bid
    and t.id = any(v_ids)
    and t.status = 'succeeded'
    and t.customer_payment_id is not null;

  update public.bank_transactions
  set status = 'reconciled',
      reconciliation_type = 'stripe_payout',
      reconciled_at = now(),
      reconciled_by = v_uid,
      updated_at = now(),
      updated_by = v_uid
  where id = v_tx.id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid,
    v_tx.id,
    'stripe_payout_reconciled',
    jsonb_build_object('journal_id',v_journal,'amount',v_total,'transaction_ids',to_jsonb(v_ids)),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'amount',v_total,'matched_count',array_length(v_ids,1));
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61108_reconcile_stripe_payout_bank_transaction"(p_bank_transaction_id uuid, p_transaction_ids uuid[]) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61108_reconcile_stripe_payout_bank_transaction"(p_bank_transaction_id uuid, p_transaction_ids uuid[]) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61108_reconcile_stripe_payout_bank_transaction"(p_bank_transaction_id uuid, p_transaction_ids uuid[]) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61108_record_stripe_refund_accounting(p_transaction_id uuid, p_refund_amount numeric, p_refund_date date DEFAULT CURRENT_DATE, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tx public.invoice_payment_transactions%rowtype;
  v_invoice public.invoices%rowtype;
  v_refund_amount numeric := round(coalesce(p_refund_amount, 0), 2);
  v_ex_gst numeric;
  v_gst numeric;
  v_cn_id uuid;
  v_refund_id uuid;
  v_cn_journal uuid;
  v_refund_journal uuid;
  v_cn_lines jsonb;
  v_sales uuid;
  v_gst_output uuid;
  v_ar uuid;
  v_clearing uuid;
  v_suffix text;
  v_ref text;
begin
  select * into v_tx
  from public.invoice_payment_transactions
  where id = p_transaction_id
  for update;

  if v_tx.id is null then
    raise exception 'Online payment transaction not found';
  end if;

  select * into v_invoice
  from public.invoices
  where id = v_tx.invoice_id
    and business_id = v_tx.business_id
  for update;

  if v_invoice.id is null then
    raise exception 'Invoice was not found for the refunded payment';
  end if;

  if v_invoice.customer_id is null then
    raise exception 'Refund accounting requires the invoice to have a customer record';
  end if;

  if v_refund_amount <= 0 then
    raise exception 'Refund amount must be greater than zero';
  end if;

  if lower(coalesce(v_tx.currency, 'nzd')) <> lower(coalesce(nullif(v_invoice.company_snapshot->>'currency',''), 'nzd')) then
    raise exception 'Refund currency does not match the invoice currency';
  end if;

  if exists (
    select 1
    from public.accounting_periods p
    where p.business_id = v_tx.business_id
      and p.status <> 'open'
      and coalesce(p_refund_date, current_date) between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this refund is locked';
  end if;

  select id into v_cn_id
  from public.customer_credit_notes
  where business_id = v_tx.business_id
    and idempotency_key = v_tx.id;

  select id into v_refund_id
  from public.customer_refunds
  where business_id = v_tx.business_id
    and idempotency_key = v_tx.id;

  select id into v_cn_journal
  from public.accounting_journals
  where business_id = v_tx.business_id
    and source_type = 'stripe_refund_credit_note'
    and source_id = v_tx.id
    and status in ('posted','reversed')
  limit 1;

  select id into v_refund_journal
  from public.accounting_journals
  where business_id = v_tx.business_id
    and source_type = 'stripe_refund'
    and source_id = v_tx.id
    and status in ('posted','reversed')
  limit 1;

  if v_cn_id is not null and v_refund_id is not null and v_cn_journal is not null and v_refund_journal is not null then
    return jsonb_build_object(
      'ok', true,
      'already_recorded', true,
      'credit_note_id', v_cn_id,
      'refund_id', v_refund_id,
      'credit_note_journal_id', v_cn_journal,
      'refund_journal_id', v_refund_journal
    );
  end if;

  v_suffix := upper(left(replace(v_tx.id::text, '-', ''), 10));
  v_ref := coalesce(nullif(btrim(p_reference), ''), coalesce(v_tx.stripe_charge_id, v_tx.stripe_payment_intent_id, 'Stripe refund'));

  v_gst := case
    when coalesce(v_invoice.total, 0) > 0
      then round(v_refund_amount * coalesce(v_invoice.gst, 0) / v_invoice.total, 2)
    else 0
  end;
  v_ex_gst := round(v_refund_amount - v_gst, 2);

  if v_cn_id is null then
    insert into public.customer_credit_notes(
      business_id,
      original_invoice_id,
      customer_id,
      credit_note_number,
      credit_date,
      reason,
      credit_type,
      currency,
      ex_gst,
      gst_amount,
      total_amount,
      lifecycle_state,
      issued_at,
      idempotency_key
    ) values (
      v_tx.business_id,
      v_invoice.id,
      v_invoice.customer_id,
      'CN-STRIPE-' || v_suffix,
      coalesce(p_refund_date, current_date),
      'Stripe refund for ' || coalesce(v_invoice.invoice_number, 'invoice'),
      case when v_refund_amount >= round(coalesce(v_invoice.total, 0), 2) then 'full' else 'partial' end,
      upper(coalesce(v_tx.currency, 'NZD')),
      v_ex_gst,
      v_gst,
      v_refund_amount,
      'issued',
      now(),
      v_tx.id
    )
    returning id into v_cn_id;

    insert into public.customer_credit_note_lines(
      business_id,
      credit_note_id,
      description,
      quantity,
      unit_amount,
      ex_gst,
      gst_amount,
      total_amount,
      tax_rate,
      tax_code,
      source_detail
    ) values (
      v_tx.business_id,
      v_cn_id,
      'Stripe refund',
      1,
      v_ex_gst,
      v_ex_gst,
      v_gst,
      v_refund_amount,
      case when v_gst > 0 and v_ex_gst > 0 then round(v_gst / v_ex_gst * 100, 4) else 0 end,
      case when v_gst > 0 then 'GST' else 'NO_GST' end,
      jsonb_build_object('invoice_payment_transaction_id', v_tx.id, 'reference', v_ref)
    );
  end if;

  if v_refund_id is null then
    insert into public.customer_refunds(
      business_id,
      customer_id,
      refund_number,
      refund_date,
      amount,
      currency,
      method,
      reference,
      notes,
      lifecycle_state,
      idempotency_key,
      recorded_at
    ) values (
      v_tx.business_id,
      v_invoice.customer_id,
      'RF-STRIPE-' || v_suffix,
      coalesce(p_refund_date, current_date),
      v_refund_amount,
      upper(coalesce(v_tx.currency, 'NZD')),
      'card',
      v_ref,
      'Recorded automatically from a Stripe refund event.',
      'recorded',
      v_tx.id,
      now()
    )
    returning id into v_refund_id;
  end if;

  v_sales := (
    select id from public.accounting_accounts
    where business_id = v_tx.business_id
      and not coalesce(archived, false)
      and (system_key = 'sales' or system_account_key = 'sales' or account_code in ('200','4000'))
    order by case when system_key = 'sales' or system_account_key = 'sales' then 0 else 1 end, account_code
    limit 1
  );
  v_gst_output := (
    select id from public.accounting_accounts
    where business_id = v_tx.business_id
      and not coalesce(archived, false)
      and (system_key in ('gst_collected','gst_payable') or system_account_key in ('gst_collected','gst_payable') or account_code in ('260','2100'))
    order by case when system_key = 'gst_collected' or system_account_key = 'gst_collected' then 0 else 1 end, account_code
    limit 1
  );
  v_ar := (
    select id from public.accounting_accounts
    where business_id = v_tx.business_id
      and not coalesce(archived, false)
      and (system_key = 'accounts_receivable' or system_account_key = 'accounts_receivable' or account_code in ('120','1100'))
    order by case when system_key = 'accounts_receivable' or system_account_key = 'accounts_receivable' then 0 else 1 end, account_code
    limit 1
  );
  v_clearing := coalesce(
    public.v6170b_account(v_tx.business_id, 'payment_clearing'),
    (select id from public.accounting_accounts where business_id = v_tx.business_id and system_key = 'payment_clearing' and not coalesce(archived,false) order by account_code limit 1)
  );

  if v_sales is null or v_ar is null or v_clearing is null or (v_gst > 0 and v_gst_output is null) then
    raise exception 'Refund accounting accounts are not available';
  end if;

  if v_cn_journal is null then
    v_cn_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_sales, 'description', 'Reverse sales for Stripe refund', 'debit', v_ex_gst, 'credit', 0, 'tax_code', case when v_gst > 0 then 'GST' else 'NO_GST' end, 'tax_rate', case when v_ex_gst > 0 then round(v_gst / v_ex_gst * 100, 4) else 0 end, 'tax_amount', v_gst, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id),
      jsonb_build_object('account_id', v_ar, 'description', 'Credit customer receivable', 'debit', 0, 'credit', v_refund_amount, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id)
    );
    if v_gst > 0 then
      v_cn_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_sales, 'description', 'Reverse sales for Stripe refund', 'debit', v_ex_gst, 'credit', 0, 'tax_code', 'GST', 'tax_rate', case when v_ex_gst > 0 then round(v_gst / v_ex_gst * 100, 4) else 0 end, 'tax_amount', v_gst, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id),
        jsonb_build_object('account_id', v_gst_output, 'description', 'Reverse GST for Stripe refund', 'debit', v_gst, 'credit', 0, 'tax_code', 'GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id),
        jsonb_build_object('account_id', v_ar, 'description', 'Credit customer receivable', 'debit', 0, 'credit', v_refund_amount, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id)
      );
    end if;

    v_cn_journal := public.v6192_create_posted_journal(
      v_tx.business_id,
      coalesce(p_refund_date, current_date),
      'credit_note',
      'stripe_refund_credit_note',
      v_tx.id,
      'CN-STRIPE-' || v_suffix,
      'Stripe refund credit note for ' || coalesce(v_invoice.invoice_number, 'invoice'),
      v_cn_lines
    );
  end if;

  if v_refund_journal is null then
    v_refund_journal := public.v6192_create_posted_journal(
      v_tx.business_id,
      coalesce(p_refund_date, current_date),
      'customer_refund',
      'stripe_refund',
      v_tx.id,
      'RF-STRIPE-' || v_suffix,
      'Stripe refund paid from clearing for ' || coalesce(v_invoice.invoice_number, 'invoice'),
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar, 'description', 'Apply customer refund', 'debit', v_refund_amount, 'credit', 0, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id),
        jsonb_build_object('account_id', v_clearing, 'description', 'Stripe refund deducted from clearing', 'debit', 0, 'credit', v_refund_amount, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id)
      )
    );
  end if;

  update public.invoice_payment_transactions
  set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'stripe_refund_accounting_recorded_at', now(),
        'stripe_refund_credit_note_id', v_cn_id,
        'stripe_refund_id', v_refund_id,
        'stripe_refund_credit_note_journal_id', v_cn_journal,
        'stripe_refund_journal_id', v_refund_journal
      ),
      updated_at = now()
  where id = v_tx.id;

  return jsonb_build_object(
    'ok', true,
    'credit_note_id', v_cn_id,
    'refund_id', v_refund_id,
    'credit_note_journal_id', v_cn_journal,
    'refund_journal_id', v_refund_journal
  );
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61108_record_stripe_refund_accounting"(p_transaction_id uuid, p_refund_amount numeric, p_refund_date date, p_reference text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61108_record_stripe_refund_accounting"(p_transaction_id uuid, p_refund_amount numeric, p_refund_date date, p_reference text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61108_undo_stripe_payout_bank_transaction(p_bank_transaction_id uuid, p_reason text DEFAULT 'Undo Stripe payout bank reconciliation'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_alloc record;
  v_reversal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select *
  into v_alloc
  from public.bank_reconciliation_allocations
  where business_id = v_bid
    and bank_transaction_id = p_bank_transaction_id
    and allocation_type = 'stripe_payout'
    and accounting_journal_id is not null
  order by created_at desc
  limit 1;

  if v_alloc.bank_transaction_id is null then
    raise exception 'Stripe payout reconciliation was not found for this bank transaction';
  end if;

  if to_regprocedure('public.v6170a_reverse_journal(uuid,text)') is null then
    raise exception 'Journal reversal function is not available; Stripe payout reconciliation was not undone';
  end if;

  execute 'select public.v6170a_reverse_journal($1,$2)'
    into v_reversal
    using v_alloc.accounting_journal_id, coalesce(nullif(btrim(p_reason),''),'Undo Stripe payout bank reconciliation');

  delete from public.bank_reconciliation_allocations
  where business_id = v_bid
    and bank_transaction_id = p_bank_transaction_id
    and allocation_type = 'stripe_payout';

  update public.bank_transactions
  set status = 'unreconciled',
      reconciliation_type = null,
      reconciled_at = null,
      reconciled_by = null,
      updated_at = now(),
      updated_by = v_uid
  where id = p_bank_transaction_id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid,
    p_bank_transaction_id,
    'stripe_payout_undo',
    jsonb_build_object('journal_id',v_alloc.accounting_journal_id,'reversal_journal_id',v_reversal,'reason',p_reason),
    v_uid
  );

  return jsonb_build_object('ok',true,'reversal_journal_id',v_reversal);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61108_undo_stripe_payout_bank_transaction"(p_bank_transaction_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61108_undo_stripe_payout_bank_transaction"(p_bank_transaction_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61108_undo_stripe_payout_bank_transaction"(p_bank_transaction_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61109_bank_accounting_account(p_business_id uuid, p_bank_transaction_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_bank_account public.bank_accounts%rowtype;
  v_account uuid;
  v_code text;
begin
  if auth.uid() is null or not coalesce(public.v6147_can_write_area(p_business_id, 'bank'), false) then
    raise exception 'Bank reconciliation write access denied' using errcode = '42501';
  end if;

  if p_business_id is null or p_bank_transaction_id is null then
    return null;
  end if;

  select ba.* into v_bank_account
  from public.bank_transactions bt
  join public.bank_accounts ba
    on ba.id = bt.bank_account_id
   and ba.business_id = bt.business_id
  where bt.id = p_bank_transaction_id
    and bt.business_id = p_business_id;

  if v_bank_account.id is null then
    return null;
  end if;

  if v_bank_account.accounting_account_id is not null then
    select a.id into v_account
    from public.accounting_accounts a
    where a.id = v_bank_account.accounting_account_id
      and a.business_id = p_business_id
      and not coalesce(a.archived, false);
    if v_account is not null then
      return v_account;
    end if;
  end if;

  select a.id into v_account
  from public.accounting_accounts a
  where a.business_id = p_business_id
    and not coalesce(a.archived, false)
    and a.account_type = 'asset'
    and a.account_subtype = 'bank'
    and lower(a.account_name) = lower(v_bank_account.name)
  limit 1;

  if v_account is null then
    select gs::text into v_code
    from generate_series(1000, 1099) gs
    where not exists (
      select 1 from public.accounting_accounts a
      where a.business_id = p_business_id
        and a.account_code = gs::text
    )
    order by gs
    limit 1;

    if v_code is null then
      raise exception 'No free bank ledger account code is available';
    end if;

    insert into public.accounting_accounts(
      business_id, account_code, account_name, account_type, account_subtype,
      normal_balance, tax_default, allow_manual_posting, report_section,
      is_system, is_control, xero_account_code, xero_account_type, xero_tax_type,
      description, created_by, updated_by
    ) values (
      p_business_id, v_code, v_bank_account.name, 'asset', 'bank',
      'debit', 'NO_GST', false, 'asset',
      true, true, v_code, 'BANK', 'NONE',
      'Bank ledger linked to imported bank account ' || coalesce(v_bank_account.account_number, v_bank_account.name),
      v_uid, v_uid
    )
    returning id into v_account;
  end if;

  update public.bank_accounts
  set accounting_account_id = v_account,
      updated_at = now(),
      updated_by = v_uid
  where id = v_bank_account.id
    and business_id = p_business_id
    and accounting_account_id is distinct from v_account;

  return v_account;
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61109_bank_accounting_account"(p_business_id uuid, p_bank_transaction_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61109_bank_accounting_account"(p_business_id uuid, p_bank_transaction_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61109_bank_accounting_account"(p_business_id uuid, p_bank_transaction_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61109_reconcile_payroll_bank_transaction(p_bank_transaction_id uuid, p_pay_run_id uuid, p_pay_run_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_amount numeric;
  v_expected numeric;
  v_run public.payroll_pay_runs%rowtype;
  v_employee public.payroll_pay_run_employees%rowtype;
  v_bank uuid;
  v_payable uuid;
  v_journal uuid;
  v_legacy_bank_posted boolean := false;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions where id = p_bank_transaction_id and business_id = v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;
  if coalesce(v_tx.amount,0) >= 0 then raise exception 'Payroll payments must be matched to a money-out bank transaction'; end if;
  v_amount := round(abs(coalesce(v_tx.amount,0)),2);

  select * into v_run from public.payroll_pay_runs where id = p_pay_run_id and business_id = v_bid;
  if v_run.id is null then raise exception 'Pay run not found in active business'; end if;
  if v_run.status <> 'finalised' then raise exception 'Only finalised pay runs can be matched to bank payments'; end if;

  if p_pay_run_employee_id is not null then
    select * into v_employee
    from public.payroll_pay_run_employees
    where id = p_pay_run_employee_id
      and business_id = v_bid
      and pay_run_id = v_run.id;
    if v_employee.id is null then raise exception 'Pay run employee was not found in this pay run'; end if;
    v_expected := round(coalesce(v_employee.net_pay,0),2);
  else
    v_expected := round(coalesce(v_run.net_pay,0),2);
  end if;

  if v_expected <= 0 or v_amount <> v_expected then
    raise exception 'Bank amount % does not match payroll net amount %', v_amount, v_expected;
  end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and v_tx.transaction_date between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this bank transaction is locked';
  end if;

  v_bank := public.v61109_bank_accounting_account(v_bid, v_tx.id);
  select id into v_payable from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_net_payable' or system_key = 'payroll_net_payable' or account_code = '266') order by account_code limit 1;
  if v_bank is null or v_payable is null then raise exception 'Bank or payroll payable account is not available'; end if;

  select exists(
    select 1
    from public.accounting_journals j
    join public.accounting_journal_lines l
      on l.journal_id = j.id
     and l.business_id = j.business_id
    join public.accounting_accounts a
      on a.id = l.account_id
     and a.business_id = l.business_id
    where j.business_id = v_bid
      and j.source_type = 'payroll'
      and j.source_id = v_run.id
      and j.status in ('posted','reversed')
      and l.credit > 0
      and (a.account_subtype = 'bank' or a.system_account_key = 'bank' or a.system_key in ('bank','bank_main') or a.account_code in ('090','1000'))
  ) into v_legacy_bank_posted;

  if not v_legacy_bank_posted then
    v_journal := public.v6192_create_posted_journal(
      v_bid,
      v_tx.transaction_date,
      'bank',
      'payroll_bank_payment',
      v_tx.id,
      coalesce(nullif(v_tx.reference,''), v_run.pay_run_number),
      'Payroll bank payment for ' || coalesce(v_run.pay_run_number, 'pay run'),
      jsonb_build_array(
        jsonb_build_object('account_id',v_payable,'description','Clear net payroll payable','debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
        jsonb_build_object('account_id',v_bank,'description','Payroll payment from bank','debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
      )
    );
  end if;

  insert into public.bank_reconciliation_allocations(
    business_id, bank_transaction_id, allocation_type, amount, pay_run_id,
    pay_run_employee_id, accounting_journal_id, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_pay_run', v_amount, v_run.id,
    p_pay_run_employee_id, v_journal, v_uid
  );

  update public.bank_transactions
  set status = 'reconciled',
      reconciliation_type = 'payroll_pay_run',
      reconciled_at = now(),
      reconciled_by = v_uid,
      updated_at = now(),
      updated_by = v_uid
  where id = v_tx.id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_bank_reconciled',
    jsonb_build_object('pay_run_id',v_run.id,'pay_run_employee_id',p_pay_run_employee_id,'journal_id',v_journal,'legacy_bank_posted',v_legacy_bank_posted),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'legacy_bank_posted',v_legacy_bank_posted,'amount',v_amount);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61109_reconcile_payroll_bank_transaction"(p_bank_transaction_id uuid, p_pay_run_id uuid, p_pay_run_employee_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61109_reconcile_payroll_bank_transaction"(p_bank_transaction_id uuid, p_pay_run_id uuid, p_pay_run_employee_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61109_reconcile_payroll_bank_transaction"(p_bank_transaction_id uuid, p_pay_run_id uuid, p_pay_run_employee_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61109_reconcile_payroll_ird_bank_transaction(p_bank_transaction_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_amount numeric;
  v_bank uuid;
  v_liability uuid;
  v_journal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions where id = p_bank_transaction_id and business_id = v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;
  if coalesce(v_tx.amount,0) >= 0 then raise exception 'IRD / PAYE payments must be matched to a money-out bank transaction'; end if;
  v_amount := round(abs(coalesce(v_tx.amount,0)),2);
  if v_amount <= 0 then raise exception 'Bank transaction amount is invalid'; end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and v_tx.transaction_date between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this bank transaction is locked';
  end if;

  v_bank := public.v61109_bank_accounting_account(v_bid, v_tx.id);
  select id into v_liability from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_liability' or system_key = 'payroll_liability' or account_code in ('265','267')) order by case when account_code = '267' then 0 else 1 end, account_code limit 1;
  if v_bank is null or v_liability is null then raise exception 'Bank or payroll liability account is not available'; end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    v_tx.transaction_date,
    'bank',
    'payroll_ird_payment',
    v_tx.id,
    coalesce(nullif(v_tx.reference,''),'IRD / PAYE payment'),
    'IRD / PAYE payment from bank',
    jsonb_build_array(
      jsonb_build_object('account_id',v_liability,'description','Clear payroll liability payment','debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_bank,'description','IRD / PAYE payment from bank','debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    )
  );

  insert into public.bank_reconciliation_allocations(
    business_id, bank_transaction_id, allocation_type, amount,
    accounting_journal_id, note, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_ird', v_amount,
    v_journal, nullif(btrim(coalesce(p_note,'')),''), v_uid
  );

  update public.bank_transactions
  set status = 'reconciled',
      reconciliation_type = 'payroll_ird',
      reconciled_at = now(),
      reconciled_by = v_uid,
      updated_at = now(),
      updated_by = v_uid
  where id = v_tx.id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_ird_reconciled',
    jsonb_build_object('journal_id',v_journal,'amount',v_amount,'note',p_note),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'amount',v_amount);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61109_reconcile_payroll_ird_bank_transaction"(p_bank_transaction_id uuid, p_note text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61109_reconcile_payroll_ird_bank_transaction"(p_bank_transaction_id uuid, p_note text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61109_reconcile_payroll_ird_bank_transaction"(p_bank_transaction_id uuid, p_note text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61109_undo_payroll_bank_transaction(p_bank_transaction_id uuid, p_reason text DEFAULT 'Undo payroll bank reconciliation'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_alloc record;
  v_reversal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select *
  into v_alloc
  from public.bank_reconciliation_allocations
  where business_id = v_bid
    and bank_transaction_id = p_bank_transaction_id
    and allocation_type in ('payroll_pay_run','payroll_ird')
  order by created_at desc
  limit 1;

  if v_alloc.bank_transaction_id is null then
    raise exception 'Payroll bank reconciliation was not found';
  end if;

  if v_alloc.accounting_journal_id is not null then
    execute 'select public.v6170a_reverse_journal($1,$2)'
      into v_reversal
      using v_alloc.accounting_journal_id, coalesce(nullif(btrim(p_reason),''),'Undo payroll bank reconciliation');
  end if;

  delete from public.bank_reconciliation_allocations
  where business_id = v_bid
    and bank_transaction_id = p_bank_transaction_id
    and allocation_type in ('payroll_pay_run','payroll_ird');

  update public.bank_transactions
  set status = 'unreconciled',
      reconciliation_type = null,
      reconciled_at = null,
      reconciled_by = null,
      updated_at = now(),
      updated_by = v_uid
  where id = p_bank_transaction_id
    and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid, p_bank_transaction_id, 'payroll_bank_undo',
    jsonb_build_object('journal_id',v_alloc.accounting_journal_id,'reversal_journal_id',v_reversal,'reason',p_reason),
    v_uid
  );

  return jsonb_build_object('ok',true,'reversal_journal_id',v_reversal);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61109_undo_payroll_bank_transaction"(p_bank_transaction_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61109_undo_payroll_bank_transaction"(p_bank_transaction_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61109_undo_payroll_bank_transaction"(p_bank_transaction_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61110_accounting_integrity_review(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(area text, issue_key text, severity text, source_id uuid, source_reference text, expected_amount numeric, actual_amount numeric, detail text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;

  return query
  select
    'holiday_pay'::text,
    'holiday_liability_needs_review'::text,
    'warning'::text,
    r.employee_id,
    r.employee_name,
    r.target_liability,
    r.posted_liability,
    r.evidence
  from public.v61110_holiday_pay_liability_review(p_as_of) r
  where r.valuation_status = 'needs_review';

  return query
  select
    'holiday_pay'::text,
    'holiday_liability_adjustment_required'::text,
    case when abs(sum(r.adjustment_required)) > 0.005 then 'info' else 'ok' end,
    null::uuid,
    'HOLIDAY-' || to_char(p_as_of, 'YYYYMMDD'),
    round(sum(r.target_liability), 2),
    round(max(r.posted_liability), 2),
    'Confirmed holiday-pay liability differs from the posted liability by ' || round(sum(r.adjustment_required), 2)::text || '.'
  from public.v61110_holiday_pay_liability_review(p_as_of) r
  where r.valuation_status = 'confirmed'
  having count(*) > 0;

  return query
  select
    'payroll'::text,
    'legacy_payroll_posted_directly_to_bank'::text,
    'warning'::text,
    j.source_id,
    coalesce(j.source_reference, j.journal_number),
    null::numeric,
    round(sum(l.credit), 2),
    'Historical payroll journal credits a bank account directly. Leave untouched unless an accountant decides to reclassify it.'
  from public.accounting_journals j
  join public.accounting_journal_lines l on l.journal_id = j.id and l.business_id = j.business_id
  join public.accounting_accounts a on a.id = l.account_id and a.business_id = l.business_id
  where j.business_id = v_bid
    and j.status = 'posted'
    and j.source_type = 'payroll'
    and j.journal_date <= p_as_of
    and l.credit > 0
    and (a.account_subtype = 'bank' or a.system_account_key = 'bank' or a.system_key in ('bank','bank_main') or a.account_code in ('090','1000'))
  group by j.source_id, coalesce(j.source_reference, j.journal_number);

  return query
  select
    'bank_reconciliation'::text,
    'reconciled_allocation_missing_journal'::text,
    case when bra.allocation_type in ('owner_equity','payroll_pay_run','payroll_ird','expense_deposit_refund','stripe_payout') then 'warning' else 'info' end,
    bt.id,
    coalesce(bt.reference, bt.description, bt.bank_transaction_id),
    abs(bt.amount),
    bra.amount,
    'Bank reconciliation allocation ' || bra.allocation_type || ' has no linked accounting journal. Review whether this type is deliberately non-posting or needs correction.'
  from public.bank_reconciliation_allocations bra
  join public.bank_transactions bt on bt.id = bra.bank_transaction_id and bt.business_id = bra.business_id
  where bra.business_id = v_bid
    and bt.status = 'reconciled'
    and bt.transaction_date <= p_as_of
    and bra.allocation_type in ('transfer','owner_equity','payroll_pay_run','payroll_ird','expense_deposit_refund','stripe_payout')
    and bra.accounting_journal_id is null;

  return query
  select
    'asset_disposal'::text,
    'disposed_asset_missing_journal'::text,
    'critical'::text,
    a.id,
    'ASSET-' || left(a.id::text, 8),
    coalesce(a.disposal_proceeds, 0),
    null::numeric,
    'Asset is marked disposed but no disposal journal is linked.'
  from public.se_assets a
  where a.business_id = v_bid
    and a.disposed_on is not null
    and a.disposed_on <= p_as_of
    and a.disposal_journal_id is null;

  return query
  select
    'asset_disposal'::text,
    'asset_disposal_journal_not_balanced'::text,
    'critical'::text,
    j.source_id,
    coalesce(j.source_reference, j.journal_number),
    round(sum(l.debit), 2),
    round(sum(l.credit), 2),
    'Asset-disposal journal is not balanced.'
  from public.accounting_journals j
  join public.accounting_journal_lines l on l.journal_id = j.id and l.business_id = j.business_id
  where j.business_id = v_bid
    and j.source_type = 'asset_disposal'
    and j.status = 'posted'
    and j.journal_date <= p_as_of
  group by j.source_id, coalesce(j.source_reference, j.journal_number)
  having abs(round(sum(l.debit) - sum(l.credit), 2)) > 0.005;

  return query
  select
    'asset_disposal'::text,
    'asset_disposal_case_matrix'::text,
    case when bool_and(m.balanced) then 'ok' else 'critical' end,
    null::uuid,
    'sample-cases',
    sum(m.debit_total),
    sum(m.credit_total),
    'Gain, loss, fully depreciated and partial private-use sample disposal formulas balance: ' || bool_and(m.balanced)::text || '.'
  from public.v61110_asset_disposal_case_matrix() m;
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61110_accounting_integrity_review"(p_as_of date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61110_accounting_integrity_review"(p_as_of date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61110_accounting_integrity_review"(p_as_of date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61110_accounting_test_harness(p_from date DEFAULT (date_trunc('year'::text, (CURRENT_DATE)::timestamp with time zone))::date, p_to date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_review jsonb;
  v_trial_debits numeric := 0;
  v_trial_credits numeric := 0;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;

  select jsonb_build_object(
    'critical', count(*) filter (where severity = 'critical'),
    'warnings', count(*) filter (where severity = 'warning'),
    'info', count(*) filter (where severity = 'info'),
    'ok', count(*) filter (where severity = 'ok'),
    'items', coalesce(jsonb_agg(to_jsonb(r) order by case severity when 'critical' then 0 when 'warning' then 1 when 'info' then 2 else 3 end, area, issue_key) filter (where severity <> 'ok'), '[]'::jsonb)
  )
  into v_review
  from public.v61110_accounting_integrity_review(p_to) r;

  select round(coalesce(sum(debits), 0), 2), round(coalesce(sum(credits), 0), 2)
    into v_trial_debits, v_trial_credits
  from public.v6170b_trial_balance(p_from, p_to);

  return jsonb_build_object(
    'ok', abs(v_trial_debits - v_trial_credits) <= 0.005 and coalesce((v_review->>'critical')::int, 0) = 0,
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'trial_balance', jsonb_build_object('debits', v_trial_debits, 'credits', v_trial_credits, 'balanced', abs(v_trial_debits - v_trial_credits) <= 0.005),
    'review', v_review
  );
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61110_accounting_test_harness"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61110_accounting_test_harness"(p_from date, p_to date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61110_accounting_test_harness"(p_from date, p_to date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61110_asset_disposal_case_matrix()
 RETURNS TABLE(case_name text, proceeds numeric, capitalised numeric, accumulated_depreciation numeric, business_use_percent numeric, debit_total numeric, credit_total numeric, balanced boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with cases(case_name, proceeds, capitalised, accumulated_depreciation, business_use_percent) as (
    values
      ('gain', 1200::numeric, 1000::numeric, 300::numeric, 100::numeric),
      ('loss', 300::numeric, 1000::numeric, 200::numeric, 100::numeric),
      ('fully_depreciated', 200::numeric, 1000::numeric, 1000::numeric, 100::numeric),
      ('partial_private_use', 1000::numeric, 1200::numeric, 400::numeric, 60::numeric)
  ),
  calc as (
    select *,
      round(proceeds * business_use_percent / 100, 2) as business_proceeds,
      round(proceeds * (100 - business_use_percent) / 100, 2) as private_proceeds,
      round(capitalised - least(capitalised, greatest(0, accumulated_depreciation)), 2) as nbv
    from cases
  ),
  lines as (
    select *,
      round(proceeds + least(capitalised, greatest(0, accumulated_depreciation)) + greatest(nbv - business_proceeds, 0), 2) as debit_total,
      round(capitalised + private_proceeds + greatest(business_proceeds - nbv, 0), 2) as credit_total
    from calc
  )
  select case_name, proceeds, capitalised, accumulated_depreciation, business_use_percent, debit_total, credit_total, abs(debit_total - credit_total) <= 0.005
  from lines;
$function$
;

REVOKE ALL ON FUNCTION public."v61110_asset_disposal_case_matrix"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61110_asset_disposal_case_matrix"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61110_asset_disposal_case_matrix"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v61110_holiday_pay_liability_review(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(employee_id uuid, employee_name text, remaining_weeks numeric, weekly_rate numeric, target_liability numeric, posted_liability numeric, adjustment_required numeric, valuation_status text, evidence text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with ctx as (
    select public.current_business_id() as bid, auth.uid() as uid
  ),
  entitlement as (
    select
      p.employee_id,
      round(sum(greatest(0, coalesce(p.remaining_statutory_weeks, 0) + coalesce(p.contractual_extra_weeks, 0) - coalesce(p.advance_weeks, 0))), 4) as remaining_weeks
    from public.payroll_annual_holiday_entitlement_periods p
    join ctx on ctx.bid = p.business_id
    where ctx.uid is not null
      and coalesce(p.status, 'active') not in ('voided','superseded','deleted')
      and coalesce(p.entitlement_date, p.period_end, p.period_start, p_as_of) <= p_as_of
    group by p.employee_id
  ),
  latest_calc as (
    select distinct on (c.employee_id)
      c.employee_id,
      greatest(coalesce(c.owp_amount, 0), coalesce(c.awe_amount, 0), coalesce(c.selected_amount, 0))::numeric as confirmed_weekly_rate,
      c.id as calculation_id,
      c.relevant_from
    from public.payroll_statutory_leave_calculations c
    join ctx on ctx.bid = c.business_id
    where ctx.uid is not null
      and c.statutory_leave_code = 'annual_holiday'
      and c.confirmation_state = 'confirmed'
      and coalesce(c.relevant_from, p_as_of) <= p_as_of
    order by c.employee_id, coalesce(c.relevant_from, c.created_at::date) desc, c.created_at desc
  ),
  posted as (
    select
      j.business_id,
      round(coalesce(sum(l.credit - l.debit), 0), 2) as posted_liability
    from public.accounting_journals j
    join public.accounting_journal_lines l
      on l.journal_id = j.id
     and l.business_id = j.business_id
    join public.accounting_accounts a
      on a.id = l.account_id
     and a.business_id = l.business_id
    join ctx on ctx.bid = j.business_id
    where ctx.uid is not null
      and j.status = 'posted'
      and j.journal_date <= p_as_of
      and j.source_type = 'payroll_leave_liability'
      and (a.system_account_key = 'holiday_pay_liability' or a.system_key = 'holiday_pay_liability' or a.account_code = '268')
    group by j.business_id
  )
  select
    e.id,
    btrim(concat(coalesce(e.preferred_name, e.first_name), ' ', e.last_name)) as employee_name,
    coalesce(ent.remaining_weeks, 0) as remaining_weeks,
    round(coalesce(lc.confirmed_weekly_rate, case when e.pay_type = 'salary' then coalesce(e.annual_salary, 0) / 52 else coalesce(e.hourly_rate, 0) * coalesce(e.standard_weekly_hours, ps.default_weekly_hours, 40) end), 2) as weekly_rate,
    case when lc.confirmed_weekly_rate is not null
      then round(coalesce(ent.remaining_weeks, 0) * lc.confirmed_weekly_rate, 2)
      else 0
    end as target_liability,
    coalesce(posted.posted_liability, 0) as posted_liability,
    case when lc.confirmed_weekly_rate is not null
      then round(coalesce(ent.remaining_weeks, 0) * lc.confirmed_weekly_rate - coalesce(posted.posted_liability, 0), 2)
      else 0
    end as adjustment_required,
    case
      when coalesce(ent.remaining_weeks, 0) <= 0 then 'no_liability'
      when lc.confirmed_weekly_rate is not null then 'confirmed'
      else 'needs_review'
    end as valuation_status,
    case
      when coalesce(ent.remaining_weeks, 0) <= 0 then 'No remaining annual-holiday weeks.'
      when lc.confirmed_weekly_rate is not null then 'Valued from confirmed annual-holiday OWP/AWE calculation ' || lc.calculation_id::text || '.'
      else 'Remaining weeks exist, but no confirmed annual-holiday OWP/AWE calculation exists as of this date.'
    end as evidence
  from ctx
  join public.payroll_employees e
    on e.business_id = ctx.bid
   and coalesce(e.archived, false) = false
   and coalesce(e.employment_status, 'active') <> 'terminated'
  left join public.payroll_settings ps on ps.business_id = e.business_id
  left join entitlement ent on ent.employee_id = e.id
  left join latest_calc lc on lc.employee_id = e.id
  left join posted on posted.business_id = e.business_id
  where ctx.uid is not null
    and coalesce(ent.remaining_weeks, 0) > 0
  order by employee_name;
$function$
;

REVOKE ALL ON FUNCTION public."v61110_holiday_pay_liability_review"(p_as_of date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61110_holiday_pay_liability_review"(p_as_of date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61110_holiday_pay_liability_review"(p_as_of date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61110_post_holiday_pay_liability(p_as_of date DEFAULT CURRENT_DATE, p_reason text DEFAULT 'Holiday pay liability adjustment'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_expense uuid;
  v_liability uuid;
  v_target numeric := 0;
  v_posted numeric := 0;
  v_adjustment numeric := 0;
  v_journal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid, 'payroll') then raise exception 'Payroll write access denied'; end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and p_as_of between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this holiday-pay adjustment is locked';
  end if;

  insert into public.accounting_accounts(
    business_id, account_code, account_name, account_type, account_subtype,
    normal_balance, tax_default, system_account_key, system_key,
    allow_manual_posting, report_section, is_system, is_control,
    xero_account_code, xero_account_type, xero_tax_type, description,
    created_by, updated_by
  ) values
    (v_bid,'268','Holiday Pay Liability','liability','payroll_leave','credit','NO_GST','holiday_pay_liability','holiday_pay_liability',false,'current_liabilities',true,true,'268','CURRLIAB','NONE','Annual-holiday liability recognised from confirmed payroll leave evidence.',v_uid,v_uid),
    (v_bid,'473','Holiday Pay Expense','expense','payroll_leave','debit','NO_GST','holiday_pay_expense','holiday_pay_expense',false,'expense',true,false,'473','EXPENSE','NONE','Holiday-pay liability expense adjustment from confirmed payroll leave evidence.',v_uid,v_uid)
  on conflict do nothing;

  select id into v_expense
  from public.accounting_accounts
  where business_id = v_bid
    and not coalesce(archived, false)
    and (system_account_key = 'holiday_pay_expense' or system_key = 'holiday_pay_expense' or account_code = '473')
  order by account_code
  limit 1;

  select id into v_liability
  from public.accounting_accounts
  where business_id = v_bid
    and not coalesce(archived, false)
    and (system_account_key = 'holiday_pay_liability' or system_key = 'holiday_pay_liability' or account_code = '268')
  order by account_code
  limit 1;

  if v_expense is null or v_liability is null then
    raise exception 'Holiday-pay accounting accounts are not available';
  end if;

  select round(coalesce(sum(target_liability), 0), 2)
    into v_target
  from public.v61110_holiday_pay_liability_review(p_as_of)
  where valuation_status = 'confirmed';

  if exists (
    select 1
    from public.v61110_holiday_pay_liability_review(p_as_of)
    where valuation_status = 'needs_review'
  ) then
    raise exception 'Holiday-pay liability cannot be posted until every employee with remaining weeks has confirmed OWP/AWE evidence';
  end if;

  select round(coalesce(sum(l.credit - l.debit), 0), 2)
    into v_posted
  from public.accounting_journals j
  join public.accounting_journal_lines l
    on l.journal_id = j.id
   and l.business_id = j.business_id
  where j.business_id = v_bid
    and j.status = 'posted'
    and j.source_type = 'payroll_leave_liability'
    and j.journal_date <= p_as_of
    and l.account_id = v_liability;

  v_adjustment := round(v_target - coalesce(v_posted, 0), 2);
  if abs(v_adjustment) <= 0.005 then
    return jsonb_build_object('ok', true, 'posted', false, 'target_liability', v_target, 'existing_liability', v_posted, 'adjustment', 0);
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    p_as_of,
    'payroll',
    'payroll_leave_liability',
    null,
    'HOLIDAY-' || to_char(p_as_of, 'YYYYMMDD'),
    coalesce(nullif(btrim(p_reason), ''), 'Holiday pay liability adjustment'),
    case when v_adjustment > 0 then
      jsonb_build_array(
        jsonb_build_object('account_id', v_expense, 'description', 'Holiday pay liability expense', 'debit', v_adjustment, 'credit', 0, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0),
        jsonb_build_object('account_id', v_liability, 'description', 'Holiday pay liability', 'debit', 0, 'credit', v_adjustment, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', v_liability, 'description', 'Reduce holiday pay liability', 'debit', abs(v_adjustment), 'credit', 0, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0),
        jsonb_build_object('account_id', v_expense, 'description', 'Reduce holiday pay expense', 'debit', 0, 'credit', abs(v_adjustment), 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0)
      )
    end
  );

  return jsonb_build_object('ok', true, 'posted', true, 'journal_id', v_journal, 'target_liability', v_target, 'existing_liability', v_posted, 'adjustment', v_adjustment);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61110_post_holiday_pay_liability"(p_as_of date, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61110_post_holiday_pay_liability"(p_as_of date, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61110_post_holiday_pay_liability"(p_as_of date, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61111_check_edge_rate_limit(p_scope text, p_identifier text, p_limit integer, p_window_seconds integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_scope text := left(nullif(btrim(coalesce(p_scope,'')),''),120); v_identifier text := left(nullif(btrim(coalesce(p_identifier,'')),''),160); v_limit integer := greatest(1,coalesce(p_limit,1)); v_window_seconds integer := greatest(10,coalesce(p_window_seconds,60)); v_now timestamptz := now(); v_start timestamptz; v_count integer;
begin
if v_scope is null or v_identifier is null then raise exception 'Rate limit scope and identifier are required'; end if;
insert into public.edge_function_rate_limits(scope,identifier,window_start,request_count,updated_at) values(v_scope,v_identifier,v_now,1,v_now)
on conflict(scope,identifier) do update set window_start=case when public.edge_function_rate_limits.window_start<=v_now-make_interval(secs=>v_window_seconds) then v_now else public.edge_function_rate_limits.window_start end,request_count=case when public.edge_function_rate_limits.window_start<=v_now-make_interval(secs=>v_window_seconds) then 1 else public.edge_function_rate_limits.request_count+1 end,updated_at=v_now returning window_start,request_count into v_start,v_count;
return jsonb_build_object('allowed',v_count<=v_limit,'count',v_count,'limit',v_limit,'reset_at',v_start+make_interval(secs=>v_window_seconds));
end $function$
;

REVOKE ALL ON FUNCTION public."v61111_check_edge_rate_limit"(p_scope text, p_identifier text, p_limit integer, p_window_seconds integer) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61111_check_edge_rate_limit"(p_scope text, p_identifier text, p_limit integer, p_window_seconds integer) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61117_customer_statement(p_customer_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_bid uuid := public.current_business_id();
 v_customer record;
 v_rows jsonb;
 v_open numeric := 0;
 v_close numeric := 0;
begin
 if v_bid is null or auth.uid() is null then raise exception 'Choose a business and sign in'; end if;
 if p_from is null or p_to is null or p_from > p_to then raise exception 'Invalid statement date range'; end if;
 select * into v_customer from public.customers c where c.business_id=v_bid and c.id=p_customer_id;
 if not found then raise exception 'Customer not found'; end if;
 with raw as (
 select i.invoice_date d,i.invoice_number ref,'Invoice'::text kind,i.total::numeric debit,0::numeric credit, i.id::text tie
 from public.invoices i where i.business_id=v_bid and i.customer_id=p_customer_id and i.invoice_date<=p_to and coalesce(i.lifecycle_state,'issued')<>'voided'
 union all
 select cp.payment_date,coalesce(cp.reference,'Payment'),'Payment',0,cp.amount,cp.id::text
 from public.customer_payments cp join public.invoices i on i.id=cp.invoice_id and i.business_id=cp.business_id
 where cp.business_id=v_bid and i.customer_id=p_customer_id and cp.payment_date<=p_to
 union all
 select cn.credit_date,cn.credit_note_number,'Credit Note',0,cn.total_amount,cn.id::text
 from public.customer_credit_notes cn where cn.business_id=v_bid and cn.customer_id=p_customer_id and cn.credit_date<=p_to and cn.lifecycle_state='issued'
 union all
 select cr.refund_date,coalesce(cr.reference,cr.refund_number,'Refund'),'Refund',cr.amount,0,cr.id::text
 from public.customer_refunds cr where cr.business_id=v_bid and cr.customer_id=p_customer_id and cr.refund_date<=p_to and cr.lifecycle_state='recorded'
 ), ordered as (
 select d,ref,kind,debit,credit,tie,
 sum(debit-credit) over(order by d,case kind when 'Invoice' then 1 when 'Credit Note' then 2 when 'Payment' then 3 else 4 end,ref,tie rows between unbounded preceding and current row) balance
 from raw
 )
 select coalesce(jsonb_agg(jsonb_build_object('date',d,'reference',ref,'description',kind,'debit',debit,'credit',credit,'balance',balance) order by d,case kind when 'Invoice' then 1 when 'Credit Note' then 2 when 'Payment' then 3 else 4 end,ref,tie) filter(where d between p_from and p_to),'[]'::jsonb),
 coalesce(sum(debit-credit) filter(where d<p_from),0),
 coalesce(sum(debit-credit),0)
 into v_rows,v_open,v_close from ordered;
 return jsonb_build_object('customer_id',v_customer.id,'customer_name',v_customer.name,'from',p_from,'to',p_to,'opening_balance',v_open,'closing_balance',v_close,'rows',v_rows);
end $function$
;

REVOKE ALL ON FUNCTION public."v61117_customer_statement"(p_customer_id uuid, p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61117_customer_statement"(p_customer_id uuid, p_from date, p_to date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61117_customer_statement"(p_customer_id uuid, p_from date, p_to date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61117_post_manual_journal(p_journal_date date, p_description text, p_lines jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_debits numeric := 0;
  v_credits numeric := 0;
  v_journal uuid;
  v_account_business uuid;
begin
  if v_uid is null or v_bid is null then
    raise exception 'Choose a business and sign in';
  end if;
  if not public.v6169a_accountant_centre_access(v_bid,true) then
    raise exception 'Manual journals are restricted to authorised accounting users';
  end if;
  if p_journal_date is null or p_description is null or length(btrim(p_description)) < 5 then
    raise exception 'Manual journal needs a date and clear description';
  end if;
  if not public.v6170a_period_is_open(v_bid,p_journal_date) then
    raise exception 'The accounting period is locked';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'Manual journal needs at least two lines';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    select a.business_id into v_account_business
    from public.accounting_accounts a
    where a.id = (v_line->>'account_id')::uuid;

    if v_account_business is distinct from v_bid then
      raise exception 'Manual journal account does not belong to this business';
    end if;

    v_debits := v_debits + greatest(0, coalesce((v_line->>'debit')::numeric,0));
    v_credits := v_credits + greatest(0, coalesce((v_line->>'credit')::numeric,0));
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', (v_line->>'account_id')::uuid,
      'description', nullif(btrim(coalesce(v_line->>'description',p_description)),''),
      'debit', round(greatest(0, coalesce((v_line->>'debit')::numeric,0)),2),
      'credit', round(greatest(0, coalesce((v_line->>'credit')::numeric,0)),2),
      'tax_code', coalesce(nullif(v_line->>'tax_code',''),'NO_GST'),
      'tax_rate', 0,
      'tax_amount', 0
    ));
  end loop;

  if round(v_debits,2) <= 0 or abs(round(v_debits - v_credits,2)) > 0.005 then
    raise exception 'Manual journal must balance before posting';
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    p_journal_date,
    'manual',
    'manual_journal',
    gen_random_uuid(),
    'MJ-' || to_char(now(),'YYYYMMDDHH24MISS'),
    p_description,
    v_lines
  );

  return v_journal;
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61117_post_manual_journal"(p_journal_date date, p_description text, p_lines jsonb) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61117_post_manual_journal"(p_journal_date date, p_description text, p_lines jsonb) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61117_post_manual_journal"(p_journal_date date, p_description text, p_lines jsonb) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61118_live_bank_feeds_enabled(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((
    select true
    from public.business_modules bm
    join public.modules m on m.id = bm.module_id
    where bm.business_id = p_business_id
      and m.slug = 'live_bank_feeds'
      and m.is_active = true
      and bm.status in ('active','trialing')
      and (bm.trial_ends_at is null or bm.trial_ends_at >= now())
    limit 1
  ), false)
  or coalesce((
    select true
    from public.profiles p
    where p.id = auth.uid()
      and coalesce(p.is_super_admin,false) = true
    limit 1
  ), false)
  or coalesce((
    select true
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
    join public.modules m on m.slug = 'live_bank_feeds'
    where s.business_id = p_business_id
      and s.status in ('active','trialing')
      and (s.trial_ends_at is null or s.trial_ends_at >= now())
      and m.is_active = true
      and to_jsonb(p.included_modules) ? 'live_bank_feeds'
    limit 1
  ), false);
$function$
;

REVOKE ALL ON FUNCTION public."v61118_live_bank_feeds_enabled"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61118_live_bank_feeds_enabled"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61118_live_bank_feeds_enabled"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61122_akahu_bank_feeds_enabled(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((
    select true
    from public.business_modules bm
    join public.modules m on m.id = bm.module_id
    where bm.business_id = p_business_id
      and m.slug = 'akahu_bank_feeds'
      and m.is_active = true
      and bm.status in ('active','trialing')
      and (bm.trial_ends_at is null or bm.trial_ends_at >= now())
    limit 1
  ), false)
  or coalesce((
    select true
    from public.profiles p
    where p.id = auth.uid()
      and coalesce(p.is_super_admin,false) = true
    limit 1
  ), false)
  or coalesce((
    select true
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
    join public.modules m on m.slug = 'akahu_bank_feeds'
    where s.business_id = p_business_id
      and s.status in ('active','trialing')
      and (s.trial_ends_at is null or s.trial_ends_at >= now())
      and m.is_active = true
      and to_jsonb(p.included_modules) ? 'akahu_bank_feeds'
    limit 1
  ), false);
$function$
;

REVOKE ALL ON FUNCTION public."v61122_akahu_bank_feeds_enabled"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61122_akahu_bank_feeds_enabled"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61122_akahu_bank_feeds_enabled"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61123_create_ird_filing_batch(p_filing_type text, p_source_table text, p_source_id uuid, p_period_start date, p_period_end date, p_due_date date DEFAULT NULL::date, p_status text DEFAULT 'exported'::text, p_filing_method text DEFAULT 'manual'::text, p_package_payload jsonb DEFAULT '{}'::jsonb, p_validation_summary jsonb DEFAULT '{}'::jsonb, p_file_name text DEFAULT NULL::text, p_file_hash text DEFAULT NULL::text, p_ird_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS ird_filing_batches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_row public.ird_filing_batches;
begin
  if v_uid is null or v_bid is null then
    raise exception 'Business access required';
  end if;
  if not public.v6147_can_write_area(v_bid,'financials') then
    raise exception 'Financials write access denied';
  end if;
  if not public.v61123_ird_connect_enabled(v_bid) then
    raise exception 'IRD Connect is not enabled for this business';
  end if;
  if p_period_start is null or p_period_end is null or p_period_start > p_period_end then
    raise exception 'Choose a valid filing period';
  end if;

  insert into public.ird_filing_batches(
    business_id, filing_type, source_table, source_id, period_start, period_end, due_date,
    status, filing_method, package_payload, validation_summary, file_name, file_hash,
    ird_reference, notes, created_by, updated_by
  )
  values (
    v_bid, p_filing_type, nullif(trim(coalesce(p_source_table,'')),''), p_source_id,
    p_period_start, p_period_end, p_due_date, coalesce(p_status,'exported'),
    coalesce(p_filing_method,'manual'), coalesce(p_package_payload,'{}'::jsonb),
    coalesce(p_validation_summary,'{}'::jsonb), nullif(trim(coalesce(p_file_name,'')),''),
    nullif(trim(coalesce(p_file_hash,'')),''), nullif(trim(coalesce(p_ird_reference,'')),''),
    nullif(trim(coalesce(p_notes,'')),''), v_uid, v_uid
  )
  returning * into v_row;

  insert into public.ird_filing_events(business_id, batch_id, event_type, status, details, created_by)
  values (
    v_bid,
    v_row.id,
    case v_row.status
      when 'filed_in_myir' then 'filed_in_myir'
      when 'reviewed' then 'reviewed'
      when 'cancelled' then 'cancelled'
      else 'exported'
    end,
    v_row.status,
    jsonb_build_object(
      'filing_type', v_row.filing_type,
      'period_start', v_row.period_start,
      'period_end', v_row.period_end,
      'source_table', v_row.source_table,
      'source_id', v_row.source_id,
      'file_name', v_row.file_name,
      'ird_reference', v_row.ird_reference
    ),
    v_uid
  );

  return v_row;
end $function$
;

REVOKE ALL ON FUNCTION public."v61123_create_ird_filing_batch"(p_filing_type text, p_source_table text, p_source_id uuid, p_period_start date, p_period_end date, p_due_date date, p_status text, p_filing_method text, p_package_payload jsonb, p_validation_summary jsonb, p_file_name text, p_file_hash text, p_ird_reference text, p_notes text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61123_create_ird_filing_batch"(p_filing_type text, p_source_table text, p_source_id uuid, p_period_start date, p_period_end date, p_due_date date, p_status text, p_filing_method text, p_package_payload jsonb, p_validation_summary jsonb, p_file_name text, p_file_hash text, p_ird_reference text, p_notes text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61123_create_ird_filing_batch"(p_filing_type text, p_source_table text, p_source_id uuid, p_period_start date, p_period_end date, p_due_date date, p_status text, p_filing_method text, p_package_payload jsonb, p_validation_summary jsonb, p_file_name text, p_file_hash text, p_ird_reference text, p_notes text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61123_ird_connect_enabled(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((
    select true
    from public.business_modules bm
    join public.modules m on m.id = bm.module_id
    where bm.business_id = p_business_id
      and m.slug = 'ird_connect'
      and m.is_active = true
      and bm.status in ('active','trialing')
      and (bm.trial_ends_at is null or bm.trial_ends_at >= now())
    limit 1
  ), false)
  or coalesce((
    select true
    from public.profiles p
    where p.id = auth.uid()
      and coalesce(p.is_super_admin,false) = true
    limit 1
  ), false)
  or coalesce((
    select true
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
    join public.modules m on m.slug = 'ird_connect'
    where s.business_id = p_business_id
      and s.status in ('active','trialing')
      and (s.trial_ends_at is null or s.trial_ends_at >= now())
      and m.is_active = true
      and to_jsonb(p.included_modules) ? 'ird_connect'
    limit 1
  ), false);
$function$
;

REVOKE ALL ON FUNCTION public."v61123_ird_connect_enabled"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61123_ird_connect_enabled"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61123_ird_connect_enabled"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61125_cleanup_email_activity(p_keep_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_keep_days integer := greatest(coalesce(p_keep_days, 90), 30);
  v_cutoff timestamptz := now() - make_interval(days => greatest(coalesce(p_keep_days, 90), 30));
  v_email_deleted integer := 0;
  v_reminder_deleted integer := 0;
begin
  delete from public.email_delivery_events
  where sent_at < v_cutoff;
  get diagnostics v_email_deleted = row_count;

  if to_regclass('public.invoice_reminder_history') is not null then
    delete from public.invoice_reminder_history
    where sent_at < v_cutoff;
    get diagnostics v_reminder_deleted = row_count;
  end if;

  return jsonb_build_object(
    'keep_days', v_keep_days,
    'cutoff', v_cutoff,
    'email_delivery_events_deleted', v_email_deleted,
    'invoice_reminder_history_deleted', v_reminder_deleted
  );
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61125_cleanup_email_activity"(p_keep_days integer) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61125_cleanup_email_activity"(p_keep_days integer) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61126_claim_invoice_auto_reminders(p_today date DEFAULT ((now() AT TIME ZONE 'Pacific/Auckland'::text))::date, p_limit integer DEFAULT 50)
 RETURNS TABLE(run_id uuid, business_id uuid, invoice_id uuid, invoice_number text, customer_name text, customer_email text, total numeric, balance_due numeric, due_date date, currency text, reminder_key text, reminder_days integer, scheduled_for date, subject_template text, body_template text, sender_template text, business_settings jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with candidates as (
    select
      i.id as invoice_id,
      i.business_id,
      i.invoice_number,
      i.customer_name,
      i.customer_email,
      i.total,
      coalesce(i.balance_due, i.total) as balance_due,
      i.due_date,
      coalesce(b.settings, '{}'::jsonb) as business_settings,
      coalesce(b.settings->>'currency', i.company_snapshot->>'currency', 'NZD') as currency,
      coalesce(c.auto_reminder_policy, 'default') as customer_policy,
      coalesce(i.auto_reminder_policy, 'default') as invoice_policy,
      coalesce(i.auto_reminders_paused_until, date '1900-01-01') as paused_until
    from public.invoices i
    join public.businesses b on b.id = i.business_id
    left join public.customers c on c.id = i.customer_id
    where lower(coalesce(i.lifecycle_state, '')) = 'issued'
      and i.due_date is not null
      and coalesce(i.balance_due, i.total, 0) > 0.005
      and coalesce(i.customer_email, '') ~* '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
      and coalesce(i.auto_reminders_paused_until, date '1900-01-01') < p_today
      and exists (
        select 1
        from public.email_delivery_events ede
        where ede.source_table = 'invoices'
          and ede.source_id = i.id
          and ede.message_type = 'invoice'
      )
  ),
  enabled_candidates as (
    select *
    from candidates c
    where case c.invoice_policy
      when 'off' then false
      when 'on' then true
      else case c.customer_policy
        when 'off' then false
        when 'on' then true
        else coalesce((c.business_settings->'autoPaymentReminders'->>'enabled')::boolean, false)
      end
    end
  ),
  schedule_rows as (
    select
      ec.*,
      coalesce(s.item->>'key', 'day_' || coalesce(s.item->>'days','0')) as reminder_key,
      coalesce((s.item->>'days')::integer, 0) as reminder_days,
      coalesce(s.item->>'label', 'Payment reminder') as reminder_label,
      coalesce((s.item->>'enabled')::boolean, true) as reminder_enabled
    from enabled_candidates ec
    cross join lateral jsonb_array_elements(
      coalesce(
        ec.business_settings->'autoPaymentReminders'->'schedule',
        '[{"key":"before_due","days":-3,"label":"3 days before due","enabled":true},{"key":"due_today","days":0,"label":"Due today","enabled":true},{"key":"overdue_7","days":7,"label":"7 days overdue","enabled":true},{"key":"overdue_14","days":14,"label":"14 days overdue","enabled":true}]'::jsonb
      )
    ) as s(item)
  ),
  due_rows as (
    select
      sr.*,
      (sr.due_date + sr.reminder_days) as scheduled_for
    from schedule_rows sr
    where sr.reminder_enabled
      and (sr.due_date + sr.reminder_days) <= p_today
      and (sr.due_date + sr.reminder_days) >= (p_today - 3)
      and not exists (
        select 1
        from public.invoice_reminder_history h
        where h.invoice_id = sr.invoice_id
          and (h.sent_at at time zone 'Pacific/Auckland')::date between (sr.due_date + sr.reminder_days) and p_today
      )
    order by (sr.due_date + sr.reminder_days), sr.invoice_number
    limit greatest(1, least(coalesce(p_limit, 50), 100))
  ),
  inserted as (
    insert into public.invoice_auto_reminder_runs (
      business_id,
      invoice_id,
      reminder_key,
      reminder_days,
      scheduled_for,
      status,
      recipient,
      metadata
    )
    select
      d.business_id,
      d.invoice_id,
      d.reminder_key,
      d.reminder_days,
      d.scheduled_for,
      'claimed',
      d.customer_email,
      jsonb_build_object('label', d.reminder_label, 'invoice_number', d.invoice_number)
    from due_rows d
    on conflict (invoice_id, reminder_key, scheduled_for) do nothing
    returning *
  )
  select
    r.id as run_id,
    d.business_id,
    d.invoice_id,
    d.invoice_number,
    d.customer_name,
    d.customer_email,
    d.total,
    d.balance_due,
    d.due_date,
    d.currency,
    d.reminder_key,
    d.reminder_days,
    d.scheduled_for,
    coalesce(d.business_settings->'reminderEmailSettings'->>'subject', 'Payment reminder - Invoice {invoiceNumber}') as subject_template,
    coalesce(d.business_settings->'reminderEmailSettings'->>'body', 'Hi {customerName},\n\nThis is a friendly reminder about invoice {invoiceNumber}.\n\n{statusLine}\nAmount outstanding: {amountOutstanding}\nDue date: {dueDate}\n\nIf you have already made payment, please disregard this reminder.\n\nKind regards,\n{tradingName}\n{phone}\n{email}') as body_template,
    coalesce(d.business_settings->'reminderEmailSettings'->>'senderName', '{tradingName} Accounts') as sender_template,
    d.business_settings
  from inserted r
  join due_rows d
    on d.invoice_id = r.invoice_id
   and d.reminder_key = r.reminder_key
   and d.scheduled_for = r.scheduled_for;
$function$
;

REVOKE ALL ON FUNCTION public."v61126_claim_invoice_auto_reminders"(p_today date, p_limit integer) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61126_claim_invoice_auto_reminders"(p_today date, p_limit integer) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61126_finish_invoice_auto_reminder(p_run_id uuid, p_status text, p_subject text DEFAULT NULL::text, p_provider_message_id text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if p_status not in ('sent','failed','skipped') then
    raise exception 'Invalid reminder status: %', p_status;
  end if;

  update public.invoice_auto_reminder_runs
     set status = p_status,
         subject = coalesce(p_subject, subject),
         provider_message_id = coalesce(p_provider_message_id, provider_message_id),
         error_message = p_error_message,
         processed_at = now()
   where id = p_run_id;
end;
$function$
;

REVOKE ALL ON FUNCTION public."v61126_finish_invoice_auto_reminder"(p_run_id uuid, p_status text, p_subject text, p_provider_message_id text, p_error_message text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61126_finish_invoice_auto_reminder"(p_run_id uuid, p_status text, p_subject text, p_provider_message_id text, p_error_message text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61128_undo_expense_bank_match(p_bank_transaction_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid(); v_tx public.bank_transactions%rowtype;
 v_alloc public.bank_reconciliation_allocations%rowtype; v_pay public.expense_payments%rowtype;
 v_existing boolean; v_audit jsonb; v_count integer;
begin
 if v_uid is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'bank'),false) then raise exception 'Bank reconciliation write access denied' using errcode='42501'; end if;
 select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
 if v_tx.id is null or v_tx.status<>'reconciled' or v_tx.reconciliation_type<>'expense' then raise exception 'Reconciled expense transaction not found'; end if;
 select count(*) into v_count from public.bank_reconciliation_allocations where bank_transaction_id=v_tx.id and business_id=v_bid;
 if v_count<>1 then raise exception 'Expected exactly one expense allocation; no changes made'; end if;
 select * into v_alloc from public.bank_reconciliation_allocations where bank_transaction_id=v_tx.id and business_id=v_bid for update;
 if v_alloc.allocation_type<>'expense' or v_alloc.expense_payment_id is null or coalesce(v_alloc.created_expense,false) then raise exception 'Not an ordinary expense payment match'; end if;
 select details into v_audit from public.bank_reconciliation_audit where bank_transaction_id=v_tx.id and business_id=v_bid and action='expense_reconciled_atomic' order by created_at desc limit 1;
 if v_audit is null or v_audit->>'payment_id' is distinct from v_alloc.expense_payment_id::text or v_audit->>'existing_payment' not in ('true','false') then raise exception 'Expense match audit does not identify payment origin; no changes made'; end if;
 v_existing := (v_audit->>'existing_payment')::boolean;
 select * into v_pay from public.expense_payments where id=v_alloc.expense_payment_id and business_id=v_bid and expense_id=v_alloc.expense_id for update;
 if v_pay.id is null then raise exception 'Linked expense payment missing'; end if;
 if exists(select 1 from public.bank_reconciliation_allocations where business_id=v_bid and expense_payment_id=v_pay.id and id<>v_alloc.id) then raise exception 'Payment has other bank allocations; no changes made'; end if;
 delete from public.bank_reconciliation_allocations where id=v_alloc.id and business_id=v_bid;
 if v_existing then
   update public.expense_payments set reconciled=false,reconciled_at=null,reconciled_by=null,bank_transaction_reference=null where id=v_pay.id and business_id=v_bid;
 else
   delete from public.expense_payments where id=v_pay.id and business_id=v_bid;
 end if;
 update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,excluded_reason=null,transfer_bank_account_id=null,updated_at=now(),updated_by=v_uid where id=v_tx.id and business_id=v_bid;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
 values(v_bid,v_tx.id,'expense_match_undo_atomic',jsonb_build_object('expense_id',v_alloc.expense_id,'payment_id',v_pay.id,'existing_payment_preserved',v_existing,'reason',coalesce(p_reason,'')),v_uid);
 return jsonb_build_object('ok',true,'existing_payment_preserved',v_existing);
end $function$
;

REVOKE ALL ON FUNCTION public."v61128_undo_expense_bank_match"(p_bank_transaction_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61128_undo_expense_bank_match"(p_bank_transaction_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61128_undo_expense_bank_match"(p_bank_transaction_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v61142b_save_purchase_order(p_order jsonb, p_lines jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_bid uuid; v_old public.purchase_orders%rowtype; v_item jsonb; v_total numeric:=0; v_qty numeric; v_price numeric; v_count int:=0;
begin
 v_bid:=(p_order->>'business_id')::uuid;
 if v_bid is null or not public.v6147_can_write_area(v_bid,'expenses') then raise exception 'Purchase order write permission denied'; end if;
 if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines)=0 then raise exception 'Purchase order must contain items'; end if;
 if nullif(trim(p_order->>'supplier_name'),'') is null or nullif(p_order->>'supplier_id','') is null then raise exception 'Select a supplier'; end if;
 if not exists(select 1 from public.suppliers where id=(p_order->>'supplier_id')::uuid and business_id=v_bid and not archived) then raise exception 'Supplier does not belong to this business'; end if;
 for v_item in select value from jsonb_array_elements(p_lines) loop
  v_count:=v_count+1; v_qty:=(v_item->>'qty')::numeric;v_price:=(v_item->>'unit_price')::numeric;
  if nullif(trim(v_item->>'description'),'') is null or v_qty is null or v_qty<=0 or v_price is null or v_price<0 then raise exception 'Invalid purchase order line'; end if;
  v_total:=v_total+v_qty*v_price;
 end loop;
 if nullif(p_order->>'id','') is not null then
  v_id:=(p_order->>'id')::uuid;
  select * into v_old from public.purchase_orders where id=v_id and business_id=v_bid for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if p_expected_updated_at is null or v_old.updated_at is distinct from p_expected_updated_at then raise exception 'Purchase order changed by another user. Reopen before saving'; end if;
  update public.purchase_orders set po_number=p_order->>'po_number',supplier_id=(p_order->>'supplier_id')::uuid,supplier_name=p_order->>'supplier_name',order_date=(p_order->>'order_date')::date,notes=p_order->>'notes',total_amount=v_total,subtotal=v_total,updated_by=auth.uid(),updated_at=clock_timestamp() where id=v_id;
  delete from public.purchase_order_lines where purchase_order_id=v_id and business_id=v_bid;
 else
  insert into public.purchase_orders(business_id,po_number,supplier_id,supplier_name,order_date,status,notes,total_amount,subtotal,currency,created_by,updated_by)
  values(v_bid,p_order->>'po_number',(p_order->>'supplier_id')::uuid,p_order->>'supplier_name',(p_order->>'order_date')::date,'draft',p_order->>'notes',v_total,v_total,coalesce(nullif(p_order->>'currency',''),'NZD'),auth.uid(),auth.uid()) returning id into v_id;
 end if;
 insert into public.purchase_order_lines(business_id,purchase_order_id,line_order,description,qty,unit_price,line_total)
 select v_bid,v_id,ordinality::integer,value->>'description',(value->>'qty')::numeric,(value->>'unit_price')::numeric,(value->>'qty')::numeric*(value->>'unit_price')::numeric from jsonb_array_elements(p_lines) with ordinality;
 return v_id;
end $function$
;

REVOKE ALL ON FUNCTION public."v61142b_save_purchase_order"(p_order jsonb, p_lines jsonb, p_expected_updated_at timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v61142b_save_purchase_order"(p_order jsonb, p_lines jsonb, p_expected_updated_at timestamp with time zone) TO "anon";

GRANT EXECUTE ON FUNCTION public."v61142b_save_purchase_order"(p_order jsonb, p_lines jsonb, p_expected_updated_at timestamp with time zone) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v61142b_save_purchase_order"(p_order jsonb, p_lines jsonb, p_expected_updated_at timestamp with time zone) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6135_bank_module_enabled(p_business_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_status text;
  v_trial_ends_at timestamptz;
begin
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;
  if not exists(select 1 from public.modules where slug='bank_reconciliation' and is_active) then return false; end if;

  select bm.status,bm.trial_ends_at into v_status,v_trial_ends_at
  from public.business_modules bm
  join public.modules m on m.id=bm.module_id
  where bm.business_id=p_business_id and m.slug='bank_reconciliation'
  order by bm.created_at desc
  limit 1;

  if v_status in ('suspended','canceled') then return false; end if;
  if v_status='active' then return true; end if;
  if v_status='trialing' and (v_trial_ends_at is null or v_trial_ends_at>=now()) then return true; end if;

  return exists(
    select 1
    from public.subscriptions s
    join public.plans p on p.id=s.plan_id
    where s.business_id=p_business_id
      and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
      and (s.cancel_at is null or s.cancel_at>now())
      and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
      and 'bank_reconciliation'=any(coalesce(p.included_modules,'{}'::text[]))
  );
end
$function$
;

REVOKE ALL ON FUNCTION public."v6135_bank_module_enabled"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6135_bank_module_enabled"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6135_bank_module_enabled"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6170a_reverse_journal(p_journal_id uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare v_bid uuid;v_old public.accounting_journals%rowtype;v_new uuid;v_number text;v_debit numeric(18,2);v_credit numeric(18,2);v_count int;v_period_status text;begin v_bid:=public.current_business_id();if v_bid is null or not public.v6169a_accountant_centre_access(v_bid,true) then raise exception 'Accounting access denied';end if;select * into v_old from public.accounting_journals where id=p_journal_id and business_id=v_bid for update;if v_old.id is null or v_old.status<>'posted' then raise exception 'Only a posted journal can be reversed';end if;if coalesce(btrim(p_reason),'')='' then raise exception 'Reversal reason is required';end if;if not public.v6170a_period_is_open(v_bid,current_date) then raise exception 'The accounting period is locked or unavailable';end if;v_number:='R-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6);insert into public.accounting_journals(business_id,journal_number,journal_date,period_date,source_type,source_id,source_reference,posting_version,migration_origin,description,journal_type,status,reversal_of_journal_id,created_by) values(v_bid,v_number,current_date,current_date,'reversal',null,v_old.source_reference,1,null,'Reversal: '||p_reason,v_old.journal_type,'draft',v_old.id,auth.uid()) returning id into v_new;insert into public.accounting_journal_lines(business_id,journal_id,account_id,description,debit,credit,tax_code,tax_rate,tax_amount,customer_id,supplier_id,job_costing_id,source_line_id) select business_id,v_new,account_id,'Reversal: '||coalesce(description,''),credit,debit,tax_code,tax_rate,-tax_amount,customer_id,supplier_id,job_costing_id,source_line_id from public.accounting_journal_lines where business_id=v_bid and journal_id=v_old.id;select count(*),coalesce(sum(debit),0),coalesce(sum(credit),0) into v_count,v_debit,v_credit from public.accounting_journal_lines where business_id=v_bid and journal_id=v_new;if v_count<2 or v_debit<=0 or v_credit<=0 or round(v_debit,2)<>round(v_credit,2) then raise exception 'Reversal journal failed balance validation';end if;if not public.v6170a_period_is_open(v_bid,current_date) then raise exception 'The accounting period is locked or unavailable';end if;update public.accounting_journals set status='posted',posted_at=now(),posted_by=auth.uid() where id=v_new and business_id=v_bid and status='draft';update public.accounting_journals set status='reversed',reversed_by_journal_id=v_new where id=v_old.id and business_id=v_bid and status='posted';insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(v_bid,'journal',v_new,'posted_reversal',jsonb_build_object('reversal_of',v_old.id,'reason',p_reason),auth.uid());insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(v_bid,'journal',v_old.id,'reversed',jsonb_build_object('reversal_journal_id',v_new,'reason',p_reason),auth.uid());return v_new;end $function$
;

REVOKE ALL ON FUNCTION public."v6170a_reverse_journal"(p_journal_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6170a_reverse_journal"(p_journal_id uuid, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6170a_reverse_journal"(p_journal_id uuid, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6170b_balance_sheet(p_as_of date)
 RETURNS TABLE(assets numeric, liabilities numeric, equity numeric, current_profit numeric, balances boolean, opening_balance_message text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with b as(select public.current_business_id() id),x as(select a.account_type,a.report_section,a.normal_balance,sum(case when a.normal_balance='debit' then l.debit-l.credit else l.credit-l.debit end) bal from public.accounting_journals j join b on b.id=j.business_id join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id join public.accounting_accounts a on a.id=l.account_id and a.business_id=j.business_id where j.status in('posted','reversed') and j.journal_date<=p_as_of group by a.account_type,a.report_section,a.normal_balance),t as(select coalesce(sum(bal)filter(where report_section in('asset','assets','current_assets','fixed_assets') or account_type in('asset','bank','current_asset','fixed_asset','inventory','non_current_asset') or(account_type='tax' and normal_balance='debit')),0) assets,coalesce(sum(bal)filter(where report_section in('liability','liabilities','current_liabilities','non_current_liabilities') or account_type in('liability','current_liability','non_current_liability') or(account_type='tax' and normal_balance='credit')),0) liabilities,coalesce(sum(bal)filter(where report_section='equity' or account_type='equity'),0) equity,coalesce(sum(bal)filter(where account_type in('revenue','other_income','income')),0)-coalesce(sum(bal)filter(where account_type in('expense','other_expense','cost_of_sales')),0) profit from x),o as(select exists(select 1 from public.accounting_journals j join b on b.id=j.business_id where j.journal_type='opening_balance' and j.status in('posted','reversed') and j.journal_date<=p_as_of)ok) select assets,liabilities,equity,profit,round(assets,2)=round(liabilities+equity+profit,2),case when o.ok then 'Opening balance established' else 'Opening balance not yet established' end from t,o
$function$
;

REVOKE ALL ON FUNCTION public."v6170b_balance_sheet"(p_as_of date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6170b_balance_sheet"(p_as_of date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6170b_balance_sheet"(p_as_of date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6170b_payment_account(p_bid uuid, p_source_type text, p_source_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_account uuid; v_funding text;
begin
 if p_source_type='customer_payment' then
  select ba.accounting_account_id into v_account from public.bank_reconciliation_allocations ra join public.bank_transactions bt on bt.id=ra.bank_transaction_id and bt.business_id=ra.business_id join public.bank_accounts ba on ba.id=bt.bank_account_id and ba.business_id=bt.business_id where ra.business_id=p_bid and ra.customer_payment_id=p_source_id limit 1;
 elsif p_source_type='supplier_payment' then
  select ep.funding_source into v_funding from public.expense_payments ep where ep.id=p_source_id and ep.business_id=p_bid;
  if v_funding='owner_personal' then return public.v6170b_account(p_bid,'owner_director_loan'); end if;
  select ba.accounting_account_id into v_account from public.bank_reconciliation_allocations ra join public.bank_transactions bt on bt.id=ra.bank_transaction_id and bt.business_id=ra.business_id join public.bank_accounts ba on ba.id=bt.bank_account_id and ba.business_id=bt.business_id where ra.business_id=p_bid and ra.expense_payment_id=p_source_id limit 1;
 end if;
 return coalesce(v_account,public.v6170b_account(p_bid,'payment_clearing'));
end $function$
;

REVOKE ALL ON FUNCTION public."v6170b_payment_account"(p_bid uuid, p_source_type text, p_source_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6170b_payment_account"(p_bid uuid, p_source_type text, p_source_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6170c1_expense_lifecycle_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare controlled boolean := coalesce(current_setting('finlo.c1_controlled',true),'')='on';
begin
  if tg_op='INSERT' then
    new.lifecycle_version:=1;
    if new.payment_status='draft' then new.lifecycle_state:='draft'; new.recorded_at:=null; new.recorded_by:=null; new.financial_locked_at:=null;
    else new.lifecycle_state:='recorded'; new.recorded_at:=coalesce(new.created_at,now()); new.recorded_by:=auth.uid(); new.financial_locked_at:=now(); end if;
    new.voided_at:=null; new.voided_by:=null; new.void_reason:=null; return new;
  end if;
  if old.lifecycle_version is null then
    if not controlled and (new.lifecycle_version is distinct from old.lifecycle_version or new.lifecycle_state is distinct from old.lifecycle_state or new.financial_locked_at is distinct from old.financial_locked_at) then
      raise exception using errcode='P0001',message='This is a pre-C1 legacy expense. Its lifecycle cannot be manufactured from the browser.';
    end if; return new;
  end if;
  if old.lifecycle_state='draft' and new.payment_status<>'draft' and new.lifecycle_state='draft' then
    new.lifecycle_state:='recorded'; new.recorded_at:=now(); new.recorded_by:=auth.uid(); new.financial_locked_at:=now(); return new;
  end if;
  if not controlled and (new.lifecycle_version is distinct from old.lifecycle_version or new.lifecycle_state is distinct from old.lifecycle_state or new.recorded_at is distinct from old.recorded_at or new.recorded_by is distinct from old.recorded_by or new.financial_locked_at is distinct from old.financial_locked_at or new.voided_at is distinct from old.voided_at or new.voided_by is distinct from old.voided_by or new.void_reason is distinct from old.void_reason) then
    raise exception using errcode='P0001',message='Expense status changes are controlled by Frindly.';
  end if;
  if old.lifecycle_state in ('recorded','voided') and not public.frindly_expense_correction_is_authorized_v1(old,new) and (new.business_id is distinct from old.business_id or new.expense_number is distinct from old.expense_number or new.supplier_id is distinct from old.supplier_id or new.supplier_name is distinct from old.supplier_name or new.supplier_reference is distinct from old.supplier_reference or new.invoice_date is distinct from old.invoice_date or new.due_date is distinct from old.due_date or new.category_id is distinct from old.category_id or new.job_costing_id is distinct from old.job_costing_id or new.amount_type is distinct from old.amount_type or new.gst_treatment is distinct from old.gst_treatment or new.gst_rate is distinct from old.gst_rate or new.gst_override is distinct from old.gst_override or new.ex_gst is distinct from old.ex_gst or new.gst_amount is distinct from old.gst_amount or new.total_amount is distinct from old.total_amount or new.currency is distinct from old.currency or new.is_split is distinct from old.is_split or new.business_use_percent is distinct from old.business_use_percent or new.business_use_amount is distinct from old.business_use_amount or new.private_use_amount is distinct from old.private_use_amount or new.business_ex_gst is distinct from old.business_ex_gst or new.business_gst_amount is distinct from old.business_gst_amount or new.allocation_method is distinct from old.allocation_method or new.allocation_basis is distinct from old.allocation_basis) then
    raise exception using errcode='P0001',message='This expense is already part of your financial records. Use a correction, supplier credit or void instead of changing financial details.';
  end if;
  if old.lifecycle_state in ('recorded','voided') and to_jsonb(new) is distinct from to_jsonb(old) then
    insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(old.business_id,'expense',old.id,'document_metadata_updated',jsonb_build_object('lifecycle_state',old.lifecycle_state),auth.uid());
  end if;
  return new;
end
$function$
;

REVOKE ALL ON FUNCTION public."v6170c1_expense_lifecycle_guard"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6170c1_expense_lifecycle_guard"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v6170e_gst_calculate(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare bid uuid:=current_business_id(); cfg jsonb; basis text; registered boolean; sales_ex numeric:=0; sales_gst numeric:=0; purch_ex numeric:=0; purch_gst numeric:=0; debit_adj numeric:=0; credit_adj numeric:=0; legacy_count int:=0; missing_count int:=0; sales_items jsonb:='[]'; purchase_items jsonb:='[]'; adjustment_items jsonb:='[]'; review jsonb:='[]'; conflict_items jsonb:='[]';
begin
 if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid GST period';end if;
 cfg:=v6170e_gst_settings(p_to); basis:=cfg->>'accounting_basis'; registered:=coalesce((cfg->>'gst_registered')::boolean,false);
 if not registered then return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'sales_ex_gst',0,'gst_collected',0,'purchases_ex_gst',0,'gst_paid',0,'debit_adjustments',0,'credit_adjustments',0,'gst_net',0,'sales_items','[]'::jsonb,'purchase_items','[]'::jsonb,'adjustment_items','[]'::jsonb,'review_items',jsonb_build_array(jsonb_build_object('severity','blocking','code','not_registered','message','Business is not GST registered for this period.')));end if;
 if basis in('invoice','hybrid') then
  select coalesce(sum(greatest(i.total-i.gst,0)),0),coalesce(sum(i.gst),0),coalesce(jsonb_agg(jsonb_build_object('source_type','invoice','source_id',i.id,'date',i.invoice_date,'reference',i.invoice_number,'party',c.name,'party_id',i.customer_id,'ex_gst',greatest(i.total-i.gst,0),'gst',i.gst,'total',i.total) order by i.invoice_date,i.invoice_number),'[]') into sales_ex,sales_gst,sales_items from invoices i left join customers c on c.id=i.customer_id and c.business_id=i.business_id where i.business_id=bid and i.invoice_date between p_from and p_to and coalesce(i.lifecycle_state,'issued') not in('draft','voided');
 else
  select coalesce(sum(greatest(cp.amount-coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),0)),0),coalesce(sum(coalesce(i.gst,0)*(cp.amount/nullif(i.total,0))),0),coalesce(jsonb_agg(jsonb_build_object('source_type','customer_payment','source_id',cp.id,'date',cp.payment_date,'reference',i.invoice_number,'party',c.name,'party_id',i.customer_id,'ex_gst',greatest(cp.amount-coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),0),'gst',coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),'total',cp.amount) order by cp.payment_date),'[]') into sales_ex,sales_gst,sales_items from customer_payments cp join invoices i on i.id=cp.invoice_id and i.business_id=cp.business_id left join customers c on c.id=i.customer_id and c.business_id=i.business_id where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=false and i.total>0;
  select count(*) into legacy_count from customer_payments cp where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=true;
  if legacy_count>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','legacy_estimated_payments','count',legacy_count,'message','Legacy estimated customer payment dates cannot be used as precise payments-basis GST evidence. Review required.'));end if;
 end if;
 if basis='invoice' then
  select coalesce(sum(e.ex_gst*coalesce(e.business_use_percent,100)/100),0),coalesce(sum(e.gst_amount*coalesce(e.business_use_percent,100)/100),0),coalesce(jsonb_agg(jsonb_build_object('source_type','expense','source_id',e.id,'date',e.invoice_date,'reference',e.expense_number,'party',e.supplier_name,'party_id',e.supplier_id,'ex_gst',e.ex_gst*coalesce(e.business_use_percent,100)/100,'gst',e.gst_amount*coalesce(e.business_use_percent,100)/100,'total',e.total_amount*coalesce(e.business_use_percent,100)/100,'business_use_percent',coalesce(e.business_use_percent,100)) order by e.invoice_date,e.expense_number),'[]') into purch_ex,purch_gst,purchase_items from expenses e where e.business_id=bid and e.invoice_date between p_from and p_to and coalesce(e.lifecycle_state,'recorded')='recorded';
 else
  select coalesce(sum(greatest(ep.amount-(e.gst_amount*(ep.amount/nullif(e.total_amount,0))),0)*coalesce(e.business_use_percent,100)/100),0),coalesce(sum(e.gst_amount*(ep.amount/nullif(e.total_amount,0))*coalesce(e.business_use_percent,100)/100),0),coalesce(jsonb_agg(jsonb_build_object('source_type','expense_payment','source_id',ep.id,'date',ep.payment_date,'reference',e.expense_number,'party',e.supplier_name,'party_id',e.supplier_id,'ex_gst',greatest(ep.amount-(e.gst_amount*(ep.amount/nullif(e.total_amount,0))),0)*coalesce(e.business_use_percent,100)/100,'gst',e.gst_amount*(ep.amount/nullif(e.total_amount,0))*coalesce(e.business_use_percent,100)/100,'total',ep.amount*coalesce(e.business_use_percent,100)/100,'business_use_percent',coalesce(e.business_use_percent,100)) order by ep.payment_date),'[]') into purch_ex,purch_gst,purchase_items from expense_payments ep join expenses e on e.id=ep.expense_id and e.business_id=ep.business_id where ep.business_id=bid and ep.payment_date between p_from and p_to and e.total_amount>0 and coalesce(e.lifecycle_state,'recorded')='recorded';
 end if;
 select sales_ex-coalesce(sum(c.ex_gst),0),sales_gst-coalesce(sum(c.gst_amount),0) into sales_ex,sales_gst from customer_credit_notes c where c.business_id=bid and c.lifecycle_state='issued' and c.credit_date between p_from and p_to;
 select sales_items || coalesce(jsonb_agg(jsonb_build_object('source_type','customer_credit_note','source_id',c.id,'date',c.credit_date,'reference',c.credit_note_number,'party',cu.name,'party_id',c.customer_id,'ex_gst',-c.ex_gst,'gst',-c.gst_amount,'total',-c.total_amount,'original_reference',i.invoice_number) order by c.credit_date,c.credit_note_number),'[]'::jsonb) into sales_items from customer_credit_notes c left join customers cu on cu.id=c.customer_id and cu.business_id=c.business_id left join invoices i on i.id=c.original_invoice_id and i.business_id=c.business_id where c.business_id=bid and c.lifecycle_state='issued' and c.credit_date between p_from and p_to;
 
 select sales_ex+coalesce(sum(a.disposal_ex_gst),0),sales_gst+coalesce(sum(a.disposal_gst_output),0) into sales_ex,sales_gst from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;
 select sales_items || coalesce(jsonb_agg(jsonb_build_object('source_type','asset_disposal','source_id',a.id,'date',a.disposed_on,'reference','ASSET-'||left(a.id::text,8),'party','Asset disposal','ex_gst',a.disposal_ex_gst,'gst',a.disposal_gst_output,'total',a.disposal_proceeds) order by a.disposed_on),'[]'::jsonb) into sales_items from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;
 select purch_ex-coalesce(sum(c.ex_gst*coalesce(e.business_use_percent,100)/100),0),purch_gst-coalesce(sum(c.gst_amount*coalesce(e.business_use_percent,100)/100),0) into purch_ex,purch_gst from supplier_credits c join expenses e on e.id=c.original_expense_id and e.business_id=c.business_id where c.business_id=bid and c.lifecycle_state='recorded' and c.credit_date between p_from and p_to;
 select purchase_items || coalesce(jsonb_agg(jsonb_build_object('source_type','supplier_credit','source_id',c.id,'date',c.credit_date,'reference',c.credit_note_number,'party',e.supplier_name,'party_id',c.supplier_id,'ex_gst',-(c.ex_gst*coalesce(e.business_use_percent,100)/100),'gst',-(c.gst_amount*coalesce(e.business_use_percent,100)/100),'total',-(c.total_amount*coalesce(e.business_use_percent,100)/100),'business_use_percent',coalesce(e.business_use_percent,100),'original_reference',e.expense_number) order by c.credit_date,c.credit_note_number),'[]'::jsonb) into purchase_items from supplier_credits c join expenses e on e.id=c.original_expense_id and e.business_id=c.business_id where c.business_id=bid and c.lifecycle_state='recorded' and c.credit_date between p_from and p_to;
 select coalesce(sum(case when direction='debit' then gst_amount else 0 end),0),coalesce(sum(case when direction='credit' then gst_amount else 0 end),0),coalesce(jsonb_agg(jsonb_build_object('id',id,'date',adjustment_date,'type',adjustment_type,'direction',direction,'gst_amount',gst_amount,'reason',reason,'reference',reference) order by adjustment_date),'[]') into debit_adj,credit_adj,adjustment_items from gst_adjustments where business_id=bid and status='active' and adjustment_date between p_from and p_to;
 
 select credit_adj+coalesce(sum(a.disposal_gst_credit_adjustment),0), adjustment_items || coalesce(jsonb_agg(jsonb_build_object('source_type','asset_disposal','source_id',a.id,'date',a.disposed_on,'type','asset_disposal_private_use','direction','credit','gst_amount',a.disposal_gst_credit_adjustment,'reason','Final/decreasing GST adjustment on mixed-use asset disposal') order by a.disposed_on) filter (where coalesce(a.disposal_gst_credit_adjustment,0)>0),'[]'::jsonb) into credit_adj,adjustment_items from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;
 select count(*) into missing_count from expenses e where e.business_id=bid and e.invoice_date between p_from and p_to and coalesce(e.lifecycle_state,'recorded')='recorded' and e.total_amount>0 and e.gst_amount is null;
 if missing_count>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','missing_gst','count',missing_count,'message','Recorded expenses are missing GST information.'));end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'period_start',r.period_start,'period_end',r.period_end,'status',r.status,'calculation_version',r.calculation_version) order by r.period_start),'[]') into conflict_items from gst_returns r where r.business_id=bid and r.status='finalised' and daterange(r.period_start,r.period_end,'[]') && daterange(p_from,p_to,'[]') and not(r.period_start=p_from and r.period_end=p_to);
 if jsonb_array_length(conflict_items)>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','finalised_period_overlap','message','GST period conflict — an existing finalised return overlaps this period.','returns',conflict_items));end if;
 return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',basis,'sales_ex_gst',round(sales_ex,2),'gst_collected',round(sales_gst,2),'purchases_ex_gst',round(purch_ex,2),'gst_paid',round(purch_gst,2),'debit_adjustments',round(debit_adj,2),'credit_adjustments',round(credit_adj,2),'gst_net',round(sales_gst+debit_adj-purch_gst-credit_adj,2),'sales_items',sales_items,'purchase_items',purchase_items,'adjustment_items',adjustment_items,'review_items',review,'calculation_version','v61.70e-p3');
end$function$
;

REVOKE ALL ON FUNCTION public."v6170e_gst_calculate"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6170e_gst_calculate"(p_from date, p_to date) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6170e_gst_calculate"(p_from date, p_to date) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6171_admin_helper_save(p_settings jsonb, p_modules jsonb, p_business_id uuid DEFAULT NULL::uuid, p_entitlement text DEFAULT NULL::text, p_allowance integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare r record;mid uuid;begin if not is_super_admin() then raise exception 'Super Admin required' using errcode='42501';end if;update finlo_helper_settings set default_helper_name=case when p_settings?'default_helper_name' then left(coalesce(nullif(btrim(regexp_replace(p_settings->>'default_helper_name','\s+',' ','g')),''),'Frindly'),30) else default_helper_name end,global_enabled=coalesce((p_settings->>'global_enabled')::boolean,global_enabled),emergency_disabled=coalesce((p_settings->>'emergency_disabled')::boolean,emergency_disabled),provider=coalesce(nullif(p_settings->>'provider',''),provider),model=coalesce(nullif(p_settings->>'model',''),model),max_output_tokens=coalesce((p_settings->>'max_output_tokens')::int,max_output_tokens),contextual_awareness=coalesce((p_settings->>'contextual_awareness')::boolean,contextual_awareness),default_question_limit=coalesce((p_settings->>'default_question_limit')::int,default_question_limit),trial_question_limit=coalesce((p_settings->>'trial_question_limit')::int,trial_question_limit),monthly_cost_ceiling=case when p_settings?'monthly_cost_ceiling' then nullif(p_settings->>'monthly_cost_ceiling','')::numeric else monthly_cost_ceiling end,monthly_price=coalesce((p_settings->>'monthly_price')::numeric,monthly_price),annual_price=case when p_settings?'annual_price' then nullif(p_settings->>'annual_price','')::numeric else annual_price end,stripe_product_id=case when p_settings?'stripe_product_id' then nullif(p_settings->>'stripe_product_id','') else stripe_product_id end,stripe_monthly_price_id=case when p_settings?'stripe_monthly_price_id' then nullif(p_settings->>'stripe_monthly_price_id','') else stripe_monthly_price_id end,stripe_annual_price_id=case when p_settings?'stripe_annual_price_id' then nullif(p_settings->>'stripe_annual_price_id','') else stripe_annual_price_id end,instruction_version=coalesce(nullif(p_settings->>'instruction_version',''),instruction_version),instruction_text=coalesce(nullif(p_settings->>'instruction_text',''),instruction_text),updated_at=now(),updated_by=auth.uid() where id=true;for r in select key,value from jsonb_each(coalesce(p_modules,'{}'::jsonb)) loop update finlo_helper_module_controls set enabled=(r.value::text)::boolean,updated_at=now(),updated_by=auth.uid() where module_context=r.key;end loop;if p_business_id is not null and p_entitlement is not null then if p_entitlement not in('not_subscribed','subscribed','included_with_plan','trial','complimentary','suspended') then raise exception 'Invalid entitlement';end if;select id into mid from modules where slug='finlo_helper';insert into optional_addon_entitlements(business_id,module_id,entitlement_state,allowance_override,updated_by) values(p_business_id,mid,p_entitlement,p_allowance,auth.uid()) on conflict(business_id,module_id) do update set entitlement_state=excluded.entitlement_state,allowance_override=excluded.allowance_override,updated_at=now(),updated_by=auth.uid();end if;end$function$
;

REVOKE ALL ON FUNCTION public."v6171_admin_helper_save"(p_settings jsonb, p_modules jsonb, p_business_id uuid, p_entitlement text, p_allowance integer) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6171_admin_helper_save"(p_settings jsonb, p_modules jsonb, p_business_id uuid, p_entitlement text, p_allowance integer) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6171_admin_helper_save"(p_settings jsonb, p_modules jsonb, p_business_id uuid, p_entitlement text, p_allowance integer) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6171_helper_status(p_module text DEFAULT 'onboarding'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare bid uuid:=current_business_id();cfg public.finlo_helper_settings;ctl boolean:=false;sub public.subscriptions;pc public.finlo_helper_plan_config;ent public.optional_addon_entitlements;mid uuid;st text:='not_subscribed';lim int:=0;used int:=0;ps timestamptz;pe timestamptz;entitled boolean:=false;business_settings jsonb:='{}'::jsonb;override_name text;default_name text;effective_name text;
begin
if bid is null then raise exception 'No active business' using errcode='42501';end if;
select * into cfg from finlo_helper_settings where id=true;
default_name:=left(coalesce(nullif(btrim(cfg.default_helper_name),''),'Frindly'),30);
select coalesce(settings,'{}'::jsonb) into business_settings from businesses where id=bid;
override_name:=left(nullif(btrim(regexp_replace(coalesce(business_settings->>'helperNameOverride',''),'\s+',' ','g')),''),30);
effective_name:=coalesce(override_name,default_name,'Frindly');
select enabled into ctl from finlo_helper_module_controls where module_context=p_module;select id into mid from modules where slug='finlo_helper';select * into ent from optional_addon_entitlements where business_id=bid and module_id=mid;select * into sub from subscriptions where business_id=bid order by created_at desc limit 1;if sub.id is not null then select * into pc from finlo_helper_plan_config where plan_id=sub.plan_id;end if;if ent.business_id is not null then st:=ent.entitlement_state;elsif coalesce(pc.included,false) then st:='included_with_plan';else st:='not_subscribed';end if;entitled:=st in('subscribed','included_with_plan','trial','complimentary');if entitled then if st='trial' or(st='included_with_plan' and sub.status='trialing') then lim:=coalesce(ent.allowance_override,pc.allowance_override,cfg.trial_question_limit);else lim:=coalesce(ent.allowance_override,pc.allowance_override,cfg.default_question_limit);end if;else lim:=0;end if;if sub.id is not null then ps:=sub.current_period_start;pe:=sub.current_period_end;else ps:=date_trunc('month',now());pe:=date_trunc('month',now())+interval '1 month';end if;select count(*) into used from finlo_helper_usage where business_id=bid and success=true and created_at>=ps and created_at<pe;
return jsonb_build_object('enabled',cfg.global_enabled and not cfg.emergency_disabled and coalesce(ctl,false),'global_enabled',cfg.global_enabled,'emergency_disabled',cfg.emergency_disabled,'module_enabled',coalesce(ctl,false),'entitlement',st,'entitled',entitled,'used',used,'limit',lim,'remaining',greatest(lim-used,0),'period_start',ps,'next_reset',pe,'contextual_awareness',cfg.contextual_awareness,'default_helper_name',default_name,'helper_name',effective_name,'helper_name_overridden',override_name is not null);
end$function$
;

REVOKE ALL ON FUNCTION public."v6171_helper_status"(p_module text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6171_helper_status"(p_module text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6171_helper_status"(p_module text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6171b_p6_admin_live_voice_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_super_admin() then
    raise exception 'Super admin required' using errcode='42501';
  end if;

  return jsonb_build_object(
    'settings', (select to_jsonb(s) from finlo_live_voice_settings s where id=true),
    'businesses', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'business_id', b.id,
            'business', b.name,
            'entitlement',
              case
                when e.entitlement_state in ('subscribed','included_with_plan','trial','complimentary','suspended')
                  then e.entitlement_state
                when p.id is not null
                  and s.status in ('trialing','active')
                  and p.included_modules @> array['finlo_live_voice']::text[]
                  then 'included_with_plan'
                else coalesce(e.entitlement_state,'not_subscribed')
              end,
            'allowance_override', e.allowance_override,
            'sessions', coalesce(x.sessions,0),
            'seconds', coalesce(x.seconds,0),
            'last_used', x.last_used
          )
          order by b.name
        ),
        '[]'::jsonb
      )
      from businesses b
      left join lateral (
        select s0.*
        from subscriptions s0
        where s0.business_id=b.id
        order by s0.created_at desc
        limit 1
      ) s on true
      left join plans p on p.id=s.plan_id
      left join modules m on m.slug='finlo_live_voice'
      left join optional_addon_entitlements e
        on e.business_id=b.id
       and e.module_id=m.id
       and (e.starts_at is null or e.starts_at<=now())
       and (e.ends_at is null or e.ends_at>now())
      left join lateral (
        select count(*) sessions,
               coalesce(sum(duration_seconds),0) seconds,
               max(started_at) last_used
        from finlo_live_voice_usage u
        where u.business_id=b.id
          and u.started_at>=date_trunc('month',now())
      ) x on true
    ),
    'kpis', jsonb_build_object(
      'sessions_this_month',(select count(*) from finlo_live_voice_usage where started_at>=date_trunc('month',now())),
      'businesses_using',(select count(distinct business_id) from finlo_live_voice_usage where started_at>=date_trunc('month',now())),
      'minutes_this_month',(select round(coalesce(sum(duration_seconds),0)/60.0,1) from finlo_live_voice_usage where started_at>=date_trunc('month',now())),
      'failed_sessions',(select count(*) from finlo_live_voice_usage where status='failed' and started_at>=date_trunc('month',now()))
    )
  );
end
$function$
;

REVOKE ALL ON FUNCTION public."v6171b_p6_admin_live_voice_overview"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6171b_p6_admin_live_voice_overview"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6171b_p6_admin_live_voice_overview"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v6171b_p6_live_voice_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  bid uuid := current_business_id();
  uid uuid := auth.uid();
  cfg public.finlo_live_voice_settings;
  mid uuid;
  ent public.optional_addon_entitlements;
  used int := 0;
  ps timestamptz;
  pe timestamptz;
  sub public.subscriptions;
  st text := 'not_subscribed';
  entitled boolean := false;
  plan_includes boolean := false;
begin
  if bid is null or uid is null then
    raise exception 'No active business' using errcode='42501';
  end if;

  if not exists (
    select 1
    from business_memberships
    where business_id = bid
      and user_id = uid
      and status = 'active'
  ) then
    raise exception 'Active membership required' using errcode='42501';
  end if;

  select * into cfg
  from finlo_live_voice_settings
  where id = true;

  select id into mid
  from modules
  where slug = 'finlo_live_voice';

  select * into ent
  from optional_addon_entitlements
  where business_id = bid
    and module_id = mid
    and (starts_at is null or starts_at <= now())
    and (ends_at is null or ends_at > now());

  select * into sub
  from subscriptions
  where business_id = bid
  order by created_at desc
  limit 1;

  plan_includes :=
    sub.id is not null
    and sub.status in ('trialing', 'active')
    and exists (
      select 1
      from plans p
      where p.id = sub.plan_id
        and p.included_modules @> array['finlo_live_voice']::text[]
    );

  -- Active manual grants and an explicit suspension remain authoritative.
  -- A stale not_subscribed row does not block a module included by the plan.
  if ent.business_id is not null
     and ent.entitlement_state in ('subscribed','included_with_plan','trial','complimentary','suspended') then
    st := ent.entitlement_state;
  elsif plan_includes then
    st := 'included_with_plan';
  elsif ent.business_id is not null then
    st := ent.entitlement_state;
  end if;

  entitled := st in ('subscribed','included_with_plan','trial','complimentary');

  if sub.id is not null
     and sub.current_period_start is not null
     and sub.current_period_end is not null then
    ps := sub.current_period_start;
    pe := sub.current_period_end;
  else
    ps := date_trunc('month', now());
    pe := ps + interval '1 month';
  end if;

  select count(*) into used
  from finlo_live_voice_usage
  where business_id = bid
    and status in ('started','ended')
    and started_at >= ps
    and started_at < pe;

  return jsonb_build_object(
    'enabled', coalesce(cfg.global_enabled,false)
      and not coalesce(cfg.emergency_disabled,false)
      and entitled
      and used < coalesce(ent.allowance_override,cfg.monthly_session_limit),
    'global_enabled', coalesce(cfg.global_enabled,false),
    'emergency_disabled', coalesce(cfg.emergency_disabled,false),
    'entitlement', st,
    'entitled', entitled,
    'plan_includes', plan_includes,
    'used_sessions', used,
    'session_limit', coalesce(ent.allowance_override,cfg.monthly_session_limit),
    'remaining_sessions', greatest(coalesce(ent.allowance_override,cfg.monthly_session_limit)-used,0),
    'max_session_minutes', cfg.max_session_minutes,
    'model', cfg.model,
    'voice', cfg.voice,
    'period_start', ps,
    'next_reset', pe
  );
end
$function$
;

REVOKE ALL ON FUNCTION public."v6171b_p6_live_voice_status"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6171b_p6_live_voice_status"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6171b_p6_live_voice_status"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v6171c_helper_business_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_business uuid := public.current_business_id();
  v_from date := (current_date - interval '12 months')::date;
  v_result jsonb;
begin
  if v_business is null then raise exception 'No active business context'; end if;
  select jsonb_build_object(
    'generated_at', now(),
    'period_from', v_from,
    'business', (select jsonb_build_object('name', b.name, 'status', b.status) from businesses b where b.id=v_business),
    'customers', (select count(*) from customers c where c.business_id=v_business),
    'employees', (select count(*) from payroll_employees e where e.business_id=v_business and coalesce(e.archived,false)=false),
    'invoices', (select jsonb_build_object('count',count(*),'total',coalesce(sum(i.total),0),'paid',coalesce(sum(i.amount_paid),0),'balance_due',coalesce(sum(coalesce(i.balance_due,i.total-coalesce(i.amount_paid,0))),0),'overdue',coalesce(sum(case when i.due_date < current_date and coalesce(i.balance_due,i.total-coalesce(i.amount_paid,0)) > 0 then coalesce(i.balance_due,i.total-coalesce(i.amount_paid,0)) else 0 end),0)) from invoices i where i.business_id=v_business and coalesce(i.invoice_date,current_date)>=v_from),
    'expenses', (select jsonb_build_object('count',count(*),'total',coalesce(sum(e.total_amount),0),'gst',coalesce(sum(e.gst_amount),0),'outstanding',coalesce(sum(e.outstanding_balance),0)) from expenses e where e.business_id=v_business and coalesce(e.invoice_date,current_date)>=v_from and coalesce(e.archived,false)=false),
    'payroll', (select jsonb_build_object('pay_runs',count(*),'gross',coalesce(sum(p.gross_pay),0),'net',coalesce(sum(p.net_pay),0),'employment_cost',coalesce(sum(p.total_employment_cost),0)) from payroll_pay_runs p where p.business_id=v_business and coalesce(p.period_end,current_date)>=v_from),
    'jobs', (select jsonb_build_object('count',count(*),'expected_profit',coalesce(sum(j.expected_profit),0),'expected_margin',coalesce(avg(j.expected_margin_percent),0)) from job_costings j where j.business_id=v_business and coalesce(j.costing_date,current_date)>=v_from),
    'schedule', (select jsonb_build_object('count',count(*),'scheduled_value',coalesce(sum(s.scheduled_value),0),'upcoming',count(*) filter (where s.start_at >= now())) from job_schedules s where s.business_id=v_business and coalesce(s.start_at,current_date::timestamptz)>=v_from),
    'bank', (select jsonb_build_object('transactions',count(*),'unreconciled',count(*) filter (where coalesce(bt.status,'') not in ('reconciled','excluded')),'net',coalesce(sum(bt.amount),0)) from bank_transactions bt where bt.business_id=v_business and coalesce(bt.transaction_date,current_date)>=v_from),
    'gst', (select coalesce(jsonb_agg(jsonb_build_object('period_start',g.period_start,'period_end',g.period_end,'status',g.status,'gst_net',g.gst_net) order by g.period_end desc),'[]'::jsonb) from (select * from gst_returns where business_id=v_business order by period_end desc limit 6) g)
  ) into v_result;
  return v_result;
end;
$function$
;

REVOKE ALL ON FUNCTION public."v6171c_helper_business_context"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6171c_helper_business_context"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6171c_helper_business_context"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v6179_schedule_eligible_quotes()
 RETURNS TABLE(id uuid, quote_number text, customer_id uuid, customer_name text, customer_address text, description text, total_incl_gst numeric, status text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'auth'
AS $function$
declare
  v_business uuid;
begin
  v_business := public.current_business_id();
  if v_business is null then raise exception 'Active business is required'; end if;
  if not public.v6179_schedule_role_allowed(v_business,false) then
    raise exception 'Schedule access not authorised';
  end if;
  return query
  select q.id,q.quote_number,q.customer_id,q.customer_name,q.customer_address,
         q.description,q.total_incl_gst,q.status
  from public.quotes q
  where q.business_id=v_business
    and q.status in ('sent','accepted','approved','won')
    and not exists (
      select 1 from public.job_schedules s
      where s.business_id=v_business and s.quote_id=q.id
    )
  order by q.created_at desc;
end;
$function$
;

REVOKE ALL ON FUNCTION public."v6179_schedule_eligible_quotes"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6179_schedule_eligible_quotes"() TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6179_schedule_eligible_quotes"() TO "service_role";

CREATE OR REPLACE FUNCTION public.v6179_schedule_entitled(p_business_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_current uuid;
  v_override text;
  v_trial_ends_at timestamptz;
  v_in_plan boolean := false;
begin
  if auth.uid() is null then
    return false;
  end if;

  v_current := public.current_business_id();
  if v_current is null or v_current <> p_business_id then
    return false;
  end if;

  select bm.status, bm.trial_ends_at
    into v_override, v_trial_ends_at
  from public.business_modules bm
  join public.modules m on m.id = bm.module_id
  where bm.business_id = p_business_id
    and m.slug = 'schedule'
  order by bm.created_at desc
  limit 1;

  if v_override = 'suspended' then
    return false;
  end if;

  if v_override = 'active' then
    return true;
  end if;

  if v_override = 'trialing'
     and (v_trial_ends_at is null or v_trial_ends_at >= now()) then
    return true;
  end if;

  -- Expired per-module trials should not block access when the paid plan includes Schedule.
  select coalesce('schedule' = any(p.included_modules), false)
    into v_in_plan
  from public.subscriptions s
  join public.plans p on p.id = s.plan_id
  where s.business_id = p_business_id
    and s.status in ('trialing', 'active')
    and (s.trial_ends_at is null or s.trial_ends_at >= now())
    and (s.cancel_at is null or s.cancel_at > now())
    and (not coalesce(s.cancel_at_period_end, false) or s.current_period_end is null or s.current_period_end > now())
  order by s.created_at desc
  limit 1;

  return coalesce(v_in_plan, false);
end;
$function$
;

REVOKE ALL ON FUNCTION public."v6179_schedule_entitled"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6179_schedule_entitled"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6179_schedule_entitled"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6179_today_schedule(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS TABLE(schedule_id uuid, start_at timestamp with time zone, end_at timestamp with time zone, title text, customer_name text, service_address text, status text, scheduled_value numeric, assigned_employee_names text[])
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_business uuid;
begin
  v_business:=public.current_business_id();
  if v_business is null then raise exception 'No active authorised business'; end if;
  if p_from is null or p_to is null or p_to<=p_from then raise exception 'Invalid schedule range'; end if;
  if not public.v6179_schedule_role_allowed(v_business,false) then raise exception 'Schedule access not authorised'; end if;

  return query
  select s.id,s.start_at,s.end_at,s.title,c.name,s.service_address,s.status,s.scheduled_value,
         coalesce(array_agg(distinct nullif(btrim(concat_ws(' ',coalesce(nullif(btrim(e.preferred_name),''),e.first_name),e.last_name)),'')) filter (where e.id is not null),array[]::text[])
  from public.job_schedules s
  left join public.customers c on c.id=s.customer_id and c.business_id=s.business_id
  left join public.job_schedule_assignments a on a.schedule_id=s.id and a.business_id=s.business_id and a.assignment_status<>'cancelled'
  left join public.payroll_employees e on e.id=a.employee_id and e.business_id=s.business_id
  where s.business_id=v_business
    and s.status<>'cancelled'
    and s.start_at is not null and s.end_at is not null
    and s.start_at < p_to and s.end_at > p_from
  group by s.id,s.start_at,s.end_at,s.title,c.name,s.service_address,s.status,s.scheduled_value
  order by s.start_at,s.title;
end
$function$
;

REVOKE ALL ON FUNCTION public."v6179_today_schedule"(p_from timestamp with time zone, p_to timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6179_today_schedule"(p_from timestamp with time zone, p_to timestamp with time zone) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6179_today_schedule"(p_from timestamp with time zone, p_to timestamp with time zone) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6181_invoice_payments_enabled(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists(select 1 from public.modules where slug='invoice_payments' and is_active)
    and not exists(
      select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
      where bm.business_id=p_business_id and m.slug='invoice_payments' and bm.status in ('suspended','canceled')
    )
    and (
      exists(
        select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
        where bm.business_id=p_business_id and m.slug='invoice_payments'
          and (bm.status='active' or (bm.status='trialing' and (bm.trial_ends_at is null or bm.trial_ends_at>=now())))
      )
      or exists(
        select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
        where s.business_id=p_business_id
          and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
          and (s.cancel_at is null or s.cancel_at>now())
          and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
          and 'invoice_payments'=any(coalesce(p.included_modules,'{}'::text[]))
      )
    )
$function$
;

REVOKE ALL ON FUNCTION public."v6181_invoice_payments_enabled"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6181_invoice_payments_enabled"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6181_record_online_invoice_payment(p_transaction_id uuid, p_payment_date date DEFAULT CURRENT_DATE, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tx public.invoice_payment_transactions%rowtype;
  v_invoice public.invoices%rowtype;
  v_paid numeric := 0;
  v_outstanding numeric := 0;
  v_payment_id uuid;
  v_reference text;
  v_invoice_currency text;
begin
  select * into v_tx
  from public.invoice_payment_transactions
  where id = p_transaction_id
  for update;

  if v_tx.id is null then
    raise exception 'Online payment transaction not found';
  end if;

  if v_tx.status = 'succeeded' then
    return jsonb_build_object(
      'transaction_id', v_tx.id,
      'status', v_tx.status,
      'customer_payment_id', v_tx.customer_payment_id,
      'already_recorded', true
    );
  end if;

  select * into v_invoice
  from public.invoices
  where id = v_tx.invoice_id
    and business_id = v_tx.business_id
  for update;

  if v_invoice.id is null then
    update public.invoice_payment_transactions
    set status = 'needs_review', failure_reason = 'Invoice was not found for the payment.', updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;

  if coalesce(v_invoice.lifecycle_state, 'issued') <> 'issued' then
    update public.invoice_payment_transactions
    set status = 'needs_review', failure_reason = format('Payment received for a %s invoice.', coalesce(v_invoice.lifecycle_state, 'unknown')), updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;

  v_invoice_currency := lower(coalesce(nullif(v_invoice.company_snapshot->>'currency', ''), 'nzd'));
  if lower(v_tx.currency) <> v_invoice_currency then
    update public.invoice_payment_transactions
    set status = 'needs_review', failure_reason = format('Payment currency %s does not match invoice currency %s.', upper(v_tx.currency), upper(v_invoice_currency)), updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;

  select coalesce(sum(cp.amount), 0)
  into v_paid
  from public.customer_payments cp
  where cp.invoice_id = v_invoice.id;

  v_outstanding := greatest(0, coalesce(v_invoice.balance_due, coalesce(v_invoice.total, 0) - v_paid));

  if v_tx.amount > v_outstanding + 0.005 then
    update public.invoice_payment_transactions
    set status = 'needs_review',
        failure_reason = format('Payment amount %s exceeds the remaining invoice balance %s.', v_tx.amount, v_outstanding),
        updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object(
      'transaction_id', v_tx.id,
      'status', 'needs_review',
      'remaining_balance', v_outstanding
    );
  end if;

  v_reference := coalesce(nullif(trim(p_reference), ''), 'Stripe Connect online payment');
  insert into public.customer_payments (
    business_id,
    invoice_id,
    payment_date,
    amount,
    reference,
    notes,
    payment_source,
    stripe_payment_intent_id,
    stripe_checkout_session_id,
    invoice_payment_transaction_id,
    currency
  ) values (
    v_tx.business_id,
    v_tx.invoice_id,
    coalesce(p_payment_date, current_date),
    v_tx.amount,
    v_reference,
    'Recorded automatically from a verified Stripe Connect payment.',
    'stripe_connect',
    v_tx.stripe_payment_intent_id,
    v_tx.stripe_checkout_session_id,
    v_tx.id,
    upper(v_tx.currency)
  )
  returning id into v_payment_id;

  update public.invoice_payment_transactions
  set status = 'succeeded',
      customer_payment_id = v_payment_id,
      payment_date = coalesce(payment_date, now()),
      updated_at = now()
  where id = v_tx.id;

  return jsonb_build_object(
    'transaction_id', v_tx.id,
    'status', 'succeeded',
    'customer_payment_id', v_payment_id,
    'remaining_balance', greatest(0, v_outstanding - v_tx.amount)
  );
exception
  when unique_violation then
    select * into v_tx from public.invoice_payment_transactions where id = p_transaction_id;
    return jsonb_build_object(
      'transaction_id', p_transaction_id,
      'status', coalesce(v_tx.status, 'needs_review'),
      'customer_payment_id', v_tx.customer_payment_id,
      'already_recorded', true
    );
end;
$function$
;

REVOKE ALL ON FUNCTION public."v6181_record_online_invoice_payment"(p_transaction_id uuid, p_payment_date date, p_reference text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6181_record_online_invoice_payment"(p_transaction_id uuid, p_payment_date date, p_reference text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6190_review_purchase(p_business_id uuid, p_expense_id uuid, p_expected_revision integer, p_rows jsonb, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bill public.expenses%rowtype; v_previous public.purchase_invoice_reviews%rowtype;
 v_line jsonb; v_category uuid; v_ex numeric; v_gst numeric; v_qty numeric;
 v_ex_total numeric:=0;v_gst_total numeric:=0;v_id uuid;v_date date;v_life integer;
 v_se_revision integer;v_stock_enabled boolean;v_target jsonb;v_index integer:=0;v_line_number integer:=0;v_net_rows jsonb; v_alloc jsonb; v_alloc_ex numeric; v_alloc_gst numeric; v_alloc_target integer; v_alloc_ex_total numeric; v_alloc_gst_total numeric;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id
    or not public.v6147_can_write_area(p_business_id,'expenses') then raise exception 'Expense access denied'; end if;
 select * into v_bill from public.expenses where id=p_expense_id and business_id=p_business_id for update;
 if not found or v_bill.payment_status='draft' or coalesce(v_bill.archived,false)
    or coalesce(v_bill.lifecycle_state,'recorded')<>'recorded' then raise exception 'Record an active bill before review'; end if;
 if exists(select 1 from public.accounting_journals where business_id=p_business_id and source_type='expense'
    and source_id=p_expense_id and status='posted') then raise exception 'A posted bill requires an accountant-approved reclassification'; end if;
 if (exists(select 1 from public.accounting_periods where business_id=p_business_id
    and status='closed' and v_bill.invoice_date between period_start and period_end)
    or exists(select 1 from public.gst_returns where business_id=p_business_id and status='finalised'
    and v_bill.invoice_date between period_start and period_end))
    and not exists(select 1 from public.late_transaction_adjustments a where a.business_id=p_business_id
      and a.expense_id=p_expense_id and a.status in ('approved_current_period','requires_prior_return_action','accounting_only'))
   then raise exception 'LATE_TRANSACTION_REVIEW_REQUIRED'; end if;
 select * into v_previous from public.purchase_invoice_reviews where business_id=p_business_id
   and expense_id=p_expense_id order by revision desc limit 1 for update;
 if coalesce(v_previous.revision,0)<>coalesce(p_expected_revision,-1) then raise exception 'The review changed; reload before saving'; end if;
 if v_previous.id is not null and nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Give a reason for correcting a confirmed review'; end if;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 150 then raise exception 'Review between 1 and 150 items'; end if;
 for v_line in select value from jsonb_array_elements(p_rows) loop
  if jsonb_typeof(v_line)<>'object' or coalesce(v_line->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment','discount')
     or length(trim(coalesce(v_line->>'description',''))) not between 1 and 500
     or nullif(v_line->>'category_id','') is null or nullif(v_line->>'ex_gst','') is null
     or nullif(v_line->>'gst','') is null or nullif(v_line->>'quantity','') is null then raise exception 'Complete every item, category, quantity and GST amount'; end if;
  begin
   v_category:=(v_line->>'category_id')::uuid;v_ex:=(v_line->>'ex_gst')::numeric;
   v_gst:=(v_line->>'gst')::numeric;v_qty:=(v_line->>'quantity')::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Invalid item category or amount'; end;
  if not exists(select 1 from public.expense_categories c where c.id=v_category and c.business_id=p_business_id and not c.archived)
     or v_qty<=0 or v_qty>1000000 or v_ex<>round(v_ex,2) or v_gst<>round(v_gst,2)
     then raise exception 'Check category, amount and quantity on every item'; end if;
  if v_line ? 'allocation' and jsonb_typeof(v_line->'allocation')='object' then
   if jsonb_typeof(v_line->'allocation'->'allocations')<>'array' or jsonb_array_length(v_line->'allocation'->'allocations')<1
      or coalesce(v_line->'allocation'->>'method','') not in ('proportional','equal','manual')
      or coalesce(v_line->'allocation'->>'type','') not in ('freight','delivery','handling','discount','other') then
     raise exception 'Check the allocation method and selected items'; end if;
   v_alloc_ex_total:=0;v_alloc_gst_total:=0;
   for v_alloc in select value from jsonb_array_elements(v_line->'allocation'->'allocations') loop
    begin v_alloc_target:=(v_alloc->>'target_index')::integer;v_alloc_ex:=(v_alloc->>'ex_gst')::numeric;v_alloc_gst:=(v_alloc->>'gst')::numeric;
    exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'Invalid allocation amount or target'; end;
    if v_alloc_target<0 or v_alloc_target>=jsonb_array_length(p_rows) or v_alloc_target=v_line_number
       or v_alloc_ex<>round(v_alloc_ex,2) or v_alloc_gst<>round(v_alloc_gst,2) then raise exception 'Check every allocated amount'; end if;
    v_target:=p_rows->v_alloc_target;
    if coalesce(v_target->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment')
       or (v_target ? 'allocation' and jsonb_typeof(v_target->'allocation')='object') then raise exception 'Allocate only to purchased item lines'; end if;
    v_alloc_ex_total:=v_alloc_ex_total+v_alloc_ex;v_alloc_gst_total:=v_alloc_gst_total+v_alloc_gst;
   end loop;
   if v_alloc_ex_total<>v_ex or v_alloc_gst_total<>v_gst then raise exception 'Allocated amounts must equal the invoice adjustment exactly'; end if;
   if v_line->>'kind'='discount' and (v_ex>=0 or v_gst>0 or v_qty<>1) then raise exception 'Check the discount amount'; end if;
   if v_line->>'kind'<>'discount' and (v_ex<0 or v_gst<0) then raise exception 'Use a discount row for a negative amount'; end if;
  elsif v_line->>'kind'='discount' then
   if coalesce(v_line->>'discount_target_index','') !~ '^[0-9]+$' then raise exception 'Choose which invoice charge this discount reduces'; end if;
   v_index:=(v_line->>'discount_target_index')::integer;
   if v_index>=v_line_number or v_ex>=0 or v_gst>0 or v_qty<>1 then raise exception 'Check the discount amount and its earlier charge'; end if;
   v_target:=p_rows->v_index;
   if coalesce(v_target->>'kind','') not in ('regular','stock','supplies','equipment','low_value_equipment')
      or v_target->>'category_id' is distinct from v_line->>'category_id'
      or v_line->>'discount_for' is distinct from v_target->>'kind' then raise exception 'Discount must reduce a charge in the same category and Use'; end if;
  elsif v_ex<0 or v_gst<0 then raise exception 'Use a discount row for a negative amount';
  end if;
  if v_line->>'kind'='equipment' then
   begin v_date:=(v_line->>'available_on')::date;v_life:=(v_line->>'life_months')::integer;
   exception when invalid_datetime_format or invalid_text_representation then raise exception 'Check the equipment ready date and life'; end;
   if v_date is null or v_date<v_bill.invoice_date or v_life not between 1 and 1200
      or coalesce(v_line->>'book_method','') not in ('SL','DV') then raise exception 'Equipment needs a ready date, useful life and method'; end if;
  end if;
  v_ex_total:=v_ex_total+v_ex;v_gst_total:=v_gst_total+v_gst;v_line_number:=v_line_number+1;
 end loop;
 if v_ex_total<>v_bill.ex_gst or v_gst_total<>v_bill.gst_amount then raise exception 'Item ex GST and GST totals must match the bill exactly'; end if;
 v_net_rows:=public.v6190_net_purchase_rows(p_rows);
 select public.v6200_stock_module_enabled(p_business_id) into v_stock_enabled;
 if v_stock_enabled then
   select coalesce(max(revision),0) into v_se_revision from public.se_invoice_reviews
    where business_id=p_business_id and expense_id=p_expense_id;
   perform public.se_review_invoice(p_business_id,p_expense_id,v_se_revision,v_net_rows,p_reason);
 end if;
 insert into public.purchase_invoice_reviews(business_id,expense_id,revision,rows,source_ex_gst,source_gst,reviewed_by,reason)
 values(p_business_id,p_expense_id,coalesce(v_previous.revision,0)+1,p_rows,v_bill.ex_gst,v_bill.gst_amount,auth.uid(),nullif(trim(p_reason),'')) returning id into v_id;
 return v_id;
end $function$
;

REVOKE ALL ON FUNCTION public."v6190_review_purchase"(p_business_id uuid, p_expense_id uuid, p_expected_revision integer, p_rows jsonb, p_reason text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6190_review_purchase"(p_business_id uuid, p_expense_id uuid, p_expected_revision integer, p_rows jsonb, p_reason text) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6190_review_purchase"(p_business_id uuid, p_expense_id uuid, p_expected_revision integer, p_rows jsonb, p_reason text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6191_seed_default_chart(p_business_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare inserted integer := 0;
begin
  if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
    raise exception 'Business access denied';
  end if;
  if not public.v6147_can_write_area(p_business_id,'business_settings') then
    raise exception 'Settings access is required';
  end if;

  with defaults(account_code, account_name, account_type, normal_balance, report_section, system_key, xero_account_type, description) as (
    values
      ('090','Business Bank','bank','debit','asset','bank_main','BANK','Primary bank or transaction account.'),
      ('095','Payment Clearing','current_asset','debit','asset','payment_clearing','CURRENT','Temporary control account for refunds awaiting the matching bank transaction.'),
      ('120','Accounts Receivable','current_asset','debit','asset','accounts_receivable','CURRENT','Customer balances owing.'),
      ('140','Inventory - Stock for Sale','inventory','debit','asset','inventory_stock','INVENTORY','Goods bought for resale; accountant-reviewed postings only.'),
      ('145','Materials and Consumables on Hand','inventory','debit','asset','materials_on_hand','INVENTORY','Work materials or consumables not yet expensed.'),
      ('150','Fixed Assets - Equipment','fixed_asset','debit','asset','fixed_assets_equipment','FIXED','Equipment kept by the business.'),
      ('155','Accumulated Depreciation - Equipment','fixed_asset','credit','asset','accum_depn_equipment','FIXED','Contra-asset for posted depreciation.'),
      ('200','Sales','income','credit','revenue','sales','REVENUE','Default sales income.'),
      ('205','Other Income','income','credit','revenue','other_income','REVENUE','Other operating income.'),
      ('260','GST Collected','tax','credit','liability','gst_collected','CURRLIAB','GST on sales.'),
      ('261','GST Paid','tax','debit','asset','gst_paid','CURRLIAB','GST on purchases.'),
      ('265','PAYE / Payroll Liabilities','current_liability','credit','liability','payroll_liability','CURRLIAB','Payroll deductions and employer obligations.'),
      ('300','Purchases / Cost of Sales','cost_of_sales','debit','cost_of_sales','cost_of_sales','DIRECTCOSTS','Posted cost of goods sold or direct purchases.'),
      ('310','Materials and Consumables Used','cost_of_sales','debit','cost_of_sales','materials_used','DIRECTCOSTS','Work supplies consumed on jobs.'),
      ('315','Depreciation Expense','expense','debit','expense','depreciation_expense','EXPENSE','Posted book depreciation.'),
      ('400','Advertising and Marketing','expense','debit','expense','advertising','EXPENSE','Advertising, marketing and promotion.'),
      ('404','Bank Fees','expense','debit','expense','bank_fees','EXPENSE','Bank and merchant fees.'),
      ('420','Motor Vehicle Expenses','expense','debit','expense','motor_vehicle','EXPENSE','Vehicle running costs.'),
      ('429','General Expenses','expense','debit','expense','general_expenses','EXPENSE','Fallback expense account.'),
      ('477','Telephone and Internet','expense','debit','expense','telephone_internet','EXPENSE','Phone and internet costs.'),
      ('800','Owner Drawings / Private Use','equity','debit','equity','owner_drawings','EQUITY','Private-use or owner drawings allocation.'),
      ('860','Retained Earnings','equity','credit','equity','retained_earnings','EQUITY','Prior year retained profit.')
  ), upserted as (
    insert into public.accounting_accounts(
      business_id, account_code, account_name, account_type, normal_balance,
      report_section, system_key, xero_account_code, xero_account_type,
      description, is_system, is_control, created_by, updated_by
    )
    select p_business_id, d.account_code, d.account_name, d.account_type, d.normal_balance,
      d.report_section, d.system_key, d.account_code, d.xero_account_type,
      d.description, true, d.system_key in ('accounts_receivable','gst_collected','gst_paid','payroll_liability','retained_earnings'), auth.uid(), auth.uid()
    from defaults d
    on conflict (business_id, account_code) do update
      set account_name = excluded.account_name,
          account_type = excluded.account_type,
          normal_balance = excluded.normal_balance,
          report_section = excluded.report_section,
          system_key = coalesce(public.accounting_accounts.system_key, excluded.system_key),
          xero_account_code = coalesce(public.accounting_accounts.xero_account_code, excluded.xero_account_code),
          xero_account_type = coalesce(public.accounting_accounts.xero_account_type, excluded.xero_account_type),
          description = coalesce(public.accounting_accounts.description, excluded.description),
          is_system = true,
          updated_at = now(),
          updated_by = auth.uid()
    returning 1
  )
  select count(*) into inserted from upserted;

  return inserted;
end $function$
;

REVOKE ALL ON FUNCTION public."v6191_seed_default_chart"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6191_seed_default_chart"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6191_seed_default_chart"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6192_account_id(p_business_id uuid, p_system_key text DEFAULT NULL::text, p_account_code text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select a.id
  from public.accounting_accounts a
  where a.business_id = p_business_id
    and coalesce(a.archived,false) = false
    and (
      (p_system_key is not null and a.system_key = p_system_key)
      or (p_account_code is not null and a.account_code = p_account_code)
    )
  order by case when p_system_key is not null and a.system_key = p_system_key then 0 else 1 end,
           a.account_code
  limit 1
$function$
;

REVOKE ALL ON FUNCTION public."v6192_account_id"(p_business_id uuid, p_system_key text, p_account_code text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6192_account_id"(p_business_id uuid, p_system_key text, p_account_code text) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6192_post_operational_ledger(p_from date, p_to date, p_include_depreciation boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_business_id uuid := public.current_business_id();
  v_user uuid := auth.uid();
  v_ar uuid;
  v_ap uuid;
  v_bank uuid;
  v_sales uuid;
  v_gst_payable uuid;
  v_gst_receivable uuid;
  v_expense_fallback uuid;
  v_payment_clearing uuid;
  v_stripe_fee_expense uuid;
  v_payment_fee_recovery uuid;
  v_fixed_assets uuid;
  v_accum_depn uuid;
  v_depn_expense uuid;
  v_invoice_count integer := 0;
  v_customer_payment_count integer := 0;
  v_expense_count integer := 0;
  v_supplier_payment_count integer := 0;
  v_depreciation_count integer := 0;
  r record;
  v_lines jsonb;
  v_amount numeric;
  v_ratio numeric;
  v_posted uuid;
begin
  if v_user is null or v_business_id is null then
    raise exception 'Sign in and choose a business first';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Select a valid posting period';
  end if;
  if not public.v6169a_accountant_centre_access(v_business_id, true) then
    raise exception 'Accountant or owner access is required to post accounting journals';
  end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_business_id
      and p.status <> 'open'
      and daterange(p.period_start, p.period_end, '[]') && daterange(p_from, p_to, '[]')
  ) then
    raise exception 'One or more accounting periods in this date range are locked';
  end if;

  insert into public.accounting_accounts(
    business_id, account_code, account_name, account_type, normal_balance,
    report_section, system_key, system_account_key, xero_account_code,
    xero_account_type, description, is_system, is_control, allow_manual_posting,
    created_by, updated_by
  ) values
    (v_business_id,'1050','Payment Clearing','asset','debit','asset','payment_clearing','payment_clearing','1050','CURRENT','Temporary clearing account for Stripe, refunds and bank settlement timing.',true,true,false,v_user,v_user),
    (v_business_id,'4150','Payment Fee Recoveries','revenue','credit','income','payment_fee_recovery','payment_fee_recovery','4150','REVENUE','Customer-paid payment processing fee recoveries.',true,false,true,v_user,v_user),
    (v_business_id,'6300','Stripe Fees','expense','debit','operating_expenses','stripe_fee_expense','stripe_fee_expense','6300','EXPENSE','Stripe card and platform processing fees.',true,false,true,v_user,v_user)
  on conflict (business_id, account_code) do nothing;

  v_ar := public.v61105_account_role_id(v_business_id,'accounts_receivable');
  v_ap := public.v61105_account_role_id(v_business_id,'accounts_payable');
  v_bank := public.v61105_account_role_id(v_business_id,'bank');
  v_sales := coalesce(
    (select sm.account_id from public.accounting_source_mappings sm where sm.business_id=v_business_id and sm.source_type='sales_default' and sm.source_key='sales_default' and sm.purpose='income' and coalesce(sm.archived,false)=false limit 1),
    public.v61105_account_role_id(v_business_id,'sales')
  );
  v_gst_payable := public.v61105_account_role_id(v_business_id,'gst_output');
  v_gst_receivable := public.v61105_account_role_id(v_business_id,'gst_input');
  v_expense_fallback := public.v61105_account_role_id(v_business_id,'general_expense');
  v_payment_clearing := coalesce(
    public.v6170b_account(v_business_id,'payment_clearing'),
    (select id from public.accounting_accounts where business_id=v_business_id and system_key='payment_clearing' and not coalesce(archived,false) order by account_code limit 1)
  );
  v_stripe_fee_expense := coalesce(
    public.v6170b_account(v_business_id,'stripe_fee_expense'),
    (select id from public.accounting_accounts where business_id=v_business_id and system_key='stripe_fee_expense' and not coalesce(archived,false) order by account_code limit 1),
    v_expense_fallback
  );
  v_payment_fee_recovery := coalesce(
    public.v6170b_account(v_business_id,'payment_fee_recovery'),
    (select id from public.accounting_accounts where business_id=v_business_id and system_key='payment_fee_recovery' and not coalesce(archived,false) order by account_code limit 1),
    v_sales
  );
  v_fixed_assets := public.v61105_account_role_id(v_business_id,'fixed_equipment');
  v_accum_depn := public.v61105_account_role_id(v_business_id,'accum_depreciation');
  v_depn_expense := public.v61105_account_role_id(v_business_id,'depreciation_expense');

  if v_ar is null or v_ap is null or v_bank is null or v_sales is null or
     v_gst_payable is null or v_gst_receivable is null or v_expense_fallback is null then
    raise exception 'Chart of accounts is incomplete. Refresh the default Frindly chart before posting.';
  end if;

  for r in
    select i.*
    from public.invoices i
    where i.business_id = v_business_id
      and i.invoice_date between p_from and p_to
      and round(coalesce(i.total,0),2) > 0
      and coalesce(i.lifecycle_state,'issued') not in ('draft','voided')
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'invoice'
          and j.source_id = i.id
          and j.status in ('posted','reversed')
      )
    order by i.invoice_date, i.invoice_number
  loop
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id',v_ar,'description','Invoice '||coalesce(r.invoice_number,''),'debit',round(coalesce(r.total,0),2),'credit',0,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id),
      jsonb_build_object('account_id',v_sales,'description','Sales revenue','debit',0,'credit',round(coalesce(r.total,0)-coalesce(r.gst,0),2),'tax_amount',round(coalesce(r.gst,0),2),'customer_id',r.customer_id,'job_costing_id',r.job_costing_id)
    );
    if round(coalesce(r.gst,0),2) > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_gst_payable,'description','GST collected','debit',0,'credit',round(coalesce(r.gst,0),2),'tax_amount',round(coalesce(r.gst,0),2),'customer_id',r.customer_id,'job_costing_id',r.job_costing_id));
    end if;
    v_posted := public.v6192_create_posted_journal(v_business_id,r.invoice_date,'invoice','invoice',r.id,r.invoice_number,'Invoice '||coalesce(r.invoice_number,''),v_lines);
    v_invoice_count := v_invoice_count + 1;
  end loop;

  for r in
    select
      p.*,
      i.invoice_number,
      i.customer_id,
      i.job_costing_id,
      t.gross_amount,
      t.customer_fee_amount,
      t.stripe_fee_amount,
      t.net_amount,
      t.status as online_payment_status
    from public.customer_payments p
    join public.invoices i on i.id = p.invoice_id and i.business_id = p.business_id
    left join public.invoice_payment_transactions t
      on t.customer_payment_id = p.id
     and t.business_id = p.business_id
     and t.status = 'succeeded'
    where p.business_id = v_business_id
      and p.payment_date between p_from and p_to
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'customer_payment'
          and j.source_id = p.id
          and j.status in ('posted','reversed')
      )
    order by p.payment_date, p.created_at
  loop
    v_amount := round(coalesce(r.amount,0),2);
    if v_amount > 0 then
      if r.payment_source = 'stripe_connect'
         and r.online_payment_status = 'succeeded'
         and v_payment_clearing is not null then
        v_lines := jsonb_build_array(
          jsonb_build_object(
            'account_id',v_payment_clearing,
            'description','Stripe gross charge',
            'debit',round(greatest(coalesce(r.gross_amount,r.amount),r.amount),2),
            'credit',0,
            'tax_code','NO_GST',
            'tax_rate',0,
            'tax_amount',0,
            'customer_id',r.customer_id,
            'job_costing_id',r.job_costing_id
          ),
          jsonb_build_object(
            'account_id',v_ar,
            'description','Clear receivable',
            'debit',0,
            'credit',v_amount,
            'tax_code','NO_GST',
            'tax_rate',0,
            'tax_amount',0,
            'customer_id',r.customer_id,
            'job_costing_id',r.job_costing_id
          )
        );

        if round(coalesce(r.customer_fee_amount,0),2) > 0 then
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'account_id',v_payment_fee_recovery,
            'description','Customer-paid payment processing fee',
            'debit',0,
            'credit',round(coalesce(r.customer_fee_amount,0),2),
            'tax_code','NO_GST',
            'tax_rate',0,
            'tax_amount',0,
            'customer_id',r.customer_id,
            'job_costing_id',r.job_costing_id
          ));
        end if;

        if round(coalesce(r.stripe_fee_amount,0),2) > 0 then
          v_lines := v_lines || jsonb_build_array(
            jsonb_build_object(
              'account_id',v_stripe_fee_expense,
              'description','Stripe processing fee',
              'debit',round(coalesce(r.stripe_fee_amount,0),2),
              'credit',0,
              'tax_code','NO_GST',
              'tax_rate',0,
              'tax_amount',0,
              'customer_id',r.customer_id,
              'job_costing_id',r.job_costing_id
            ),
            jsonb_build_object(
              'account_id',v_payment_clearing,
              'description','Stripe fee deducted before payout',
              'debit',0,
              'credit',round(coalesce(r.stripe_fee_amount,0),2),
              'tax_code','NO_GST',
              'tax_rate',0,
              'tax_amount',0,
              'customer_id',r.customer_id,
              'job_costing_id',r.job_costing_id
            )
          );
        end if;

        v_posted := public.v6192_create_posted_journal(
          v_business_id,
          r.payment_date,
          'customer_payment',
          'customer_payment',
          r.id,
          coalesce(r.reference,r.invoice_number),
          'Stripe payment for '||coalesce(r.invoice_number,'invoice'),
          v_lines
        );
      else
        v_posted := public.v6192_create_posted_journal(
          v_business_id,r.payment_date,'customer_payment','customer_payment',r.id,coalesce(r.reference,r.invoice_number),'Customer payment for '||coalesce(r.invoice_number,'invoice'),
          jsonb_build_array(
            jsonb_build_object('account_id',v_bank,'description','Customer payment','debit',v_amount,'credit',0,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id),
            jsonb_build_object('account_id',v_ar,'description','Clear receivable','debit',0,'credit',v_amount,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id)
          )
        );
      end if;
      v_customer_payment_count := v_customer_payment_count + 1;
    end if;
  end loop;

  for r in
    select e.*
    from public.expenses e
    where e.business_id = v_business_id
      and e.invoice_date between p_from and p_to
      and coalesce(e.archived,false) = false
      and coalesce(e.payment_status,'') <> 'draft'
      and coalesce(e.lifecycle_state,'recorded') not in ('draft','voided')
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'expense'
          and j.source_id = e.id
          and j.status in ('posted','reversed')
      )
    order by e.invoice_date, e.expense_number
  loop
    v_ratio := greatest(0, least(1, coalesce(r.business_use_percent,100) / 100));

    with source_lines as (
      select
        l.id as source_line_id,
        coalesce(l.description,r.description,'Supplier bill') as description,
        l.category_id,
        l.job_costing_id,
        round(coalesce(l.ex_gst,0) * v_ratio, 2) as ex_gst,
        round(coalesce(l.gst_amount,0) * v_ratio, 2) as gst_amount,
        l.gst_rate
      from public.expense_lines l
      where l.business_id = v_business_id
        and l.expense_id = r.id
        and coalesce(r.is_split,false) = true
      union all
      select
        null::uuid,
        coalesce(r.description,'Supplier bill'),
        r.category_id,
        r.job_costing_id,
        round(coalesce(r.business_ex_gst, r.ex_gst * v_ratio), 2),
        round(coalesce(r.business_gst_amount, r.gst_amount * v_ratio), 2),
        r.gst_rate
      where not exists (
        select 1 from public.expense_lines l
        where l.business_id = v_business_id
          and l.expense_id = r.id
          and coalesce(r.is_split,false) = true
      )
    ), mapped as (
      select
        sl.*,
        coalesce(sm.account_id, v_expense_fallback) as account_id
      from source_lines sl
      left join public.accounting_source_mappings sm
        on sm.business_id = v_business_id
       and sm.source_type = 'expense_category'
       and sm.source_id = sl.category_id
       and sm.purpose = 'expense'
       and coalesce(sm.archived,false) = false
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'account_id', account_id,
      'description', description,
      'debit', ex_gst,
      'credit', 0,
      'tax_amount', gst_amount,
      'tax_rate', gst_rate,
      'supplier_id', r.supplier_id,
      'job_costing_id', job_costing_id,
      'source_line_id', source_line_id
    )) filter (where ex_gst > 0), '[]'::jsonb)
    into v_lines
    from mapped;

    v_lines := public.v61105_phase13c_capitalise_expense_lines(v_business_id,r.id,v_ratio,v_lines,v_fixed_assets);

    if round(coalesce(r.business_gst_amount, r.gst_amount * v_ratio),2) > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id',v_gst_receivable,
        'description','GST claimable',
        'debit',round(coalesce(r.business_gst_amount, r.gst_amount * v_ratio),2),
        'credit',0,
        'tax_amount',round(coalesce(r.business_gst_amount, r.gst_amount * v_ratio),2),
        'supplier_id',r.supplier_id,
        'job_costing_id',r.job_costing_id
      ));
    end if;

    select round(coalesce(sum((x.debit)::numeric),0),2)
      into v_amount
    from jsonb_to_recordset(v_lines) as x(debit numeric);
    if v_amount > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id',v_ap,
        'description','Supplier bill payable',
        'debit',0,
        'credit',v_amount,
        'supplier_id',r.supplier_id,
        'job_costing_id',r.job_costing_id
      ));
      v_posted := public.v6192_create_posted_journal(v_business_id,r.invoice_date,'expense','expense',r.id,r.expense_number,'Supplier bill '||coalesce(r.expense_number,''),v_lines);
      v_expense_count := v_expense_count + 1;
    end if;
  end loop;

  for r in
    select p.*, e.expense_number, e.supplier_id, e.job_costing_id
    from public.expense_payments p
    join public.expenses e on e.id = p.expense_id and e.business_id = p.business_id
    where p.business_id = v_business_id
      and p.payment_date between p_from and p_to
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'supplier_payment'
          and j.source_id = p.id
          and j.status in ('posted','reversed')
      )
    order by p.payment_date, p.created_at
  loop
    v_amount := round(coalesce(r.amount,0),2);
    if v_amount > 0 then
      v_posted := public.v6192_create_posted_journal(
        v_business_id,r.payment_date,'supplier_payment','supplier_payment',r.id,coalesce(r.reference,r.expense_number),'Supplier payment for '||coalesce(r.expense_number,'bill'),
        jsonb_build_array(
          jsonb_build_object('account_id',v_ap,'description','Clear payable','debit',v_amount,'credit',0,'supplier_id',r.supplier_id,'job_costing_id',r.job_costing_id),
          jsonb_build_object('account_id',v_bank,'description','Supplier payment','debit',0,'credit',v_amount,'supplier_id',r.supplier_id,'job_costing_id',r.job_costing_id)
        )
      );
      v_supplier_payment_count := v_supplier_payment_count + 1;
    end if;
  end loop;

  if p_include_depreciation and v_fixed_assets is not null and v_accum_depn is not null and v_depn_expense is not null then
    for r in
      with months as (
        select (date_trunc('month', gs)::date + interval '1 month - 1 day')::date as month_end
        from generate_series(date_trunc('month', p_from)::date, date_trunc('month', p_to)::date, interval '1 month') gs
      )
      select a.id, a.available_on, a.original_cost, a.book_opening_value, a.business_use_percent, a.accounting_rate, m.month_end
      from public.se_assets a
      join months m on m.month_end between greatest(coalesce(a.available_on,a.purchased_on,m.month_end), p_from) and p_to
      where a.business_id = v_business_id
        and a.voided_at is null
        and a.disposed_on is null
        and coalesce(a.tracking_treatment,'') <> 'low_value'
        and coalesce(a.accounting_rate,0) > 0
        and not exists (
          select 1 from public.accounting_journals j
          where j.business_id = v_business_id
            and j.source_type = 'depreciation'
            and j.source_id = a.id
            and j.journal_date = m.month_end
            and j.status in ('posted','reversed')
        )
      order by m.month_end, a.id
    loop
      v_amount := round(coalesce(r.book_opening_value,r.original_cost,0) * coalesce(r.business_use_percent,100) / 100 * coalesce(r.accounting_rate,0) / 100 / 12, 2);
      if v_amount > 0 then
        v_posted := public.v6192_create_posted_journal(
          v_business_id,r.month_end,'depreciation','depreciation',r.id,'DEP-'||to_char(r.month_end,'YYYY-MM'),'Monthly depreciation',
          jsonb_build_array(
            jsonb_build_object('account_id',v_depn_expense,'description','Monthly depreciation','debit',v_amount,'credit',0),
            jsonb_build_object('account_id',v_accum_depn,'description','Accumulated depreciation','debit',0,'credit',v_amount)
          )
        );
        v_depreciation_count := v_depreciation_count + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'posted', v_invoice_count + v_customer_payment_count + v_expense_count + v_supplier_payment_count + v_depreciation_count,
    'invoices', v_invoice_count,
    'customer_payments', v_customer_payment_count,
    'supplier_bills', v_expense_count,
    'supplier_payments', v_supplier_payment_count,
    'depreciation', v_depreciation_count,
    'period_start', p_from,
    'period_end', p_to
  );
end
$function$
;

REVOKE ALL ON FUNCTION public."v6192_post_operational_ledger"(p_from date, p_to date, p_include_depreciation boolean) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6192_post_operational_ledger"(p_from date, p_to date, p_include_depreciation boolean) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6192_post_operational_ledger"(p_from date, p_to date, p_include_depreciation boolean) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6200_stock_module_enabled(p_business_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_status text;
  v_trial_ends_at timestamptz;
begin
  if public.is_super_admin() then return true; end if;
  if auth.uid() is null or p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;
  if not exists(select 1 from public.modules where slug='stock_equipment' and is_active) then return false; end if;

  select bm.status,bm.trial_ends_at into v_status,v_trial_ends_at
  from public.business_modules bm
  join public.modules m on m.id=bm.module_id
  where bm.business_id=p_business_id and m.slug='stock_equipment'
  order by bm.created_at desc
  limit 1;

  if v_status in ('suspended','canceled') then return false; end if;
  if v_status='active' then return true; end if;
  if v_status='trialing' and (v_trial_ends_at is null or v_trial_ends_at>=now()) then return true; end if;

  return exists(
    select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
    where s.business_id=p_business_id
      and (s.status='active' or (s.status='trialing' and (s.trial_ends_at is null or s.trial_ends_at>=now())))
      and (s.cancel_at is null or s.cancel_at>now())
      and (not coalesce(s.cancel_at_period_end,false) or s.current_period_end is null or s.current_period_end>now())
      and 'stock_equipment'=any(coalesce(p.included_modules,'{}'::text[]))
  );
end
$function$
;

REVOKE ALL ON FUNCTION public."v6200_stock_module_enabled"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6200_stock_module_enabled"(p_business_id uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6200_stock_module_enabled"(p_business_id uuid) TO "service_role";

CREATE OR REPLACE FUNCTION public.v6215_confirm_import(p_batch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bid uuid:=current_business_id();v_batch import_batches;v_r import_records;v_n jsonb;v_id uuid;v_existing uuid;
  v_seq integer;v_contact jsonb;v_number text;v_items jsonb;v_total numeric;v_gst numeric;v_subtotal numeric;v_outstanding numeric;
begin
  if v_bid is null or not v6147_can_write_area(v_bid,'core') then raise exception 'Import access denied' using errcode='42501'; end if;
  select * into v_batch from import_batches where id=p_batch and business_id=v_bid for update;
  if not found then raise exception 'Import batch not found'; end if;
  if v_batch.status='completed' then return v6215_import_get(p_batch); end if;
  if v_batch.status not in ('analysed','reviewed') then raise exception 'Review this import before confirming it'; end if;
  perform pg_advisory_xact_lock(hashtext('v6215-import-'||v_bid::text));
  update import_batches set status='importing',updated_at=now() where id=p_batch;

  for v_r in select * from import_records where batch_id=p_batch order by sheet_id,display_label for update loop
    if v_r.validation_status='rejected' or v_r.duplicate_action='skip' then
      update import_records set validation_status='skipped',updated_at=now() where id=v_r.id;
      insert into import_commit_events(business_id,batch_id,import_record_id,action,result,detail,created_by) values(v_bid,p_batch,v_r.id,v_r.duplicate_action,'skipped',jsonb_build_object('reason','Rejected or user selected Skip'),auth.uid());
      continue;
    end if;
    v_n:=v_r.normalized_data;v_id:=null;v_existing:=v_r.existing_record_id;

    if v_r.record_type='customers' then
      if v_existing is null then select id into v_existing from customers where business_id=v_bid and lower(btrim(name))=lower(btrim(v_n->>'name')) limit 1; end if;
      if v_existing is not null and v_r.duplicate_action='update_safe' then
        v_contact:=case when coalesce(nullif(btrim(v_n->>'email'),''),nullif(btrim(v_n->>'phone'),''),nullif(btrim(v_n->>'mobile'),'')) is null then null else jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'name',v_n->>'name','designation','','phone',coalesce(v_n->>'phone',''),'mobile',coalesce(v_n->>'mobile',''),'email',coalesce(v_n->>'email',''),'dob','','billing',true)) end;
        update customers set address=coalesce(nullif(btrim(v_n->>'address'),''),address),contacts=coalesce(v_contact,contacts),updated_at=now() where id=v_existing and business_id=v_bid returning id into v_id;
      elsif v_existing is not null then v_id:=v_existing;
      else
        select coalesce(max(nullif(regexp_replace(customer_number,'\D','','g'),'')::int),0)+1 into v_seq from customers where business_id=v_bid and customer_number~'[0-9]';
        v_contact:=case when coalesce(nullif(btrim(v_n->>'email'),''),nullif(btrim(v_n->>'phone'),''),nullif(btrim(v_n->>'mobile'),'')) is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'name',v_n->>'name','designation','','phone',coalesce(v_n->>'phone',''),'mobile',coalesce(v_n->>'mobile',''),'email',coalesce(v_n->>'email',''),'dob','','billing',true)) end;
        insert into customers(business_id,customer_number,customer_type,name,address,contacts,custom_fields) values(v_bid,'C'||lpad(v_seq::text,4,'0'),'individual',btrim(v_n->>'name'),nullif(btrim(v_n->>'address'),''),v_contact,'[]') returning id into v_id;
      end if;

    elsif v_r.record_type='suppliers' then
      if v_existing is null then select id into v_existing from suppliers where business_id=v_bid and lower(btrim(supplier_name))=lower(btrim(v_n->>'name')) and not archived limit 1; end if;
      if v_existing is not null and v_r.duplicate_action='update_safe' then
        update suppliers set contact_person=coalesce(nullif(btrim(v_n->>'contact_person'),''),contact_person),address=coalesce(nullif(btrim(v_n->>'address'),''),address),phone=coalesce(nullif(btrim(v_n->>'phone'),''),phone),mobile=coalesce(nullif(btrim(v_n->>'mobile'),''),mobile),email=coalesce(nullif(btrim(v_n->>'email'),''),email),registration_number=coalesce(nullif(btrim(v_n->>'registration_number'),''),registration_number),tax_number=coalesce(nullif(btrim(v_n->>'tax_number'),''),tax_number),updated_at=now(),updated_by=auth.uid() where id=v_existing and business_id=v_bid returning id into v_id;
      elsif v_existing is not null then v_id:=v_existing;
      else
        insert into suppliers(business_id,supplier_name,contact_person,address,phone,mobile,email,registration_number,tax_number,default_gst_treatment,payment_terms_days) values(v_bid,btrim(v_n->>'name'),nullif(btrim(v_n->>'contact_person'),''),nullif(btrim(v_n->>'address'),''),nullif(btrim(v_n->>'phone'),''),nullif(btrim(v_n->>'mobile'),''),nullif(btrim(v_n->>'email'),''),nullif(btrim(v_n->>'registration_number'),''),nullif(btrim(v_n->>'tax_number'),''),'gst',0) returning id into v_id;
      end if;

    elsif v_r.record_type in ('invoices','expenses') and (v_r.commit_mode='historical_reference' or v_r.duplicate_action='historical_reference') then
      insert into migration_historical_documents(business_id,batch_id,import_record_id,document_type,source_platform,source_external_id,document_number,document_date,due_date,party_name,party_external_id,currency,items,subtotal,gst,total,paid_amount,outstanding_amount,source_status,source_evidence,canonical_hash,created_by)
      values(v_bid,p_batch,v_r.id,case when v_r.record_type='invoices' then 'invoice' else 'expense' end,coalesce(v_batch.source_adapter,'generic_file'),v_r.source_external_id,nullif(v_n->>'number',''),nullif(v_n->>'date','')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'party_name',''),'Unknown'),nullif(v_n->>'party_external_id',''),upper(coalesce(nullif(v_n->>'currency',''),'NZD'))::char(3),coalesce(v_n->'items','[]'::jsonb),coalesce((v_n->>'subtotal')::numeric,0),coalesce((v_n->>'gst')::numeric,0),coalesce((v_n->>'total')::numeric,0),coalesce((v_n->>'paid_amount')::numeric,0),coalesce((v_n->>'outstanding_amount')::numeric,0),nullif(v_n->>'status',''),coalesce(v_n->'source_evidence','{}'::jsonb),v_r.canonical_hash,auth.uid())
      on conflict (business_id,document_type,canonical_hash) do nothing returning id into v_id;
      if v_id is null then select id into v_id from migration_historical_documents where business_id=v_bid and document_type=case when v_r.record_type='invoices' then 'invoice' else 'expense' end and canonical_hash=v_r.canonical_hash; end if;

    elsif v_r.record_type='invoices' and v_r.commit_mode='native_opening' then
      v_total:=coalesce((v_n->>'total')::numeric,0);v_gst:=coalesce((v_n->>'gst')::numeric,0);v_subtotal:=coalesce((v_n->>'subtotal')::numeric,v_total-v_gst);v_outstanding:=coalesce((v_n->>'outstanding_amount')::numeric,v_total);
      if v_outstanding<=0 then raise exception 'Open invoice % has no outstanding amount',v_r.display_label; end if;
      if exists(select 1 from invoices where business_id=v_bid and invoice_number=v_n->>'number') then select id into v_id from invoices where business_id=v_bid and invoice_number=v_n->>'number' limit 1;
      else
        v_items:=coalesce(v_n->'items',jsonb_build_array(jsonb_build_object('description',coalesce(v_n->>'description','Imported opening invoice'),'quantity',1,'rate',v_subtotal,'amount',v_subtotal)));
        insert into invoices(business_id,invoice_number,invoice_date,due_date,customer_name,customer_address,customer_email,reference,customer_note,items,subtotal,gst,total,amount_paid,balance_due,company_snapshot)
        values(v_bid,v_n->>'number',(v_n->>'date')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'party_name',''),'Imported customer'),nullif(v_n->>'party_address',''),nullif(v_n->>'party_email',''),nullif(v_n->>'reference',''),'Imported opening receivable. Settlement history was not manufactured.',v_items,v_subtotal,v_gst,v_total,greatest(0,v_total-v_outstanding),v_outstanding,jsonb_build_object('migration_batch_id',p_batch,'source_adapter',v_batch.source_adapter)) returning id into v_id;
        perform v6170c1_issue_invoice(v_id);
      end if;

    elsif v_r.record_type='expenses' and v_r.commit_mode='native_opening' then
      v_total:=coalesce((v_n->>'total')::numeric,0);v_gst:=coalesce((v_n->>'gst')::numeric,0);v_subtotal:=coalesce((v_n->>'subtotal')::numeric,v_total-v_gst);v_outstanding:=coalesce((v_n->>'outstanding_amount')::numeric,v_total);
      if v_outstanding<=0 then raise exception 'Open expense % has no outstanding amount',v_r.display_label; end if;
      v_number:=coalesce(nullif(v_n->>'number',''),'MIG-'||substr(v_r.id::text,1,8));
      if exists(select 1 from expenses where business_id=v_bid and expense_number=v_number) then select id into v_id from expenses where business_id=v_bid and expense_number=v_number;
      else insert into expenses(business_id,expense_number,supplier_name,supplier_reference,invoice_date,due_date,description,amount_type,gst_treatment,gst_rate,gst_override,ex_gst,gst_amount,total_amount,amount_paid,outstanding_balance,payment_status,currency,is_split,archived,business_use_percent,business_use_amount,private_use_amount,business_ex_gst,business_gst_amount,allocation_method,allocation_basis,updated_by)
        values(v_bid,v_number,nullif(v_n->>'party_name',''),nullif(v_n->>'reference',''),(v_n->>'date')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'description',''),'Imported opening payable'),'inclusive',case when v_gst>0 then 'gst' else 'no_gst' end,case when v_gst>0 then 15 else 0 end,true,v_subtotal,v_gst,v_total,greatest(0,v_total-v_outstanding),v_outstanding,case when v_outstanding<v_total then 'part_paid' else 'unpaid' end,upper(coalesce(nullif(v_n->>'currency',''),'NZD'))::char(3),false,false,100,v_total,0,v_subtotal,v_gst,'percentage','Imported opening payable',auth.uid()) returning id into v_id; end if;

    elsif v_r.record_type='quotes' then
      v_total:=coalesce((v_n->>'total')::numeric,0);v_gst:=coalesce((v_n->>'gst')::numeric,0);v_subtotal:=coalesce((v_n->>'subtotal')::numeric,v_total-v_gst);
      if exists(select 1 from quotes where business_id=v_bid and quote_number=v_n->>'number') then select id into v_id from quotes where business_id=v_bid and quote_number=v_n->>'number' limit 1;
      else insert into quotes(business_id,quote_number,quote_date,valid_until,customer_name,customer_address,customer_email,description,quoted_price_ex_gst,gst_rate,gst_amount,total_incl_gst,notes,terms,status,quote_items)
        values(v_bid,v_n->>'number',(v_n->>'date')::date,nullif(v_n->>'due_date','')::date,coalesce(nullif(v_n->>'party_name',''),'Imported customer'),nullif(v_n->>'party_address',''),nullif(v_n->>'party_email',''),coalesce(nullif(v_n->>'description',''),'Imported quote'),v_subtotal,case when v_subtotal>0 then round(v_gst/v_subtotal*100,4) else 0 end,v_gst,v_total,nullif(v_n->>'notes',''),nullif(v_n->>'terms',''),case when v_n->>'status' in ('draft','sent','approved','won','rejected') then v_n->>'status' else 'draft' end,coalesce(v_n->'items','[]'::jsonb)) returning id into v_id; end if;

    elsif v_r.record_type='stock' then
      if nullif(v_n->>'sku','') is not null then select id into v_id from se_items where business_id=v_bid and lower(sku)=lower(v_n->>'sku') and not archived limit 1; end if;
      if v_id is null then select id into v_id from se_items where business_id=v_bid and lower(btrim(name))=lower(btrim(v_n->>'name')) and kind='stock' and not archived limit 1; end if;
      if v_id is null then v_id:=se_create_item(v_bid,'stock',v_n->>'name',nullif(v_n->>'sku',''),coalesce(nullif(v_n->>'unit',''),'each'),nullif(v_n->>'low_stock_at','')::numeric); end if;
      if coalesce((v_n->>'quantity')::numeric,0)>0 and not exists(select 1 from se_movements where business_id=v_bid and item_id=v_id and kind='opening' and reason like 'Migration batch %') then perform se_record_movement(v_bid,v_id,'opening',(v_n->>'quantity')::numeric,coalesce((v_n->>'unit_cost')::numeric,0),coalesce(nullif(v_n->>'date','')::date,v_batch.cutover_date,current_date),'Migration batch '||p_batch::text,null,null,null); end if;

    elsif v_r.record_type='equipment' then
      select a.id into v_id from se_assets a join se_items i on i.id=a.item_id where a.business_id=v_bid and lower(btrim(i.name))=lower(btrim(v_n->>'name')) and a.voided_at is null limit 1;
      if v_id is null then v_id:=se_create_opening_asset_v61105(v_bid,v_n->>'name',coalesce((v_n->>'original_cost')::numeric,0),coalesce((v_n->>'gst')::numeric,0),nullif(v_n->>'purchased_on','')::date,coalesce(nullif(v_n->>'available_on','')::date,v_batch.cutover_date,current_date),coalesce((v_n->>'business_use_percent')::numeric,100),coalesce(nullif(v_n->>'condition',''),'unknown'),coalesce(v_n->>'category',''),nullif(v_n->>'book_opening_value','')::numeric,nullif(v_n->>'tax_opening_value','')::numeric,coalesce(v_batch.cutover_date,current_date)); end if;

    elsif v_r.record_type='employees' then
      if nullif(v_n->>'employee_number','') is not null then select id into v_id from payroll_employees where business_id=v_bid and employee_number=v_n->>'employee_number' limit 1; end if;
      if v_id is null then select id into v_id from payroll_employees where business_id=v_bid and lower(btrim(first_name))=lower(btrim(v_n->>'first_name')) and lower(btrim(last_name))=lower(btrim(v_n->>'last_name')) and (nullif(v_n->>'date_of_birth','') is null or date_of_birth=nullif(v_n->>'date_of_birth','')::date) limit 1; end if;
      if v_id is null then
        v_number:=coalesce(nullif(v_n->>'employee_number',''),'EMP-'||substr(v_r.id::text,1,8));
        insert into payroll_employees(business_id,employee_number,first_name,last_name,date_of_birth,email,mobile,phone,address,employment_type,job_title,start_date,standard_weekly_hours,standard_working_days,pay_frequency,employment_status,pay_type,hourly_rate,annual_salary,ird_number,tax_code,student_loan,kiwisaver_status,kiwisaver_employee_rate,kiwisaver_employer_rate,annual_holiday_method,holiday_pay_rate,bank_account_name,bank_account_number,bank_payment_reference,notes)
        values(v_bid,v_number,coalesce(nullif(v_n->>'first_name',''),'Imported'),coalesce(nullif(v_n->>'last_name',''),'Employee'),nullif(v_n->>'date_of_birth','')::date,nullif(v_n->>'email',''),nullif(v_n->>'mobile',''),nullif(v_n->>'phone',''),nullif(v_n->>'address',''),coalesce(nullif(v_n->>'employment_type',''),'casual'),nullif(v_n->>'job_title',''),coalesce(nullif(v_n->>'start_date','')::date,v_batch.cutover_date,current_date),coalesce((v_n->>'standard_weekly_hours')::numeric,40),coalesce((v_n->>'standard_working_days')::numeric,5),coalesce(nullif(v_n->>'pay_frequency',''),'fortnightly'),'active',coalesce(nullif(v_n->>'pay_type',''),'hourly'),coalesce((v_n->>'hourly_rate')::numeric,0),coalesce((v_n->>'annual_salary')::numeric,0),nullif(v_n->>'ird_number',''),coalesce(nullif(v_n->>'tax_code',''),'M'),coalesce((v_n->>'student_loan')::boolean,false),coalesce(nullif(v_n->>'kiwisaver_status',''),'not_enrolled'),coalesce((v_n->>'kiwisaver_employee_rate')::numeric,3.5),coalesce((v_n->>'kiwisaver_employer_rate')::numeric,3.5),coalesce(nullif(v_n->>'annual_holiday_method',''),'standard'),coalesce((v_n->>'holiday_pay_rate')::numeric,8),nullif(v_n->>'bank_account_name',''),nullif(v_n->>'bank_account_number',''),nullif(v_n->>'bank_payment_reference',''),'Imported employee setup; verify tax, leave and bank details before first pay run.') returning id into v_id;
      end if;
      if coalesce(nullif(v_n->>'gross_ytd','')::numeric,0)<>0 or coalesce(nullif(v_n->>'paye_ytd','')::numeric,0)<>0 or coalesce(nullif(v_n->>'net_ytd','')::numeric,0)<>0 or coalesce(nullif(v_n->>'annual_leave_hours','')::numeric,0)<>0 or coalesce(nullif(v_n->>'sick_leave_hours','')::numeric,0)<>0 or coalesce(nullif(v_n->>'alternative_holiday_hours','')::numeric,0)<>0 then
        insert into payroll_migration_opening_balances(business_id,employee_id,batch_id,effective_date,gross_ytd,paye_ytd,net_ytd,annual_leave_hours,sick_leave_hours,alternative_holiday_hours,evidence,created_by)
        values(v_bid,v_id,p_batch,coalesce(v_batch.cutover_date,current_date),coalesce(nullif(v_n->>'gross_ytd','')::numeric,0),coalesce(nullif(v_n->>'paye_ytd','')::numeric,0),coalesce(nullif(v_n->>'net_ytd','')::numeric,0),nullif(v_n->>'annual_leave_hours','')::numeric,nullif(v_n->>'sick_leave_hours','')::numeric,nullif(v_n->>'alternative_holiday_hours','')::numeric,jsonb_build_object('source','Smart Migration Centre','record_id',v_r.id),auth.uid())
        on conflict(business_id,employee_id,effective_date) do nothing;
      end if;

    elsif v_r.record_type='payroll_history' then
      insert into payroll_migration_history(business_id,batch_id,import_record_id,employee_external_id,employee_number,employee_name,period_start,period_end,pay_date,gross_pay,paye,deductions,net_pay,source_platform,canonical_hash,source_evidence,created_by)
      values(v_bid,p_batch,v_r.id,nullif(v_n->>'employee_external_id',''),nullif(v_n->>'employee_number',''),coalesce(nullif(v_n->>'employee_name',''),'Imported employee'),nullif(v_n->>'period_start','')::date,nullif(v_n->>'period_end','')::date,nullif(v_n->>'pay_date','')::date,coalesce((v_n->>'gross_pay')::numeric,0),coalesce((v_n->>'paye')::numeric,0),coalesce((v_n->>'deductions')::numeric,0),coalesce((v_n->>'net_pay')::numeric,0),coalesce(v_batch.source_adapter,'generic_file'),v_r.canonical_hash,coalesce(v_n->'source_evidence','{}'::jsonb),auth.uid())
      on conflict (business_id,canonical_hash) do nothing returning id into v_id;
      if v_id is null then select id into v_id from payroll_migration_history where business_id=v_bid and canonical_hash=v_r.canonical_hash; end if;
    end if;

    if v_id is null then raise exception 'Import record % did not produce a target record',v_r.display_label; end if;
    update import_records set validation_status='imported',duplicate_status='imported',imported_record_type=v_r.record_type,imported_record_id=v_id,updated_at=now() where id=v_r.id;
    insert into import_commit_events(business_id,batch_id,import_record_id,action,result,target_type,target_id,detail,created_by) values(v_bid,p_batch,v_r.id,v_r.duplicate_action,case when v_existing is not null and v_r.duplicate_action='update_safe' then 'updated' else 'imported' end,v_r.record_type,v_id,jsonb_build_object('commit_mode',v_r.commit_mode),auth.uid());
  end loop;

  update import_batches set status='completed',mapping_version='v62.15',imported_rows=(select count(*) from import_records where batch_id=p_batch and validation_status='imported'),warning_rows=(select count(*) from import_records where batch_id=p_batch and validation_status='warning'),rejected_rows=(select count(*) from import_records where batch_id=p_batch and validation_status='rejected'),completed_at=now(),updated_at=now() where id=p_batch;
  return v6215_import_get(p_batch);
exception when others then
  raise;
end$function$
;

REVOKE ALL ON FUNCTION public."v6215_confirm_import"(p_batch uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public."v6215_confirm_import"(p_batch uuid) TO "authenticated";

GRANT EXECUTE ON FUNCTION public."v6215_confirm_import"(p_batch uuid) TO "service_role";
