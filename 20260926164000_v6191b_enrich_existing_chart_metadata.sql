-- v61.91B metadata alignment for existing production charts.
-- This is metadata-only: it keeps legacy ledger account_type values intact so
-- posted P&L, Balance Sheet and Trial Balance functions continue to work.

begin;

with defaults(account_code, report_section, system_key, xero_account_type, description) as (
  values
    ('1000','current_assets','bank','BANK','Main business bank account.'),
    ('1100','current_assets','accounts_receivable','CURRENT','Money owed by customers.'),
    ('1200','current_assets','gst_receivable','CURRENT','GST claimable on purchases.'),
    ('1500','fixed_assets','fixed_assets','FIXED','Business equipment and assets.'),
    ('1550','fixed_assets','accumulated_depreciation','FIXED','Accumulated depreciation contra asset.'),
    ('2000','current_liabilities','accounts_payable','CURRLIAB','Supplier bills payable.'),
    ('2100','current_liabilities','gst_payable','CURRLIAB','GST collected on sales.'),
    ('2200','current_liabilities','paye_payable','CURRLIAB','PAYE payable.'),
    ('2210','current_liabilities','kiwisaver_payable','CURRLIAB','KiwiSaver payable.'),
    ('2220','current_liabilities','wages_payable','CURRLIAB','Wages payable.'),
    ('3000','equity','owner_funds','EQUITY','Owner funds or share capital.'),
    ('3100','equity','owner_drawings','EQUITY','Owner drawings.'),
    ('3200','equity','retained_earnings','EQUITY','Prior year retained earnings.'),
    ('3300','equity','current_year_earnings','EQUITY','Current year earnings.'),
    ('4000','income','sales','REVENUE','Sales and invoice revenue.'),
    ('5000','cost_of_sales','cost_of_sales','DIRECTCOSTS','Direct cost of sales.'),
    ('6000','operating_expenses','business_expenses','EXPENSE','General business expenses.'),
    ('6100','operating_expenses','wages','EXPENSE','Wages expense.'),
    ('6110','operating_expenses','employer_contributions','EXPENSE','Employer payroll contributions.'),
    ('6200','operating_expenses','depreciation','DEPRECIATN','Depreciation expense.'),
    ('9999','review','needs_review','EXPENSE','Temporary account for items needing accountant review.')
)
update public.accounting_accounts a
set
  report_section = d.report_section,
  system_key = coalesce(a.system_key, d.system_key),
  xero_account_code = coalesce(a.xero_account_code, a.account_code),
  xero_account_type = coalesce(a.xero_account_type, d.xero_account_type),
  description = coalesce(nullif(a.description,''), d.description),
  updated_at = now()
from defaults d
where a.account_code = d.account_code
  and coalesce(a.archived,false) = false;

notify pgrst, 'reload schema';

commit;
