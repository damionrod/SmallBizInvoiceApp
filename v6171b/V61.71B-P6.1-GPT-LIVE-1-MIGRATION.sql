-- V61.71B-P6.1 — narrow Finlo Live Voice engine migration only.
-- Preserves entitlements, limits, usage, privacy and all accounting data.

ALTER TABLE public.finlo_live_voice_settings
  ALTER COLUMN model SET DEFAULT 'gpt-live-1';

UPDATE public.finlo_live_voice_settings
SET model = 'gpt-live-1', updated_at = now()
WHERE id = true AND model IN ('gpt-realtime-2.1-mini','gpt-realtime-2.1');

CREATE OR REPLACE FUNCTION public.v6171b_p6_admin_live_voice_save(
  p_enabled boolean,
  p_emergency boolean,
  p_model text,
  p_voice text,
  p_max_minutes integer,
  p_monthly_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
  IF NOT is_super_admin() THEN
    RAISE EXCEPTION 'Super admin required' USING errcode='42501';
  END IF;
  IF p_model <> 'gpt-live-1' THEN
    RAISE EXCEPTION 'Unsupported Live Voice model';
  END IF;
  IF coalesce(trim(p_voice),'')='' THEN
    RAISE EXCEPTION 'Voice required';
  END IF;
  UPDATE finlo_live_voice_settings
  SET global_enabled=p_enabled,
      emergency_disabled=p_emergency,
      model='gpt-live-1',
      voice=trim(p_voice),
      max_session_minutes=greatest(1,least(p_max_minutes,60)),
      monthly_session_limit=greatest(0,p_monthly_limit),
      updated_at=now(),
      updated_by=auth.uid()
  WHERE id=true;
  RETURN (SELECT to_jsonb(s) FROM finlo_live_voice_settings s WHERE id=true);
END $$;

REVOKE ALL ON FUNCTION public.v6171b_p6_admin_live_voice_save(boolean,boolean,text,text,integer,integer) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.v6171b_p6_admin_live_voice_save(boolean,boolean,text,text,integer,integer) TO authenticated;
