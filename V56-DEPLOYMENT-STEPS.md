# V56 Payroll usability update

This update builds on V55. It does not replace or redesign the existing Invoicing, Job Costing, My Expenses, Customers, Reports, subscriptions or email functions.

## If V55 is already deployed
1. Supabase > SQL Editor > New query.
2. Run `V56-PAYROLL-USABILITY.sql`.
3. Wait for Success / No rows returned.
4. Deploy this V56 package to Netlify.
5. No Edge Function redeployment is required. `send-payslip`, `send-invoice` and `send-quote` remain unchanged.

## What V56 adds
- Default Payroll pay weekday in Settings. Weekly/fortnightly runs continue from the last run cadence when available.
- Visible/editable NZ income-tax, ACC earners levy and student-loan rule values in Payroll Settings. Finalised runs retain their historical rules snapshot.
- Employee permanent Delete only when no payroll/timesheet/document/leave history exists. Otherwise use Terminate/Inactive.
- Draft/calculated Pay Runs show Edit; finalised Pay Runs remain locked.
- Quick Add to Pay controls for allowances, reimbursements, travel/mileage and other configured pay items before finalisation.
- Newly generated payslips include timesheet job/date/hours detail.

## Quick test
- Settings > Payroll: set Fortnightly + Friday and save.
- New Pay Run: Pay Date should default to the appropriate Friday; subsequent fortnightly runs follow a 14-day cadence from the prior run.
- Add an employee, edit and save them. A new employee with no history can be deleted.
- Calculate a draft pay run, use Add to Pay for Travel/Mileage, save, reopen and edit it.
- Finalise a test run and verify the payslip shows job/date/hours.
- Confirm a finalised run cannot be edited.
