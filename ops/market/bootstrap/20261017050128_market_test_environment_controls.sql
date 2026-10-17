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
CREATE OR REPLACE FUNCTION public.frindly_market_environment_status()
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog
AS $status$
  SELECT jsonb_build_object('environment','market','project_ref','smvvevrtjqkflyqkyape','outbound_services_enabled',false,'uses_existing_isolated_project',true);
$status$;
REVOKE ALL ON FUNCTION public.frindly_market_environment_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.frindly_market_environment_status() TO anon, authenticated, service_role;
ALTER TABLE public."_schema_clone_errors" ENABLE ROW LEVEL SECURITY;
UPDATE public.payment_provider_settings SET enabled=false, mode='test' WHERE enabled OR mode IS DISTINCT FROM 'test';
UPDATE public.finlo_helper_settings SET global_enabled=false, emergency_disabled=true WHERE global_enabled OR emergency_disabled IS DISTINCT FROM true;
UPDATE public.import_migration_settings SET ai_mapping_enabled=false WHERE ai_mapping_enabled;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
SELECT id,name,public,file_size_limit,allowed_mime_types
FROM jsonb_to_recordset($buckets$[{"id":"community-media","name":"community-media","public":true,"file_size_limit":5242880,"allowed_mime_types":["image/jpeg","image/png","image/webp","image/gif"]},{"id":"expense-documents","name":"expense-documents","public":false,"file_size_limit":10485760,"allowed_mime_types":["image/jpeg","image/png","image/webp","image/heic","image/heif","application/pdf"]},{"id":"frindly-avatars","name":"frindly-avatars","public":false,"file_size_limit":1048576,"allowed_mime_types":["image/jpeg"]},{"id":"frindly-documents","name":"frindly-documents","public":false,"file_size_limit":10485760,"allowed_mime_types":["application/pdf"]},{"id":"payroll-documents","name":"payroll-documents","public":false,"file_size_limit":10485760,"allowed_mime_types":["application/pdf","image/jpeg","image/png","image/webp","application/msword","application/vnd.openxmlformats-officedocument.wordprocessingml.document"]},{"id":"support-attachments","name":"support-attachments","public":false,"file_size_limit":5242880,"allowed_mime_types":["image/png","image/jpeg","image/webp","application/pdf"]}]$buckets$::jsonb)
AS b(id text,name text,public boolean,file_size_limit bigint,allowed_mime_types text[])
ON CONFLICT(id) DO NOTHING;
