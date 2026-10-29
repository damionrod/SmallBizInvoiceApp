-- ACC source monitoring and review-only levy caps. No payroll rules activated by this migration.
INSERT INTO public.payroll_compliance_sources(country_code,source_name,source_type,source_url,source_identifier,purpose,active,check_frequency)
SELECT 'NZ','Accident Compensation Corporation','official_web_page','https://www.acc.co.nz/about-us/our-levies-2/levy-results','acc-levy-results','Maximum liable earnings for ACC Work levy',true,'daily'
WHERE NOT EXISTS (SELECT 1 FROM public.payroll_compliance_sources WHERE source_identifier='acc-levy-results');
DO $$
DECLARE y record; rid uuid;
BEGIN
 FOR y IN SELECT * FROM (VALUES
 ('2025/26'::text,'2025-04-01'::date,'2026-03-31'::date,152790::numeric),
 ('2026/27','2026-04-01'::date,'2027-03-31'::date,156641::numeric),
 ('2027/28','2027-04-01'::date,'2028-03-31'::date,160244::numeric)
 ) AS t(levy_year,start_date,end_date,earnings_cap)
 LOOP
  IF NOT EXISTS (SELECT 1 FROM public.country_payroll_rules WHERE country_code='NZ' AND rule_type='acc' AND rule_key='maximum_liable_earnings' AND effective_from=y.start_date AND active=true)
  AND NOT EXISTS (SELECT 1 FROM public.payroll_rulesets WHERE country_code='NZ' AND name='ACC Maximum Liable Earnings' AND version=y.levy_year)
  THEN
   INSERT INTO public.payroll_rulesets(country_code,name,version,effective_from,effective_to,status)
   VALUES ('NZ','ACC Maximum Liable Earnings',y.levy_year,y.start_date,y.end_date,'draft') RETURNING id INTO rid;
   INSERT INTO public.payroll_ruleset_rules(ruleset_id,rule_type,rule_key,numeric_value,source_note)
   VALUES (rid,'acc','maximum_liable_earnings',y.earnings_cap,'ACC official levy results: https://www.acc.co.nz/about-us/our-levies-2/levy-results');
  END IF;
 END LOOP;
END $$;