# v55 Payroll — Regression & Security Test Checklist

## Existing app regression
- Invoicing opens, saves, previews, downloads and emails as before.
- My Customers opens and edits as before.
- Job Costing existing estimate calculations are unchanged.
- Quotes behave as before.
- My Expenses existing capture/payment/report flows are unchanged.
- Reports Sales and Expense Report still work.
- Existing Settings and business currency still work.
- Super Admin module controls still work.

## Payroll module entitlement
- Business A with Payroll enabled can open Payroll.
- Business B with Payroll disabled cannot see Payroll navigation.
- Direct frontend attempts do not bypass database RLS when Payroll is disabled.
- Re-enabling Payroll restores access to existing records.

## Tenant isolation
Create/use two enabled businesses and confirm:
- Employees from A are not visible to B.
- Timesheets from A are not visible to B.
- Pay Runs/payslips from A are not visible to B.
- Payroll settings/rules from A are not visible to B.
- Employee documents from A cannot be opened by B.
- Job selector only shows jobs available to the current business.
- Database rejects cross-business employee/job/pay-item/document references.

## Employee workflow
- Automatic employee numbers are sequential per business.
- Hourly and salary employee records save correctly.
- IRD/tax/KiwiSaver/bank details remain inside the employee record, not list views.
- Terminating an employee retains payroll/timesheet/payslip history.
- Employee documents upload and open with private signed access.
- Leave balances and leave transaction history update correctly.

## Timesheets
- Start/finish/break calculates hours correctly.
- Invalid finish/break combinations are rejected clearly.
- Job selection derives the linked customer where applicable.
- Draft → Submitted → Approved works.
- Only approved hours are imported into a Pay Run.

## Pay Runs
- Weekly/Fortnightly/Monthly filters eligible employees correctly.
- Hourly employees import approved time in the selected period.
- Salary employees receive the correct period salary basis.
- PAYG holiday pay appears separately when configured.
- Allowance/reimbursement/deduction adjustments work.
- Finalising creates payslips and Payroll financial-reference records once.
- Finalised Pay Runs cannot be directly edited or deleted.
- Historical snapshot values remain unchanged if an employee rate later changes.

## Payroll/other-module links
- Timesheets reference existing Job IDs rather than duplicate jobs/customers.
- Payroll exposes approved job-linked labour data without altering Job Costing estimates.
- Reimbursements remain Payroll-source records and are not duplicated as My Expenses bills.
- Payroll reports use the current business currency.
- Business name/logo/contact information continues to come from the existing business settings.

## Mobile
- Main Payroll tabs remain Employees / Timesheets / Pay Runs only.
- Employee rows convert to cards.
- Timesheets are easy to enter at phone width.
- Pay Run lists/cards remain usable without horizontal page scrolling.
- Employee forms/modals remain accessible on a phone.
- Payslip view is readable on mobile.
