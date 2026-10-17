-- Market only. Restrict unclassified extra source columns as well as normalized payroll.
DO $$BEGIN IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;END$$;
CREATE OR REPLACE FUNCTION public.v6223_import_batch_access(p_batch uuid,p_write boolean DEFAULT false)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE bid uuid:=public.current_business_id(); typ text;
BEGIN
 IF auth.uid() IS NULL OR bid IS NULL OR NOT EXISTS(SELECT 1 FROM public.import_batches b WHERE b.id=p_batch AND b.business_id=bid)
 THEN RETURN false; END IF;
 -- Raw exports can contain extra columns that automatic record classification cannot prove safe.
 -- A source file belongs to its uploader; owners/admins can oversee business migrations.
 IF NOT EXISTS(SELECT 1 FROM public.import_batches b WHERE b.id=p_batch AND b.business_id=bid
   AND (b.user_id=auth.uid() OR public.v6147_can_read_area(bid,'business_settings'))) THEN RETURN false;END IF;
 IF p_write THEN
  IF NOT coalesce(public.v6147_can_write_area(bid,'core'),false) THEN RETURN false; END IF;
 ELSE
  IF NOT coalesce(public.v6147_can_read_area(bid,'core'),false) THEN RETURN false; END IF;
 END IF;
 FOR typ IN
  SELECT s.detected_record_type FROM public.import_sheets s WHERE s.batch_id=p_batch AND s.business_id=bid
  UNION SELECT r.record_type FROM public.import_records r WHERE r.batch_id=p_batch AND r.business_id=bid
  UNION SELECT r.record_type FROM public.import_rows r WHERE r.batch_id=p_batch AND r.business_id=bid AND r.record_type IS NOT NULL
 LOOP
  IF typ='unknown' THEN
   IF NOT EXISTS(SELECT 1 FROM public.import_batches b WHERE b.id=p_batch AND b.business_id=bid AND (b.user_id=auth.uid() OR public.v6147_can_read_area(bid,'business_settings'))) THEN RETURN false; END IF;
  ELSIF NOT public.v6223_import_type_access(bid,typ,p_write) THEN RETURN false; END IF;
 END LOOP;
 RETURN true;
END$$;

