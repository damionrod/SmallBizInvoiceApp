# Invoice Manager v44

This version contains **layout-only refinements to the New Costing customer/job details and Pricing decision sections**. It does not change calculations, validation, database behaviour, or any other app functionality. The alignment is tightened on desktop and remains responsive on tablet/mobile.


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

## v24 — Universal Job Costing Upgrade
Run `V24-JOB-COSTING-UPGRADE.sql` after the v23 migration. This upgrade preserves existing invoice/customer/quote data and adds overhead allocation, labour roles, variable rates including fuel, direct costs, contingency, minimum charge, true gross-margin pricing, profit/margin feedback, snapshot-based historical costings, duplication, and the two overhead allocation bases.


## v25 — Compact Job Costing Layout & Editing Fix
- Makes the New Costing screen substantially denser on desktop, with a two-column workspace and sticky pricing/cost summary.
- Keeps the existing mobile stacking behaviour and improves mobile action placement.
- Adds a Create Customer button directly in New Costing using the existing My Customers editor; the newly saved customer is automatically selected in the costing.
- Makes saved costing quote-price editing explicit and enabled.
- Improves Edit Quote so the ex-GST price is clearly editable and GST/customer total update live before saving.
- No database migration is required for v25; it uses the existing v24 schema.


## v26 – Live line total fix
- Job Costing Labour line totals now update immediately when hours, workers, or cost/hour change.
- Travel / Variable Cost line totals now update immediately when quantity or rate changes.
- Direct Job Cost line totals now update immediately when quantity or unit cost changes.
- Overall costing summary continues to recalculate at the same time.
- No database migration is required from v25.

## v27 — Custom New Costing Template
- Every Active Labour Role is automatically shown on a new costing with its saved hourly cost.
- Every Active Variable Cost Rate is automatically shown with its saved rate/calculation.
- Every Active Cost Preset is automatically shown with its saved unit cost.
- Optional variable/direct quantities and labour hours start at zero, so visible template rows do not accidentally add cost until used.
- Active Business Overheads continue to be allocated automatically and can now be expanded in the Cost Breakdown to see which overheads are included and each job allocation.
- Inactive settings remain available in Cost Settings but are not preloaded on new costings.
- Existing saved costings still use their historical snapshots and are not changed by current settings.
- No database migration is required from v24-v26.

## v28 — Module navigation + compact invoice layout
- Main navigation simplified to four primary modules: Invoicing, Job Costing, My Customers, Reports.
- Invoicing now contains Create Invoice, My Invoices and Settings as internal module tabs.
- Super Admin access moved into Account & subscription so it remains available without occupying main navigation.
- Create Invoice layout made denser on desktop/tablet while preserving all existing fields and behaviour.
- Mobile navigation normalized to four primary modules; invoice sub-navigation remains touch-friendly.
- No database migration is required for v28.


## v29 – Account Menu & Quote Designer

This release is a UI/settings-structure upgrade over v28. Existing invoicing, customers, reports, job costing calculations, saved costings, quote workflow, email, PDF and SaaS data structures remain in place.

### Account menu
- The top-right account initial now opens a dedicated account menu instead of sending the user to Invoice Settings.
- Account Settings contains user name, login email, business account details, subscription status/usage, Change Plan, Billing Portal (when available), Sign Out and Super Admin access for authorized users.
- Account/subscription controls were removed from Invoice Settings.
- On mobile, the account button remains available in the top-right while the four primary modules remain in the bottom navigation.

### Quote Design
- Job Costing → Cost Settings now includes a Quote Design tab.
- Users can customize quotation title, accent colour, customer/date/table headings, subtotal/GST/total labels, terms heading, default note and whether the business logo is shown.
- A live quotation preview updates while settings are edited.
- The saved design is used by the customer-facing quote preview and generated quote PDF.
- Internal costing, overhead, contingency, profit and margin remain excluded from customer quotations.

### Database
No new Supabase SQL migration is required for v29. Quote design settings are stored inside the existing business settings JSON.

## v30 – Quote Templates, Advances, Quick Quotes & Admin Portal

### Quotation templates
- Quote Design now offers the same core template choices as invoices: Classic, Minimal, Modern, Pastel Cute and Pastel Elegant.
- The selected quote template is used in the live preview and quote PDF.
- Quote branding/labels/logo controls remain configurable.
- Quotations now show the business's default bank/account details by default.

### Advance payments
- Quote settings include a default advance toggle and default advance percentage.
- New job costings inherit the default advance setting, but the user can turn it off or change the percentage for that job before creating the quote.
- Manually created quotes and saved quote editing also allow the advance setting/percentage to be changed or removed.
- The advance amount is calculated from the customer total including GST and shown separately on the quotation.

