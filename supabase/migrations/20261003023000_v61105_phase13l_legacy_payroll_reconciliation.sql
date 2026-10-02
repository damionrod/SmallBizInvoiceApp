-- Phase 13L: read-only legacy payroll evidence and accountant handoff gate.
create or replace function public.v61105_phase13l_legacy_payroll_review(p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare b uuid:=public.current_business_id();v jsonb;
begin
 if auth.uid() is null or b is null or p_from is null or p_to is null or p_from>p_to then raise exception 'Choose a business and valid review period';end if;
 if not public.v6169a_accountant_centre_access(b,false) then raise exception 'Accounting access denied';end if;
 with runs as(
 select p.id,p.pay_run_number,p.pay_date,round(p.gross_pay,2) gross_pay,round(p.total_deductions,2) deductions,round(p.net_pay,2) net_pay,round(p.total_employment_cost,2) employment_cost,
 round(coalesce(sum(e.reimbursements),0),2) reimbursements,round(p.gross_pay-p.total_deductions+coalesce(sum(e.reimbursements),0),2) expected_net,count(e.id) employee_count,
 (select count(*) from public.bank_transactions bt where bt.business_id=b and bt.amount=-p.net_pay and bt.transaction_date between p.pay_date-7 and p.pay_date+7) exact_bank_candidates
 from public.payroll_pay_runs p left join public.payroll_pay_run_employees e on e.pay_run_id=p.id and e.business_id=p.business_id
 where p.business_id=b and p.pay_date between p_from and p_to and p.status in('finalised','reversed') and p.finalised_at<timestamp '2026-10-01'
 and not exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='payroll' and j.source_id=p.id and j.status in('posted','reversed')) group by p.id)
 select jsonb_build_object('version','v61.105-phase13l','business_id',b,'period_start',p_from,'period_end',p_to,'legacy_payroll_count',count(*),'arithmetically_consistent_count',count(*) filter(where abs(net_pay-expected_net)<=0.005),'bank_evidence_found_count',count(*) filter(where exact_bank_candidates>0),'posting_recommendation','do_not_auto_post_without_independent_cash evidence','runs',coalesce(jsonb_agg(jsonb_build_object('pay_run_id',id,'pay_run_number',pay_run_number,'pay_date',pay_date,'gross_pay',gross_pay,'deductions',deductions,'reimbursements',reimbursements,'net_pay',net_pay,'expected_net',expected_net,'employment_cost',employment_cost,'employee_count',employee_count,'arithmetically_consistent',abs(net_pay-expected_net)<=0.005,'exact_bank_candidates',exact_bank_candidates,'classification',case when abs(net_pay-expected_net)>0.005 then 'legacy_payroll_data_review' when exact_bank_candidates=0 then 'legacy_payroll_unverified_cash_history' else 'legacy_payroll_bank_evidence_available' end) order by pay_date,pay_run_number),'[]'::jsonb)) into v from runs;return v;
end$$;
revoke execute on function public.v61105_phase13l_legacy_payroll_review(date,date) from public,anon;
grant execute on function public.v61105_phase13l_legacy_payroll_review(date,date) to authenticated;

do $$declare d text;begin select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='v61105_ledger_reconciliation';if d is null or strpos(d,'''legacy_pre_payroll_posting''')=0 then raise exception '13L reconciliation guard failed';end if;d:=replace(d,'''legacy_pre_payroll_posting''','''legacy_payroll_unverified_cash_history''');d:=replace(d,'''v61.105-phase13j''','''v61.105-phase13l''');execute d;end$$;
revoke execute on function public.v61105_ledger_reconciliation(date,date) from public,anon;
grant execute on function public.v61105_ledger_reconciliation(date,date) to authenticated;

do $$declare d text;begin select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='v61105_phase13i_accountant_handoff';if d is null or strpos(d,'and coalesce((v_recon->>''configuration_required_count'')::int,0)=0;')=0 then raise exception '13L handoff guard failed';end if;d:=replace(d,'and coalesce((v_recon->>''configuration_required_count'')::int,0)=0;','and coalesce((v_recon->>''configuration_required_count'')::int,0)=0 and coalesce((v_recon->>''legacy_review_count'')::int,0)=0;');d:=replace(d,'''v61.105-phase13j''','''v61.105-phase13l''');execute d;end$$;
revoke execute on function public.v61105_phase13i_accountant_handoff(date,date) from public,anon;
grant execute on function public.v61105_phase13i_accountant_handoff(date,date) to authenticated;
