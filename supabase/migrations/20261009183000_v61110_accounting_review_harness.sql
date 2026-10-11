-- v61.110: broader accounting review harness and holiday-pay liability model.
--
-- Scope:
-- - Adds a controlled holiday-pay liability valuation/posting path using existing
--   annual-holiday entitlement periods and confirmed OWP/AWE evidence.
-- - Adds read-only accounting integrity reviews for historical payroll/bank,
--   bank-reconciliation coverage and asset-disposal journals.
-- - Does not rewrite historical journals automatically.

insert into public.accounting_accounts (
  business_id, account_code, account_name, account_type, account_subtype,
  normal_balance, tax_default, system_account_key, system_key,
  allow_manual_posting, report_section, is_system, is_control,
  xero_account_code, xero_account_type, xero_tax_type, description,
  created_by, updated_by
)
select
  b.id, x.account_code, x.account_name, x.account_type, x.account_subtype,
  x.normal_balance, 'NO_GST', x.system_account_key, x.system_key,
  false, x.report_section, true, x.is_control,
  x.account_code, x.xero_account_type, 'NONE', x.description,
  null, null
from public.businesses b
cross join (values
  ('268','Holiday Pay Liability','liability','payroll_leave','credit','holiday_pay_liability','holiday_pay_liability','current_liabilities','CURRLIAB','Annual-holiday liability recognised from confirmed payroll leave evidence.',true),
  ('473','Holiday Pay Expense','expense','payroll_leave','debit','holiday_pay_expense','holiday_pay_expense','expense','EXPENSE','Holiday-pay liability expense adjustment from confirmed payroll leave evidence.',false)
) as x(account_code,account_name,account_type,account_subtype,normal_balance,system_account_key,system_key,report_section,xero_account_type,description,is_control)
where not exists (
  select 1
  from public.accounting_accounts a
  where a.business_id = b.id
    and (
      a.account_code = x.account_code
      or a.system_account_key = x.system_account_key
      or a.system_key = x.system_key
    )
);

