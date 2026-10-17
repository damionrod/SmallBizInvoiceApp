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
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_catalog;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '90s';

ALTER TABLE public."accounting_accounts" DROP CONSTRAINT "accounting_accounts_account_type_check";

ALTER TABLE public."accounting_accounts" ADD CONSTRAINT "accounting_accounts_account_type_check" CHECK (account_type = ANY (ARRAY['asset'::text, 'liability'::text, 'revenue'::text, 'other_income'::text, 'other_expense'::text, 'bank'::text, 'current_asset'::text, 'fixed_asset'::text, 'inventory'::text, 'non_current_asset'::text, 'current_liability'::text, 'non_current_liability'::text, 'equity'::text, 'income'::text, 'cost_of_sales'::text, 'expense'::text, 'tax'::text, 'other'::text]));

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ADD CONSTRAINT "accounting_legacy_payroll_resolution_events_event_type_check" CHECK (event_type = ANY (ARRAY['resolve'::text, 'reopen'::text]));

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ADD CONSTRAINT "accounting_legacy_payroll_resolution_events_pkey" PRIMARY KEY (id);

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ADD CONSTRAINT "legacy_payroll_resolution_note_ck" CHECK (length(btrim(note)) >= 10);

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ADD CONSTRAINT "legacy_payroll_resolution_treatment_ck" CHECK (event_type = 'reopen'::text AND treatment IS NULL OR event_type = 'resolve'::text AND (treatment = ANY (ARRAY['historical_record_acknowledged'::text, 'handled_in_opening_balance'::text, 'verified_outside_frindly'::text])));

ALTER TABLE public."accounting_periods" ADD CONSTRAINT "frindly_accounting_periods_no_overlap" EXCLUDE USING gist (business_id WITH =, daterange(period_start, period_end, '[]'::text) WITH &&);

ALTER TABLE public."accounting_source_mappings" ADD CONSTRAINT "accounting_source_mappings_check" CHECK (source_id IS NOT NULL OR source_key IS NOT NULL);

ALTER TABLE public."accounting_source_mappings" ADD CONSTRAINT "accounting_source_mappings_pkey" PRIMARY KEY (id);

ALTER TABLE public."akahu_feed_accounts" ADD CONSTRAINT "akahu_feed_accounts_currency_len" CHECK (char_length(currency) >= 3 AND char_length(currency) <= 3);

ALTER TABLE public."akahu_feed_accounts" ADD CONSTRAINT "akahu_feed_accounts_pkey" PRIMARY KEY (id);

ALTER TABLE public."akahu_feed_accounts" ADD CONSTRAINT "akahu_feed_accounts_status_chk" CHECK (status = ANY (ARRAY['active'::text, 'archived'::text, 'error'::text, 'inactive'::text]));

ALTER TABLE public."akahu_feed_connections" ADD CONSTRAINT "akahu_feed_connections_environment_chk" CHECK (environment = ANY (ARRAY['sandbox'::text, 'production'::text]));

ALTER TABLE public."akahu_feed_connections" ADD CONSTRAINT "akahu_feed_connections_pkey" PRIMARY KEY (id);

ALTER TABLE public."akahu_feed_connections" ADD CONSTRAINT "akahu_feed_connections_provider_chk" CHECK (provider = 'akahu'::text);

ALTER TABLE public."akahu_feed_connections" ADD CONSTRAINT "akahu_feed_connections_status_chk" CHECK (status = ANY (ARRAY['pending'::text, 'active'::text, 'needs_reconnect'::text, 'disconnected'::text, 'error'::text]));

ALTER TABLE public."akahu_feed_sync_runs" ADD CONSTRAINT "akahu_feed_sync_runs_pkey" PRIMARY KEY (id);

ALTER TABLE public."akahu_feed_sync_runs" ADD CONSTRAINT "akahu_feed_sync_runs_status_chk" CHECK (status = ANY (ARRAY['running'::text, 'completed'::text, 'failed'::text, 'skipped'::text]));

