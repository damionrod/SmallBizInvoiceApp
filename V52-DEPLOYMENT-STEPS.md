# v52 deployment steps

This is the pre-deployment hardening revision of v51 My Expenses.

## What changed
- Keeps Job Costing as an estimating module. Expenses may retain an optional job reference for expense-side allocation/reporting, but no actual-expense calculation is added to Job Costing.
- Super Admin permanent business deletion now removes known expense receipt/PDF objects from the private `expense-documents` bucket before deleting the business database account. If storage cleanup fails, database deletion is aborted.
- No existing invoice, quote, customer, Job Costing calculation, email, payment-gateway or subscription logic was changed.

## Deploy (if v51 has NOT been deployed)
1. Run `V51-MY-EXPENSES.sql` in Supabase SQL Editor. This copy already contains the v52-reviewed Expenses schema.
2. Deploy this ZIP to Netlify.
3. In Super Admin, enable **My Expenses** for the required business.

No Edge Function redeployment is required.