create or replace function public.v61110_holiday_pay_liability_review(
  p_as_of date default current_date
) returns table(
  employee_id uuid,
  employee_name text,
  remaining_weeks numeric,
  weekly_rate numeric,
  target_liability numeric,
  posted_liability numeric,
  adjustment_required numeric,
  valuation_status text,
  evidence text
)
language sql
security definer
set search_path = ''
as $$
  with ctx as (
    select public.current_business_id() as bid, auth.uid() as uid
  ),
  entitlement as (
    select
      p.employee_id,
      round(sum(greatest(0, coalesce(p.remaining_statutory_weeks, 0) + coalesce(p.contractual_extra_weeks, 0) - coalesce(p.advance_weeks, 0))), 4) as remaining_weeks
    from public.payroll_annual_holiday_entitlement_periods p
    join ctx on ctx.bid = p.business_id
    where ctx.uid is not null
      and coalesce(p.status, 'active') not in ('voided','superseded','deleted')
      and coalesce(p.entitlement_date, p.period_end, p.period_start, p_as_of) <= p_as_of
    group by p.employee_id
  ),
  latest_calc as (
    select distinct on (c.employee_id)
      c.employee_id,
      greatest(coalesce(c.owp_amount, 0), coalesce(c.awe_amount, 0), coalesce(c.selected_amount, 0))::numeric as confirmed_weekly_rate,
      c.id as calculation_id,
      c.relevant_from
    from public.payroll_statutory_leave_calculations c
    join ctx on ctx.bid = c.business_id
    where ctx.uid is not null
      and c.statutory_leave_code = 'annual_holiday'
      and c.confirmation_state = 'confirmed'
      and coalesce(c.relevant_from, p_as_of) <= p_as_of
    order by c.employee_id, coalesce(c.relevant_from, c.created_at::date) desc, c.created_at desc
  ),
  posted as (
    select
      j.business_id,
      round(coalesce(sum(l.credit - l.debit), 0), 2) as posted_liability
    from public.accounting_journals j
    join public.accounting_journal_lines l
      on l.journal_id = j.id
     and l.business_id = j.business_id
    join public.accounting_accounts a
      on a.id = l.account_id
     and a.business_id = l.business_id
    join ctx on ctx.bid = j.business_id
    where ctx.uid is not null
      and j.status = 'posted'
      and j.journal_date <= p_as_of
      and j.source_type = 'payroll_leave_liability'
      and (a.system_account_key = 'holiday_pay_liability' or a.system_key = 'holiday_pay_liability' or a.account_code = '268')
    group by j.business_id
  )
  select
    e.id,
    btrim(concat(coalesce(e.preferred_name, e.first_name), ' ', e.last_name)) as employee_name,
    coalesce(ent.remaining_weeks, 0) as remaining_weeks,
    round(coalesce(lc.confirmed_weekly_rate, case when e.pay_type = 'salary' then coalesce(e.annual_salary, 0) / 52 else coalesce(e.hourly_rate, 0) * coalesce(e.standard_weekly_hours, ps.default_weekly_hours, 40) end), 2) as weekly_rate,
    case when lc.confirmed_weekly_rate is not null
      then round(coalesce(ent.remaining_weeks, 0) * lc.confirmed_weekly_rate, 2)
      else 0
    end as target_liability,
    coalesce(posted.posted_liability, 0) as posted_liability,
    case when lc.confirmed_weekly_rate is not null
      then round(coalesce(ent.remaining_weeks, 0) * lc.confirmed_weekly_rate - coalesce(posted.posted_liability, 0), 2)
      else 0
    end as adjustment_required,
    case
      when coalesce(ent.remaining_weeks, 0) <= 0 then 'no_liability'
      when lc.confirmed_weekly_rate is not null then 'confirmed'
      else 'needs_review'
    end as valuation_status,
    case
      when coalesce(ent.remaining_weeks, 0) <= 0 then 'No remaining annual-holiday weeks.'
      when lc.confirmed_weekly_rate is not null then 'Valued from confirmed annual-holiday OWP/AWE calculation ' || lc.calculation_id::text || '.'
      else 'Remaining weeks exist, but no confirmed annual-holiday OWP/AWE calculation exists as of this date.'
    end as evidence
  from ctx
  join public.payroll_employees e
    on e.business_id = ctx.bid
   and coalesce(e.archived, false) = false
   and coalesce(e.employment_status, 'active') <> 'terminated'
  left join public.payroll_settings ps on ps.business_id = e.business_id
  left join entitlement ent on ent.employee_id = e.id
  left join latest_calc lc on lc.employee_id = e.id
  left join posted on posted.business_id = e.business_id
  where ctx.uid is not null
    and coalesce(ent.remaining_weeks, 0) > 0
  order by employee_name;
$$;

revoke execute on function public.v61110_holiday_pay_liability_review(date) from public, anon;
grant execute on function public.v61110_holiday_pay_liability_review(date) to authenticated, service_role;

