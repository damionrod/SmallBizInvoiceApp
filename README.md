# Invoice Manager v55 — Payroll Module

v55 adds Payroll as a native, separately entitled module to the existing multi-business SaaS application.

Visible Payroll structure:
- Employees
- Timesheets
- Pay Runs

Integrated areas:
- **Super Admin Modules:** enable/disable Payroll per business.
- **Settings:** Payroll configuration, pay items, leave types and employee document types.
- **Reports:** central Payroll report and CSV export.
- **Job Costing:** approved job-linked timesheets remain referenceable as actual labour without changing the existing estimate engine.
- **My Customers:** customer is derived from an existing Job where applicable; customer records are not duplicated.
- **My Expenses / Financial layer:** Payroll reimbursements stay Payroll-source transactions rather than creating duplicate expense bills.
- **Business settings:** existing business identity and currency are reused.
- **Data Export:** Payroll tables are included in business export.
- **Account deletion:** private Payroll employee documents are removed before permanent business deletion.

Security:
- Payroll data is database/RLS business scoped.
- Payroll access also requires the Payroll module to be enabled for that tenant.
- Employee documents use a private Supabase Storage bucket.
- Cross-business references are validated in the database.
- Finalised Pay Runs and their financial details are locked.

Deployment instructions are in `V55-DEPLOYMENT-STEPS.md`.
