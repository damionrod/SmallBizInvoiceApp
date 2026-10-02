-- Phase 13A: post newly-finalised payroll into the formal accounting journal.
create or replace function public.v61105_phase13a_post_payroll_journal(p_pay_run_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid;
  v_run public.payroll_pay_runs%rowtype;
  v_existing uuid;
  v_direct_wages uuid;
  v_indirect_wages uuid;
  v_direct_employer uuid;
  v_indirect_employer uuid;
  v_direct_reimb uuid;
  v_indirect_reimb uuid;
  v_bank uuid;
  v_liability uuid;
  v_lines jsonb := '[]'::jsonb;
  v_direct_gross numeric := 0;
  v_indirect_gross numeric := 0;
  v_direct_employer_cost numeric := 0;
  v_indirect_employer_cost numeric := 0;
  v_direct_reimb_cost numeric := 0;
  v_indirect_reimb_cost numeric := 0;
  v_net numeric := 0;
  v_total_cost numeric := 0;
  v_liability_credit numeric := 0;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_bid := public.current_business_id();
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'payroll') then raise exception 'Payroll write access denied'; end if;

  select * into v_run
  from public.payroll_pay_runs
  where id=p_pay_run_id and business_id=v_bid;
  if v_run.id is null then raise exception 'Pay run not found in active business'; end if;
  if v_run.status <> 'finalised' then raise exception 'Only finalised payroll can be posted'; end if;

  select id into v_existing
  from public.accounting_journals
  where business_id=v_bid and source_type='payroll' and source_id=p_pay_run_id
    and posting_version=1 and status in ('posted','reversed')
  limit 1;
  if v_existing is not null then return v_existing; end if;

  -- Add only missing system accounts. Existing customer chart rows are never renamed or reclassified.
  insert into public.accounting_accounts(business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by)
  values
    (v_bid,'301','Direct Labour - Payroll','cost_of_sales','debit','cost_of_sales','payroll_direct_wages','301','DIRECTCOSTS','Direct employee wages allocated to service/job delivery.',true,false,auth.uid(),auth.uid()),
    (v_bid,'470','Wages and Salaries','expense','debit','expense','payroll_indirect_wages','470','EXPENSE','Indirect employee wages and salaries.',true,false,auth.uid(),auth.uid()),
    (v_bid,'302','Direct Employer Payroll Costs','cost_of_sales','debit','cost_of_sales','payroll_direct_employer_cost','302','DIRECTCOSTS','Employer payroll costs for direct labour.',true,false,auth.uid(),auth.uid()),
    (v_bid,'471','Employer Payroll Costs','expense','debit','expense','payroll_indirect_employer_cost','471','EXPENSE','Employer payroll costs for indirect labour.',true,false,auth.uid(),auth.uid()),
    (v_bid,'303','Direct Payroll Reimbursements','cost_of_sales','debit','cost_of_sales','payroll_direct_reimbursements','303','DIRECTCOSTS','Employee reimbursements and non-taxable allowances for direct labour.',true,false,auth.uid(),auth.uid()),
    (v_bid,'472','Payroll Reimbursements','expense','debit','expense','payroll_indirect_reimbursements','472','EXPENSE','Employee reimbursements and non-taxable allowances for indirect labour.',true,false,auth.uid(),auth.uid())
  on conflict (business_id,account_code) do nothing;

  select id into v_bank from public.accounting_accounts where business_id=v_bid and system_key='bank_main' and not archived order by account_code limit 1;
  select id into v_liability from public.accounting_accounts where business_id=v_bid and system_key='payroll_liability' and not archived order by account_code limit 1;
  select id into v_direct_wages from public.accounting_accounts where business_id=v_bid and system_key='payroll_direct_wages' and not archived limit 1;
  select id into v_indirect_wages from public.accounting_accounts where business_id=v_bid and system_key='payroll_indirect_wages' and not archived limit 1;
  select id into v_direct_employer from public.accounting_accounts where business_id=v_bid and system_key='payroll_direct_employer_cost' and not archived limit 1;
  select id into v_indirect_employer from public.accounting_accounts where business_id=v_bid and system_key='payroll_indirect_employer_cost' and not archived limit 1;
  select id into v_direct_reimb from public.accounting_accounts where business_id=v_bid and system_key='payroll_direct_reimbursements' and not archived limit 1;
  select id into v_indirect_reimb from public.accounting_accounts where business_id=v_bid and system_key='payroll_indirect_reimbursements' and not archived limit 1;
  if v_bank is null or v_liability is null or v_direct_wages is null or v_indirect_wages is null or v_direct_employer is null or v_indirect_employer is null or v_direct_reimb is null or v_indirect_reimb is null then
    raise exception 'Payroll accounting accounts are not available; payroll was not posted';
  end if;

  with emp as (
    select pre.id, pre.employee_id, coalesce(pre.gross_pay,0)::numeric gross,
           coalesce(pre.kiwisaver_employer_gross,0)::numeric employer_gross,
           coalesce(pre.reimbursements,0)::numeric reimbursements,
           coalesce(pre.total_employment_cost,0)::numeric total_cost,
           case when coalesce(e.labour_classification,'indirect')='direct' then 'direct' else 'indirect' end cls,
           coalesce((select sum(coalesce(l.amount,0)) from public.payroll_pay_run_lines l where l.pay_run_employee_id=pre.id and l.line_type='allowance' and coalesce(l.taxable,true)=false),0)::numeric tax_free_allowances,
           coalesce((select sum(coalesce(l.amount,0)) from public.payroll_pay_run_lines l where l.pay_run_employee_id=pre.id and l.line_type='contribution'),0)::numeric other_employer
    from public.payroll_pay_run_employees pre
    left join public.payroll_employees e on e.id=pre.employee_id and e.business_id=pre.business_id
    where pre.business_id=v_bid and pre.pay_run_id=p_pay_run_id
  )
  select
    coalesce(sum(gross) filter(where cls='direct'),0),
    coalesce(sum(gross) filter(where cls='indirect'),0),
    coalesce(sum(employer_gross+other_employer) filter(where cls='direct'),0),
    coalesce(sum(employer_gross+other_employer) filter(where cls='indirect'),0),
    coalesce(sum(reimbursements+tax_free_allowances) filter(where cls='direct'),0),
    coalesce(sum(reimbursements+tax_free_allowances) filter(where cls='indirect'),0),
    coalesce(sum(total_cost),0)
  into v_direct_gross,v_indirect_gross,v_direct_employer_cost,v_indirect_employer_cost,v_direct_reimb_cost,v_indirect_reimb_cost,v_total_cost
  from emp;

  v_net := round(coalesce(v_run.net_pay,0),2);
  v_total_cost := round(v_total_cost,2);
  v_liability_credit := round(v_total_cost-v_net,2);
  if v_total_cost <= 0 or v_net < 0 or v_liability_credit < 0 then raise exception 'Payroll totals are invalid for accounting posting'; end if;

  if round(v_direct_gross,2)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_direct_wages,'description','Direct payroll wages','debit',round(v_direct_gross,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_gross,2)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_indirect_wages,'description','Wages and salaries','debit',round(v_indirect_gross,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_direct_employer_cost,2)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_direct_employer,'description','Direct employer payroll costs','debit',round(v_direct_employer_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_employer_cost,2)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_indirect_employer,'description','Employer payroll costs','debit',round(v_indirect_employer_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_direct_reimb_cost,2)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_direct_reimb,'description','Direct payroll reimbursements','debit',round(v_direct_reimb_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_reimb_cost,2)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_indirect_reimb,'description','Payroll reimbursements','debit',round(v_indirect_reimb_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if v_net>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_bank,'description','Net payroll payment','debit',0,'credit',v_net,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if v_liability_credit>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_liability,'description','Payroll deductions and employer obligations','debit',0,'credit',v_liability_credit,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;

  return public.v6192_create_posted_journal(v_bid,v_run.pay_date,'payroll','payroll',p_pay_run_id,v_run.pay_run_number,'Payroll '||v_run.pay_run_number,v_lines);
end;
$$;

revoke execute on function public.v61105_phase13a_post_payroll_journal(uuid) from public, anon;
grant execute on function public.v61105_phase13a_post_payroll_journal(uuid) to authenticated;

create or replace function public.v61105_phase13a_payroll_finalise_posting_trigger()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status='finalised' and old.status is distinct from 'finalised' then
    perform public.v61105_phase13a_post_payroll_journal(new.id);
  end if;
  return new;
end;
$$;

revoke execute on function public.v61105_phase13a_payroll_finalise_posting_trigger() from public, anon, authenticated;

drop trigger if exists v61105_phase13a_post_payroll_journal on public.payroll_pay_runs;
create trigger v61105_phase13a_post_payroll_journal
after update of status on public.payroll_pay_runs
for each row execute function public.v61105_phase13a_payroll_finalise_posting_trigger();