create or replace function public.v61110_post_holiday_pay_liability(
  p_as_of date default current_date,
  p_reason text default 'Holiday pay liability adjustment'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_expense uuid;
  v_liability uuid;
  v_target numeric := 0;
  v_posted numeric := 0;
  v_adjustment numeric := 0;
  v_journal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid, 'payroll') then raise exception 'Payroll write access denied'; end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and p_as_of between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this holiday-pay adjustment is locked';
  end if;

  insert into public.accounting_accounts(
    business_id, account_code, account_name, account_type, account_subtype,
    normal_balance, tax_default, system_account_key, system_key,
    allow_manual_posting, report_section, is_system, is_control,
    xero_account_code, xero_account_type, xero_tax_type, description,
    created_by, updated_by
  ) values
    (v_bid,'268','Holiday Pay Liability','liability','payroll_leave','credit','NO_GST','holiday_pay_liability','holiday_pay_liability',false,'current_liabilities',true,true,'268','CURRLIAB','NONE','Annual-holiday liability recognised from confirmed payroll leave evidence.',v_uid,v_uid),
    (v_bid,'473','Holiday Pay Expense','expense','payroll_leave','debit','NO_GST','holiday_pay_expense','holiday_pay_expense',false,'expense',true,false,'473','EXPENSE','NONE','Holiday-pay liability expense adjustment from confirmed payroll leave evidence.',v_uid,v_uid)
  on conflict do nothing;

  select id into v_expense
  from public.accounting_accounts
  where business_id = v_bid
    and not coalesce(archived, false)
    and (system_account_key = 'holiday_pay_expense' or system_key = 'holiday_pay_expense' or account_code = '473')
  order by account_code
  limit 1;

  select id into v_liability
  from public.accounting_accounts
  where business_id = v_bid
    and not coalesce(archived, false)
    and (system_account_key = 'holiday_pay_liability' or system_key = 'holiday_pay_liability' or account_code = '268')
  order by account_code
  limit 1;

  if v_expense is null or v_liability is null then
    raise exception 'Holiday-pay accounting accounts are not available';
  end if;

  select round(coalesce(sum(target_liability), 0), 2)
    into v_target
  from public.v61110_holiday_pay_liability_review(p_as_of)
  where valuation_status = 'confirmed';

  if exists (
    select 1
    from public.v61110_holiday_pay_liability_review(p_as_of)
    where valuation_status = 'needs_review'
  ) then
    raise exception 'Holiday-pay liability cannot be posted until every employee with remaining weeks has confirmed OWP/AWE evidence';
  end if;

  select round(coalesce(sum(l.credit - l.debit), 0), 2)
    into v_posted
  from public.accounting_journals j
  join public.accounting_journal_lines l
    on l.journal_id = j.id
   and l.business_id = j.business_id
  where j.business_id = v_bid
    and j.status = 'posted'
    and j.source_type = 'payroll_leave_liability'
    and j.journal_date <= p_as_of
    and l.account_id = v_liability;

  v_adjustment := round(v_target - coalesce(v_posted, 0), 2);
  if abs(v_adjustment) <= 0.005 then
    return jsonb_build_object('ok', true, 'posted', false, 'target_liability', v_target, 'existing_liability', v_posted, 'adjustment', 0);
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    p_as_of,
    'payroll',
    'payroll_leave_liability',
    null,
    'HOLIDAY-' || to_char(p_as_of, 'YYYYMMDD'),
    coalesce(nullif(btrim(p_reason), ''), 'Holiday pay liability adjustment'),
    case when v_adjustment > 0 then
      jsonb_build_array(
        jsonb_build_object('account_id', v_expense, 'description', 'Holiday pay liability expense', 'debit', v_adjustment, 'credit', 0, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0),
        jsonb_build_object('account_id', v_liability, 'description', 'Holiday pay liability', 'debit', 0, 'credit', v_adjustment, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', v_liability, 'description', 'Reduce holiday pay liability', 'debit', abs(v_adjustment), 'credit', 0, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0),
        jsonb_build_object('account_id', v_expense, 'description', 'Reduce holiday pay expense', 'debit', 0, 'credit', abs(v_adjustment), 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0)
      )
    end
  );

  return jsonb_build_object('ok', true, 'posted', true, 'journal_id', v_journal, 'target_liability', v_target, 'existing_liability', v_posted, 'adjustment', v_adjustment);
end;
$$;

revoke execute on function public.v61110_post_holiday_pay_liability(date,text) from public, anon;
grant execute on function public.v61110_post_holiday_pay_liability(date,text) to authenticated;

