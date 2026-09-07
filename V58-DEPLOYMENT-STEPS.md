# v58.1 Financials SQL Hotfix

This package fixes the `Authentication required` error that could occur when V58-FINANCIALS.sql seeded Financials records from the Supabase SQL Editor. The migration remains safe to rerun after the earlier partial v58 attempt because its tables, indexes, functions, policies and triggers are created/replaced idempotently and seed inserts use conflict handling.

If the earlier v58 SQL failed with `v58_financials_tenant_guard(): Authentication required`, simply run the corrected `V58-FINANCIALS.sql` in full from the beginning. Do not manually delete the partially-created Financials tables.

# v58 Financials deployment

This release adds the new standalone **Financials** module without replacing existing modules.

## 1. Supabase SQL
Open **Supabase → SQL Editor → New query**, paste the full contents of `V58-FINANCIALS.sql`, and run it once.

Expected result: **Success / No rows returned**.

## 2. Netlify
Deploy this complete v58 folder/ZIP to Netlify in the same way as previous releases.

## 3. Enable Financials
Open **Super Admin → business → Modules**, enable **Financials**, and save.

When disabled, Financials is hidden and its Financials-specific database records remain stored for later reactivation.

## 4. No Edge Function changes
Do **not** redeploy `send-invoice`, `send-quote`, or `send-payslip`. v58 does not change them.

## 5. First-use setup
Open **Settings → Financials** and review:
- financial year start
- estimated business tax rate
- GST filing frequency/accounting basis
- expense-category Financial Classifications
- Payroll classifications if Payroll is enabled

Then open **Financials** and check Overview, Profit & Loss, Cash Flow, GST Return, Cash Book, Balance Sheet and Budget.
