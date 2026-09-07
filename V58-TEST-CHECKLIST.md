# v58 Financials test checklist

After running `V58-FINANCIALS.sql` and deploying v58:

1. **Super Admin** — enable Financials for one test business; confirm the nav appears. Disable it; confirm the nav disappears and re-enable it; confirm prior budget/GST data remains.
2. **Isolation** — use two businesses and confirm Financials settings, mappings, budgets and saved GST returns do not cross tenants.
3. **Settings** — review financial year, estimated tax rate and category classifications. Confirm changing a Financial Classification does not alter the underlying Expense category.
4. **Overview / P&L** — compare sales with existing invoices and expense totals with existing My Expenses records. Expand Direct/Indirect categories and inspect source transactions.
5. **GST** — test a known GST-inclusive invoice/expense period. Confirm Collected − Paid = Payable/Refund. Save Draft, mark Reviewed, Finalise and confirm the finalised return locks.
6. **Budget** — create a budget, spread annual values evenly, change monthly values, save and activate. Confirm Overview shows Budget vs Actual.
7. **Cash Flow / Cash Book** — confirm the screen clearly states that no verified bank balance is shown without bank-feed/reconciliation data.
8. **Optional modules** — disable Payroll or Job Costing and confirm Financials still opens without broken links/errors.
9. **Regression** — create/view an invoice, expense, job costing, employee/pay run, customer, existing Reports, PDF and email workflow to confirm no unrelated behaviour changed.
10. **Mobile** — test Overview, P&L, GST and Budget at phone width. Confirm the page itself does not overflow horizontally; detailed tables may use contained scrolling where necessary.
