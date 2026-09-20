-- Read-only, tenant-scoped business summary for Finlo Helper.
create or replace function public.v6171c_helper_business_context()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid := public.current_business_id();
  v_from date := (current_date - interval '12 months')::date;
  v_result jsonb;
begin
  if v_business is null then raise exception 'No active business context'; end if;

  select jsonb_build_object(
    'generated_at', now(),
    'period_from', v_from,
    'business', (select jsonb_build_object('name', b.name, 'status', b.status) from businesses b where b.id=v_business),
    'customers', (select count(*) from customers c where c.business_id=v_business),
    'employees', (select count(*) from payroll_employees e where e.business_id=v_business and coalesce(e.archived,false)=false),
    'invoices', (select jsonb_build_object('count',count(*),'total',coalesce(sum(i.total),0),'paid',coalesce(sum(i.amount_paid),0),'balance_due',coalesce(sum(coalesce(i.balance_due,i.total-coalesce(i.amount_paid,0))),0),'overdue',coalesce(sum(case when i.due_date < current_date and coalesce(i.balance_due,i.total-coalesce(i.amount_paid,0)) > 0 then coalesce(i.balance_due,i.total-coalesce(i.amount_paid,0)) else 0 end),0)) from invoices i where i.business_id=v_business and coalesce(i.invoice_date,current_date)>=v_from),
    'expenses', (select jsonb_build_object('count',count(*),'total',coalesce(sum(e.total_amount),0),'gst',coalesce(sum(e.gst_amount),0),'outstanding',coalesce(sum(e.outstanding_balance),0)) from expenses e where e.business_id=v_business and coalesce(e.invoice_date,current_date)>=v_from and coalesce(e.archived,false)=false),
    'payroll', (select jsonb_build_object('pay_runs',count(*),'gross',coalesce(sum(p.gross_pay),0),'net',coalesce(sum(p.net_pay),0),'employment_cost',coalesce(sum(p.total_employment_cost),0)) from payroll_pay_runs p where p.business_id=v_business and coalesce(p.period_end,current_date)>=v_from),
    'jobs', (select jsonb_build_object('count',count(*),'expected_profit',coalesce(sum(j.expected_profit),0),'expected_margin',coalesce(avg(j.expected_margin_percent),0)) from job_costings j where j.business_id=v_business and coalesce(j.costing_date,current_date)>=v_from),
    'schedule', (select jsonb_build_object('count',count(*),'scheduled_value',coalesce(sum(s.scheduled_value),0),'upcoming',count(*) filter (where s.start_at >= now())) from job_schedules s where s.business_id=v_business and coalesce(s.start_at,current_date::timestamptz)>=v_from),
    'bank', (select jsonb_build_object('transactions',count(*),'unreconciled',count(*) filter (where coalesce(bt.status,'') not in ('reconciled','excluded')),'net',coalesce(sum(bt.amount),0)) from bank_transactions bt where bt.business_id=v_business and coalesce(bt.transaction_date,current_date)>=v_from),
    'gst', (select coalesce(jsonb_agg(jsonb_build_object('period_start',g.period_start,'period_end',g.period_end,'status',g.status,'gst_net',g.gst_net) order by g.period_end desc),'[]'::jsonb) from (select * from gst_returns where business_id=v_business order by period_end desc limit 6) g)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.v6171c_helper_business_context() from public;
revoke execute on function public.v6171c_helper_business_context() from anon;
grant execute on function public.v6171c_helper_business_context() to authenticated;
