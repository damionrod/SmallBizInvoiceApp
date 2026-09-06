-- V56 Payroll usability additions only.
-- Safe additive migration for an existing V55 Payroll deployment.

alter table public.payroll_settings
  add column if not exists default_pay_day smallint not null default 5;

alter table public.payroll_settings
  drop constraint if exists payroll_settings_default_pay_day_check;
alter table public.payroll_settings
  add constraint payroll_settings_default_pay_day_check check(default_pay_day between 0 and 6);

notify pgrst,'reload schema';
