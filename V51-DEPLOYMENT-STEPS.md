# v51 — My Expenses deployment

This release adds the new **My Expenses** module to the existing v50 application. Existing invoice, customer, job costing, quote, reports, account, subscription and payment-gateway behaviour is preserved.

## Step 1 — Run the database migration

In **Supabase → SQL Editor → New query**, paste and run the entire contents of:

`V51-MY-EXPENSES.sql`

Wait for **Success. No rows returned.**

This creates the business-scoped expense/supplier/payment tables, private `expense-documents` Storage bucket, RLS policies, default expense categories, payment/reconciliation logic, audit records and the `expenses` module catalogue entry.

## Step 2 — Deploy the website

Deploy this v51 folder/ZIP to Netlify in the same way as previous releases.

No Edge Function redeployment is required for v51.

## Step 3 — Enable My Expenses for a business

The new module is deliberately **not automatically enabled for every customer business**.

1. Log in as Super Admin.
2. Open **Super Admin**.
3. Find the business.
4. Click **Modules**.
5. Tick **My Expenses**.
6. Click **Save modules**.

Unticking My Expenses later suspends that module for that business without deleting its expense data.

## Step 4 — First checks

For one enabled test business:

- Open **My Expenses**.
- Confirm the default categories are visible.
- Create a supplier.
- Create a GST-inclusive test expense for 115.00 at 15% GST and confirm Ex GST = 100.00, GST = 15.00 and Total = 115.00.
- Upload a receipt/photo and confirm it can be viewed.
- Record a partial payment and confirm status becomes Part Paid.
- Mark the expense reconciled and confirm reconciliation remains separate from payment status.
- Create an expense linked to a Job Costing record.

Then log into a second business and confirm the first business's suppliers, categories, expenses, documents and payments do not appear.
