begin;
create table if not exists public.payroll_historical_payroll_evidence(
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 employee_id uuid not null references public.payroll_employees(id) on delete cascade,
 period_start date not null, period_end date not null, pay_date date not null,
 gross_earnings numeric(14,2) not null default 0, paye numeric(14,2) not null default 0,
 kiwisaver_employee numeric(14,2) not null default 0, kiwisaver_employer numeric(14,2) not null default 0,
 student_loan numeric(14,2) not null default 0, other_deductions numeric(14,2) not null default 0,
 paid_hours numeric(12,2) not null default 0, source_reference text, evidence_status text not null default 'imported_review' check(evidence_status in ('sample','imported_review','verified')),
 created_at timestamptz not null default now(), created_by uuid default auth.uid(), unique(business_id,employee_id,period_start,period_end,pay_date)
);
create index if not exists payroll_hist_ev_lookup on public.payroll_historical_payroll_evidence(business_id,employee_id,period_end);
alter table public.payroll_historical_payroll_evidence enable row level security;
create policy payroll_hist_ev_select on public.payroll_historical_payroll_evidence for select using (business_id=public.current_business_id());
create policy payroll_hist_ev_write on public.payroll_historical_payroll_evidence for all using (business_id=public.current_business_id() and public.v6147_can_write_area(business_id,'payroll')) with check (business_id=public.current_business_id() and public.v6147_can_write_area(business_id,'payroll'));
commit;
