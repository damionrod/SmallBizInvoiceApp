# Invoice Manager v60 — Financial Integrity Corrections

Targeted update from v59. Existing module structure/design retained.

Key corrections:
- Financials uses the same merged invoice dataset as My Invoices for P&L reconciliation.
- Archived historical expenses remain in Financials reporting.
- Dated customer payments added for future Cash Flow and payments-basis GST accuracy.
- Payments-basis GST uses actual recorded customer/supplier payment dates and proportional GST.
- Legacy pre-v60 customer payments are preserved and explicitly marked as estimated-date records.
- Payroll P&L costs derive from finalised pay-run detail: job-linked labour = direct, non-job salary/wages = operating, tax-free allowances/reimbursements included, employer contributions allocated consistently.
- NZ estimated income tax uses entity-aware planning logic for company/sole trader/trust; other entity/country cases retain configured estimate rate.
- Existing month-by-month P&L and mobile-friendly layout retained.

Run V60-FINANCIAL-CORRECTIONS.sql before deploying the site.
No Edge Function changes.
