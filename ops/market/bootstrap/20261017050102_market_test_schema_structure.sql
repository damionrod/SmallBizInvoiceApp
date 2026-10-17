-- Frindly Market: isolated project smvvevrtjqkflyqkyape only.
-- Production remains read-only. Preserve existing test records.
DO $market_guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='frindly_isolated_full_expense_rollback_test_v1') THEN
    RAISE EXCEPTION 'Market bootstrap requires the existing isolated-test project';
  END IF;
END;
$market_guard$;
SET LOCAL check_function_bodies = off;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '90s';

CREATE TABLE public."accounting_legacy_payroll_resolution_events" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "pay_run_id" uuid NOT NULL,
  "event_type" text NOT NULL,
  "treatment" text,
  "note" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "created_by" uuid NOT NULL
);

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."accounting_source_mappings" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "source_type" text NOT NULL,
  "source_id" uuid,
  "source_key" text,
  "source_name" text DEFAULT ''::text NOT NULL,
  "purpose" text DEFAULT 'expense'::text NOT NULL,
  "account_id" uuid,
  "xero_account_code" text,
  "xero_tax_type" text,
  "requires_review" boolean DEFAULT false NOT NULL,
  "notes" text,
  "archived" boolean DEFAULT false NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_by" uuid
);

ALTER TABLE public."accounting_source_mappings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."akahu_feed_accounts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "connection_id" uuid NOT NULL,
  "bank_account_id" uuid,
  "provider_account_id" text NOT NULL,
  "account_name" text,
  "account_number" text,
  "currency" text DEFAULT 'NZD'::text NOT NULL,
  "account_type" text,
  "status" text DEFAULT 'active'::text NOT NULL,
  "last_balance" numeric(14,2),
  "last_balance_at" timestamp with time zone,
  "last_synced_at" timestamp with time zone,
  "raw_account" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."akahu_feed_accounts" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."akahu_feed_connections" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "provider" text DEFAULT 'akahu'::text NOT NULL,
  "environment" text DEFAULT 'sandbox'::text NOT NULL,
  "status" text DEFAULT 'pending'::text NOT NULL,
  "akahu_user_id" text,
  "consent_state" text,
  "scopes" text[] DEFAULT '{}'::text[] NOT NULL,
  "access_token" text,
  "refresh_token" text,
  "token_expires_at" timestamp with time zone,
  "last_sync_at" timestamp with time zone,
  "last_sync_status" text,
  "last_sync_message" text,
  "created_by" uuid,
  "updated_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."akahu_feed_connections" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."akahu_feed_sync_runs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "connection_id" uuid,
  "status" text DEFAULT 'running'::text NOT NULL,
  "started_at" timestamp with time zone DEFAULT now() NOT NULL,
  "finished_at" timestamp with time zone,
  "imported_count" integer DEFAULT 0 NOT NULL,
  "duplicate_count" integer DEFAULT 0 NOT NULL,
  "account_count" integer DEFAULT 0 NOT NULL,
  "error_message" text,
  "created_by" uuid
);

ALTER TABLE public."akahu_feed_sync_runs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."blinkpay_feed_accounts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "connection_id" uuid NOT NULL,
  "bank_account_id" uuid,
  "provider_account_id" text NOT NULL,
  "account_name" text,
  "account_number" text,
  "currency" text DEFAULT 'NZD'::text NOT NULL,
  "account_type" text,
  "status" text DEFAULT 'active'::text NOT NULL,
  "last_balance" numeric(14,2),
  "last_balance_at" timestamp with time zone,
  "last_synced_at" timestamp with time zone,
  "raw_account" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."blinkpay_feed_accounts" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."blinkpay_feed_connections" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "provider" text DEFAULT 'blinkpay'::text NOT NULL,
  "environment" text DEFAULT 'sandbox'::text NOT NULL,
  "status" text DEFAULT 'pending'::text NOT NULL,
  "bank_name" text,
  "consent_id" text,
  "consent_state" text,
  "scopes" text[] DEFAULT '{}'::text[] NOT NULL,
  "access_token" text,
  "refresh_token" text,
  "token_expires_at" timestamp with time zone,
  "consent_expires_at" timestamp with time zone,
  "last_sync_at" timestamp with time zone,
  "last_sync_status" text,
  "last_sync_message" text,
  "created_by" uuid,
  "updated_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."blinkpay_feed_connections" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."blinkpay_feed_sync_runs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "connection_id" uuid,
  "status" text DEFAULT 'running'::text NOT NULL,
  "started_at" timestamp with time zone DEFAULT now() NOT NULL,
  "finished_at" timestamp with time zone,
  "imported_count" integer DEFAULT 0 NOT NULL,
  "duplicate_count" integer DEFAULT 0 NOT NULL,
  "account_count" integer DEFAULT 0 NOT NULL,
  "error_message" text,
  "created_by" uuid
);

