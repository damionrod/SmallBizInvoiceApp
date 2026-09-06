# v49 deployment

1. Deploy this ZIP to Netlify.
2. Redeploy Supabase Edge Function `send-invoice` from `supabase/functions/send-invoice/index.ts`.
3. Redeploy Supabase Edge Function `send-quote` from `supabase/functions/send-quote/index.ts`.
4. Keep **Verify JWT with legacy secret = OFF** for both functions.
5. In each business, open Invoice Settings and review/save the separate **Invoice email wording** and **Quotation email wording** templates.

No SQL migration is required.