ALTER TABLE public."blinkpay_feed_accounts" ADD CONSTRAINT "blinkpay_feed_accounts_currency_len" CHECK (char_length(currency) >= 3 AND char_length(currency) <= 3);

ALTER TABLE public."blinkpay_feed_accounts" ADD CONSTRAINT "blinkpay_feed_accounts_pkey" PRIMARY KEY (id);

ALTER TABLE public."blinkpay_feed_accounts" ADD CONSTRAINT "blinkpay_feed_accounts_status_chk" CHECK (status = ANY (ARRAY['active'::text, 'archived'::text, 'error'::text]));

ALTER TABLE public."blinkpay_feed_connections" ADD CONSTRAINT "blinkpay_feed_connections_environment_chk" CHECK (environment = ANY (ARRAY['sandbox'::text, 'production'::text]));

ALTER TABLE public."blinkpay_feed_connections" ADD CONSTRAINT "blinkpay_feed_connections_pkey" PRIMARY KEY (id);

ALTER TABLE public."blinkpay_feed_connections" ADD CONSTRAINT "blinkpay_feed_connections_provider_chk" CHECK (provider = 'blinkpay'::text);

ALTER TABLE public."blinkpay_feed_connections" ADD CONSTRAINT "blinkpay_feed_connections_status_chk" CHECK (status = ANY (ARRAY['pending'::text, 'active'::text, 'needs_reconnect'::text, 'disconnected'::text, 'error'::text]));

ALTER TABLE public."blinkpay_feed_sync_runs" ADD CONSTRAINT "blinkpay_feed_sync_runs_pkey" PRIMARY KEY (id);

ALTER TABLE public."blinkpay_feed_sync_runs" ADD CONSTRAINT "blinkpay_feed_sync_runs_status_chk" CHECK (status = ANY (ARRAY['running'::text, 'completed'::text, 'failed'::text, 'skipped'::text]));

ALTER TABLE public."business_owner_history" ADD CONSTRAINT "business_owner_history_change_type_check" CHECK (change_type = ANY (ARRAY['created'::text, 'details_corrected'::text, 'role_changed'::text, 'shareholding_changed'::text, 'appointed_director'::text, 'resigned_director'::text, 'activated'::text, 'deactivated'::text]));

ALTER TABLE public."business_owner_history" ADD CONSTRAINT "business_owner_history_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_dates" CHECK (ends_at > starts_at);

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_len" CHECK (char_length(sponsor_name) >= 1 AND char_length(sponsor_name) <= 120 AND char_length(title) >= 1 AND char_length(title) <= 140);

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_payment_status" CHECK (payment_status = ANY (ARRAY['manual'::text, 'pending'::text, 'paid'::text, 'failed'::text, 'refunded'::text]));

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_placement" CHECK (placement = ANY (ARRAY['top'::text, 'feed'::text, 'sidebar'::text, 'inbox'::text]));

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_sponsor_type" CHECK (sponsor_type = ANY (ARRAY['frindly_user'::text, 'external'::text]));

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_status" CHECK (status = ANY (ARRAY['draft'::text, 'pending_payment'::text, 'paid'::text, 'pending_review'::text, 'active'::text, 'paused'::text, 'rejected'::text, 'expired'::text]));

ALTER TABLE public."community_ad_clicks" ADD CONSTRAINT "community_ad_clicks_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_ad_impressions" ADD CONSTRAINT "community_ad_impressions_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_ad_packages" ADD CONSTRAINT "community_ad_packages_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_ad_packages" ADD CONSTRAINT "community_ad_packages_placement" CHECK (placement = ANY (ARRAY['top'::text, 'feed'::text, 'sidebar'::text, 'inbox'::text]));

ALTER TABLE public."community_ad_packages" ADD CONSTRAINT "community_ad_packages_price" CHECK (price >= 0::numeric AND duration_days > 0);

ALTER TABLE public."community_ad_packages" ADD CONSTRAINT "community_ad_packages_slot_limit_check" CHECK (slot_limit >= 1 AND slot_limit <= 20);

