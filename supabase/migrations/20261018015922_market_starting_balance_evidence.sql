-- A read-only, single-snapshot conversion check. It never posts opening balances.
CREATE FUNCTION public.v6228_starting_balance_evidence(p_cutover date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $f$
DECLARE bid uuid:=public.current_business_id();asof date;body jsonb;tax jsonb;tax_error text;document_count bigint;import_count bigint;zone text;
BEGIN
 IF auth.uid() IS NULL OR bid IS NULL OR NOT coalesce(public.v6147_can_write_area(bid,'financials'),false) OR NOT coalesce(public.v6169a_accountant_centre_access(bid,false),false) OR NOT coalesce(public.v6147_can_read_area(bid,'core'),false) OR NOT coalesce(public.v6147_can_read_area(bid,'expenses'),false) THEN RAISE EXCEPTION 'Financials, invoice and expense access are required to review conversion evidence.' USING ERRCODE='42501';END IF;
 IF p_cutover IS NULL OR NOT isfinite(p_cutover) OR p_cutover<'1900-01-02'::date OR p_cutover>'2100-12-31'::date THEN RAISE EXCEPTION 'Choose a starting date between 2 January 1900 and 31 December 2100.' USING ERRCODE='22023';END IF;
 asof:=p_cutover-1;SELECT CASE WHEN upper(coalesce(settings->>'country','NZ'))='AU' THEN 'Australia/Sydney' ELSE 'Pacific/Auckland' END INTO zone FROM public.businesses WHERE id=bid;
 SELECT (SELECT count(*) FROM public.invoices WHERE business_id=bid AND (invoice_date<=asof OR invoice_date IS NULL))+(SELECT count(*) FROM public.expenses WHERE business_id=bid AND (invoice_date<=asof OR invoice_date IS NULL)) INTO document_count;
 SELECT count(*) INTO import_count FROM public.import_records r JOIN public.import_batches b ON b.id=r.batch_id AND b.business_id=r.business_id WHERE r.business_id=bid AND r.record_type IN ('invoices','expenses') AND b.status='completed';
 IF document_count+import_count>20000 THEN RAISE EXCEPTION 'This conversion has more than 20,000 financial records. Use a reviewed full export; no partial check has been returned.' USING ERRCODE='54000';END IF;
 BEGIN tax:=public.v61105_effective_tax_status(asof)-ARRAY['tax_identifier'];EXCEPTION WHEN invalid_parameter_value THEN tax_error:=SQLERRM;END;
 WITH cp AS (
  SELECT invoice_id,sum(amount) FILTER(WHERE payment_date<=asof) paid_before,sum(amount) paid_all,count(*) FILTER(WHERE payment_date IS NULL) undated FROM public.customer_payments WHERE business_id=bid GROUP BY invoice_id
 ),ep AS (
  SELECT expense_id,sum(amount) FILTER(WHERE payment_date<=asof) paid_before,sum(amount) paid_all,count(*) FILTER(WHERE payment_date IS NULL) undated FROM public.expense_payments WHERE business_id=bid GROUP BY expense_id
 ),cc AS (
  SELECT original_invoice_id,sum(total_amount) credits FROM public.customer_credit_notes WHERE business_id=bid AND lifecycle_state='issued' AND credit_date<=asof GROUP BY original_invoice_id
 ),sc AS (
  SELECT original_expense_id,sum(total_amount) credits FROM public.supplier_credits WHERE business_id=bid AND lifecycle_state='recorded' AND credit_date<=asof GROUP BY original_expense_id
 ),journals AS (
  SELECT source_type,source_id,count(*) n FROM public.accounting_journals WHERE business_id=bid AND source_type IN ('invoice','expense') AND status IN ('posted','reversed') AND journal_date<=asof GROUP BY source_type,source_id
 ),docs AS (
  SELECT 'invoice'::text kind,i.id,i.invoice_number reference,i.invoice_date date,i.total gross,i.amount_paid stored_paid,i.balance_due stored_balance,
    i.lifecycle_state,i.voided_at,i.company_snapshot->>'currency' currency,
    coalesce(cp.paid_before,0) paid_before,coalesce(cp.paid_all,0) paid_all,coalesce(cc.credits,0) credits_before,coalesce(cp.undated,0) undated_payments,
    coalesce(j.n,0) source_journals,i.voided_at>=(p_cutover::timestamp AT TIME ZONE zone) voided_after_cutover
  FROM public.invoices i LEFT JOIN cp ON cp.invoice_id=i.id LEFT JOIN cc ON cc.original_invoice_id=i.id LEFT JOIN journals j ON j.source_type='invoice' AND j.source_id=i.id
  WHERE i.business_id=bid AND (i.invoice_date<=asof OR i.invoice_date IS NULL)
  UNION ALL
  SELECT 'expense',e.id,e.expense_number,e.invoice_date,e.total_amount,e.amount_paid,e.outstanding_balance,
    e.lifecycle_state,e.voided_at,e.currency,coalesce(ep.paid_before,0),coalesce(ep.paid_all,0),coalesce(sc.credits,0),coalesce(ep.undated,0),coalesce(j.n,0),e.voided_at>=(p_cutover::timestamp AT TIME ZONE zone)
  FROM public.expenses e LEFT JOIN ep ON ep.expense_id=e.id LEFT JOIN sc ON sc.original_expense_id=e.id LEFT JOIN journals j ON j.source_type='expense' AND j.source_id=e.id
  WHERE e.business_id=bid AND (e.invoice_date<=asof OR e.invoice_date IS NULL)
 )
 SELECT jsonb_build_object('version','v62.28-conversion-evidence','business_id',bid,'cutover_date',p_cutover,'ledger_as_of',asof,'currency',(SELECT nullif(btrim(settings->>'currency'),'') FROM public.businesses WHERE id=bid),
  'posts_balances',false,'current_document_states',true,'tax_status',tax,'tax_error',tax_error,
  'counts',jsonb_build_object('documents',document_count,'completed_import_records',import_count),
  'accounts',(SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.account_code,a.id),'[]') FROM (SELECT id,account_code,account_name,archived,is_control,allow_manual_posting,system_key,system_account_key FROM public.accounting_accounts WHERE business_id=bid)a),
  'ledger',(SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.account_code),'[]') FROM public.v6170b_trial_balance('0001-01-01',asof)l),
  'documents',(SELECT coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('open_before_cutover',greatest(d.gross-d.paid_before-d.credits_before,0),'excess_credit',greatest(d.paid_before+d.credits_before-d.gross,0),'source_journals',d.source_journals) ORDER BY d.kind,d.date,d.reference,d.id),'[]') FROM docs d),
  'completed_imports',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',r.id,'batch_id',b.id,'cutover_date',b.cutover_date,'migration_mode',b.migration_mode,'kind',r.record_type,'reference',r.display_label,'commit_mode',r.commit_mode,'duplicate_action',r.duplicate_action,'imported_record_type',r.imported_record_type,'imported_record_id',r.imported_record_id,'source_date',r.normalized_data->>'date','source_total',r.normalized_data->'total','source_paid',r.normalized_data->'paid_amount','source_outstanding',r.normalized_data->'outstanding_amount','currency',r.normalized_data->>'currency') ORDER BY b.completed_at,r.id),'[]') FROM public.import_records r JOIN public.import_batches b ON b.id=r.batch_id AND b.business_id=r.business_id WHERE r.business_id=bid AND r.record_type IN ('invoices','expenses') AND b.status='completed'),
  'history_gaps',jsonb_build_object('invoice',(SELECT count(*) FROM public.customer_credit_notes WHERE business_id=bid AND credit_date<=asof AND lifecycle_state='voided' AND (voided_at IS NULL OR voided_at>=(p_cutover::timestamp AT TIME ZONE zone))),
   'expense',(SELECT count(*) FROM public.supplier_credits WHERE business_id=bid AND credit_date<=asof AND lifecycle_state='voided' AND (voided_at IS NULL OR voided_at>=(p_cutover::timestamp AT TIME ZONE zone)))),
  'settlements',jsonb_build_object(
   'customer_credits_before',coalesce((SELECT sum(total_amount) FROM public.customer_credit_notes WHERE business_id=bid AND lifecycle_state='issued' AND credit_date<=asof),0),
   'supplier_credits_before',coalesce((SELECT sum(total_amount) FROM public.supplier_credits WHERE business_id=bid AND lifecycle_state='recorded' AND credit_date<=asof),0),
   'customer_refunds_before',coalesce((SELECT sum(amount) FROM public.customer_refunds WHERE business_id=bid AND lifecycle_state='recorded' AND refund_date<=asof),0),
   'supplier_refunds_before',coalesce((SELECT sum(amount) FROM public.supplier_refunds WHERE business_id=bid AND lifecycle_state='recorded' AND refund_date<=asof),0)),
  'incomplete_batches',(SELECT count(*) FROM public.import_batches b WHERE b.business_id=bid AND b.status NOT IN ('completed','cancelled','failed')),
  'bank_control_accounts',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',a.id,'account_code',a.account_code,'account_name',a.account_name) ORDER BY a.account_code),'[]') FROM public.accounting_accounts a WHERE a.business_id=bid AND (a.system_account_key IN ('bank','cash','payment_clearing') OR a.system_key IN ('bank','cash','payment_clearing') OR a.account_subtype IN ('bank','cash')))
 ) INTO body;
 RETURN body||jsonb_build_object('snapshot_hash',encode(sha256(convert_to(body::text,'UTF8')),'hex'));
END;$f$;
REVOKE ALL ON FUNCTION public.v6228_starting_balance_evidence(date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6228_starting_balance_evidence(date) TO authenticated;