ALTER TABLE public."blinkpay_feed_sync_runs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."business_owner_history" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "owner_id" uuid NOT NULL,
  "effective_date" date NOT NULL,
  "change_type" text NOT NULL,
  "before_data" jsonb,
  "after_data" jsonb NOT NULL,
  "note" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "created_by" uuid
);

ALTER TABLE public."business_owner_history" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_ad_campaigns" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "package_id" uuid,
  "sponsor_type" text DEFAULT 'external'::text NOT NULL,
  "sponsor_business_id" uuid,
  "sponsor_name" text NOT NULL,
  "sponsor_contact_email" text,
  "title" text NOT NULL,
  "body" text,
  "destination_url" text,
  "placement" text DEFAULT 'top'::text NOT NULL,
  "target_region" text,
  "target_industry" text,
  "price_charged" numeric(12,2) DEFAULT 0 NOT NULL,
  "currency" text DEFAULT 'NZD'::text NOT NULL,
  "stripe_checkout_session_id" text,
  "stripe_payment_intent_id" text,
  "payment_status" text DEFAULT 'manual'::text NOT NULL,
  "status" text DEFAULT 'draft'::text NOT NULL,
  "priority" integer DEFAULT 0 NOT NULL,
  "starts_at" timestamp with time zone DEFAULT now() NOT NULL,
  "ends_at" timestamp with time zone DEFAULT (now() + '30 days'::interval) NOT NULL,
  "approved_by" uuid,
  "approved_at" timestamp with time zone,
  "created_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "image_url" text
);

ALTER TABLE public."community_ad_campaigns" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_ad_clicks" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "campaign_id" uuid NOT NULL,
  "business_id" uuid,
  "user_id" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."community_ad_clicks" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_ad_impressions" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "campaign_id" uuid NOT NULL,
  "business_id" uuid,
  "user_id" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."community_ad_impressions" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_ad_packages" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "name" text NOT NULL,
  "price" numeric(12,2) DEFAULT 0 NOT NULL,
  "currency" text DEFAULT 'NZD'::text NOT NULL,
  "duration_days" integer DEFAULT 30 NOT NULL,
  "placement" text DEFAULT 'top'::text NOT NULL,
  "active" boolean DEFAULT true NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "slot_limit" integer DEFAULT 1 NOT NULL
);

ALTER TABLE public."community_ad_packages" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_blocked_words" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "word" text NOT NULL,
  "severity" text DEFAULT 'block'::text NOT NULL,
  "active" boolean DEFAULT true NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."community_blocked_words" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_comments" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "post_id" uuid NOT NULL,
  "author_profile_id" uuid NOT NULL,
  "body" text NOT NULL,
  "status" text DEFAULT 'active'::text NOT NULL,
  "hidden_reason" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."community_comments" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_conversations" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "created_by_profile_id" uuid NOT NULL,
  "participant_profile_ids" uuid[] NOT NULL,
  "status" text DEFAULT 'active'::text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."community_conversations" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_messages" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "conversation_id" uuid NOT NULL,
  "author_profile_id" uuid NOT NULL,
  "body" text NOT NULL,
  "status" text DEFAULT 'active'::text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "read_at" timestamp with time zone
);

