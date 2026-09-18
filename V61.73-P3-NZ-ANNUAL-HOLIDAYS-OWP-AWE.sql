-- V61.73-P3 — NZ Annual Holidays: statutory earnings classification + OWP/AWE
-- REVIEW PACKAGE ONLY. NOT APPLIED TO PRODUCTION.
-- Additive/prospective. Does not recalculate or mutate historical payroll.

begin;

-- Effective-dated statutory parameters used by the P3 calculation engine.
insert into public.country_payroll_rules(country_code,rule_type,rule_key,numeric_value,effective_from,effective_to,active,source_note)
values
('NZ','holidays','owp_formula_divisor_weeks',4,'2004-04-01',null,true,'Holidays Act 2003 s 8(2): OWP alternative formula divisor c = 4. https://www.legislation.govt.nz/act/public/2003/129/en/latest/sections/DLM236387/DLM236852'),
('NZ','holidays','awe_standard_divisor_weeks',52,'2004-04-01',null,true,'Employment New Zealand — Annual holiday pay: AWE is gross earnings over the prior 12 months divided by 52. https://www.employment.govt.nz/pay-and-hours/pay-and-wages/leave-and-holiday-pay/annual-holiday-pay'),
('NZ','holidays','awe_lookback_months',12,'2004-04-01',null,true,'Holidays Act 2003 s 21(2): AWE for the 12 months immediately before the end of the last pay period before annual holiday. https://www.legislation.govt.nz/act/public/2003/129/en/latest/sections/DLM236387/DLM236884')
on conflict (country_code,rule_type,rule_key,effective_from) do nothing;

insert into public.country_payroll_rules(country_code,rule_type,rule_key,text_value,effective_from,effective_to,active,source_note)
values
('NZ','holidays','annual_holiday_payment_selection','greater_of_owp_awe','2004-04-01',null,true,'Holidays Act 2003 s 21(2): annual holiday pay is based on the greater of OWP or AWE. https://www.legislation.govt.nz/act/public/2003/129/en/latest/sections/DLM236387/DLM236884')
on conflict (country_code,rule_type,rule_key,effective_from) do nothing;

-- P3 controlled earning codes. NOT VALID protects unexpected pre-existing P2 values while
-- enforcing the controlled vocabulary for new/updated rows. No historical item is rewritten
-- merely because it is taxable.
do $$ begin
  alter table public.payroll_pay_items add constraint payroll_pay_items_p3_statutory_earning_code_check
    check (statutory_earning_code is null or statutory_earning_code in (
      'ordinary_earnings','overtime','bonus','commission','allowance','reimbursement',
      'annual_holiday_payment','public_holiday_payment','alternative_holiday_payment',
      'sick_leave_payment','bereavement_leave_payment','family_violence_leave_payment',
      'first_week_acc_compensation','board_lodgings','other'
    )) not valid;
exception when duplicate_object then null; end $$;

-- Seed only classifications that are unambiguous from Finlo's built-in semantic item type/name.
-- Ambiguous items remain needs_confirmation; taxable is never used as the statutory classifier.
update public.payroll_pay_items
set statutory_earning_code='ordinary_earnings',
    holidays_gross_earnings_mode='include',
    owp_inclusion_mode='include',
    classification_notes=coalesce(classification_notes,'Finlo P3 built-in Ordinary Hours: wages are Holidays Act gross earnings and ordinary weekly earnings.')
where statutory_earning_code is null and item_type='earning' and name='Ordinary Hours';

update public.payroll_pay_items
set statutory_earning_code='overtime',
    holidays_gross_earnings_mode='include',
    owp_inclusion_mode='conditional',
    classification_notes=coalesce(classification_notes,'Finlo P3 built-in Overtime: included in Holidays Act gross earnings when employer is required to pay it; OWP inclusion depends on whether overtime is a regular part of pay.')
where statutory_earning_code is null and item_type='earning' and name='Overtime';

update public.payroll_pay_items
set statutory_earning_code='bonus',
    holidays_gross_earnings_mode='needs_confirmation',
    owp_inclusion_mode='needs_confirmation',
    classification_notes=coalesce(classification_notes,'Bonus treatment depends on whether the employer is bound to pay it and whether it is regular. Employer confirmation required.')
where statutory_earning_code is null and item_type='earning' and name='Bonus';

update public.payroll_pay_items
set statutory_earning_code='commission',
    holidays_gross_earnings_mode='needs_confirmation',
    owp_inclusion_mode='needs_confirmation',
    classification_notes=coalesce(classification_notes,'Commission/productivity treatment depends on contractual obligation and regularity. Employer confirmation required.')
where statutory_earning_code is null and item_type='earning' and name='Commission';

-- P3.1 hardening: reimbursement exclusion is not inferred from item_type alone.
-- A reimbursement item remains Needs confirmation until the employer has established
-- that it genuinely reimburses qualifying employment-related costs.
update public.payroll_pay_items
set statutory_earning_code='reimbursement',
    holidays_gross_earnings_mode='needs_confirmation',
    owp_inclusion_mode='needs_confirmation',
    classification_notes=coalesce(classification_notes,'Reimbursement treatment requires confirmation that the payment genuinely reimburses qualifying employment-related costs; item type or taxable status alone is not sufficient.')
where statutory_earning_code is null and item_type='reimbursement';

update public.payroll_pay_items
set statutory_earning_code='allowance',
    holidays_gross_earnings_mode='needs_confirmation',
    owp_inclusion_mode='needs_confirmation',
    classification_notes=coalesce(classification_notes,'Allowance treatment is not inferred from taxable status. Confirm contractual/gross-earnings treatment and regularity for OWP.')
where statutory_earning_code is null and item_type='allowance';

-- Explicit auditable P3 calculation fields. Existing P2 snapshots remain intact.
alter table public.payroll_statutory_leave_calculations
  add column if not exists owp_method text null,
  add column if not exists awe_period_start date null,
  add column if not exists awe_period_end date null,
  add column if not exists awe_gross_earnings numeric(14,2) null,
  add column if not exists awe_divisor numeric(12,4) null;

do $$ begin
  alter table public.payroll_statutory_leave_calculations add constraint payroll_stat_leave_p3_owp_method_check
    check (owp_method is null or owp_method in ('ordinary_week','statutory_formula','employment_agreement_rate'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.payroll_statutory_leave_calculations add constraint payroll_stat_leave_p3_awe_divisor_check
    check (awe_divisor is null or awe_divisor>0);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.payroll_statutory_leave_calculations add constraint payroll_stat_leave_p3_awe_dates_check
    check (awe_period_start is null or awe_period_end is null or awe_period_end>=awe_period_start);
exception when duplicate_object then null; end $$;

commit;
