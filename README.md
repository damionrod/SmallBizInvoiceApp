# Invoice Manager v23 — SaaS + Job Costing

# Invoice Manager v22 — SaaS Foundation

v22 keeps the existing invoice, customer, report, PDF, email-status, recurring-invoice and settings workflows, while adding the account/subscription architecture needed to sell the application to multiple businesses.

## What is new in v22

### 1. Login and account creation
- Email + password login.
- Simple sign-up form: owner name, business name, address, phone, email and password.
- Password reset.
- A new business workspace is created automatically for every new account.
- New businesses automatically start on a 14-day Trial plan.

### 2. Cloud-first, multi-device data
- Supabase is now the source of truth for signed-in users.
- Invoices and customers are separated by `business_id` and protected with Row Level Security (RLS).
- Business settings are also stored in Supabase, so the same logo/company/settings appear after logging in on another device.
- Browser storage remains a per-business cache/fallback only.
- The Supabase project URL and publishable key are application infrastructure in `app-config.js`; customers no longer configure Supabase in Settings.

### 3. Existing-data migration
On the first v22 login from the browser that contains the old invoice data, the app attempts a one-time migration of locally stored customers and invoices into the signed-in business workspace. The old browser data can no longer be claimed by a second business account on that browser.

For the safest migration, create/log into your owner account on the same desktop/browser that currently contains your invoices before testing from the phone.

### 4. Subscription plans and invoice limits
Default starter plans are created in Supabase:
- Trial — 10 invoices
- Starter — 25 invoices
- Business — 100 invoices
- Pro — unlimited

Prices and limits are stored in the database and can be changed from Super Admin. Invoice-limit enforcement happens in the database as well as the UI, so it cannot be bypassed by changing browser code.

### 5. Stripe-ready billing
Included Edge Functions:
- `create-checkout` — opens Stripe Checkout for a paid plan.
- `create-portal` — opens Stripe Customer Portal for card/subscription management.
- `stripe-webhook` — updates the app subscription after Stripe events.

The billing UI is built, but purchases become live only after you add your Stripe secret, webhook secret and Stripe Price IDs. Do not put Stripe secret keys in the browser files.

### 6. Super Admin
The Super Admin interface can:
- View businesses and owner users.
- Search/filter accounts.
- See subscription status and invoice usage.
- Change a business plan/status.
- Extend/create trial access.
- Suspend/reactivate subscriptions.
- Create a new business/owner account.
- Edit plan prices, invoice limits and Stripe Price IDs.
- Manage included modules on plans.
- Create/edit future module definitions.
- Enable/disable modules for individual businesses.

### 7. Future modules
The database includes:
- `modules`
- `business_modules`
- `plans.included_modules`

`invoice_manager` is the first module. Future modules such as Job Costing can be added without redesigning the account/subscription system.

### 8. Email wording is configurable
Settings now includes **Email wording**:
- Sender display name
- Subject template
- Body template

Supported placeholders:
`{customerName}`, `{invoiceNumber}`, `{tradingName}`, `{companyName}`, `{total}`, `{balanceDue}`, `{dueDate}`, `{phone}`, `{email}`.

The v22 `send-invoice` Edge Function is generic and no business name is hardcoded.

---

# REQUIRED DEPLOYMENT ORDER

## Step 1 — Run the v22 SQL
In Supabase → SQL Editor, run:

`V22-SAAS-MIGRATION.sql`

If you are creating a completely new Supabase project, `schema.sql` contains both the original invoice schema and the v22 SaaS migration.

**Do this before deploying the v22 website.** v22 replaces the old permissive prototype policies with authenticated business-scoped RLS.

## Step 2 — Deploy v22 to Netlify
Deploy the contents of this folder as the site root. No build command is required.

The public Supabase browser configuration is in:

`app-config.js`

The Supabase publishable key is a browser/public key. Never put a Supabase service-role key, Stripe secret key or Resend secret in this file.

## Step 3 — Create your owner account
Open the deployed site on the desktop/browser containing your current invoices and choose **Create account**.

After signup/login, v22 will attempt to move the existing local browser invoices/customers into that new business workspace. Once cloud data is present, logging into the same account on the phone should show the same invoices and customers.

## Step 4 — Make your account Super Admin
After your account exists, run this once in Supabase SQL Editor, replacing the email:

