# v48 deployment steps

This release fixes currency coverage/display, makes the invoice/quote sender email obvious in Account Settings, and strengthens per-business isolation for products and job-costing settings.

1. Deploy the v48 ZIP to Netlify. No SQL migration is required.
2. In Supabase Edge Functions, redeploy the updated `send-invoice` and `send-quote` functions from this package so emailed amounts also show the selected ISO currency code. Keep **Verify JWT with legacy secret = OFF** for both functions.
3. Sign out and back in once after deployment so the business-specific settings cache is rebuilt.
4. Open **Account Settings** and choose the business currency and sender email, then save them.

Note: v47 and earlier could copy browser-cached Products / Cost Settings into a newly-created business when that business had no cloud settings yet. v48 prevents that. It also performs a conservative one-time cleanup only when those sections exactly match legacy settings claimed by another business on the same browser.
