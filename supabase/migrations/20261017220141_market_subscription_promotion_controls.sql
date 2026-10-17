-- Percentage offers for new subscription checkouts only. No billing-provider writes.
CREATE TABLE public.subscription_promotion_settings (
 singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
 enabled boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.subscription_promotion_settings(singleton) VALUES(true);
CREATE TABLE public.subscription_promotion_codes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 code text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]{2,31}$'),
 percent_off integer NOT NULL CHECK (percent_off BETWEEN 1 AND 100),
 duration text NOT NULL CHECK (duration IN ('once','forever')),
 billing_interval text NOT NULL CHECK (billing_interval IN ('monthly','annual','both')),
 expires_at timestamptz,
 enabled boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 created_by uuid NOT NULL REFERENCES auth.users(id)
);
CREATE TABLE public.subscription_promotion_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 created_at timestamptz NOT NULL DEFAULT now(),
 actor_id uuid NOT NULL REFERENCES auth.users(id),
 action text NOT NULL,
 details jsonb NOT NULL,
 revision bigint NOT NULL
);
ALTER TABLE public.subscription_promotion_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_promotion_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_promotion_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.subscription_promotion_settings,public.subscription_promotion_codes,public.subscription_promotion_audit FROM anon,authenticated;
GRANT SELECT ON public.subscription_promotion_settings,public.subscription_promotion_codes,public.subscription_promotion_audit TO authenticated;
GRANT SELECT ON public.subscription_promotion_settings,public.subscription_promotion_codes TO service_role;
CREATE POLICY promotion_settings_admin_read ON public.subscription_promotion_settings FOR SELECT TO authenticated USING ((SELECT public.is_super_admin()));
CREATE POLICY promotion_codes_admin_read ON public.subscription_promotion_codes FOR SELECT TO authenticated USING ((SELECT public.is_super_admin()));
CREATE POLICY promotion_audit_admin_read ON public.subscription_promotion_audit FOR SELECT TO authenticated USING ((SELECT public.is_super_admin()));

CREATE FUNCTION public.v6224_subscription_promotions(p_action text DEFAULT 'list',p_payload jsonb DEFAULT '{}',p_expected_revision bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE s public.subscription_promotion_settings%ROWTYPE; c public.subscription_promotion_codes%ROWTYPE; details jsonb; result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only Super Admin can manage subscription offers.' USING ERRCODE='42501'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('list','create','set_enabled','set_global') THEN RAISE EXCEPTION 'Unknown offer action.' USING ERRCODE='22023'; END IF;
 SELECT * INTO STRICT s FROM public.subscription_promotion_settings WHERE singleton FOR UPDATE;
 IF p_action<>'list' THEN
  IF p_expected_revision IS NULL OR p_expected_revision<>s.revision THEN RAISE EXCEPTION 'Offers changed in another session. Reload before saving.' USING ERRCODE='40001'; END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR octet_length(p_payload::text)>2048 THEN RAISE EXCEPTION 'Invalid offer settings.' USING ERRCODE='22023'; END IF;
  IF p_action='create' THEN
   IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('code','percent_off','duration','billing_interval','expires_at')) THEN RAISE EXCEPTION 'Unknown offer field.' USING ERRCODE='22023'; END IF;
   IF (p_payload->>'percent_off') IS NULL OR (p_payload->>'percent_off') !~ '^[0-9]{1,3}$' THEN RAISE EXCEPTION 'Use a whole percentage between 1 and 100.' USING ERRCODE='22023'; END IF;
   IF nullif(p_payload->>'expires_at','')::timestamptz<=clock_timestamp() THEN RAISE EXCEPTION 'Choose a future expiry time.' USING ERRCODE='22023'; END IF;
   INSERT INTO public.subscription_promotion_codes(code,percent_off,duration,billing_interval,expires_at,created_by)
    VALUES(upper(btrim(p_payload->>'code')),(p_payload->>'percent_off')::integer,p_payload->>'duration',p_payload->>'billing_interval',nullif(p_payload->>'expires_at','')::timestamptz,auth.uid()) RETURNING * INTO c;
   details:=to_jsonb(c);
  ELSE
   IF jsonb_typeof(p_payload->'enabled') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Choose enabled or disabled.' USING ERRCODE='22023'; END IF;
   IF p_action='set_global' THEN
    UPDATE public.subscription_promotion_settings SET enabled=(p_payload->>'enabled')::boolean WHERE singleton;
    details:=jsonb_build_object('enabled',(p_payload->>'enabled')::boolean);
   ELSE
    SELECT * INTO c FROM public.subscription_promotion_codes WHERE id=(p_payload->>'id')::uuid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found.' USING ERRCODE='22023'; END IF;
    IF (p_payload->>'enabled')::boolean AND c.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'This offer has expired. Create a new code.' USING ERRCODE='22023'; END IF;
    UPDATE public.subscription_promotion_codes SET enabled=(p_payload->>'enabled')::boolean WHERE id=c.id;
    details:=jsonb_build_object('id',c.id,'code',c.code,'enabled',(p_payload->>'enabled')::boolean);
   END IF;
  END IF;
  UPDATE public.subscription_promotion_settings SET revision=revision+1,updated_at=clock_timestamp() WHERE singleton RETURNING * INTO s;
  INSERT INTO public.subscription_promotion_audit(actor_id,action,details,revision) VALUES(auth.uid(),p_action,details,s.revision);
 END IF;
 SELECT jsonb_build_object('enabled',s.enabled,'revision',s.revision,'codes',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id) FROM public.subscription_promotion_codes x),'[]'::jsonb)) INTO result;
 RETURN result;
END;$fn$;
REVOKE ALL ON FUNCTION public.v6224_subscription_promotions(text,jsonb,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6224_subscription_promotions(text,jsonb,bigint) TO authenticated;

-- Safe public capability bit only; never expose codes or discount terms for guessing.
CREATE FUNCTION public.v6224_subscription_promotions_available() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 SELECT coalesce((SELECT enabled FROM public.subscription_promotion_settings WHERE singleton),false)
$fn$;
REVOKE ALL ON FUNCTION public.v6224_subscription_promotions_available() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.v6224_subscription_promotions_available() TO anon,authenticated;
