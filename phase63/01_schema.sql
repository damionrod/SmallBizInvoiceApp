-- DISPOSABLE TEST DATABASE ONLY. NEVER RUN ON SUPABASE.
-- Minimal columns from read-only live information_schema inspection, 2026-10-07.
CREATE SCHEMA IF NOT EXISTS public;
CREATE TABLE public.invoices (id uuid PRIMARY KEY, business_id uuid, total numeric NOT NULL DEFAULT 0, lifecycle_state text, amount_paid numeric NOT NULL DEFAULT 0, balance_due numeric, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.invoice_payment_transactions (
 id uuid PRIMARY KEY, business_id uuid NOT NULL, invoice_id uuid NOT NULL,
 amount numeric NOT NULL, currency text NOT NULL DEFAULT 'nzd', status text NOT NULL DEFAULT 'pending',
 customer_payment_id uuid, stripe_payment_intent_id text, stripe_checkout_session_id text,
 failure_reason text, payment_date timestamptz, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.customer_payments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), business_id uuid NOT NULL, invoice_id uuid NOT NULL,
 payment_date date NOT NULL DEFAULT CURRENT_DATE, amount numeric NOT NULL, reference text, notes text,
 payment_source text NOT NULL DEFAULT 'manual', stripe_payment_intent_id text,
 stripe_checkout_session_id text, invoice_payment_transaction_id uuid, currency text
);
-- Verified against live pg_indexes, read-only. NO UNIQUE index on invoice_payment_transaction_id.
CREATE UNIQUE INDEX customer_payments_stripe_payment_intent_uidx ON public.customer_payments(stripe_payment_intent_id) WHERE stripe_payment_intent_id IS NOT NULL;
CREATE UNIQUE INDEX customer_payments_stripe_checkout_session_uidx ON public.customer_payments(stripe_checkout_session_id) WHERE stripe_checkout_session_id IS NOT NULL;
CREATE UNIQUE INDEX invoice_payment_transactions_stripe_payment_intent_id_key ON public.invoice_payment_transactions(stripe_payment_intent_id);
CREATE UNIQUE INDEX invoice_payment_transactions_stripe_checkout_session_id_key ON public.invoice_payment_transactions(stripe_checkout_session_id);

-- Phase59: actual verified FK relationship for payment references, fixture-only.
ALTER TABLE public.invoice_payment_transactions
  ADD CONSTRAINT invoice_payment_transactions_customer_payment_id_fkey
  FOREIGN KEY (customer_payment_id) REFERENCES public.customer_payments(id) ON DELETE SET NULL;
ALTER TABLE public.customer_payments
  ADD CONSTRAINT customer_payments_invoice_payment_transaction_id_fkey
  FOREIGN KEY (invoice_payment_transaction_id) REFERENCES public.invoice_payment_transactions(id) ON DELETE SET NULL;

-- Phase62: production-confirmed invoice foreign keys (isolated fixture only).
ALTER TABLE public.invoice_payment_transactions
  ADD CONSTRAINT invoice_payment_transactions_invoice_id_fkey
  FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE RESTRICT;
ALTER TABLE public.customer_payments
  ADD CONSTRAINT customer_payments_invoice_id_fkey
  FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;