### Quick Create Quote
- Job Costing → Quotes now includes **+ Create Quote**.
- A quote can be created without creating a Job Costing first.
- The form links to My Customers and the existing Product/Service list and supports multiple quote items.
- Approved quick quotes progress to the existing invoice screen with all quoted items pre-filled.

### Simplified Cost Settings
- General, Business Overheads, Labour Roles, Variable Cost Rates and Cost Presets are now on one Cost Settings page.
- Quote Design remains a separate sub-tab so the operational costing settings stay easy to scan.

### Super Admin portal
- Super Admin now opens in a separate platform-owner portal mode at `#super-admin` with its own header and Back to App control.
- Normal customer application navigation is hidden while the Super Admin portal is open.
- Access remains restricted to accounts flagged as Super Admin.

### Database migration
Run `V30-QUOTE-UPGRADE.sql` once before using the v30 quote advance feature. It safely adds `advance_enabled`, `advance_percent`, and `advance_amount` to existing quotes. Historical quotes remain unchanged with no advance requirement.


## v31 — Super Admin permission fix
- Fixes a UI bug where the `hidden` attribute on the Super Admin account-menu item could be overridden by the menu button's `display:flex` CSS.
- Normal business owners (`is_super_admin = false`) no longer see the Super Admin option.
- Opening the Super Admin portal now re-checks the authenticated profile in Supabase before access is granted.
- A normal customer attempting to use the `#super-admin` route is redirected back to the customer app and denied access.
- Existing Supabase RLS/database protections remain in place; no database migration is required for this release.
- No invoice, customer, quote, job-costing, report, subscription or PDF functionality was changed.

## v32 – Module enforcement + account suspension
- Business-level module switches now override plan-included modules. Turning Job Costing off for one company creates a suspended module override instead of deleting the row and falling back to the plan.
- Normal users re-check module access when the app loads and when the browser regains focus.
- Suspended/canceled businesses are blocked from the application with a clear account-unavailable screen and Sign out option.
- Super Admin Suspend/Activate now updates both the subscription and business status and reports database errors instead of failing silently.
- No database migration required; existing business_modules.status already supports suspended.

## v33 — Subscription signup, plan management and suspension fix

Version 33 adds the subscription flow requested for SaaS onboarding and hardens Super Admin subscription controls.

### What changed
- Fixed **Suspend / Activate** so it no longer depends on an empty nested subscription UUID. Admin actions now operate by `business_id` through guarded database RPC functions.
- Fixed **change plan/status** for a business in Super Admin using the same guarded RPC layer.
- Added **Create subscription plan** to Super Admin.
- Expanded **Edit plan** so Super Admin can change plan name, slug, description, monthly price, invoice limit, Stripe Price ID, included modules, public visibility and sort order.
- Signup now includes a required **Subscription plan** selector.
- **Trial** signup creates the account without payment.
- Selecting a **paid plan** stores the selected plan on signup and automatically continues to Stripe Checkout once the user has an authenticated session. If email confirmation is enabled, the payment step starts after confirmation/login.
- Paid-plan checkout requires that plan to have a valid Stripe Price ID in Super Admin.
- Cache-busting has been moved to `v=33` for the SaaS, invoice and job-costing scripts.

### Required Supabase step for v33
Run this file once in Supabase SQL Editor before testing the new Super Admin actions:

`V33-SUBSCRIPTIONS-ADMIN-SIGNUP.sql`

This migration creates Super-Admin-only RPC functions for plan updates, plan creation, business plan/status changes, trial extensions and suspend/activate. It does not delete or recreate your existing data.

### Stripe requirements for paid signup
Keep the existing Stripe Edge Functions deployed (`create-checkout`, `create-portal`, `stripe-webhook`) and ensure the existing secrets are configured:
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `SUPABASE_SERVICE_ROLE_KEY` (provided by Supabase runtime where applicable)

For each paid plan, enter its Stripe recurring **Price ID** (`price_...`) in Super Admin. A customer selecting that paid plan is then sent to Stripe Checkout after account creation/authentication. The webhook changes the business subscription to the purchased plan after successful checkout.

### Recommended v33 test
1. Run `V33-SUBSCRIPTIONS-ADMIN-SIGNUP.sql`.
2. Deploy the v33 ZIP to Netlify.
3. Log in as Damien → Super Admin.
4. Edit an existing plan and save it; reload and confirm the change persisted.
5. Create a small test paid plan and add a Stripe test-mode recurring Price ID.
6. Suspend Fixfast; refresh Shamal's separate browser session and confirm the account is blocked.
7. Activate Fixfast and confirm access returns.
8. Open Create account in a private browser, choose Trial and verify no Stripe page opens.
9. Create another test account, choose the paid test plan, confirm the account/email, and verify Stripe Checkout opens.

