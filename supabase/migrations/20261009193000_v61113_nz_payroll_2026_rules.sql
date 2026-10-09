-- v61.113: refresh NZ payroll statutory defaults for the 2026/27 year.
-- The app reads country_payroll_rules first and keeps payroll_country_rules as a legacy fallback.

do $$
declare
  v_table regclass;
  r record;
  v_updated integer;
begin
  for v_table in
    select x.table_name::regclass
    from (
      values (to_regclass('public.country_payroll_rules')),
             (to_regclass('public.payroll_country_rules'))
    ) as x(table_name)
    where x.table_name is not null
  loop
    for r in
      select *
      from (
        values
          ('NZ','acc','earners_levy_rate','2026-04-01'::date,null::date,1.75::numeric,null::text,null::jsonb,'ACC earners levy for the 2026/27 tax year.'),
          ('NZ','acc','max_earnings','2026-04-01'::date,null::date,156641::numeric,null::text,null::jsonb,'ACC maximum liable earnings for the 2026/27 tax year.'),
          ('NZ','kiwisaver','default_employee_rate','2026-04-01'::date,null::date,3.5::numeric,null::text,null::jsonb,'Default KiwiSaver employee rate for new 2026/27 enrolments.'),
          ('NZ','kiwisaver','default_employer_rate','2026-04-01'::date,null::date,3.5::numeric,null::text,null::jsonb,'Default KiwiSaver employer rate for new 2026/27 enrolments.'),
          ('NZ','minimum_wage','adult_hourly_rate','2026-04-01'::date,null::date,23.95::numeric,null::text,null::jsonb,'Adult minimum wage from 1 April 2026.'),
          ('NZ','minimum_wage','starting_out_hourly_rate','2026-04-01'::date,null::date,19.16::numeric,null::text,null::jsonb,'Starting-out minimum wage from 1 April 2026.'),
          ('NZ','minimum_wage','training_hourly_rate','2026-04-01'::date,null::date,19.16::numeric,null::text,null::jsonb,'Training minimum wage from 1 April 2026.'),
          ('NZ','paye','annual_brackets','2026-04-01'::date,null::date,null::numeric,null::text,'[
            {"max":15600,"rate":0.105},
            {"max":53500,"rate":0.175},
            {"max":78100,"rate":0.30},
            {"max":180000,"rate":0.33},
            {"max":null,"rate":0.39}
          ]'::jsonb,'PAYE annual income tax brackets for 2026/27 calculations.'),
          ('NZ','paye','secondary_rates','2026-04-01'::date,null::date,null::numeric,null::text,'{
            "SB":0.1225,
            "S":0.1925,
            "SH":0.3175,
            "ST":0.3475,
            "SA":0.4075,
            "CAE":0.1925,
            "EDW":0.1925,
            "NSW":0.1225,
            "ND":0.4675
          }'::jsonb,'Secondary and special PAYE rates used by the 2026/27 payroll engine.'),
          ('NZ','paye','ietc','2026-04-01'::date,null::date,null::numeric,null::text,'{
            "min_income":24000,
            "full_to":66000,
            "max_income":70000,
            "credit":520,
            "abatement":0.13
          }'::jsonb,'Independent earner tax credit parameters for 2026/27 calculations.'),
          ('NZ','paye','tax_codes','2026-04-01'::date,null::date,null::numeric,null::text,'[
            {"code":"M","label":"M","mode":"primary","ietc":false,"student_loan":false,"student_loan_threshold":true},
            {"code":"ME","label":"ME","mode":"primary","ietc":true,"student_loan":false,"student_loan_threshold":true},
            {"code":"M SL","label":"M SL","mode":"primary","ietc":false,"student_loan":true,"student_loan_threshold":true},
            {"code":"ME SL","label":"ME SL","mode":"primary","ietc":true,"student_loan":true,"student_loan_threshold":true},
            {"code":"SB","label":"SB","mode":"secondary","secondary_key":"SB","student_loan":false,"student_loan_threshold":false},
            {"code":"SB SL","label":"SB SL","mode":"secondary","secondary_key":"SB","student_loan":true,"student_loan_threshold":false},
            {"code":"S","label":"S","mode":"secondary","secondary_key":"S","student_loan":false,"student_loan_threshold":false},
            {"code":"S SL","label":"S SL","mode":"secondary","secondary_key":"S","student_loan":true,"student_loan_threshold":false},
            {"code":"SH","label":"SH","mode":"secondary","secondary_key":"SH","student_loan":false,"student_loan_threshold":false},
            {"code":"SH SL","label":"SH SL","mode":"secondary","secondary_key":"SH","student_loan":true,"student_loan_threshold":false},
            {"code":"ST","label":"ST","mode":"secondary","secondary_key":"ST","student_loan":false,"student_loan_threshold":false},
            {"code":"ST SL","label":"ST SL","mode":"secondary","secondary_key":"ST","student_loan":true,"student_loan_threshold":false},
            {"code":"SA","label":"SA","mode":"secondary","secondary_key":"SA","student_loan":false,"student_loan_threshold":false},
            {"code":"SA SL","label":"SA SL","mode":"secondary","secondary_key":"SA","student_loan":true,"student_loan_threshold":false},
            {"code":"CAE","label":"CAE","mode":"secondary","secondary_key":"CAE","student_loan":false,"student_loan_threshold":false},
            {"code":"CAE SL","label":"CAE SL","mode":"secondary","secondary_key":"CAE","student_loan":true,"student_loan_threshold":false},
            {"code":"EDW","label":"EDW","mode":"secondary","secondary_key":"EDW","student_loan":false,"student_loan_threshold":false},
            {"code":"EDW SL","label":"EDW SL","mode":"secondary","secondary_key":"EDW","student_loan":true,"student_loan_threshold":false},
            {"code":"NSW","label":"NSW","mode":"secondary","secondary_key":"NSW","student_loan":false,"student_loan_threshold":false},
            {"code":"ND","label":"ND","mode":"secondary","secondary_key":"ND","student_loan":false,"student_loan_threshold":false}
          ]'::jsonb,'Supported NZ tax-code profiles for 2026/27 calculations.'),
          ('NZ','student_loan','standard_rate','2026-04-01'::date,null::date,12::numeric,null::text,null::jsonb,'Student loan standard deduction rate for 2026/27 calculations.'),
          ('NZ','student_loan','annual_threshold','2026-04-01'::date,null::date,24128::numeric,null::text,null::jsonb,'Student loan annual repayment threshold used by 2026/27 payroll calculations.'),
          ('NZ','esct','annual_rates','2026-04-01'::date,null::date,null::numeric,null::text,'[
            {"max":18720,"rate":0.105},
            {"max":64200,"rate":0.175},
            {"max":93720,"rate":0.30},
            {"max":216000,"rate":0.33},
            {"max":null,"rate":0.39}
          ]'::jsonb,'ESCT annual threshold rates for 2026/27 calculations.'),
          ('NZ','holidays','payg_minimum_rate','2026-04-01'::date,null::date,8::numeric,null::text,null::jsonb,'Minimum PAYG annual holiday pay rate.')
      ) as x(country_code,rule_type,rule_key,effective_from,effective_to,numeric_value,text_value,json_value,source_note)
    loop
      execute format(
        'update %s
            set numeric_value=$1,
                text_value=$2,
                json_value=$3,
                effective_to=$4,
                active=true,
                source_note=$5
          where country_code=$6
            and rule_type=$7
            and rule_key=$8
            and effective_from=$9',
        v_table
      )
      using r.numeric_value,r.text_value,r.json_value,r.effective_to,r.source_note,r.country_code,r.rule_type,r.rule_key,r.effective_from;

      get diagnostics v_updated = row_count;

      if v_updated = 0 then
        execute format(
          'insert into %s
             (country_code, rule_type, rule_key, effective_from, effective_to, numeric_value, text_value, json_value, active, source_note)
           values ($1,$2,$3,$4,$5,$6,$7,$8,true,$9)',
          v_table
        )
        using r.country_code,r.rule_type,r.rule_key,r.effective_from,r.effective_to,r.numeric_value,r.text_value,r.json_value,r.source_note;
      end if;
    end loop;
  end loop;
end $$;