ALTER TABLE public."community_blocked_words" ADD CONSTRAINT "community_blocked_words_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_blocked_words" ADD CONSTRAINT "community_blocked_words_severity" CHECK (severity = ANY (ARRAY['block'::text, 'review'::text]));

ALTER TABLE public."community_blocked_words" ADD CONSTRAINT "community_blocked_words_word_key" UNIQUE (word);

ALTER TABLE public."community_comments" ADD CONSTRAINT "community_comments_body_len" CHECK (char_length(body) >= 1 AND char_length(body) <= 1200);

ALTER TABLE public."community_comments" ADD CONSTRAINT "community_comments_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_comments" ADD CONSTRAINT "community_comments_status" CHECK (status = ANY (ARRAY['active'::text, 'hidden'::text, 'deleted'::text]));

ALTER TABLE public."community_conversations" ADD CONSTRAINT "community_conversations_participants" CHECK (array_length(participant_profile_ids, 1) >= 2);

ALTER TABLE public."community_conversations" ADD CONSTRAINT "community_conversations_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_conversations" ADD CONSTRAINT "community_conversations_status" CHECK (status = ANY (ARRAY['active'::text, 'archived'::text, 'blocked'::text]));

ALTER TABLE public."community_messages" ADD CONSTRAINT "community_messages_body_len" CHECK (char_length(body) >= 1 AND char_length(body) <= 1200);

ALTER TABLE public."community_messages" ADD CONSTRAINT "community_messages_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_messages" ADD CONSTRAINT "community_messages_status" CHECK (status = ANY (ARRAY['active'::text, 'hidden'::text, 'deleted'::text]));

ALTER TABLE public."community_posts" ADD CONSTRAINT "community_posts_category" CHECK (category = ANY (ARRAY['need_workers'::text, 'business_advice'::text, 'recommendation'::text, 'equipment_supplies'::text, 'general'::text]));

ALTER TABLE public."community_posts" ADD CONSTRAINT "community_posts_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_posts" ADD CONSTRAINT "community_posts_status" CHECK (status = ANY (ARRAY['pending'::text, 'active'::text, 'hidden'::text, 'archived'::text, 'deleted'::text]));

ALTER TABLE public."community_posts" ADD CONSTRAINT "community_posts_text_len" CHECK (char_length(title) >= 1 AND char_length(title) <= 140 AND char_length(body) >= 1 AND char_length(body) <= 2000);

ALTER TABLE public."community_profiles" ADD CONSTRAINT "community_profiles_display_name_len" CHECK (char_length(display_name) >= 1 AND char_length(display_name) <= 60);

ALTER TABLE public."community_profiles" ADD CONSTRAINT "community_profiles_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_profiles" ADD CONSTRAINT "community_profiles_user_id_business_id_key" UNIQUE (user_id, business_id);

ALTER TABLE public."community_reports" ADD CONSTRAINT "community_reports_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_reports" ADD CONSTRAINT "community_reports_status" CHECK (status = ANY (ARRAY['open'::text, 'reviewing'::text, 'closed'::text, 'dismissed'::text]));

ALTER TABLE public."community_reports" ADD CONSTRAINT "community_reports_target_type" CHECK (target_type = ANY (ARRAY['post'::text, 'comment'::text, 'message'::text, 'profile'::text, 'ad'::text]));

ALTER TABLE public."community_settings" ADD CONSTRAINT "community_settings_id_check" CHECK (id);

ALTER TABLE public."community_settings" ADD CONSTRAINT "community_settings_pkey" PRIMARY KEY (id);

ALTER TABLE public."community_settings" ADD CONSTRAINT "community_settings_posts_per_page_check" CHECK (posts_per_page >= 5 AND posts_per_page <= 100);

ALTER TABLE public."community_settings" ADD CONSTRAINT "community_settings_retention_months_check" CHECK (retention_months >= 1 AND retention_months <= 120);

ALTER TABLE public."customers" ADD CONSTRAINT "customers_auto_reminder_policy_check" CHECK (auto_reminder_policy = ANY (ARRAY['default'::text, 'on'::text, 'off'::text]));