ALTER TABLE public."community_messages" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_posts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "author_profile_id" uuid NOT NULL,
  "business_id" uuid NOT NULL,
  "title" text NOT NULL,
  "body" text NOT NULL,
  "category" text DEFAULT 'general'::text NOT NULL,
  "region" text,
  "industry" text,
  "status" text DEFAULT 'active'::text NOT NULL,
  "hidden_reason" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "image_url" text
);

ALTER TABLE public."community_posts" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_profiles" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "business_id" uuid NOT NULL,
  "display_name" text NOT NULL,
  "show_business_name" boolean DEFAULT true NOT NULL,
  "show_region" boolean DEFAULT true NOT NULL,
  "show_industry" boolean DEFAULT true NOT NULL,
  "private_messages_enabled" boolean DEFAULT true NOT NULL,
  "region" text,
  "industry" text,
  "suspended_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."community_profiles" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_reports" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "reporter_profile_id" uuid NOT NULL,
  "target_type" text NOT NULL,
  "target_id" uuid NOT NULL,
  "reason" text,
  "status" text DEFAULT 'open'::text NOT NULL,
  "reviewed_by" uuid,
  "reviewed_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."community_reports" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."community_settings" (
  "id" boolean DEFAULT true NOT NULL,
  "auto_post" boolean DEFAULT true NOT NULL,
  "allow_post_images" boolean DEFAULT false NOT NULL,
  "posts_per_page" integer DEFAULT 20 NOT NULL,
  "retention_months" integer DEFAULT 12 NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_by" uuid
);

ALTER TABLE public."community_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."edge_function_rate_limits" (
  "scope" text NOT NULL,
  "identifier" text NOT NULL,
  "window_start" timestamp with time zone NOT NULL,
  "request_count" integer DEFAULT 0 NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."edge_function_rate_limits" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."email_delivery_events" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "message_type" text NOT NULL,
  "source_table" text,
  "source_id" uuid,
  "recipient" text NOT NULL,
  "subject" text,
  "provider" text DEFAULT 'resend'::text NOT NULL,
  "provider_message_id" text,
  "status" text DEFAULT 'sent'::text NOT NULL,
  "sent_by" uuid,
  "sent_at" timestamp with time zone DEFAULT now() NOT NULL,
  "delivered_at" timestamp with time zone,
  "failed_at" timestamp with time zone,
  "error_message" text,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."email_delivery_events" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."gst_transition_reviews" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "jurisdiction" text DEFAULT 'NZ'::text NOT NULL,
  "effective_from" date NOT NULL,
  "previous_registered" boolean NOT NULL,
  "new_registered" boolean NOT NULL,
  "window_end" date,
  "affected_invoice_ids" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
  "affected_expense_ids" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
  "invoice_count" integer DEFAULT 0 NOT NULL,
  "expense_count" integer DEFAULT 0 NOT NULL,
  "status" text DEFAULT 'open'::text NOT NULL,
  "created_by" uuid NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "resolved_by" uuid,
  "resolved_at" timestamp with time zone,
  "notes" text
);

ALTER TABLE public."gst_transition_reviews" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."invoice_auto_reminder_runs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "invoice_id" uuid NOT NULL,
  "reminder_key" text NOT NULL,
  "reminder_days" integer NOT NULL,
  "scheduled_for" date NOT NULL,
  "status" text DEFAULT 'claimed'::text NOT NULL,
  "recipient" text,
  "subject" text,
  "provider_message_id" text,
  "error_message" text,
  "claimed_at" timestamp with time zone DEFAULT now() NOT NULL,
  "processed_at" timestamp with time zone,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL
);

ALTER TABLE public."invoice_auto_reminder_runs" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."invoice_reminder_history" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "invoice_id" uuid NOT NULL,
  "recipient" text NOT NULL,
  "subject" text NOT NULL,
  "provider_message_id" text,
  "sent_by" uuid,
  "sent_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."invoice_reminder_history" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."ird_connect_settings" (
  "provider" text DEFAULT 'ird'::text NOT NULL,
  "enabled" boolean DEFAULT false NOT NULL,
  "mode" text DEFAULT 'manual'::text NOT NULL,
  "public_config" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "notes" text,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_by" uuid
);

