# v34 deployment steps

1. Supabase → SQL Editor → run `V34-PAYMENT-GATEWAYS.sql` once.
2. Netlify → Deploys → upload the v34 ZIP.
3. Supabase → Edge Functions → replace/redeploy `create-checkout`, `create-portal`, and `stripe-webhook` using the v34 versions.
4. Create/deploy the new `test-payment-provider` Edge Function.
5. Log in as Damien → Super Admin → Payment gateway settings.

No Stripe account is required to deploy v34. Leave Stripe disabled until credentials are available.

After this one-time deployment, Stripe keys can be changed from Super Admin without changing the app code again.