ALTER TABLE public."edge_function_rate_limits" ADD CONSTRAINT "edge_function_rate_limits_pkey" PRIMARY KEY (scope, identifier);

ALTER TABLE public."email_delivery_events" ADD CONSTRAINT "email_delivery_events_message_type_check" CHECK (message_type = ANY (ARRAY['invoice'::text, 'invoice_reminder'::text, 'quote'::text, 'payslip'::text, 'payment_receipt'::text, 'referral_invite'::text, 'business_invite'::text, 'support_notification'::text, 'other'::text]));

ALTER TABLE public."email_delivery_events" ADD CONSTRAINT "email_delivery_events_pkey" PRIMARY KEY (id);

ALTER TABLE public."email_delivery_events" ADD CONSTRAINT "email_delivery_events_status_check" CHECK (status = ANY (ARRAY['queued'::text, 'sent'::text, 'delivered'::text, 'bounced'::text, 'complained'::text, 'opened'::text, 'clicked'::text, 'failed'::text, 'delivery_unknown'::text]));

ALTER TABLE public."gst_transition_reviews" ADD CONSTRAINT "gst_transition_reviews_expense_count_check" CHECK (expense_count >= 0);

ALTER TABLE public."gst_transition_reviews" ADD CONSTRAINT "gst_transition_reviews_invoice_count_check" CHECK (invoice_count >= 0);

ALTER TABLE public."gst_transition_reviews" ADD CONSTRAINT "gst_transition_reviews_jurisdiction_check" CHECK (jurisdiction = 'NZ'::text);

ALTER TABLE public."gst_transition_reviews" ADD CONSTRAINT "gst_transition_reviews_pkey" PRIMARY KEY (id);

ALTER TABLE public."gst_transition_reviews" ADD CONSTRAINT "gst_transition_reviews_status_check" CHECK (status = ANY (ARRAY['open'::text, 'resolved'::text]));

ALTER TABLE public."invoice_auto_reminder_runs" ADD CONSTRAINT "invoice_auto_reminder_runs_invoice_id_reminder_key_schedule_key" UNIQUE (invoice_id, reminder_key, scheduled_for);

ALTER TABLE public."invoice_auto_reminder_runs" ADD CONSTRAINT "invoice_auto_reminder_runs_pkey" PRIMARY KEY (id);

ALTER TABLE public."invoice_auto_reminder_runs" ADD CONSTRAINT "invoice_auto_reminder_runs_status_check" CHECK (status = ANY (ARRAY['claimed'::text, 'sent'::text, 'failed'::text, 'skipped'::text]));

ALTER TABLE public."invoice_reminder_history" ADD CONSTRAINT "invoice_reminder_history_pkey" PRIMARY KEY (id);

ALTER TABLE public."invoices" ADD CONSTRAINT "invoices_auto_reminder_policy_check" CHECK (auto_reminder_policy = ANY (ARRAY['default'::text, 'on'::text, 'off'::text]));

ALTER TABLE public."ird_connect_settings" ADD CONSTRAINT "ird_connect_settings_mode_chk" CHECK (mode = ANY (ARRAY['manual'::text, 'test'::text, 'live'::text]));

ALTER TABLE public."ird_connect_settings" ADD CONSTRAINT "ird_connect_settings_pkey" PRIMARY KEY (provider);

ALTER TABLE public."ird_connect_settings" ADD CONSTRAINT "ird_connect_settings_provider_chk" CHECK (provider = 'ird'::text);

ALTER TABLE public."ird_filing_batches" ADD CONSTRAINT "ird_filing_batches_method_chk" CHECK (filing_method = ANY (ARRAY['manual'::text, 'file_upload'::text, 'gateway'::text]));

ALTER TABLE public."ird_filing_batches" ADD CONSTRAINT "ird_filing_batches_period_chk" CHECK (period_start <= period_end);

ALTER TABLE public."ird_filing_batches" ADD CONSTRAINT "ird_filing_batches_pkey" PRIMARY KEY (id);