## v34 — Super Admin payment gateway settings

v34 adds a secure **Super Admin → Payment gateway settings** section.

### What is new
- Stripe API credentials can now be entered and changed from Super Admin without editing the website code again.
- Stripe settings include Test/Live mode, Publishable Key, Secret Key, Webhook Signing Secret, Enable/Disable, and a connection test.
- Secret values are stored in **Supabase Vault** and are not written to browser localStorage or returned to the admin UI after saving.
- `create-checkout`, `create-portal`, and `stripe-webhook` now read Stripe credentials from the saved payment settings. Existing Supabase environment secrets remain as a backwards-compatible fallback.
- PayPal, Mollie, and Other/Future Gateway cards are included so credentials/configuration can be stored securely now.
- Only Stripe has an active subscription-checkout adapter in v34. Merely storing PayPal/Mollie/Other credentials cannot make those APIs compatible automatically; each provider needs its own checkout/webhook adapter before it can process subscriptions.

### One-time v34 setup
1. Run `V34-PAYMENT-GATEWAYS.sql` once in Supabase SQL Editor. This enables Supabase Vault and creates the secure gateway settings functions.
2. Redeploy the website ZIP to Netlify.
3. Redeploy these Supabase Edge Functions from the v34 package:
   - `create-checkout`
   - `create-portal`
   - `stripe-webhook`
   - `test-payment-provider` (new)
4. Keep `stripe-webhook` configured as a public webhook endpoint (JWT verification off), as before.
5. After that, future Stripe API-key changes are done from **Super Admin → Payment gateway settings** and do not require another website code deployment.

### Later, when a Stripe account is ready
1. In Super Admin, open Payment gateway settings → Stripe.
2. Start in Test / Sandbox mode.
3. Paste the Stripe Publishable Key, Secret Key, and Webhook Signing Secret.
4. Save Stripe and click **Test connection**.
5. Enable Stripe for checkout and save again.
6. Add the Stripe recurring Price ID to each paid Subscription Plan.
7. Test a new paid signup in an Incognito/private browser window.

The Stripe webhook URL is shown directly in the Super Admin payment card so it can be copied into the Stripe Dashboard when the account is configured.

## v35 — Signup and payment UX hardening
- Paid plans are disabled on signup and in Change Plan while Stripe is disabled or the selected plan has no Stripe Price ID.
- Customers see friendly payment-unavailable wording instead of a raw Edge Function error.
- Create Account now includes **Already have an account? Log in** and duplicate-user errors route back to login.
- Super Admin flags repeated owner-email business records with a **Duplicate record** badge; it does not auto-delete data.
- Run `V35-SIGNUP-PAYMENT-UX.sql` once in Supabase SQL Editor, then deploy the website ZIP.

## v36 – Super Admin permanent account deletion
Run `V36-DELETE-ACCOUNT.sql` in Supabase SQL Editor before using the new Super Admin **Delete** button. The action requires two confirmations and permanently removes the selected business, its linked users, and business-owned database records. The currently logged-in Super Admin business cannot be deleted from its own session.

## v38 — exact invoice preview/PDF renderer
- PDF generation now captures the same HTML invoice renderer used for the actual invoice preview.
- Logo, selected template, colours, headings, table styling, totals and payment section now stay visually aligned between preview and PDF.
- No database migration is required for v38.


## v39 – Quote preview/PDF consistency
- Quote PDFs are now rendered from the exact same quotation HTML/template used by the live quotation preview and the customer-facing quote preview.
- Logo, template, colours, customer/date cards, table styling, totals, payment details, notes and terms now use one renderer.
- No database migration is required for v39.
- No other app functionality was intentionally changed.


## v40 – Quick quote customer fix
- Fixed **+ Create Customer** from the Create Quote window so the customer editor opens above the quote.
- A quote can now be issued by typing only a new customer/business name. When the quote is saved, that name is automatically created in My Customers and linked to the quote.
- Existing customer names continue to link to the existing customer record.
- No database migration is required.
- No other app behaviour was changed.


## v41 – Super Admin duplicate row display fix
- Fixed the Super Admin portal rendering the same business twice because the admin table was being rendered twice at the same time when the Admin view opened.
- No business, subscription, customer, invoice, quote or other database records are changed or deleted.
- No database migration is required.
- No other app behaviour was changed.


## v43 – Optional job name and simplified duration input
- Job name / description is no longer required to save a costing or create a quote.
- Expected duration (hours) has been removed from the Job Costing input screen.
- No database migration is required.
