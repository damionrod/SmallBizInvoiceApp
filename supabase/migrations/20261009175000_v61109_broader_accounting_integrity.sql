-- v61.109: broader accounting integrity hardening.
--
-- Scope:
-- - Future payroll finalisation posts net wages to Payroll Net Payable instead
--   of directly to bank.
-- - Bank reconciliation clears payroll payable and IRD/PAYE liabilities against
--   the actual imported bank account.
-- - Owner/equity bank reconciliation uses the actual imported bank account and
--   posts with an allowed journal type.
-- - Existing posted journals are not rewritten.

insert into public.accounting_accounts (
  business_id, account_code, account_name, account_type, account_subtype,
  normal_balance, tax_default, system_account_key, system_key,
  allow_manual_posting, report_section, is_system, is_control,
  xero_account_code, xero_account_type, xero_tax_type, description
)
select
  b.id, x.account_code, x.account_name, x.account_type, x.account_subtype,
  x.normal_balance, 'NO_GST', x.system_account_key, x.system_key,
  x.allow_manual_posting, x.report_section, true, x.is_control,
  x.account_code, x.xero_account_type, 'NONE', x.description
from public.businesses b
cross join (values
  ('266','Payroll Net Payable','liability','payroll','credit','payroll_net_payable','payroll_net_payable',false,'current_liabilities','CURRLIAB','Net wages payable until the bank payment is reconciled.',true),
  ('267','IRD / PAYE Payable','liability','payroll_tax','credit','payroll_liability','payroll_liability',false,'current_liabilities','CURRLIAB','PAYE, KiwiSaver, ESCT and other payroll obligations payable to IRD or similar agencies.',true)
) as x(account_code,account_name,account_type,account_subtype,normal_balance,system_account_key,system_key,allow_manual_posting,report_section,xero_account_type,description,is_control)
where not exists (
  select 1 from public.accounting_accounts a
  where a.business_id = b.id
    and (
      a.account_code = x.account_code
      or a.system_account_key = x.system_account_key
      or a.system_key = x.system_key
    )
);

