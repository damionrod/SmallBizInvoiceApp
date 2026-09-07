# v60 deployment

1. Supabase > SQL Editor: run `V60-FINANCIAL-CORRECTIONS.sql` once.
2. Confirm Success / no blocking error.
3. Deploy the full v60 ZIP to Netlify.
4. Hard refresh (Ctrl+Shift+R).
5. Test: My Invoices > Payment on one unpaid invoice, then Financials > Cash Flow and GST Return.

No Edge Functions need changing.

Important: payments that existed before v60 had no historical payment date. v60 preserves them as `legacy date estimate` records using the invoice date. New payments store the actual date.