ALTER TABLE public."ird_filing_batches" ADD CONSTRAINT "ird_filing_batches_status_chk" CHECK (status = ANY (ARRAY['draft'::text, 'reviewed'::text, 'exported'::text, 'filed_in_myir'::text, 'gateway_pending'::text, 'gateway_accepted'::text, 'gateway_rejected'::text, 'cancelled'::text]));

ALTER TABLE public."ird_filing_batches" ADD CONSTRAINT "ird_filing_batches_type_chk" CHECK (filing_type = ANY (ARRAY['gst_return'::text, 'payday_filing'::text, 'aim_statement'::text, 'income_tax_return'::text]));

ALTER TABLE public."ird_filing_events" ADD CONSTRAINT "ird_filing_events_pkey" PRIMARY KEY (id);

ALTER TABLE public."ird_filing_events" ADD CONSTRAINT "ird_filing_events_type_chk" CHECK (event_type = ANY (ARRAY['created'::text, 'reviewed'::text, 'exported'::text, 'filed_in_myir'::text, 'gateway_status'::text, 'note'::text, 'cancelled'::text]));

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_business_id_expense_id_key" UNIQUE (business_id, expense_id);

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_pkey" PRIMARY KEY (id);

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_status_check" CHECK (status = ANY (ARRAY['approved_current_period'::text, 'requires_prior_return_action'::text, 'accounting_only'::text, 'reversed'::text]));

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_treatment_check" CHECK (treatment = ANY (ARRAY['current_period'::text, 'prior_return_action'::text, 'accounting_only'::text]));

ALTER TABLE public."payroll_employees" ADD CONSTRAINT "payroll_employees_labour_classification_check" CHECK (labour_classification IS NULL OR (labour_classification = ANY (ARRAY['direct'::text, 'indirect'::text])));

ALTER TABLE public."payroll_ird_filings" ADD CONSTRAINT "payroll_ird_filings_filing_method_check" CHECK (filing_method = ANY (ARRAY['manual'::text, 'file'::text]));

ALTER TABLE public."payroll_ird_filings" ADD CONSTRAINT "payroll_ird_filings_pkey" PRIMARY KEY (id);

ALTER TABLE public."payroll_ird_filings" ADD CONSTRAINT "payroll_ird_filings_status_check" CHECK (status = ANY (ARRAY['manual_viewed'::text, 'file_downloaded'::text, 'filed_in_myir'::text, 'rejected_needs_correction'::text, 'amended'::text]));

ALTER TABLE public."payroll_pay_runs" DROP CONSTRAINT "payroll_pay_runs_status_check";

ALTER TABLE public."payroll_pay_runs" ADD CONSTRAINT "payroll_pay_runs_status_check" CHECK (status = ANY (ARRAY['draft'::text, 'calculated'::text, 'approved'::text, 'finalised'::text, 'reversed'::text]));

ALTER TABLE public."payroll_settings" ADD CONSTRAINT "payroll_settings_default_labour_classification_check" CHECK (default_labour_classification = ANY (ARRAY['direct'::text, 'indirect'::text]));

ALTER TABLE public."payroll_timesheets" ADD CONSTRAINT "payroll_timesheets_source_type_ck" CHECK (source_type IS NULL OR source_type = 'schedule'::text);

ALTER TABLE public."plan_public_features" ADD CONSTRAINT "plan_public_features_feature_key_key" UNIQUE (feature_key);

ALTER TABLE public."plan_public_features" ADD CONSTRAINT "plan_public_features_pkey" PRIMARY KEY (id);

ALTER TABLE public."plan_public_features" ADD CONSTRAINT "plan_public_features_value_source_check" CHECK (value_source = ANY (ARRAY['module'::text, 'core'::text, 'invoice_limit'::text, 'employee_limit'::text]));

ALTER TABLE public."provisional_tax_instalments" ADD CONSTRAINT "provisional_tax_instalments_amount_chk" CHECK (suggested_amount >= 0::numeric AND paid_amount >= 0::numeric);

ALTER TABLE public."provisional_tax_instalments" ADD CONSTRAINT "provisional_tax_instalments_number_chk" CHECK (instalment_number >= 1 AND instalment_number <= 6);