```sql
update public.profiles
set is_super_admin = true
where email = 'YOUR-LOGIN-EMAIL';
```

Reload the app. The **Admin** tab will appear only for that Super Admin account.

## Step 5 — Deploy Edge Functions
Deploy these functions:
- `send-invoice`
- `create-checkout`
- `create-portal`
- `stripe-webhook`
- `admin-create-user`

The function source is in `supabase/functions/`.

### Required Supabase secrets
For email:
- `RESEND_API_KEY`
- `EMAIL_FROM_ADDRESS` — use an address on your verified Resend domain, e.g. `invoices@yourdomain.co.nz`

For Stripe billing:
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`

Supabase normally supplies these automatically to Edge Functions:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

## Step 6 — Add Stripe Price IDs
Create the paid prices/products in Stripe. Then in **Super Admin → Subscription plans**, paste each Stripe `price_...` ID into the relevant plan.

Until a plan has a Stripe Price ID, clicking Choose Plan will correctly report that billing has not yet been configured for that plan.

## Step 7 — Stripe webhook
Point a Stripe webhook endpoint at your deployed `stripe-webhook` Supabase function and subscribe to:
- `checkout.session.completed`
- `customer.subscription.updated`
- `customer.subscription.deleted`

Copy the webhook signing secret into Supabase as `STRIPE_WEBHOOK_SECRET`.

---

# Important production notes

- Do not re-enable the old `using (true)` prototype RLS policies.
- Keep service-role and payment-provider secret keys only in Supabase secrets.
- Test signup, login, password reset, trial expiry, invoice limits, cross-device sync and Stripe test-mode checkout before taking customer payments.
- Supabase email confirmation settings determine whether a new user receives a confirmation email before the first login.
- Application code changes still require a normal deployment. Super Admin manages users, plans, access and modules; it does not edit application source code from the browser.

# Files
- `index.html` — application UI
- `styles.css` — desktop/mobile UI
- `app.js` — existing invoice/customer/report workflows plus v22 subscription gate/cloud behavior
- `saas.js` — authentication, tenant bootstrap, cross-device settings, subscriptions and Super Admin
- `app-config.js` — public Supabase browser config
- `V22-SAAS-MIGRATION.sql` — upgrade existing Supabase database
- `schema.sql` — complete schema for a fresh install
- `supabase/functions/` — email, Stripe and admin server functions

## v23 — Job Costing + Quotes

v23 keeps the existing v22 invoicing, customer, reports, settings, SaaS login/subscription and admin workflows, and adds the first optional business module: **Job Costing**.

### New workflow
1. Job Costing → Cost Settings: set default labour cost/hour, target gross margin, quote validity, prefixes, terms and reusable cost presets.
2. New Costing: select an existing customer from My Customers, enter labour, variable/direct costs and optional custom fields.
3. The app calculates total job cost ex GST and a recommended selling price using true gross margin: `cost / (1 - margin%)`.
4. Override the recommended figure with your own quote price ex GST.
5. Create Quote: saves the quote in Supabase with GST and total.
6. Quotes can be opened, edited, downloaded as PDF, emailed, marked Approved/Rejected, and searched by status.
7. Once Approved, Create Invoice pre-fills the existing Create Invoice screen with the same customer, quote reference, service description and ex-GST quoted price.
8. When that invoice is actually saved, the source quote is automatically marked **Deal won** with a green status tag and linked to the invoice.

### Required database migration
Run `V23-JOB-COSTING-MIGRATION.sql` in Supabase SQL Editor after the v22 migration. It creates `job_costings` and `quotes`, adds the quote-to-invoice link, tenant RLS, the Job Costing module catalogue entry, trial provisioning and the automatic Deal Won trigger.

### Quote email function
Deploy `supabase/functions/send-quote/index.ts` as a Supabase Edge Function named exactly `send-quote`. It uses the same existing Supabase secrets as invoice email: `RESEND_API_KEY` and `EMAIL_FROM_ADDRESS`.

### Module/subscription behaviour
Existing v22 businesses receive Job Costing access when the v23 migration runs so the module can be tested immediately. New Trial accounts include Job Costing. For paid plans, Super Admin can include `job_costing` in a plan's Included modules or enable it for an individual business from Admin → Modules.
