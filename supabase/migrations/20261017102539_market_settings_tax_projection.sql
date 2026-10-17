-- Dedicated Tax settings are the only GST writer. Ordinary preferences preserve existing tax projections.
-- Market-only rollout: one locked, revision-checked settings save and redacted audit.
-- Legacy tax/bank projections remain compatible until their dedicated forms migrate.
CREATE OR REPLACE FUNCTION public.v6221_save_business_settings(
  p_business_id uuid, p_expected_updated_at timestamptz, p_settings jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  b public.businesses%ROWTYPE;
  incoming jsonb;
  merged jsonb;
  changed text[];
  allowed text[] := ARRAY['company','trading','address','phone','email','website','gstNumber','dueDays','invoicePrefix','currency','outboundEmail','gstRate','extraFeeEnabled','extraFeeLabel','extraFeeRate','bankAccounts','bankAccount','products','template','theme','primaryColor','accentColor','logoData','emailSettings','quoteEmailSettings','reminderEmailSettings','autoPaymentReminders','invoiceText','jobCostingSettings','latePaymentFees','helperNameOverride','_settingsBusinessId'];
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS DISTINCT FROM public.current_business_id()
    OR NOT public.v6147_can_write_area(p_business_id,'business_settings') THEN
    RAISE EXCEPTION 'You do not have permission to change these business settings.' USING ERRCODE='42501';
  END IF;
  IF p_settings IS NULL OR jsonb_typeof(p_settings)<>'object' OR octet_length(p_settings::text)>2097152 THEN
    RAISE EXCEPTION 'Settings must be an object smaller than 2 MB.' USING ERRCODE='22023';
  END IF;
  SELECT * INTO b FROM public.businesses WHERE id=p_business_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Business not found.'; END IF;
  IF p_expected_updated_at IS NULL OR b.updated_at IS DISTINCT FROM p_expected_updated_at THEN
    RAISE EXCEPTION 'Settings changed in another session. Reload Settings before saving again.' USING ERRCODE='40001';
  END IF;
  incoming := p_settings - ARRAY['supabaseUrl','supabaseKey','bankAccounts','bankAccount','gstNumber','gstRate'];
  IF EXISTS(SELECT 1 FROM jsonb_each(incoming) e WHERE NOT(e.key=ANY(allowed)) AND e.value IS DISTINCT FROM coalesce(b.settings,'{}'::jsonb)->e.key) THEN
    RAISE EXCEPTION 'This setting has a dedicated editor. Reload and use that editor.' USING ERRCODE='22023';
  END IF;
  IF incoming ? '_settingsBusinessId' AND incoming->>'_settingsBusinessId' IS DISTINCT FROM p_business_id::text THEN
    RAISE EXCEPTION 'Settings belong to another business.' USING ERRCODE='42501';
  END IF;
  merged := (coalesce(b.settings,'{}'::jsonb) || incoming) - ARRAY['supabaseUrl','supabaseKey'];
  merged := merged || jsonb_build_object('_settingsBusinessId',p_business_id);
  IF EXISTS(SELECT 1 FROM public.bank_accounts WHERE business_id=p_business_id) THEN
    merged:=merged||jsonb_build_object('bankAccounts',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',x.name,'account',coalesce(x.account_number,''),'isDefault',x.is_default) ORDER BY x.is_default DESC,x.name,x.id),'[]'::jsonb) FROM public.bank_accounts x WHERE x.business_id=p_business_id AND NOT coalesce(x.archived,false) AND x.currency=coalesce(merged->>'currency','NZD')));
  END IF;
  SELECT array_agg(e.key ORDER BY e.key) INTO changed FROM jsonb_each(merged) e WHERE e.value IS DISTINCT FROM coalesce(b.settings,'{}'::jsonb)->e.key;
  UPDATE public.businesses SET settings=merged,
    name=CASE WHEN incoming ? 'company' AND nullif(btrim(incoming->>'company'),'') IS NOT NULL THEN incoming->>'company' ELSE name END,
    address=CASE WHEN incoming ? 'address' THEN incoming->>'address' ELSE address END,
    phone=CASE WHEN incoming ? 'phone' THEN incoming->>'phone' ELSE phone END,
    updated_at=clock_timestamp()
  WHERE id=p_business_id RETURNING * INTO b;
  INSERT INTO public.financial_audit_log(business_id,entity_type,entity_id,action,after_data,created_by)
    VALUES(p_business_id,'business_settings',p_business_id,'settings_updated',jsonb_build_object('changed_fields',coalesce(changed,ARRAY[]::text[])),auth.uid());
  RETURN jsonb_build_object('id',b.id,'name',b.name,'address',b.address,'phone',b.phone,'settings',b.settings,'updated_at',b.updated_at);
END;
$fn$;
REVOKE ALL ON FUNCTION public.v6221_save_business_settings(uuid,timestamptz,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6221_save_business_settings(uuid,timestamptz,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.v6221_save_tax_settings(p_business_id uuid,p_expected_business_updated_at timestamptz,p_expected_financial_updated_at timestamptz,p_values jsonb,p_mappings jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE b public.businesses%ROWTYPE; f public.financial_settings%ROWTYPE; prior_f public.financial_settings%ROWTYPE; v public.financial_settings%ROWTYPE;
 country text; effective date; on_date date; prior_status jsonb; current_status jsonb; ignored jsonb; next_date date; inv_ids uuid[]; exp_ids uuid[]; m jsonb; affected integer;
BEGIN
 IF auth.uid() IS NULL OR p_business_id IS DISTINCT FROM public.current_business_id() OR NOT public.v6147_can_write_area(p_business_id,'financials') THEN RAISE EXCEPTION 'Financial settings access denied.' USING ERRCODE='42501'; END IF;
 IF jsonb_typeof(p_values) IS DISTINCT FROM 'object' OR jsonb_typeof(p_mappings) IS DISTINCT FROM 'array' OR jsonb_array_length(p_mappings)>500 THEN RAISE EXCEPTION 'Invalid financial settings request.' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_values) k WHERE k NOT IN ('financial_year_start_month','financial_year_start_day','default_report_period','business_entity_type','estimated_tax_rate','provisional_tax_enabled','gst_registered','gst_number','gst_accounting_basis','gst_filing_frequency','balance_date_month','balance_date_day','effective_from')) THEN RAISE EXCEPTION 'Unknown financial settings field.' USING ERRCODE='22023'; END IF;
 SELECT * INTO b FROM public.businesses WHERE id=p_business_id FOR UPDATE;
 IF p_expected_business_updated_at IS NULL OR b.updated_at IS DISTINCT FROM p_expected_business_updated_at THEN RAISE EXCEPTION 'Business settings changed. Reload before saving.' USING ERRCODE='40001'; END IF;
 SELECT * INTO f FROM public.financial_settings WHERE business_id=p_business_id FOR UPDATE;
 IF f.updated_at IS DISTINCT FROM p_expected_financial_updated_at THEN RAISE EXCEPTION 'Financial settings changed. Reload before saving.' USING ERRCODE='40001'; END IF;
 IF f.id IS NULL THEN
   INSERT INTO public.financial_settings(business_id,updated_by) VALUES(p_business_id,auth.uid()) RETURNING * INTO f;
 END IF;
 prior_f:=f;
 v:=jsonb_populate_record(f,p_values-'effective_from');effective:=(p_values->>'effective_from')::date;
 country:=upper(coalesce(b.settings->>'country','NZ'));on_date:=(clock_timestamp() AT TIME ZONE CASE WHEN country='AU' THEN 'Australia/Sydney' ELSE 'Pacific/Auckland' END)::date;
 IF country NOT IN ('NZ','AU') OR effective IS NULL THEN RAISE EXCEPTION 'Review your business country and effective date.' USING ERRCODE='22023'; END IF;
 IF v.financial_year_start_month NOT BETWEEN 1 AND 12 OR v.financial_year_start_day NOT BETWEEN 1 AND 28 OR v.estimated_tax_rate NOT BETWEEN 0 AND 100 OR v.default_report_period NOT IN ('this_month','last_month','this_quarter','last_quarter','fytd','current_fy','previous_fy','3','6','12','custom') THEN RAISE EXCEPTION 'Review your reporting dates and planning rate.' USING ERRCODE='22023'; END IF;
 IF v.business_entity_type NOT IN ('company','sole_trader','partnership','trust','other') THEN RAISE EXCEPTION 'Review the business entity type.' USING ERRCODE='22023'; END IF;
 IF v.balance_date_month NOT BETWEEN 1 AND 12 OR v.balance_date_day<1 OR v.balance_date_day>extract(day FROM (make_date(2000,v.balance_date_month,1)+interval '1 month - 1 day')) THEN RAISE EXCEPTION 'Invalid balance date.' USING ERRCODE='22023'; END IF;
 IF (v.financial_year_start_month<>f.financial_year_start_month OR v.financial_year_start_day<>f.financial_year_start_day) AND EXISTS(SELECT 1 FROM public.accounting_periods WHERE business_id=p_business_id) THEN RAISE EXCEPTION 'Financial year cannot change while accounting periods exist. Ask your accountant to review the periods.'; END IF;
 prior_status:=public.v61105_effective_tax_status(effective);
 UPDATE public.financial_settings SET financial_year_start_month=v.financial_year_start_month,financial_year_start_day=v.financial_year_start_day,default_report_period=v.default_report_period,business_entity_type=v.business_entity_type,estimated_tax_rate=v.estimated_tax_rate,provisional_tax_enabled=v.provisional_tax_enabled,updated_at=clock_timestamp(),updated_by=auth.uid() WHERE id=f.id;
 IF country='NZ' THEN
   ignored:=public.v6170e_set_gst_settings(v.gst_registered,v.gst_number,v.gst_accounting_basis,v.gst_filing_frequency,v.balance_date_month,v.balance_date_day,effective);
 ELSE
   ignored:=public.v6170f_set_bas_settings(v.gst_registered,v.gst_number,p_values->>'gst_accounting_basis',p_values->>'gst_filing_frequency',v.balance_date_month,v.balance_date_day,effective);
 END IF;
 -- A future history entry must not become today's invoice or reporting defaults.
 IF effective>on_date THEN
   UPDATE public.financial_settings SET gst_registered=prior_f.gst_registered,gst_number=prior_f.gst_number,gst_accounting_basis=prior_f.gst_accounting_basis,gst_filing_frequency=prior_f.gst_filing_frequency,balance_date_month=prior_f.balance_date_month,balance_date_day=prior_f.balance_date_day WHERE id=f.id;
 END IF;
 current_status:=public.v61105_effective_tax_status(on_date);
 UPDATE public.financial_settings SET gst_registered=(current_status->>'gst_registered')::boolean,gst_number=current_status->>'tax_identifier',gst_accounting_basis=CASE WHEN country='AU' THEN CASE WHEN current_status->>'accounting_basis'='cash' THEN 'payments' ELSE 'invoice' END ELSE current_status->>'accounting_basis' END,gst_filing_frequency=CASE WHEN country='AU' THEN CASE WHEN current_status->>'filing_frequency'='monthly' THEN 'monthly' ELSE 'two_monthly' END ELSE current_status->>'filing_frequency' END,
 balance_date_month=coalesce((SELECT balance_date_month FROM public.gst_settings_history WHERE business_id=p_business_id AND jurisdiction=country AND effective_from<=on_date ORDER BY effective_from DESC LIMIT 1),prior_f.balance_date_month),
 balance_date_day=coalesce((SELECT balance_date_day FROM public.gst_settings_history WHERE business_id=p_business_id AND jurisdiction=country AND effective_from<=on_date ORDER BY effective_from DESC LIMIT 1),prior_f.balance_date_day),updated_at=clock_timestamp(),updated_by=auth.uid() WHERE id=f.id;

 UPDATE public.businesses SET settings=coalesce(settings,'{}'::jsonb)||jsonb_build_object('gstNumber',current_status->>'tax_identifier','gstRate',(current_status->>'effective_rate_percent')::numeric),updated_at=clock_timestamp() WHERE id=p_business_id RETURNING * INTO b;
 IF country='NZ' AND (prior_status->>'gst_registered')::boolean IS DISTINCT FROM v.gst_registered THEN
   SELECT min(effective_from) INTO next_date FROM public.gst_settings_history WHERE business_id=p_business_id AND jurisdiction='NZ' AND effective_from>effective;
   SELECT coalesce(array_agg(id),ARRAY[]::uuid[]) INTO inv_ids FROM public.invoices WHERE business_id=p_business_id AND invoice_date>=effective AND (next_date IS NULL OR invoice_date<next_date) AND CASE WHEN v.gst_registered THEN coalesce(gst,0)<=0 ELSE coalesce(gst,0)>0 END;
   SELECT coalesce(array_agg(id),ARRAY[]::uuid[]) INTO exp_ids FROM public.expenses WHERE business_id=p_business_id AND invoice_date>=effective AND (next_date IS NULL OR invoice_date<next_date) AND CASE WHEN v.gst_registered THEN gst_treatment='no_gst' OR coalesce(gst_amount,0)<=0 ELSE coalesce(gst_amount,0)>0 END;
   INSERT INTO public.gst_transition_reviews(business_id,jurisdiction,effective_from,previous_registered,new_registered,window_end,affected_invoice_ids,affected_expense_ids,invoice_count,expense_count,status,created_by) VALUES(p_business_id,'NZ',effective,(prior_status->>'gst_registered')::boolean,v.gst_registered,next_date,inv_ids,exp_ids,cardinality(inv_ids),cardinality(exp_ids),'open',auth.uid());
 END IF;
 FOR m IN SELECT value FROM jsonb_array_elements(p_mappings) LOOP
   IF jsonb_typeof(m) IS DISTINCT FROM 'object' OR m->>'classification' NOT IN ('revenue','direct_cost','indirect_cost','asset','liability','tax','equity','other') THEN RAISE EXCEPTION 'Invalid account classification.' USING ERRCODE='22023'; END IF;
   UPDATE public.financial_category_mappings SET classification=m->>'classification',updated_at=clock_timestamp(),updated_by=auth.uid() WHERE id=(m->>'id')::uuid AND business_id=p_business_id;
   GET DIAGNOSTICS affected=ROW_COUNT;IF affected<>1 THEN RAISE EXCEPTION 'Account mapping belongs to another business or was removed.' USING ERRCODE='42501'; END IF;
 END LOOP;
 PERFORM public.frindly_ensure_accounting_period(p_business_id,on_date);
 SELECT * INTO f FROM public.financial_settings WHERE id=f.id;
 INSERT INTO public.financial_audit_log(business_id,entity_type,entity_id,action,after_data,created_by) VALUES(p_business_id,'financial_settings',f.id,'settings_updated',jsonb_build_object('effective_from',effective,'jurisdiction',country,'mapping_count',jsonb_array_length(p_mappings)),auth.uid());
 RETURN jsonb_build_object('business',jsonb_build_object('id',b.id,'settings',b.settings,'updated_at',b.updated_at),'financial_settings',to_jsonb(f),'effective_from',effective,'current_tax_status',current_status);
END;
$fn$;
REVOKE ALL ON FUNCTION public.v6221_save_tax_settings(uuid,timestamptz,timestamptz,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6221_save_tax_settings(uuid,timestamptz,timestamptz,jsonb,jsonb) TO authenticated;