ALTER TABLE public."ird_connect_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."ird_filing_batches" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "filing_type" text NOT NULL,
  "source_table" text,
  "source_id" uuid,
  "period_start" date NOT NULL,
  "period_end" date NOT NULL,
  "due_date" date,
  "status" text DEFAULT 'draft'::text NOT NULL,
  "filing_method" text DEFAULT 'manual'::text NOT NULL,
  "package_payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "validation_summary" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "file_name" text,
  "file_hash" text,
  "ird_reference" text,
  "notes" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "created_by" uuid,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_by" uuid
);

ALTER TABLE public."ird_filing_batches" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."ird_filing_events" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "batch_id" uuid NOT NULL,
  "event_type" text NOT NULL,
  "status" text,
  "details" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "created_by" uuid
);

ALTER TABLE public."ird_filing_events" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."late_transaction_adjustments" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "expense_id" uuid NOT NULL,
  "original_invoice_date" date NOT NULL,
  "entered_at" timestamp with time zone DEFAULT now() NOT NULL,
  "original_gst_return_id" uuid,
  "original_gst_period_start" date,
  "original_gst_period_end" date,
  "original_return_status" text,
  "accounting_period_id" uuid,
  "gst_basis" text NOT NULL,
  "gst_amount" numeric(14,2) DEFAULT 0 NOT NULL,
  "treatment" text NOT NULL,
  "adjustment_date" date,
  "adjustment_gst_period_start" date,
  "adjustment_gst_period_end" date,
  "adjustment_reason" text NOT NULL,
  "rule_version" text NOT NULL,
  "status" text NOT NULL,
  "gst_adjustment_id" uuid,
  "correction_item_id" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "created_by" uuid,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_by" uuid
);

ALTER TABLE public."late_transaction_adjustments" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."payroll_ird_filings" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "pay_run_id" uuid NOT NULL,
  "pay_date" date NOT NULL,
  "filing_method" text NOT NULL,
  "status" text NOT NULL,
  "file_name" text,
  "file_hash" text,
  "ird_reference" text,
  "notes" text,
  "marked_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."payroll_ird_filings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."plan_public_features" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "feature_key" text NOT NULL,
  "title" text NOT NULL,
  "description" text,
  "feature_group" text DEFAULT 'Features'::text NOT NULL,
  "module_slug" text,
  "value_source" text DEFAULT 'module'::text NOT NULL,
  "is_public" boolean DEFAULT true NOT NULL,
  "sort_order" integer DEFAULT 100 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."plan_public_features" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."provisional_tax_instalments" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "plan_id" uuid NOT NULL,
  "instalment_number" integer NOT NULL,
  "due_date" date NOT NULL,
  "suggested_amount" numeric DEFAULT 0 NOT NULL,
  "paid_amount" numeric DEFAULT 0 NOT NULL,
  "status" text DEFAULT 'planned'::text NOT NULL,
  "notes" text,
  "updated_by" uuid,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."provisional_tax_instalments" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."provisional_tax_plans" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "tax_year_end" date NOT NULL,
  "method" text DEFAULT 'estimate'::text NOT NULL,
  "estimated_taxable_profit" numeric DEFAULT 0 NOT NULL,
  "estimated_income_tax" numeric DEFAULT 0 NOT NULL,
  "status" text DEFAULT 'draft'::text NOT NULL,
  "notes" text,
  "created_by" uuid,
  "updated_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."provisional_tax_plans" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."subscription_lifecycle_notifications" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "subscription_id" uuid NOT NULL,
  "notification_key" text NOT NULL,
  "event_type" text NOT NULL,
  "event_at" timestamp with time zone NOT NULL,
  "due_at" timestamp with time zone NOT NULL,
  "sent_at" timestamp with time zone,
  "email_to" text,
  "error_message" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."subscription_lifecycle_notifications" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."subscription_notification_scheduler_config" (
  "singleton" boolean DEFAULT true NOT NULL,
  "endpoint" text NOT NULL,
  "secret_name" text DEFAULT 'subscription_notification_secret'::text NOT NULL,
  "enabled" boolean DEFAULT false NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."subscription_notification_scheduler_config" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."support_audit_log" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "admin_user_id" uuid NOT NULL,
  "target_user_id" uuid,
  "target_business_id" uuid,
  "action" text NOT NULL,
  "outcome" text NOT NULL,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL
);