create or replace function public.v61109_bank_accounting_account(
  p_business_id uuid,
  p_bank_transaction_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_bank_account public.bank_accounts%rowtype;
  v_account uuid;
  v_code text;
begin
  if p_business_id is null or p_bank_transaction_id is null then
    return null;
  end if;

  select ba.* into v_bank_account
  from public.bank_transactions bt
  join public.bank_accounts ba
    on ba.id = bt.bank_account_id
   and ba.business_id = bt.business_id
  where bt.id = p_bank_transaction_id
    and bt.business_id = p_business_id;

  if v_bank_account.id is null then
    return null;
  end if;

  if v_bank_account.accounting_account_id is not null then
    select a.id into v_account
    from public.accounting_accounts a
    where a.id = v_bank_account.accounting_account_id
      and a.business_id = p_business_id
      and not coalesce(a.archived, false);
    if v_account is not null then
      return v_account;
    end if;
  end if;

  select a.id into v_account
  from public.accounting_accounts a
  where a.business_id = p_business_id
    and not coalesce(a.archived, false)
    and a.account_type = 'asset'
    and a.account_subtype = 'bank'
    and lower(a.account_name) = lower(v_bank_account.name)
  limit 1;

  if v_account is null then
    select gs::text into v_code
    from generate_series(1000, 1099) gs
    where not exists (
      select 1 from public.accounting_accounts a
      where a.business_id = p_business_id
        and a.account_code = gs::text
    )
    order by gs
    limit 1;

    if v_code is null then
      raise exception 'No free bank ledger account code is available';
    end if;

    insert into public.accounting_accounts(
      business_id, account_code, account_name, account_type, account_subtype,
      normal_balance, tax_default, allow_manual_posting, report_section,
      is_system, is_control, xero_account_code, xero_account_type, xero_tax_type,
      description, created_by, updated_by
    ) values (
      p_business_id, v_code, v_bank_account.name, 'asset', 'bank',
      'debit', 'NO_GST', false, 'asset',
      true, true, v_code, 'BANK', 'NONE',
      'Bank ledger linked to imported bank account ' || coalesce(v_bank_account.account_number, v_bank_account.name),
      v_uid, v_uid
    )
    returning id into v_account;
  end if;

  update public.bank_accounts
  set accounting_account_id = v_account,
      updated_at = now(),
      updated_by = v_uid
  where id = v_bank_account.id
    and business_id = p_business_id
    and accounting_account_id is distinct from v_account;

  return v_account;
end;
$$;

revoke execute on function public.v61109_bank_accounting_account(uuid,uuid) from public, anon;
grant execute on function public.v61109_bank_accounting_account(uuid,uuid) to authenticated, service_role;

do $$
declare
  c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.bank_reconciliation_allocations'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%allocation_type%'
  loop
    execute format('alter table public.bank_reconciliation_allocations drop constraint %I', c.conname);
  end loop;
end$$;

alter table public.bank_reconciliation_allocations
  add constraint bank_reconciliation_allocations_allocation_type_ck
  check (allocation_type in (
    'invoice',
    'expense',
    'transfer',
    'customer_refund',
    'supplier_refund',
    'payroll_pay_run',
    'payroll_ird',
    'owner_equity',
    'expense_deposit_refund',
    'stripe_payout'
  ));

create or replace function public.v61105_phase13a_post_payroll_journal(
  p_pay_run_id uuid
) returns uuid
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
  v_net_payable uuid;
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
  where id = p_pay_run_id
    and business_id = v_bid;

  if v_run.id is null then raise exception 'Pay run not found in active business'; end if;
  if v_run.status <> 'finalised' then raise exception 'Only finalised payroll can be posted'; end if;

  select id into v_existing
  from public.accounting_journals
  where business_id = v_bid
    and source_type = 'payroll'
    and source_id = p_pay_run_id
    and posting_version = 1
    and status in ('posted','reversed')
  limit 1;
  if v_existing is not null then return v_existing; end if;

  insert into public.accounting_accounts(
    business_id, account_code, account_name, account_type, account_subtype,
    normal_balance, tax_default, system_account_key, system_key,
    allow_manual_posting, report_section, is_system, is_control,
    xero_account_code, xero_account_type, xero_tax_type, description,
    created_by, updated_by
  ) values
    (v_bid,'266','Payroll Net Payable','liability','payroll','credit','NO_GST','payroll_net_payable','payroll_net_payable',false,'current_liabilities',true,true,'266','CURRLIAB','NONE','Net wages payable until the bank payment is reconciled.',auth.uid(),auth.uid()),
    (v_bid,'267','IRD / PAYE Payable','liability','payroll_tax','credit','NO_GST','payroll_liability','payroll_liability',false,'current_liabilities',true,true,'267','CURRLIAB','NONE','PAYE, KiwiSaver, ESCT and other payroll obligations payable to IRD or similar agencies.',auth.uid(),auth.uid()),
    (v_bid,'301','Direct Labour - Payroll','cost_of_sales',null,'debit','NO_GST','payroll_direct_wages','payroll_direct_wages',true,'cost_of_sales',true,false,'301','DIRECTCOSTS','NONE','Direct employee wages allocated to service/job delivery.',auth.uid(),auth.uid()),
    (v_bid,'470','Wages and Salaries','expense',null,'debit','NO_GST','payroll_indirect_wages','payroll_indirect_wages',true,'expense',true,false,'470','EXPENSE','NONE','Indirect employee wages and salaries.',auth.uid(),auth.uid()),
    (v_bid,'302','Direct Employer Payroll Costs','cost_of_sales',null,'debit','NO_GST','payroll_direct_employer_cost','payroll_direct_employer_cost',true,'cost_of_sales',true,false,'302','DIRECTCOSTS','NONE','Employer payroll costs for direct labour.',auth.uid(),auth.uid()),
    (v_bid,'471','Employer Payroll Costs','expense',null,'debit','NO_GST','payroll_indirect_employer_cost','payroll_indirect_employer_cost',true,'expense',true,false,'471','EXPENSE','NONE','Employer payroll costs for indirect labour.',auth.uid(),auth.uid()),
    (v_bid,'303','Direct Payroll Reimbursements','cost_of_sales',null,'debit','NO_GST','payroll_direct_reimbursements','payroll_direct_reimbursements',true,'cost_of_sales',true,false,'303','DIRECTCOSTS','NONE','Employee reimbursements and non-taxable allowances for direct labour.',auth.uid(),auth.uid()),
    (v_bid,'472','Payroll Reimbursements','expense',null,'debit','NO_GST','payroll_indirect_reimbursements','payroll_indirect_reimbursements',true,'expense',true,false,'472','EXPENSE','NONE','Employee reimbursements and non-taxable allowances for indirect labour.',auth.uid(),auth.uid())
  on conflict do nothing;

  select id into v_net_payable from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_net_payable' or system_key = 'payroll_net_payable' or account_code = '266') order by account_code limit 1;
  select id into v_liability from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_liability' or system_key = 'payroll_liability' or account_code in ('265','267')) order by case when account_code = '267' then 0 else 1 end, account_code limit 1;
  select id into v_direct_wages from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_direct_wages' and not archived limit 1;
  select id into v_indirect_wages from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_indirect_wages' and not archived limit 1;
  select id into v_direct_employer from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_direct_employer_cost' and not archived limit 1;
  select id into v_indirect_employer from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_indirect_employer_cost' and not archived limit 1;
  select id into v_direct_reimb from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_direct_reimbursements' and not archived limit 1;
  select id into v_indirect_reimb from public.accounting_accounts where business_id = v_bid and system_key = 'payroll_indirect_reimbursements' and not archived limit 1;

  if v_net_payable is null or v_liability is null or v_direct_wages is null or v_indirect_wages is null or v_direct_employer is null or v_indirect_employer is null or v_direct_reimb is null or v_indirect_reimb is null then
    raise exception 'Payroll accounting accounts are not available; payroll was not posted';
  end if;

  with emp as (
    select
      pre.id,
      pre.employee_id,
      coalesce(pre.gross_pay, 0)::numeric gross,
      coalesce(pre.kiwisaver_employer_gross, 0)::numeric employer_gross,
      coalesce(pre.reimbursements, 0)::numeric reimbursements,
      coalesce(pre.total_employment_cost, 0)::numeric total_cost,
      case when coalesce(e.labour_classification, 'indirect') = 'direct' then 'direct' else 'indirect' end cls,
      coalesce((select sum(coalesce(l.amount,0)) from public.payroll_pay_run_lines l where l.pay_run_employee_id = pre.id and l.line_type = 'allowance' and coalesce(l.taxable,true) = false), 0)::numeric tax_free_allowances,
      coalesce((select sum(coalesce(l.amount,0)) from public.payroll_pay_run_lines l where l.pay_run_employee_id = pre.id and l.line_type = 'contribution'), 0)::numeric other_employer
    from public.payroll_pay_run_employees pre
    left join public.payroll_employees e
      on e.id = pre.employee_id
     and e.business_id = pre.business_id
    where pre.business_id = v_bid
      and pre.pay_run_id = p_pay_run_id
  )
  select
    coalesce(sum(gross) filter(where cls = 'direct'), 0),
    coalesce(sum(gross) filter(where cls = 'indirect'), 0),
    coalesce(sum(employer_gross + other_employer) filter(where cls = 'direct'), 0),
    coalesce(sum(employer_gross + other_employer) filter(where cls = 'indirect'), 0),
    coalesce(sum(reimbursements + tax_free_allowances) filter(where cls = 'direct'), 0),
    coalesce(sum(reimbursements + tax_free_allowances) filter(where cls = 'indirect'), 0),
    coalesce(sum(total_cost), 0)
  into v_direct_gross, v_indirect_gross, v_direct_employer_cost, v_indirect_employer_cost, v_direct_reimb_cost, v_indirect_reimb_cost, v_total_cost
  from emp;

  v_net := round(coalesce(v_run.net_pay, 0), 2);
  v_total_cost := round(v_total_cost, 2);
  v_liability_credit := round(v_total_cost - v_net, 2);

  if v_total_cost <= 0 or v_net < 0 or v_liability_credit < 0 then
    raise exception 'Payroll totals are invalid for accounting posting';
  end if;

  if round(v_direct_gross,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_direct_wages,'description','Direct payroll wages','debit',round(v_direct_gross,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_gross,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_indirect_wages,'description','Wages and salaries','debit',round(v_indirect_gross,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_direct_employer_cost,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_direct_employer,'description','Direct employer payroll costs','debit',round(v_direct_employer_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_employer_cost,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_indirect_employer,'description','Employer payroll costs','debit',round(v_indirect_employer_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_direct_reimb_cost,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_direct_reimb,'description','Direct payroll reimbursements','debit',round(v_direct_reimb_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if round(v_indirect_reimb_cost,2) > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_indirect_reimb,'description','Payroll reimbursements','debit',round(v_indirect_reimb_cost,2),'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if v_net > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_net_payable,'description','Net wages payable','debit',0,'credit',v_net,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
  if v_liability_credit > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_liability,'description','Payroll deductions and employer obligations','debit',0,'credit',v_liability_credit,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;

  return public.v6192_create_posted_journal(v_bid, v_run.pay_date, 'payroll', 'payroll', p_pay_run_id, v_run.pay_run_number, 'Payroll ' || v_run.pay_run_number, v_lines);
end;
$$;

revoke execute on function public.v61105_phase13a_post_payroll_journal(uuid) from public, anon;
grant execute on function public.v61105_phase13a_post_payroll_journal(uuid) to authenticated;

create or replace function public.v61109_reconcile_payroll_bank_transaction(
  p_bank_transaction_id uuid,
  p_pay_run_id uuid,
  p_pay_run_employee_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_amount numeric;
  v_expected numeric;
  v_run public.payroll_pay_runs%rowtype;
  v_employee public.payroll_pay_run_employees%rowtype;
  v_bank uuid;
  v_payable uuid;
  v_journal uuid;
  v_legacy_bank_posted boolean := false;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions where id = p_bank_transaction_id and business_id = v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;
  if coalesce(v_tx.amount,0) >= 0 then raise exception 'Payroll payments must be matched to a money-out bank transaction'; end if;
  v_amount := round(abs(coalesce(v_tx.amount,0)),2);

  select * into v_run from public.payroll_pay_runs where id = p_pay_run_id and business_id = v_bid;
  if v_run.id is null then raise exception 'Pay run not found in active business'; end if;
  if v_run.status <> 'finalised' then raise exception 'Only finalised pay runs can be matched to bank payments'; end if;

  if p_pay_run_employee_id is not null then
    select * into v_employee
    from public.payroll_pay_run_employees
    where id = p_pay_run_employee_id
      and business_id = v_bid
      and pay_run_id = v_run.id;
    if v_employee.id is null then raise exception 'Pay run employee was not found in this pay run'; end if;
    v_expected := round(coalesce(v_employee.net_pay,0),2);
  else
    v_expected := round(coalesce(v_run.net_pay,0),2);
  end if;

  if v_expected <= 0 or v_amount <> v_expected then
    raise exception 'Bank amount % does not match payroll net amount %', v_amount, v_expected;
  end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and v_tx.transaction_date between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this bank transaction is locked';
  end if;

  v_bank := public.v61109_bank_accounting_account(v_bid, v_tx.id);
  select id into v_payable from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_net_payable' or system_key = 'payroll_net_payable' or account_code = '266') order by account_code limit 1;
  if v_bank is null or v_payable is null then raise exception 'Bank or payroll payable account is not available'; end if;

  select exists(
    select 1
    from public.accounting_journals j
    join public.accounting_journal_lines l
      on l.journal_id = j.id
     and l.business_id = j.business_id
    join public.accounting_accounts a
      on a.id = l.account_id
     and a.business_id = l.business_id
    where j.business_id = v_bid
      and j.source_type = 'payroll'
      and j.source_id = v_run.id
      and j.status in ('posted','reversed')
      and l.credit > 0
      and (a.account_subtype = 'bank' or a.system_account_key = 'bank' or a.system_key in ('bank','bank_main') or a.account_code in ('090','1000'))
  ) into v_legacy_bank_posted;

  if not v_legacy_bank_posted then
    v_journal := public.v6192_create_posted_journal(
      v_bid,
      v_tx.transaction_date,
      'bank',
      'payroll_bank_payment',
      v_tx.id,
      coalesce(nullif(v_tx.reference,''), v_run.pay_run_number),
      'Payroll bank payment for ' || coalesce(v_run.pay_run_number, 'pay run'),
      jsonb_build_array(
        jsonb_build_object('account_id',v_payable,'description','Clear net payroll payable','debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
        jsonb_build_object('account_id',v_bank,'description','Payroll payment from bank','debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
      )
    );
  end if;

  insert into public.bank_reconciliation_allocations(
    business_id, bank_transaction_id, allocation_type, amount, pay_run_id,
    pay_run_employee_id, accounting_journal_id, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_pay_run', v_amount, v_run.id,
    p_pay_run_employee_id, v_journal, v_uid
  );

  update public.bank_transactions
  set status = 'reconciled',
      reconciliation_type = 'payroll_pay_run',
      reconciled_at = now(),
      reconciled_by = v_uid,
      updated_at = now(),
      updated_by = v_uid
  where id = v_tx.id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_bank_reconciled',
    jsonb_build_object('pay_run_id',v_run.id,'pay_run_employee_id',p_pay_run_employee_id,'journal_id',v_journal,'legacy_bank_posted',v_legacy_bank_posted),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'legacy_bank_posted',v_legacy_bank_posted,'amount',v_amount);
end;
$$;

revoke execute on function public.v61109_reconcile_payroll_bank_transaction(uuid,uuid,uuid) from public, anon;
grant execute on function public.v61109_reconcile_payroll_bank_transaction(uuid,uuid,uuid) to authenticated;

create or replace function public.v61109_reconcile_payroll_ird_bank_transaction(
  p_bank_transaction_id uuid,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_amount numeric;
  v_bank uuid;
  v_liability uuid;
  v_journal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions where id = p_bank_transaction_id and business_id = v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;
  if coalesce(v_tx.amount,0) >= 0 then raise exception 'IRD / PAYE payments must be matched to a money-out bank transaction'; end if;
  v_amount := round(abs(coalesce(v_tx.amount,0)),2);
  if v_amount <= 0 then raise exception 'Bank transaction amount is invalid'; end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and v_tx.transaction_date between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this bank transaction is locked';
  end if;

  v_bank := public.v61109_bank_accounting_account(v_bid, v_tx.id);
  select id into v_liability from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_liability' or system_key = 'payroll_liability' or account_code in ('265','267')) order by case when account_code = '267' then 0 else 1 end, account_code limit 1;
  if v_bank is null or v_liability is null then raise exception 'Bank or payroll liability account is not available'; end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    v_tx.transaction_date,
    'bank',
    'payroll_ird_payment',
    v_tx.id,
    coalesce(nullif(v_tx.reference,''),'IRD / PAYE payment'),
    'IRD / PAYE payment from bank',
    jsonb_build_array(
      jsonb_build_object('account_id',v_liability,'description','Clear payroll liability payment','debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_bank,'description','IRD / PAYE payment from bank','debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    )
  );

  insert into public.bank_reconciliation_allocations(
    business_id, bank_transaction_id, allocation_type, amount,
    accounting_journal_id, note, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_ird', v_amount,
    v_journal, nullif(btrim(coalesce(p_note,'')),''), v_uid
  );

  update public.bank_transactions
  set status = 'reconciled',
      reconciliation_type = 'payroll_ird',
      reconciled_at = now(),
      reconciled_by = v_uid,
      updated_at = now(),
      updated_by = v_uid
  where id = v_tx.id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_ird_reconciled',
    jsonb_build_object('journal_id',v_journal,'amount',v_amount,'note',p_note),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'amount',v_amount);
end;
$$;

revoke execute on function public.v61109_reconcile_payroll_ird_bank_transaction(uuid,text) from public, anon;
grant execute on function public.v61109_reconcile_payroll_ird_bank_transaction(uuid,text) to authenticated;

create or replace function public.v61109_undo_payroll_bank_transaction(
  p_bank_transaction_id uuid,
  p_reason text default 'Undo payroll bank reconciliation'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_alloc record;
  v_reversal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select *
  into v_alloc
  from public.bank_reconciliation_allocations
  where business_id = v_bid
    and bank_transaction_id = p_bank_transaction_id
    and allocation_type in ('payroll_pay_run','payroll_ird')
  order by created_at desc
  limit 1;

  if v_alloc.bank_transaction_id is null then
    raise exception 'Payroll bank reconciliation was not found';
  end if;

  if v_alloc.accounting_journal_id is not null then
    execute 'select public.v6170a_reverse_journal($1,$2)'
      into v_reversal
      using v_alloc.accounting_journal_id, coalesce(nullif(btrim(p_reason),''),'Undo payroll bank reconciliation');
  end if;

  delete from public.bank_reconciliation_allocations
  where business_id = v_bid
    and bank_transaction_id = p_bank_transaction_id
    and allocation_type in ('payroll_pay_run','payroll_ird');

  update public.bank_transactions
  set status = 'unreconciled',
      reconciliation_type = null,
      reconciled_at = null,
      reconciled_by = null,
      updated_at = now(),
      updated_by = v_uid
  where id = p_bank_transaction_id
    and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid, p_bank_transaction_id, 'payroll_bank_undo',
    jsonb_build_object('journal_id',v_alloc.accounting_journal_id,'reversal_journal_id',v_reversal,'reason',p_reason),
    v_uid
  );

  return jsonb_build_object('ok',true,'reversal_journal_id',v_reversal);
end;
$$;

revoke execute on function public.v61109_undo_payroll_bank_transaction(uuid,text) from public, anon;
grant execute on function public.v61109_undo_payroll_bank_transaction(uuid,text) to authenticated;

do $$
declare
  d text;
  start_pos integer;
  end_pos integer;
  start_marker text := '-- Resolve the existing bank ledger';
  end_marker text := '  if v_bank is null then raise exception ''A bank ledger account is not available for this business''; end if;';
  replacement text := '  -- Resolve the bank ledger from the actual imported bank transaction.
  v_bank := public.v61109_bank_accounting_account(v_bid, p_bank_transaction_id);
  if v_bank is null then raise exception ''A bank ledger account is not available for this bank transaction''; end if;';
begin
  select pg_get_functiondef(p.oid)
    into d
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'v61106e_reconcile_owner_equity_bank_transaction';

  if d is null then
    raise exception 'Owner/equity reconciliation function not found';
  end if;

  start_pos := strpos(d, start_marker);
  end_pos := strpos(d, end_marker);
  if start_pos = 0 or end_pos = 0 or end_pos <= start_pos then
    raise exception 'Owner/equity bank ledger block was not recognised; migration stopped before changing the function';
  end if;

  d := substr(d, 1, start_pos - 1)
    || replacement
    || substr(d, end_pos + length(end_marker));

  d := replace(
    d,
    'v_bid,v_tx.transaction_date,''bank_reconciliation'',''owner_equity'',v_tx.id,',
    'v_bid,v_tx.transaction_date,''bank'',''owner_equity'',v_tx.id,'
  );

  execute d;
end$$;
