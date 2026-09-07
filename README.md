Invoice Manager v58.1 — Financials SQL installation hotfix

This is the same v58 Financials module with a corrected tenant-guard migration so Supabase SQL Editor seeding can complete safely. Existing application module behaviour is unchanged.

# Invoice Manager v58

v58 adds a new standalone **Financials** module on top of v57. Existing Invoicing, Job Costing, My Expenses, Payroll, My Customers, Reports, Settings, PDFs and email Edge Functions are preserved.

Financials includes:
- Super Admin module enable/disable
- Overview with sales, direct/indirect costs, profit, estimated tax and liabilities
- Profit & Loss with drill-down
- Cash Flow and Cash Book using available payment records
- simple supported-data Balance Sheet
- detailed GST Return with sales/expense detail, snapshots and PDF/CSV/Excel-compatible export
- annual/monthly Budget and Budget vs Actual
- Settings → Financials category classification
- strict Financials tenant RLS

See `V58-DEPLOYMENT-STEPS.md`.
