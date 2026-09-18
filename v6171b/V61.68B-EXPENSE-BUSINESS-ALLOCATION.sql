-- Finlo V61.68B - Mobile-first expense business/private allocation
-- Additive only. Original supplier bill/payment fields remain unchanged.

alter table public.expenses
  add column if not exists business_use_percent numeric(5,2) not null default 100,
  add column if not exists business_use_amount numeric(14,2),
  add column if not exists private_use_amount numeric(14,2),
  add column if not exists business_ex_gst numeric(14,2),
  add column if not exists business_gst_amount numeric(14,2),
  add column if not exists allocation_method text not null default 'percentage',
  add column if not exists allocation_basis text,
  add column if not exists allocation_notes text;

alter table public.expenses drop constraint if exists expenses_business_use_percent_check;
alter table public.expenses add constraint expenses_business_use_percent_check check (business_use_percent >= 0 and business_use_percent <= 100);
alter table public.expenses drop constraint if exists expenses_allocation_method_check;
alter table public.expenses add constraint expenses_allocation_method_check check (allocation_method in ('percentage','business_amount'));
alter table public.expenses drop constraint if exists expenses_business_use_amount_check;
alter table public.expenses add constraint expenses_business_use_amount_check check (business_use_amount is null or business_use_amount >= 0);
alter table public.expenses drop constraint if exists expenses_private_use_amount_check;
alter table public.expenses add constraint expenses_private_use_amount_check check (private_use_amount is null or private_use_amount >= 0);

comment on column public.expenses.business_use_percent is 'Business-use allocation percentage. Original supplier bill fields remain unchanged.';
comment on column public.expenses.business_use_amount is 'GST-inclusive business-use portion of the original supplier bill.';
comment on column public.expenses.private_use_amount is 'GST-inclusive private/non-business portion of the original supplier bill.';
comment on column public.expenses.business_ex_gst is 'Business-use ex-GST portion; original ex_gst remains the supplier bill value.';
comment on column public.expenses.business_gst_amount is 'Business-use GST portion; original gst_amount remains the supplier bill GST.';
