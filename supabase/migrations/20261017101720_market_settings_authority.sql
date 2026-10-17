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
  incoming := p_settings - ARRAY['supabaseUrl','supabaseKey'];
  IF EXISTS(SELECT 1 FROM jsonb_each(incoming) e WHERE NOT(e.key=ANY(allowed)) AND e.value IS DISTINCT FROM coalesce(b.settings,'{}'::jsonb)->e.key) THEN
    RAISE EXCEPTION 'This setting has a dedicated editor. Reload and use that editor.' USING ERRCODE='22023';
  END IF;
  IF incoming ? '_settingsBusinessId' AND incoming->>'_settingsBusinessId' IS DISTINCT FROM p_business_id::text THEN
    RAISE EXCEPTION 'Settings belong to another business.' USING ERRCODE='42501';
  END IF;
  merged := (coalesce(b.settings,'{}'::jsonb) || incoming) - ARRAY['supabaseUrl','supabaseKey'];
  merged := merged || jsonb_build_object('_settingsBusinessId',p_business_id);
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
