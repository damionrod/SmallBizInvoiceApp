-- v61.106N: classify historical partial payroll allocations at employee level when unambiguous.
-- Accounting-neutral metadata correction only: no amounts, journals, GST, payroll or bank transactions are changed.
with candidates as (
  select a.id as allocation_id, min(pre.id::text)::uuid as employee_row_id, count(*) as match_count
  from public.bank_reconciliation_allocations a
  join public.payroll_pay_runs pr
    on pr.id=a.pay_run_id and pr.business_id=a.business_id
  join public.payroll_pay_run_employees pre
    on pre.pay_run_id=a.pay_run_id and pre.business_id=a.business_id
   and abs(coalesce(pre.net_pay,0)-coalesce(a.amount,0)) <= 0.01
  where a.allocation_type='payroll_pay_run'
    and a.pay_run_id is not null
    and a.pay_run_employee_id is null
    and abs(coalesce(a.amount,0)-coalesce(pr.net_pay,0)) > 0.01
  group by a.id
)
update public.bank_reconciliation_allocations a
set pay_run_employee_id=c.employee_row_id
from candidates c
where a.id=c.allocation_id and c.match_count=1 and a.pay_run_employee_id is null;
