# V57 Payroll Fixes — Deployment

This is a targeted update to Payroll only.

1. In Supabase > SQL Editor, run `V57-PAYROLL-FIXES.sql` once.
2. Deploy the v57 ZIP to Netlify.
3. No Edge Functions need to be changed or redeployed.

## What changed
- Employee selector in a Pay Run is populated before Calculate.
- Employee list has clear Edit and Delete actions.
- Draft/calculated Pay Runs have Edit and Delete actions.
- Finalised Pay Runs remain locked and retained for payroll/audit history.
- Pay Items now show a Tax-free / full amount to employee option.
- Built-in Travel Allowance and Tool Allowance are set tax-free by this migration.
- New Allowance and Reimbursement pay items default to tax-free; the setting can be changed where the payment is legally taxable.
- Tax-free allowances are excluded from PAYE taxable earnings and added in full to net pay.
- Payslips identify each allowance/reimbursement by name and mark tax-free allowances clearly.

No invoice, quote, customer, expense, job-costing, subscription, email, or other module logic was intentionally changed.
