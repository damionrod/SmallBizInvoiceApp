# V61 Deployment Steps

1. In Supabase SQL Editor, run `V61-PAYROLL-EXPENSES-DELETE-FINALISED.sql` once.
2. Deploy the updated application files (`index.html`, `styles.css`, `saas.js`, `payroll.js`, `financials.js`).
3. Hard refresh the browser after deployment.
4. Test: create a timesheet with a reimbursement, approve it, calculate/finalise a pay run, verify PAYE excludes the reimbursement, verify the payslip breakdown, and verify a finalised pay run can be deleted after confirmation.