create or replace function public.v61110_asset_disposal_case_matrix()
returns table(case_name text, proceeds numeric, capitalised numeric, accumulated_depreciation numeric, business_use_percent numeric, debit_total numeric, credit_total numeric, balanced boolean)
language sql
stable
set search_path = ''
as $$
  with cases(case_name, proceeds, capitalised, accumulated_depreciation, business_use_percent) as (
    values
      ('gain', 1200::numeric, 1000::numeric, 300::numeric, 100::numeric),
      ('loss', 300::numeric, 1000::numeric, 200::numeric, 100::numeric),
      ('fully_depreciated', 200::numeric, 1000::numeric, 1000::numeric, 100::numeric),
      ('partial_private_use', 1000::numeric, 1200::numeric, 400::numeric, 60::numeric)
  ),
  calc as (
    select *,
      round(proceeds * business_use_percent / 100, 2) as business_proceeds,
      round(proceeds * (100 - business_use_percent) / 100, 2) as private_proceeds,
      round(capitalised - least(capitalised, greatest(0, accumulated_depreciation)), 2) as nbv
    from cases
  ),
  lines as (
    select *,
      round(proceeds + least(capitalised, greatest(0, accumulated_depreciation)) + greatest(nbv - business_proceeds, 0), 2) as debit_total,
      round(capitalised + private_proceeds + greatest(business_proceeds - nbv, 0), 2) as credit_total
    from calc
  )
  select case_name, proceeds, capitalised, accumulated_depreciation, business_use_percent, debit_total, credit_total, abs(debit_total - credit_total) <= 0.005
  from lines;
$$;

revoke execute on function public.v61110_asset_disposal_case_matrix() from public, anon;
grant execute on function public.v61110_asset_disposal_case_matrix() to authenticated, service_role;