ALTER TABLE public."provisional_tax_instalments" ADD CONSTRAINT "provisional_tax_instalments_pkey" PRIMARY KEY (id);

ALTER TABLE public."provisional_tax_instalments" ADD CONSTRAINT "provisional_tax_instalments_status_chk" CHECK (status = ANY (ARRAY['planned'::text, 'paid'::text, 'review'::text, 'skipped'::text]));

ALTER TABLE public."provisional_tax_plans" ADD CONSTRAINT "provisional_tax_plans_method_chk" CHECK (method = ANY (ARRAY['estimate'::text, 'standard_uplift'::text, 'accountant_advised'::text]));

ALTER TABLE public."provisional_tax_plans" ADD CONSTRAINT "provisional_tax_plans_pkey" PRIMARY KEY (id);

ALTER TABLE public."provisional_tax_plans" ADD CONSTRAINT "provisional_tax_plans_status_chk" CHECK (status = ANY (ARRAY['draft'::text, 'reviewed'::text, 'archived'::text]));

ALTER TABLE public."stripe_refund_processing" ADD CONSTRAINT "stripe_refund_processing_amount_check" CHECK (amount > 0::numeric);

ALTER TABLE public."subscription_lifecycle_notifications" ADD CONSTRAINT "subscription_lifecycle_notifi_subscription_id_notification__key" UNIQUE (subscription_id, notification_key);

ALTER TABLE public."subscription_lifecycle_notifications" ADD CONSTRAINT "subscription_lifecycle_notifications_pkey" PRIMARY KEY (id);

ALTER TABLE public."subscription_notification_scheduler_config" ADD CONSTRAINT "subscription_notification_scheduler_config_pkey" PRIMARY KEY (singleton);

ALTER TABLE public."subscription_notification_scheduler_config" ADD CONSTRAINT "subscription_notification_scheduler_config_singleton_check" CHECK (singleton);

ALTER TABLE public."subscriptions" ADD CONSTRAINT "subscriptions_renewal_preference_check" CHECK (renewal_preference = ANY (ARRAY['automatic'::text, 'manual'::text, 'cancelled'::text]));

ALTER TABLE public."support_audit_log" ADD CONSTRAINT "support_audit_log_pkey" PRIMARY KEY (id);

ALTER TABLE public."support_messages" ADD CONSTRAINT "support_messages_check" CHECK (length(TRIM(BOTH FROM body)) > 0 OR attachment_path IS NOT NULL);

ALTER TABLE public."support_messages" ADD CONSTRAINT "support_messages_pkey" PRIMARY KEY (id);

ALTER TABLE public."support_messages" ADD CONSTRAINT "support_messages_sender_role_check" CHECK (sender_role = ANY (ARRAY['customer'::text, 'support'::text]));

ALTER TABLE public."support_operational_events" ADD CONSTRAINT "support_operational_events_pkey" PRIMARY KEY (id);

ALTER TABLE public."support_operational_events" ADD CONSTRAINT "support_operational_events_reference_key" UNIQUE (reference);

ALTER TABLE public."support_operational_events" ADD CONSTRAINT "support_operational_events_severity_check" CHECK (severity = ANY (ARRAY['Info'::text, 'Warning'::text, 'Critical'::text]));

ALTER TABLE public."support_operational_events" ADD CONSTRAINT "support_operational_events_status_check" CHECK (status = ANY (ARRAY['Open'::text, 'Resolved'::text]));

ALTER TABLE public."support_presence" ADD CONSTRAINT "support_presence_pkey" PRIMARY KEY (admin_user_id);

ALTER TABLE public."support_threads" ADD CONSTRAINT "support_threads_channel_check" CHECK (channel = ANY (ARRAY['ticket'::text, 'live_chat'::text]));

ALTER TABLE public."support_threads" ADD CONSTRAINT "support_threads_pkey" PRIMARY KEY (id);

ALTER TABLE public."support_threads" ADD CONSTRAINT "support_threads_status_check" CHECK (status = ANY (ARRAY['open'::text, 'waiting'::text, 'resolved'::text]));
