# Stripe subscription connection

## Result

Stripe subscription billing is connected in **test mode** for the Supabase project `oxsbzytwbphagcbilxud`.

The existing Finlo billing path is still used:

`saas.js` → `create-checkout` → Stripe Checkout → `stripe-webhook` → `subscriptions`.

No database schema, authentication, billing rules, or unrelated Finlo modules were changed.

## Root cause found

The Stripe test account had no webhook endpoints. Checkout could be created, but Stripe had no destination for subscription completion, renewal, cancellation, or payment-failure events, so Finlo could not reliably update subscription status.

The local source was also incomplete: `create-checkout` and `create-portal` imported a shared payment configuration file that was absent from the local function folder, and the local `create-portal` and `test-payment-provider` sources were missing.

## Deployed functions

- `create-checkout` — active version 7
- `create-portal` — active version 5
- `test-payment-provider` — active version 3
- `stripe-webhook` — active version 10

The functions read gateway credentials from the existing Supabase Vault-backed payment settings. The Stripe secret and webhook signing secret are not stored in source code or returned to the browser.

## Stripe test webhook

An enabled test-mode webhook now targets:

`https://oxsbzytwbphagcbilxud.supabase.co/functions/v1/stripe-webhook`

It listens for Checkout completion, subscription creation/update/deletion, invoice creation, successful payment, and failed payment events. Its signing secret is stored in the existing Supabase Vault record for Stripe.

## Current catalog

The active test Stripe prices are monthly NZD prices for the configured Starter, Business, and Pro plans. Annual checkout remains unavailable until annual Stripe Price IDs are created and entered for the plans; this is intentional and prevents an annual button from charging the wrong amount.

## Verification

- Stripe API confirmed the configured monthly Price IDs are active recurring prices and match the plan amounts.
- Stripe API confirmed the webhook endpoint is enabled and uses the current Stripe API version.
- Supabase confirmed Stripe is enabled in test mode and both `secret_key` and `webhook_secret` exist in Vault (values are intentionally not exposed).
- Function deployment bundling succeeded for all four billing functions.
- Local regression test: `tests/stripe-subscription-integration.test.js` — 9/9 passed.

## Before live launch

Connect a live-mode Stripe account, create live Price IDs, enter a live restricted API key and live webhook signing secret in Super Admin → Payment Settings, switch Stripe to Live, and create a live webhook for the same endpoint. Test mode and live mode use separate Stripe objects and secrets.
