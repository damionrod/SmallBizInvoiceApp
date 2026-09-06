# v50 deployment — profile security hardening

This release changes **database security only**. There are no UI, calculation, email, invoice, quote, customer, job-costing, subscription or layout changes.

## Step 1 — Supabase
Open **Supabase → SQL Editor → New query** and run the complete contents of:

`V50-PROFILE-PRIVILEGE-HARDENING.sql`

Expected result: **Success. No rows returned.**

## Step 2 — Netlify
Deploy the v50 ZIP normally. The application files are otherwise unchanged from v49.

## No Edge Function redeploy is required
The v49 `send-invoice` and `send-quote` functions remain unchanged.
