-- v61.107C — IRD payday filing support.
-- Additive only: does not change payroll calculations, pay-run totals, journals or reconciliation.

alter table public.payroll_settings
  add column if not exists employer_ird_number text,
  add column if not exists payroll_contact_name text,
  add column if not exists payroll_contact_phone text,
  add column if not exists payroll_contact_email text,
  add column if not exists paye_intermediary_ird_number text,
  add column if not exists payroll_package_identifier text default 'Frindly_v61';

create table if not exists public.payroll_ird_filings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  pay_run_id uuid not null references public.payroll_pay_runs(id) on delete cascade,
  pay_date date not null,
  filing_method text not null check (filing_method in ('manual','file')),
  status text not null check (status in ('manual_viewed','file_downloaded','filed_in_myir','rejected_needs_correction','amended')),
  file_name text,
  file_hash text,
  ird_reference text,
  notes text,
  marked_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists payroll_ird_filings_business_run_idx
  on public.payroll_ird_filings(business_id, pay_run_id, created_at desc);

alter table public.payroll_ird_filings enable row level security;

drop policy if exists payroll_ird_filings_select_member on public.payroll_ird_filings;
create policy payroll_ird_filings_select_member
on public.payroll_ird_filings
for select to authenticated
using (business_id = public.current_business_id());

drop policy if exists payroll_ird_filings_insert_member on public.payroll_ird_filings;
create policy payroll_ird_filings_insert_member
on public.payroll_ird_filings
for insert to authenticated
with check (business_id = public.current_business_id());