create or replace function public.v61110_accounting_integrity_review(
  p_as_of date default current_date
) returns table(
  area text,
  issue_key text,
  severity text,
  source_id uuid,
  source_reference text,
  expected_amount numeric,
  actual_amount numeric,
  detail text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;

  return query
  select
    'holiday_pay'::text,
    'holiday_liability_needs_review'::text,
    'warning'::text,
    r.employee_id,
    r.employee_name,
    r.target_liability,
    r.posted_liability,
    r.evidence
  from public.v61110_holiday_pay_liability_review(p_as_of) r
  where r.valuation_status = 'needs_review';

  return query
  select
    'holiday_pay'::text,
    'holiday_liability_adjustment_required'::text,
    case when abs(sum(r.adjustment_required)) > 0.005 then 'info' else 'ok' end,
    null::uuid,
    'HOLIDAY-' || to_char(p_as_of, 'YYYYMMDD'),
    round(sum(r.target_liability), 2),
    round(max(r.posted_liability), 2),
    'Confirmed holiday-pay liability differs from the posted liability by ' || round(sum(r.adjustment_required), 2)::text || '.'
  from public.v61110_holiday_pay_liability_review(p_as_of) r
  where r.valuation_status = 'confirmed'
  having count(*) > 0;

  return query
  select
    'payroll'::text,
    'legacy_payroll_posted_directly_to_bank'::text,
    'warning'::text,
    j.source_id,
    coalesce(j.source_reference, j.journal_number),
    null::numeric,
    round(sum(l.credit), 2),
    'Historical payroll journal credits a bank account directly. Leave untouched unless an accountant decides to reclassify it.'
  from public.accounting_journals j
  join public.accounting_journal_lines l on l.journal_id = j.id and l.business_id = j.business_id
  join public.accounting_accounts a on a.id = l.account_id and a.business_id = l.business_id
  where j.business_id = v_bid
    and j.status = 'posted'
    and j.source_type = 'payroll'
    and j.journal_date <= p_as_of
    and l.credit > 0
    and (a.account_subtype = 'bank' or a.system_account_key = 'bank' or a.system_key in ('bank','bank_main') or a.account_code in ('090','1000'))
  group by j.source_id, coalesce(j.source_reference, j.journal_number);

  return query
  select
    'bank_reconciliation'::text,
    'reconciled_allocation_missing_journal'::text,
    case when bra.allocation_type in ('owner_equity','payroll_pay_run','payroll_ird','expense_deposit_refund','stripe_payout') then 'warning' else 'info' end,
    bt.id,
    coalesce(bt.reference, bt.description, bt.bank_transaction_id),
    abs(bt.amount),
    bra.amount,
    'Bank reconciliation allocation ' || bra.allocation_type || ' has no linked accounting journal. Review whether this type is deliberately non-posting or needs correction.'
  from public.bank_reconciliation_allocations bra
  join public.bank_transactions bt on bt.id = bra.bank_transaction_id and bt.business_id = bra.business_id
  where bra.business_id = v_bid
    and bt.status = 'reconciled'
    and bt.transaction_date <= p_as_of
    and bra.allocation_type in ('transfer','owner_equity','payroll_pay_run','payroll_ird','expense_deposit_refund','stripe_payout')
    and bra.accounting_journal_id is null;

  return query
  select
    'asset_disposal'::text,
    'disposed_asset_missing_journal'::text,
    'critical'::text,
    a.id,
    'ASSET-' || left(a.id::text, 8),
    coalesce(a.disposal_proceeds, 0),
    null::numeric,
    'Asset is marked disposed but no disposal journal is linked.'
  from public.se_assets a
  where a.business_id = v_bid
    and a.disposed_on is not null
    and a.disposed_on <= p_as_of
    and a.disposal_journal_id is null;

  return query
  select
    'asset_disposal'::text,
    'asset_disposal_journal_not_balanced'::text,
    'critical'::text,
    j.source_id,
    coalesce(j.source_reference, j.journal_number),
    round(sum(l.debit), 2),
    round(sum(l.credit), 2),
    'Asset-disposal journal is not balanced.'
  from public.accounting_journals j
  join public.accounting_journal_lines l on l.journal_id = j.id and l.business_id = j.business_id
  where j.business_id = v_bid
    and j.source_type = 'asset_disposal'
    and j.status = 'posted'
    and j.journal_date <= p_as_of
  group by j.source_id, coalesce(j.source_reference, j.journal_number)
  having abs(round(sum(l.debit) - sum(l.credit), 2)) > 0.005;

  return query
  select
    'asset_disposal'::text,
    'asset_disposal_case_matrix'::text,
    case when bool_and(m.balanced) then 'ok' else 'critical' end,
    null::uuid,
    'sample-cases',
    sum(m.debit_total),
    sum(m.credit_total),
    'Gain, loss, fully depreciated and partial private-use sample disposal formulas balance: ' || bool_and(m.balanced)::text || '.'
  from public.v61110_asset_disposal_case_matrix() m;
end;
$$;

revoke execute on function public.v61110_accounting_integrity_review(date) from public, anon;
grant execute on function public.v61110_accounting_integrity_review(date) to authenticated, service_role;

create or replace function public.v61110_accounting_test_harness(
  p_from date default date_trunc('year', current_date)::date,
  p_to date default current_date
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_review jsonb;
  v_trial_debits numeric := 0;
  v_trial_credits numeric := 0;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;

  select jsonb_build_object(
    'critical', count(*) filter (where severity = 'critical'),
    'warnings', count(*) filter (where severity = 'warning'),
    'info', count(*) filter (where severity = 'info'),
    'ok', count(*) filter (where severity = 'ok'),
    'items', coalesce(jsonb_agg(to_jsonb(r) order by case severity when 'critical' then 0 when 'warning' then 1 when 'info' then 2 else 3 end, area, issue_key) filter (where severity <> 'ok'), '[]'::jsonb)
  )
  into v_review
  from public.v61110_accounting_integrity_review(p_to) r;

  select round(coalesce(sum(debits), 0), 2), round(coalesce(sum(credits), 0), 2)
    into v_trial_debits, v_trial_credits
  from public.v6170b_trial_balance(p_from, p_to);

  return jsonb_build_object(
    'ok', abs(v_trial_debits - v_trial_credits) <= 0.005 and coalesce((v_review->>'critical')::int, 0) = 0,
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'trial_balance', jsonb_build_object('debits', v_trial_debits, 'credits', v_trial_credits, 'balanced', abs(v_trial_debits - v_trial_credits) <= 0.005),
    'review', v_review
  );
end;
$$;

revoke execute on function public.v61110_accounting_test_harness(date,date) from public, anon;
grant execute on function public.v61110_accounting_test_harness(date,date) to authenticated, service_role;
