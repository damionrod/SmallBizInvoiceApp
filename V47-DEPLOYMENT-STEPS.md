# Invoice Manager v47 deployment

This release adds only:
- Export My Data for each business.
- Export Business Data for Super Admin, per business.
- Per-business invoice/quote sender email in Account Settings.
- Per-business currency in Account Settings.

## 1. Netlify
Deploy the full v47 ZIP/site folder to Netlify as usual.

## 2. Supabase Edge Functions
Redeploy these two existing functions using the v47 files:
- `send-invoice` → `supabase/functions/send-invoice/index.ts`
- `send-quote` → `supabase/functions/send-quote/index.ts`

Keep **Verify JWT with legacy secret OFF** for both functions, matching the existing setup.

## 3. No SQL migration
No database migration is required. Sender email and currency are stored inside the existing `businesses.settings` JSON field.

## Sender email note
A business can enter its own From email address in Account Settings. The domain of that address must be verified with the configured email provider (Resend). If left blank, the existing platform sender email is used.
