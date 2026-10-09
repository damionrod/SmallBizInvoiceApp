-- v61.114: posted-ledger Statement of Cash Flows.
-- Adds a read-only direct-method cash flow report without changing posting logic.

create or replace function public.v61114_statement_cash_flows(
  p_from date,
  p_to date
) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with ctx as (
  select public.current_business_id() as bid, auth.uid() as uid
),
cash_accounts as (
  select a.id
  from public.accounting_accounts a
  join ctx on ctx.bid = a.business_id
  where ctx.uid is not null
    and not coalesce(a.archived, false)
    and (
      a.account_type in ('bank','cash')
      or
      a.account_subtype in ('bank','cash','cash_equivalent')
      or a.system_account_key in ('bank','bank_main','cash','cash_on_hand')
      or a.system_key in ('bank','bank_main','cash','cash_on_hand')
      or a.xero_account_type in ('BANK')
      or a.account_code in ('090','1000')
    )
),
cash_by_journal as (
  select
    j.id as journal_id,
    j.business_id,
    j.journal_date,
    j.journal_number,
    coalesce(j.source_reference, j.journal_number) as reference,
    coalesce(j.source_type, j.journal_type, 'journal') as source_type,
    round(sum(l.debit - l.credit), 2) as cash_change
  from public.accounting_journals j
  join ctx on ctx.bid = j.business_id
  join public.accounting_journal_lines l
    on l.journal_id = j.id
   and l.business_id = j.business_id
  join cash_accounts ca on ca.id = l.account_id
  where ctx.uid is not null
    and j.status in ('posted','reversed')
    and j.journal_date <= p_to
  group by j.id, j.business_id, j.journal_date, j.journal_number, j.source_reference, j.source_type, j.journal_type
),
period_cash as (
  select *
  from cash_by_journal
  where journal_date between p_from and p_to
    and abs(cash_change) > 0.005
),
classified as (
  select
    pc.*,
    case
      when exists (
        select 1
        from public.accounting_journal_lines l
        join public.accounting_accounts a
          on a.id = l.account_id
         and a.business_id = l.business_id
        where l.journal_id = pc.journal_id
          and l.business_id = pc.business_id
          and l.account_id not in (select id from cash_accounts)
          and (
            a.account_type = 'equity'
            or a.report_section = 'equity'
            or a.account_subtype in ('loan','borrowings','owner_equity','owner_current','shareholder_current')
            or coalesce(a.system_account_key,'') similar to '%(owner|shareholder|loan|borrowing|dividend|drawing|capital)%'
            or coalesce(a.system_key,'') similar to '%(owner|shareholder|loan|borrowing|dividend|drawing|capital)%'
          )
      ) then 'financing'
      when exists (
        select 1
        from public.accounting_journal_lines l
        join public.accounting_accounts a
          on a.id = l.account_id
         and a.business_id = l.business_id
        where l.journal_id = pc.journal_id
          and l.business_id = pc.business_id
          and l.account_id not in (select id from cash_accounts)
          and (
            a.account_type in ('fixed_asset','non_current_asset')
            or a.report_section in ('fixed_assets','non_current_assets')
            or a.account_subtype in ('fixed_asset','equipment','vehicle','property')
            or coalesce(a.system_account_key,'') similar to '%(fixed_asset|equipment|asset_disposal)%'
            or coalesce(a.system_key,'') similar to '%(fixed_asset|equipment|asset_disposal)%'
          )
      ) then 'investing'
      else 'operating'
    end as section
  from period_cash pc
),
labelled as (
  select
    c.*,
    case
      when section = 'operating' and cash_change >= 0 then 'Receipts from customers and operating income'
      when section = 'operating' and source_type in ('payroll','bank') and exists (
        select 1
        from public.accounting_journal_lines l
        join public.accounting_accounts a on a.id = l.account_id and a.business_id = l.business_id
        where l.journal_id = c.journal_id
          and l.business_id = c.business_id
          and (a.account_subtype = 'payroll' or coalesce(a.system_account_key,'') like 'payroll_%' or coalesce(a.system_key,'') like 'payroll_%')
      ) then 'Payroll, PAYE and employee payments'
      when section = 'operating' then 'Payments to suppliers, tax and operations'
      when section = 'investing' and cash_change >= 0 then 'Proceeds from sale of assets'
      when section = 'investing' then 'Purchase of property and equipment'
      when section = 'financing' and cash_change >= 0 then 'Owner, shareholder or loan funds received'
      else 'Owner drawings, dividends or loan repayments'
    end as line_label
  from classified c
),
line_totals as (
  select
    section,
    line_label,
    round(sum(cash_change), 2) as amount,
    count(*) as journal_count
  from labelled
  group by section, line_label
),
section_totals as (
  select section, round(sum(amount), 2) as amount
  from line_totals
  group by section
),
section_payload as (
  select jsonb_agg(
    jsonb_build_object(
      'section', s.section,
      'label', case s.section
        when 'operating' then 'Cash flows from operating activities'
        when 'investing' then 'Cash flows from investing activities'
        else 'Cash flows from financing activities'
      end,
      'amount', coalesce(st.amount, 0),
      'lines', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'label', lt.line_label,
            'amount', lt.amount,
            'journal_count', lt.journal_count
          )
          order by lt.line_label
        )
        from line_totals lt
        where lt.section = s.section
      ), '[]'::jsonb)
    )
    order by case s.section when 'operating' then 1 when 'investing' then 2 else 3 end
  ) as sections
  from (values ('operating'), ('investing'), ('financing')) as s(section)
  left join section_totals st on st.section = s.section
),
totals as (
  select
    round(coalesce((select sum(cash_change) from cash_by_journal where journal_date < p_from), 0), 2) as opening_cash,
    round(coalesce((select sum(cash_change) from cash_by_journal where journal_date <= p_to), 0), 2) as closing_cash,
    round(coalesce((select sum(cash_change) from labelled), 0), 2) as net_movement,
    (select count(*) from cash_accounts) as cash_account_count,
    (select count(*) from period_cash) as journal_count
)
select jsonb_build_object(
  'from', p_from,
  'to', p_to,
  'method', 'direct',
  'basis', 'posted_ledger',
  'opening_cash', opening_cash,
  'closing_cash', closing_cash,
  'net_movement', net_movement,
  'calculated_closing_cash', round(opening_cash + net_movement, 2),
  'reconciles', round(opening_cash + net_movement, 2) = round(closing_cash, 2),
  'cash_account_count', cash_account_count,
  'journal_count', journal_count,
  'sections', coalesce(section_payload.sections, '[]'::jsonb),
  'warnings', (
    case when cash_account_count = 0
      then jsonb_build_array('No posted bank or cash ledger accounts were found for this business.')
      else '[]'::jsonb
    end
    ||
    case when round(opening_cash + net_movement, 2) <> round(closing_cash, 2)
      then jsonb_build_array('Opening cash plus net movement does not equal closing cash. Review cash/bank account setup.')
      else '[]'::jsonb
    end
  )
)
from totals, section_payload;
$$;

revoke execute on function public.v61114_statement_cash_flows(date,date) from public, anon;
grant execute on function public.v61114_statement_cash_flows(date,date) to authenticated, service_role;
