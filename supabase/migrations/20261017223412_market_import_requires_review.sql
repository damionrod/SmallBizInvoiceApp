CREATE OR REPLACE FUNCTION public.v6225_validate_import_evidence(p_batch uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE expected bigint;actual bigint;distinct_rows bigint;bid uuid;
BEGIN
 SELECT business_id INTO bid FROM public.import_batches WHERE id=p_batch;
 IF EXISTS(SELECT 1 FROM public.import_batches WHERE id=p_batch AND mapping_version='v62.25-staging') THEN RAISE EXCEPTION 'Build the review before confirming this import.' USING ERRCODE='22023';END IF;
 IF bid IS NULL THEN RAISE EXCEPTION 'Import batch not found.' USING ERRCODE='22023';END IF;
 SELECT count(*) INTO expected FROM public.import_rows WHERE batch_id=p_batch;
 SELECT count(*),count(DISTINCT import_row_id) INTO actual,distinct_rows FROM public.import_record_members WHERE batch_id=p_batch;
 IF expected<>actual OR expected<>distinct_rows OR EXISTS(
  SELECT 1 FROM public.import_record_members m
  LEFT JOIN public.import_rows raw ON raw.id=m.import_row_id
  LEFT JOIN public.import_records r ON r.id=m.import_record_id
  WHERE m.batch_id=p_batch AND (m.business_id IS DISTINCT FROM bid OR raw.batch_id IS DISTINCT FROM p_batch OR r.batch_id IS DISTINCT FROM p_batch OR raw.business_id IS DISTINCT FROM bid OR r.business_id IS DISTINCT FROM bid OR raw.sheet_id IS DISTINCT FROM r.sheet_id)
 ) THEN RAISE EXCEPTION 'This review does not account for every source row. Rebuild the review before confirming.' USING ERRCODE='22023';END IF;
END;$fn$;
REVOKE ALL ON FUNCTION public.v6225_validate_import_evidence(uuid) FROM PUBLIC,anon,authenticated,service_role;
