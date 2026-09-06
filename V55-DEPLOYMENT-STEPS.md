# Invoice Manager v55 — Payroll Module Deployment

This version adds Payroll as a separately controlled SaaS module. It does not require changes to the existing invoice, quote, customer, Job Costing, Expenses, payment gateway, or existing email Edge Functions.

## 1. Run the Payroll SQL migration

1. Open **Supabase → SQL Editor → New query**.
2. Open `V55-PAYROLL.sql` from this ZIP.
3. Copy the **entire** file into the SQL Editor.
4. Click **Run**.
5. Wait for a successful result (normally `Success. No rows returned`).

The migration creates the Payroll tables, tenant RLS policies, private employee-document storage bucket, NZ country-rule records, finalised-pay-run locks, module entitlement checks, and default Payroll configuration.

## 2. Deploy the new `send-payslip` Edge Function

1. Open **Supabase → Edge Functions**.
2. Create a function named exactly: `send-payslip`.
3. Open `supabase/functions/send-payslip/index.ts` from this ZIP.
4. Replace the function code with the complete contents of that file.
5. Deploy the function.
6. Open the function settings and keep **Verify JWT with legacy secret = OFF**, consistent with the existing `send-invoice` and `send-quote` functions.

The function reuses the existing secrets:
- `RESEND_API_KEY`
- `EMAIL_FROM_ADDRESS`

Do **not** replace or redeploy `send-invoice` or `send-quote` for this release.

## 3. Deploy the website

Deploy `invoice-manager-v55-payroll-module.zip` to Netlify using the same method as the previous versions.

## 4. Enable Payroll for a test business

1. Sign in as Super Admin.
2. Open the business.
3. Open **Modules**.
4. Enable **Payroll**.
5. Save modules.

Payroll should now appear in the main navigation. If disabled again, Payroll navigation/data access is blocked but the business's Payroll records are retained.

## 5. First test sequence

Use a test business first:

1. Add an employee.
2. Add/submit a timesheet and optionally select an existing Job.
3. Approve the timesheet.
4. Create a Pay Run for the matching pay frequency and period.
5. Calculate it and review gross pay, deductions, KiwiSaver and net pay.
6. Optionally use **Adjust** for an allowance/reimbursement/authorised deduction.
7. Finalise the Pay Run.
8. Open the generated payslip.
9. Download the payslip PDF.
10. Test payslip email.
11. Open **Reports → Payroll**.
12. Export the Payroll report CSV and Payday filing data CSV.
13. Disable Payroll for the business and confirm the module disappears.
14. Re-enable Payroll and confirm the existing employee/pay-run data returns.

## Important

Payroll calculations use effective-dated New Zealand rule records seeded for the 2026/27 tax year. Because payroll is compliance-sensitive, run test payrolls against your expected IRD results before using the module for live wage processing.
