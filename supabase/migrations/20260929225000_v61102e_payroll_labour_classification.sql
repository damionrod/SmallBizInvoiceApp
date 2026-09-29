alter table public.payroll_settings
  add column if not exists default_labour_classification text not null default 'indirect'
  check (default_labour_classification in ('direct','indirect'));

alter table public.payroll_employees
  add column if not exists labour_classification text
  check (labour_classification is null or labour_classification in ('direct','indirect'));

comment on column public.payroll_settings.default_labour_classification is 'Business default management-reporting classification for wages when no job is linked: direct or indirect.';
comment on column public.payroll_employees.labour_classification is 'Optional employee override for management-reporting wage classification when no job is linked. Null uses the business payroll default.';