ALTER TABLE public."support_audit_log" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."support_messages" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "thread_id" uuid NOT NULL,
  "business_id" uuid NOT NULL,
  "sender_user_id" uuid NOT NULL,
  "sender_role" text NOT NULL,
  "body" text DEFAULT ''::text NOT NULL,
  "attachment_path" text,
  "attachment_name" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."support_messages" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."support_operational_events" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "reference" text NOT NULL,
  "severity" text NOT NULL,
  "service" text NOT NULL,
  "business_id" uuid,
  "user_id" uuid,
  "summary" text NOT NULL,
  "status" text DEFAULT 'Open'::text NOT NULL,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL
);

ALTER TABLE public."support_operational_events" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."support_presence" (
  "admin_user_id" uuid NOT NULL,
  "is_online" boolean DEFAULT false NOT NULL,
  "last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."support_presence" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."support_threads" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "business_id" uuid NOT NULL,
  "created_by_user_id" uuid NOT NULL,
  "category" text DEFAULT 'other'::text NOT NULL,
  "subject" text NOT NULL,
  "status" text DEFAULT 'open'::text NOT NULL,
  "channel" text DEFAULT 'ticket'::text NOT NULL,
  "current_module" text,
  "browser" text,
  "app_version" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "last_message_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public."support_threads" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_accounts" ADD COLUMN "report_section" text DEFAULT 'other'::text NOT NULL;

ALTER TABLE public."accounting_accounts" ADD COLUMN "is_system" boolean DEFAULT false NOT NULL;

ALTER TABLE public."accounting_accounts" ADD COLUMN "is_control" boolean DEFAULT false NOT NULL;

ALTER TABLE public."accounting_accounts" ADD COLUMN "xero_account_code" text;

ALTER TABLE public."accounting_accounts" ADD COLUMN "xero_account_type" text;

ALTER TABLE public."accounting_accounts" ADD COLUMN "xero_tax_type" text;

ALTER TABLE public."accounting_accounts" ADD COLUMN "description" text;

ALTER TABLE public."bank_reconciliation_allocations" ADD COLUMN "pay_run_id" uuid;

ALTER TABLE public."bank_reconciliation_allocations" ADD COLUMN "equity_transaction_type" text;

ALTER TABLE public."bank_reconciliation_allocations" ADD COLUMN "equity_note" text;

ALTER TABLE public."bank_reconciliation_allocations" ADD COLUMN "accounting_journal_id" uuid;

ALTER TABLE public."bank_reconciliation_allocations" ADD COLUMN "pay_run_employee_id" uuid;

ALTER TABLE public."bank_reconciliation_allocations" ADD COLUMN "related_bank_transaction_id" uuid;

ALTER TABLE public."bank_reconciliation_allocations" ADD COLUMN "owner_id" uuid;

ALTER TABLE public."bank_transactions" ADD COLUMN "source_provider" text DEFAULT 'csv'::text NOT NULL;

ALTER TABLE public."bank_transactions" ADD COLUMN "external_transaction_id" text;

ALTER TABLE public."bank_transactions" ADD COLUMN "external_account_id" text;

ALTER TABLE public."bank_transactions" ADD COLUMN "source_payload" jsonb DEFAULT '{}'::jsonb NOT NULL;

ALTER TABLE public."bank_transactions" ADD COLUMN "pending_status" text;

ALTER TABLE public."customers" ADD COLUMN "auto_reminder_policy" text DEFAULT 'default'::text NOT NULL;

ALTER TABLE public."finlo_helper_settings" ADD COLUMN "default_helper_name" text DEFAULT 'Frindly'::text NOT NULL;

ALTER TABLE public."invoices" ADD COLUMN "quote_billing_type" text;

ALTER TABLE public."invoices" ADD COLUMN "quote_stage_label" text;

ALTER TABLE public."invoices" ADD COLUMN "quote_billing_ex_gst" numeric;

ALTER TABLE public."invoices" ADD COLUMN "quote_original_ex_gst" numeric;

ALTER TABLE public."invoices" ADD COLUMN "quote_previously_invoiced_ex_gst" numeric;

ALTER TABLE public."invoices" ADD COLUMN "quote_remaining_ex_gst" numeric;

ALTER TABLE public."invoices" ADD COLUMN "billing_series_id" uuid;

ALTER TABLE public."invoices" ADD COLUMN "auto_reminder_policy" text DEFAULT 'default'::text NOT NULL;

ALTER TABLE public."invoices" ADD COLUMN "auto_reminders_paused_until" date;

ALTER TABLE public."job_schedules" ADD COLUMN "payroll_create_timesheets" boolean DEFAULT true NOT NULL;

ALTER TABLE public."job_schedules" ADD COLUMN "payroll_break_minutes" integer DEFAULT 0 NOT NULL;

ALTER TABLE public."payroll_employees" ADD COLUMN "labour_classification" text;

ALTER TABLE public."payroll_settings" ADD COLUMN "default_labour_classification" text DEFAULT 'indirect'::text NOT NULL;

ALTER TABLE public."payroll_settings" ADD COLUMN "employer_ird_number" text;

ALTER TABLE public."payroll_settings" ADD COLUMN "payroll_contact_name" text;

ALTER TABLE public."payroll_settings" ADD COLUMN "payroll_contact_phone" text;

ALTER TABLE public."payroll_settings" ADD COLUMN "payroll_contact_email" text;

ALTER TABLE public."payroll_settings" ADD COLUMN "paye_intermediary_ird_number" text;

ALTER TABLE public."payroll_settings" ADD COLUMN "payroll_package_identifier" text DEFAULT 'Frindly_v61'::text;

ALTER TABLE public."payroll_timesheets" ADD COLUMN "source_type" text;

ALTER TABLE public."payroll_timesheets" ADD COLUMN "source_schedule_id" uuid;

ALTER TABLE public."payroll_timesheets" ADD COLUMN "source_schedule_assignment_id" uuid;

ALTER TABLE public."se_assets" ADD COLUMN "disposal_ex_gst" numeric;

ALTER TABLE public."se_assets" ADD COLUMN "disposal_gst_output" numeric;

ALTER TABLE public."se_assets" ADD COLUMN "disposal_gst_credit_adjustment" numeric;

ALTER TABLE public."se_assets" ADD COLUMN "disposal_journal_id" uuid;

ALTER TABLE public."se_assets" ADD COLUMN "disposal_reason" text;

ALTER TABLE public."se_assets" ADD COLUMN "disposal_accounted_at" timestamp with time zone;

ALTER TABLE public."subscriptions" ADD COLUMN "renewal_preference" text DEFAULT 'automatic'::text NOT NULL;

ALTER TABLE public."business_owners" ALTER COLUMN "ownership_percent" TYPE numeric(7,4);

ALTER TABLE public."business_owners" ALTER COLUMN "shares_held" TYPE numeric(18,4);

ALTER TABLE public."frindly_expense_correction_requests_v1" ALTER COLUMN "proposed_total" TYPE numeric;

ALTER TABLE public."frindly_expense_correction_requests_v1" ALTER COLUMN "original_total" TYPE numeric;

ALTER TABLE public."owner_current_account_entries" ALTER COLUMN "amount" TYPE numeric(14,2);

ALTER TABLE public."invoice_payment_settings" ALTER COLUMN "fee_mode" SET DEFAULT 'pass'::text;
