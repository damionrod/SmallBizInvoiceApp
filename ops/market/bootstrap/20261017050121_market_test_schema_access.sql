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

ALTER TABLE public."accounting_journal_lines" DROP CONSTRAINT "accounting_journal_lines_business_id_job_costing_id_fkey";

ALTER TABLE public."accounting_journal_lines" ADD CONSTRAINT "accounting_journal_lines_business_id_job_costing_id_fkey" FOREIGN KEY (business_id, job_costing_id) REFERENCES job_costings(business_id, id) ON DELETE RESTRICT;

ALTER TABLE public."accounting_journal_lines" DROP CONSTRAINT "accounting_journal_lines_business_id_supplier_id_fkey";

ALTER TABLE public."accounting_journal_lines" ADD CONSTRAINT "accounting_journal_lines_business_id_supplier_id_fkey" FOREIGN KEY (business_id, supplier_id) REFERENCES suppliers(business_id, id) ON DELETE RESTRICT;

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ADD CONSTRAINT "accounting_legacy_payroll_resolution_events_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ADD CONSTRAINT "accounting_legacy_payroll_resolution_events_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ADD CONSTRAINT "accounting_legacy_payroll_resolution_events_pay_run_id_fkey" FOREIGN KEY (pay_run_id) REFERENCES payroll_pay_runs(id) ON DELETE CASCADE;

ALTER TABLE public."accounting_source_mappings" ADD CONSTRAINT "accounting_source_mappings_account_id_fkey" FOREIGN KEY (account_id) REFERENCES accounting_accounts(id) ON DELETE SET NULL;

ALTER TABLE public."accounting_source_mappings" ADD CONSTRAINT "accounting_source_mappings_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."akahu_feed_accounts" ADD CONSTRAINT "akahu_feed_accounts_bank_account_id_fkey" FOREIGN KEY (bank_account_id) REFERENCES bank_accounts(id) ON DELETE SET NULL;

ALTER TABLE public."akahu_feed_accounts" ADD CONSTRAINT "akahu_feed_accounts_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."akahu_feed_accounts" ADD CONSTRAINT "akahu_feed_accounts_connection_id_fkey" FOREIGN KEY (connection_id) REFERENCES akahu_feed_connections(id) ON DELETE CASCADE;

ALTER TABLE public."akahu_feed_connections" ADD CONSTRAINT "akahu_feed_connections_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."akahu_feed_connections" ADD CONSTRAINT "akahu_feed_connections_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."akahu_feed_connections" ADD CONSTRAINT "akahu_feed_connections_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."akahu_feed_sync_runs" ADD CONSTRAINT "akahu_feed_sync_runs_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."akahu_feed_sync_runs" ADD CONSTRAINT "akahu_feed_sync_runs_connection_id_fkey" FOREIGN KEY (connection_id) REFERENCES akahu_feed_connections(id) ON DELETE SET NULL;

ALTER TABLE public."akahu_feed_sync_runs" ADD CONSTRAINT "akahu_feed_sync_runs_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."bank_reconciliation_allocations" ADD CONSTRAINT "bank_reconciliation_allocation_related_bank_transaction_id_fkey" FOREIGN KEY (related_bank_transaction_id) REFERENCES bank_transactions(id) ON DELETE RESTRICT;

ALTER TABLE public."bank_reconciliation_allocations" ADD CONSTRAINT "bank_reconciliation_allocations_invoice_payment_tx_fk" FOREIGN KEY (invoice_payment_transaction_id) REFERENCES invoice_payment_transactions(id) ON DELETE RESTRICT;

ALTER TABLE public."bank_reconciliation_allocations" ADD CONSTRAINT "bank_reconciliation_allocations_journal_fk" FOREIGN KEY (accounting_journal_id) REFERENCES accounting_journals(id) ON DELETE SET NULL;

ALTER TABLE public."bank_reconciliation_allocations" ADD CONSTRAINT "bank_reconciliation_allocations_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES business_owners(id) ON DELETE RESTRICT;

ALTER TABLE public."bank_reconciliation_allocations" ADD CONSTRAINT "bank_reconciliation_allocations_pay_run_employee_fk" FOREIGN KEY (pay_run_employee_id) REFERENCES payroll_pay_run_employees(id) ON DELETE SET NULL;

ALTER TABLE public."bank_reconciliation_allocations" ADD CONSTRAINT "bank_reconciliation_allocations_pay_run_fk" FOREIGN KEY (pay_run_id) REFERENCES payroll_pay_runs(id) ON DELETE SET NULL;

ALTER TABLE public."blinkpay_feed_accounts" ADD CONSTRAINT "blinkpay_feed_accounts_bank_account_id_fkey" FOREIGN KEY (bank_account_id) REFERENCES bank_accounts(id) ON DELETE SET NULL;

ALTER TABLE public."blinkpay_feed_accounts" ADD CONSTRAINT "blinkpay_feed_accounts_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."blinkpay_feed_accounts" ADD CONSTRAINT "blinkpay_feed_accounts_connection_id_fkey" FOREIGN KEY (connection_id) REFERENCES blinkpay_feed_connections(id) ON DELETE CASCADE;

ALTER TABLE public."blinkpay_feed_connections" ADD CONSTRAINT "blinkpay_feed_connections_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."blinkpay_feed_connections" ADD CONSTRAINT "blinkpay_feed_connections_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."blinkpay_feed_connections" ADD CONSTRAINT "blinkpay_feed_connections_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."blinkpay_feed_sync_runs" ADD CONSTRAINT "blinkpay_feed_sync_runs_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."blinkpay_feed_sync_runs" ADD CONSTRAINT "blinkpay_feed_sync_runs_connection_id_fkey" FOREIGN KEY (connection_id) REFERENCES blinkpay_feed_connections(id) ON DELETE SET NULL;

ALTER TABLE public."blinkpay_feed_sync_runs" ADD CONSTRAINT "blinkpay_feed_sync_runs_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."business_owner_history" ADD CONSTRAINT "business_owner_history_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE RESTRICT;

ALTER TABLE public."business_owner_history" ADD CONSTRAINT "business_owner_history_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES business_owners(id) ON DELETE RESTRICT;

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_approved_by_fkey" FOREIGN KEY (approved_by) REFERENCES auth.users(id);

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_package_id_fkey" FOREIGN KEY (package_id) REFERENCES community_ad_packages(id) ON DELETE SET NULL;

ALTER TABLE public."community_ad_campaigns" ADD CONSTRAINT "community_ad_campaigns_sponsor_business_id_fkey" FOREIGN KEY (sponsor_business_id) REFERENCES businesses(id) ON DELETE SET NULL;

ALTER TABLE public."community_ad_clicks" ADD CONSTRAINT "community_ad_clicks_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE SET NULL;

ALTER TABLE public."community_ad_clicks" ADD CONSTRAINT "community_ad_clicks_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES community_ad_campaigns(id) ON DELETE CASCADE;

ALTER TABLE public."community_ad_clicks" ADD CONSTRAINT "community_ad_clicks_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."community_ad_impressions" ADD CONSTRAINT "community_ad_impressions_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE SET NULL;

ALTER TABLE public."community_ad_impressions" ADD CONSTRAINT "community_ad_impressions_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES community_ad_campaigns(id) ON DELETE CASCADE;

ALTER TABLE public."community_ad_impressions" ADD CONSTRAINT "community_ad_impressions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."community_comments" ADD CONSTRAINT "community_comments_author_profile_id_fkey" FOREIGN KEY (author_profile_id) REFERENCES community_profiles(id) ON DELETE CASCADE;

ALTER TABLE public."community_comments" ADD CONSTRAINT "community_comments_post_id_fkey" FOREIGN KEY (post_id) REFERENCES community_posts(id) ON DELETE CASCADE;

ALTER TABLE public."community_conversations" ADD CONSTRAINT "community_conversations_created_by_profile_id_fkey" FOREIGN KEY (created_by_profile_id) REFERENCES community_profiles(id) ON DELETE CASCADE;

ALTER TABLE public."community_messages" ADD CONSTRAINT "community_messages_author_profile_id_fkey" FOREIGN KEY (author_profile_id) REFERENCES community_profiles(id) ON DELETE CASCADE;

ALTER TABLE public."community_messages" ADD CONSTRAINT "community_messages_conversation_id_fkey" FOREIGN KEY (conversation_id) REFERENCES community_conversations(id) ON DELETE CASCADE;

ALTER TABLE public."community_posts" ADD CONSTRAINT "community_posts_author_profile_id_fkey" FOREIGN KEY (author_profile_id) REFERENCES community_profiles(id) ON DELETE CASCADE;

ALTER TABLE public."community_posts" ADD CONSTRAINT "community_posts_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."community_profiles" ADD CONSTRAINT "community_profiles_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."community_profiles" ADD CONSTRAINT "community_profiles_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public."community_reports" ADD CONSTRAINT "community_reports_reporter_profile_id_fkey" FOREIGN KEY (reporter_profile_id) REFERENCES community_profiles(id) ON DELETE CASCADE;

ALTER TABLE public."community_reports" ADD CONSTRAINT "community_reports_reviewed_by_fkey" FOREIGN KEY (reviewed_by) REFERENCES auth.users(id);

ALTER TABLE public."community_settings" ADD CONSTRAINT "community_settings_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES auth.users(id);

ALTER TABLE public."email_delivery_events" ADD CONSTRAINT "email_delivery_events_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."email_delivery_events" ADD CONSTRAINT "email_delivery_events_sent_by_fkey" FOREIGN KEY (sent_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."frindly_expense_correction_requests_v1" ADD CONSTRAINT "frindly_expense_correction_requests_v1_expense_id_fkey" FOREIGN KEY (expense_id) REFERENCES expenses(id);

ALTER TABLE public."gst_transition_reviews" ADD CONSTRAINT "gst_transition_reviews_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."gst_transition_reviews" ADD CONSTRAINT "gst_transition_reviews_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);

ALTER TABLE public."gst_transition_reviews" ADD CONSTRAINT "gst_transition_reviews_resolved_by_fkey" FOREIGN KEY (resolved_by) REFERENCES auth.users(id);

ALTER TABLE public."invoice_auto_reminder_runs" ADD CONSTRAINT "invoice_auto_reminder_runs_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."invoice_auto_reminder_runs" ADD CONSTRAINT "invoice_auto_reminder_runs_invoice_id_fkey" FOREIGN KEY (invoice_id) REFERENCES invoices(id) ON DELETE CASCADE;

ALTER TABLE public."invoice_reminder_history" ADD CONSTRAINT "invoice_reminder_history_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."invoice_reminder_history" ADD CONSTRAINT "invoice_reminder_history_invoice_id_fkey" FOREIGN KEY (invoice_id) REFERENCES invoices(id) ON DELETE CASCADE;

ALTER TABLE public."invoice_reminder_history" ADD CONSTRAINT "invoice_reminder_history_sent_by_fkey" FOREIGN KEY (sent_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."ird_connect_settings" ADD CONSTRAINT "ird_connect_settings_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES auth.users(id);

ALTER TABLE public."ird_filing_batches" ADD CONSTRAINT "ird_filing_batches_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."ird_filing_batches" ADD CONSTRAINT "ird_filing_batches_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);

ALTER TABLE public."ird_filing_batches" ADD CONSTRAINT "ird_filing_batches_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES auth.users(id);

ALTER TABLE public."ird_filing_events" ADD CONSTRAINT "ird_filing_events_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES ird_filing_batches(id) ON DELETE CASCADE;

ALTER TABLE public."ird_filing_events" ADD CONSTRAINT "ird_filing_events_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."ird_filing_events" ADD CONSTRAINT "ird_filing_events_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_accounting_period_id_fkey" FOREIGN KEY (accounting_period_id) REFERENCES accounting_periods(id);

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_correction_item_id_fkey" FOREIGN KEY (correction_item_id) REFERENCES gst_correction_items(id);

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_expense_id_fkey" FOREIGN KEY (expense_id) REFERENCES expenses(id) ON DELETE CASCADE;

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_gst_adjustment_id_fkey" FOREIGN KEY (gst_adjustment_id) REFERENCES gst_adjustments(id);

ALTER TABLE public."late_transaction_adjustments" ADD CONSTRAINT "late_transaction_adjustments_original_gst_return_id_fkey" FOREIGN KEY (original_gst_return_id) REFERENCES gst_returns(id);

ALTER TABLE public."payroll_ird_filings" ADD CONSTRAINT "payroll_ird_filings_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."payroll_ird_filings" ADD CONSTRAINT "payroll_ird_filings_marked_by_fkey" FOREIGN KEY (marked_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public."payroll_ird_filings" ADD CONSTRAINT "payroll_ird_filings_pay_run_id_fkey" FOREIGN KEY (pay_run_id) REFERENCES payroll_pay_runs(id) ON DELETE CASCADE;

ALTER TABLE public."payroll_timesheets" ADD CONSTRAINT "payroll_timesheets_source_schedule_assignment_id_fkey" FOREIGN KEY (source_schedule_assignment_id) REFERENCES job_schedule_assignments(id) ON DELETE SET NULL;

ALTER TABLE public."payroll_timesheets" ADD CONSTRAINT "payroll_timesheets_source_schedule_id_fkey" FOREIGN KEY (source_schedule_id) REFERENCES job_schedules(id) ON DELETE SET NULL;

ALTER TABLE public."provisional_tax_instalments" ADD CONSTRAINT "provisional_tax_instalments_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."provisional_tax_instalments" ADD CONSTRAINT "provisional_tax_instalments_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES provisional_tax_plans(id) ON DELETE CASCADE;

ALTER TABLE public."provisional_tax_plans" ADD CONSTRAINT "provisional_tax_plans_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."se_assets" ADD CONSTRAINT "se_assets_disposal_journal_id_fkey" FOREIGN KEY (disposal_journal_id) REFERENCES accounting_journals(id) ON DELETE RESTRICT;

ALTER TABLE public."stripe_refund_processing" ADD CONSTRAINT "stripe_refund_processing_credit_note_id_fkey" FOREIGN KEY (credit_note_id) REFERENCES customer_credit_notes(id);

ALTER TABLE public."stripe_refund_processing" ADD CONSTRAINT "stripe_refund_processing_credit_note_journal_id_fkey" FOREIGN KEY (credit_note_journal_id) REFERENCES accounting_journals(id);

ALTER TABLE public."stripe_refund_processing" ADD CONSTRAINT "stripe_refund_processing_customer_refund_id_fkey" FOREIGN KEY (customer_refund_id) REFERENCES customer_refunds(id);

ALTER TABLE public."stripe_refund_processing" ADD CONSTRAINT "stripe_refund_processing_invoice_payment_transaction_id_fkey" FOREIGN KEY (invoice_payment_transaction_id) REFERENCES invoice_payment_transactions(id);

ALTER TABLE public."stripe_refund_processing" ADD CONSTRAINT "stripe_refund_processing_refund_journal_id_fkey" FOREIGN KEY (refund_journal_id) REFERENCES accounting_journals(id);

ALTER TABLE public."subscription_lifecycle_notifications" ADD CONSTRAINT "subscription_lifecycle_notifications_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."subscription_lifecycle_notifications" ADD CONSTRAINT "subscription_lifecycle_notifications_subscription_id_fkey" FOREIGN KEY (subscription_id) REFERENCES subscriptions(id) ON DELETE CASCADE;

ALTER TABLE public."support_messages" ADD CONSTRAINT "support_messages_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."support_messages" ADD CONSTRAINT "support_messages_sender_user_id_fkey" FOREIGN KEY (sender_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public."support_messages" ADD CONSTRAINT "support_messages_thread_id_fkey" FOREIGN KEY (thread_id) REFERENCES support_threads(id) ON DELETE CASCADE;

ALTER TABLE public."support_presence" ADD CONSTRAINT "support_presence_admin_user_id_fkey" FOREIGN KEY (admin_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public."support_threads" ADD CONSTRAINT "support_threads_business_id_fkey" FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE;

ALTER TABLE public."support_threads" ADD CONSTRAINT "support_threads_created_by_user_id_fkey" FOREIGN KEY (created_by_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX accounting_accounts_business_system_key_unique ON public.accounting_accounts USING btree (business_id, system_key) WHERE ((system_key IS NOT NULL) AND (archived = false));

CREATE INDEX accounting_legacy_payroll_resolution_events_lookup_idx ON public.accounting_legacy_payroll_resolution_events USING btree (business_id, pay_run_id, created_at DESC, id DESC);

CREATE UNIQUE INDEX accounting_source_mappings_source_id_unique ON public.accounting_source_mappings USING btree (business_id, source_type, source_id, purpose) WHERE ((source_id IS NOT NULL) AND (archived = false));

CREATE UNIQUE INDEX accounting_source_mappings_source_key_unique ON public.accounting_source_mappings USING btree (business_id, source_type, source_key, purpose) WHERE ((source_key IS NOT NULL) AND (archived = false));

CREATE INDEX akahu_feed_accounts_business_idx ON public.akahu_feed_accounts USING btree (business_id, bank_account_id);

CREATE UNIQUE INDEX akahu_feed_accounts_provider_uq ON public.akahu_feed_accounts USING btree (connection_id, provider_account_id);

CREATE INDEX akahu_feed_connections_business_idx ON public.akahu_feed_connections USING btree (business_id, status, created_at DESC);

CREATE UNIQUE INDEX akahu_feed_connections_state_uq ON public.akahu_feed_connections USING btree (consent_state) WHERE (consent_state IS NOT NULL);

CREATE INDEX akahu_feed_sync_runs_business_idx ON public.akahu_feed_sync_runs USING btree (business_id, started_at DESC);

CREATE INDEX bank_recon_alloc_related_bank_tx_idx ON public.bank_reconciliation_allocations USING btree (related_bank_transaction_id) WHERE (related_bank_transaction_id IS NOT NULL);

CREATE INDEX bank_reconciliation_allocations_existing_customer_payment_idx ON public.bank_reconciliation_allocations USING btree (existing_customer_payment_id) WHERE (existing_customer_payment_id IS NOT NULL);

CREATE INDEX bank_reconciliation_allocations_owner_idx ON public.bank_reconciliation_allocations USING btree (business_id, owner_id) WHERE (owner_id IS NOT NULL);

CREATE UNIQUE INDEX bank_reconciliation_allocations_pay_run_employee_uq ON public.bank_reconciliation_allocations USING btree (pay_run_employee_id) WHERE (pay_run_employee_id IS NOT NULL);

CREATE UNIQUE INDEX bank_transactions_external_provider_uq ON public.bank_transactions USING btree (business_id, bank_account_id, source_provider, external_transaction_id) WHERE (external_transaction_id IS NOT NULL);

CREATE INDEX blinkpay_feed_accounts_business_idx ON public.blinkpay_feed_accounts USING btree (business_id, bank_account_id);

CREATE UNIQUE INDEX blinkpay_feed_accounts_provider_uq ON public.blinkpay_feed_accounts USING btree (connection_id, provider_account_id);

CREATE INDEX blinkpay_feed_connections_business_idx ON public.blinkpay_feed_connections USING btree (business_id, status, created_at DESC);

CREATE UNIQUE INDEX blinkpay_feed_connections_state_uq ON public.blinkpay_feed_connections USING btree (consent_state) WHERE (consent_state IS NOT NULL);

CREATE INDEX blinkpay_feed_sync_runs_business_idx ON public.blinkpay_feed_sync_runs USING btree (business_id, started_at DESC);

CREATE INDEX business_owner_history_owner_date_idx ON public.business_owner_history USING btree (business_id, owner_id, effective_date DESC, created_at DESC);

CREATE INDEX business_owners_business_idx ON public.business_owners USING btree (business_id, status);

CREATE UNIQUE INDEX business_owners_name_active_uq ON public.business_owners USING btree (business_id, lower(TRIM(BOTH FROM display_name))) WHERE (status = 'active'::text);

CREATE INDEX community_ad_campaigns_active_idx ON public.community_ad_campaigns USING btree (status, placement, target_region, target_industry, starts_at, ends_at);

CREATE INDEX community_comments_post_idx ON public.community_comments USING btree (post_id, status, created_at);

CREATE INDEX community_conversations_participants_idx ON public.community_conversations USING gin (participant_profile_ids);

CREATE INDEX community_messages_conversation_idx ON public.community_messages USING btree (conversation_id, status, created_at);

CREATE INDEX community_posts_feed_idx ON public.community_posts USING btree (status, region, industry, category, created_at DESC);

CREATE INDEX email_delivery_events_business_sent_idx ON public.email_delivery_events USING btree (business_id, sent_at DESC);

CREATE UNIQUE INDEX email_delivery_events_provider_message_idx ON public.email_delivery_events USING btree (provider, provider_message_id) WHERE (provider_message_id IS NOT NULL);

CREATE INDEX email_delivery_events_source_idx ON public.email_delivery_events USING btree (source_table, source_id, sent_at DESC) WHERE (source_id IS NOT NULL);

CREATE INDEX expense_payments_owner_idx ON public.expense_payments USING btree (business_id, owner_id, payment_date) WHERE (owner_id IS NOT NULL);

CREATE INDEX gst_transition_reviews_business_effective_idx ON public.gst_transition_reviews USING btree (business_id, effective_from DESC, created_at DESC);

CREATE INDEX invoice_auto_reminder_runs_business_idx ON public.invoice_auto_reminder_runs USING btree (business_id, scheduled_for DESC);

CREATE INDEX invoice_auto_reminder_runs_invoice_idx ON public.invoice_auto_reminder_runs USING btree (invoice_id, scheduled_for DESC);

CREATE INDEX invoice_reminder_history_invoice_sent_idx ON public.invoice_reminder_history USING btree (invoice_id, sent_at DESC);

CREATE INDEX ird_filing_batches_business_idx ON public.ird_filing_batches USING btree (business_id, filing_type, period_start DESC, created_at DESC);

CREATE INDEX ird_filing_events_business_idx ON public.ird_filing_events USING btree (business_id, batch_id, created_at DESC);

CREATE INDEX owner_current_entries_journal_idx ON public.owner_current_account_entries USING btree (accounting_journal_id) WHERE (accounting_journal_id IS NOT NULL);

CREATE INDEX owner_current_entries_owner_date_idx ON public.owner_current_account_entries USING btree (business_id, owner_id, entry_date, id);

CREATE INDEX payroll_ird_filings_business_run_idx ON public.payroll_ird_filings USING btree (business_id, pay_run_id, created_at DESC);

CREATE UNIQUE INDEX payroll_timesheets_schedule_assignment_uidx ON public.payroll_timesheets USING btree (source_schedule_assignment_id) WHERE ((source_type = 'schedule'::text) AND (source_schedule_assignment_id IS NOT NULL));

CREATE INDEX payroll_timesheets_source_schedule_idx ON public.payroll_timesheets USING btree (business_id, source_schedule_id, status);

CREATE UNIQUE INDEX provisional_tax_instalments_plan_number_uq ON public.provisional_tax_instalments USING btree (plan_id, instalment_number);

CREATE UNIQUE INDEX provisional_tax_plans_business_year_uq ON public.provisional_tax_plans USING btree (business_id, tax_year_end);

CREATE INDEX purchase_order_events_po_idx ON public.purchase_order_events USING btree (business_id, purchase_order_id, created_at DESC);

CREATE INDEX purchase_order_lines_po_idx ON public.purchase_order_lines USING btree (business_id, purchase_order_id, line_order);

CREATE UNIQUE INDEX purchase_orders_business_number_uq ON public.purchase_orders USING btree (business_id, lower(po_number));

CREATE INDEX stripe_refund_processing_tx_idx ON public.stripe_refund_processing USING btree (invoice_payment_transaction_id);

CREATE INDEX subscription_lifecycle_notifications_due_idx ON public.subscription_lifecycle_notifications USING btree (due_at) WHERE (sent_at IS NULL);

CREATE INDEX support_audit_log_created_idx ON public.support_audit_log USING btree (created_at DESC);

CREATE INDEX support_audit_log_target_business_idx ON public.support_audit_log USING btree (target_business_id, created_at DESC);

CREATE INDEX support_audit_log_target_user_idx ON public.support_audit_log USING btree (target_user_id, created_at DESC);

CREATE INDEX support_messages_thread_idx ON public.support_messages USING btree (thread_id, created_at);

CREATE INDEX support_operational_events_created_idx ON public.support_operational_events USING btree (created_at DESC);

CREATE INDEX support_operational_events_service_idx ON public.support_operational_events USING btree (service, created_at DESC);

CREATE INDEX support_threads_business_idx ON public.support_threads USING btree (business_id, last_message_at DESC);

CREATE INDEX support_threads_creator_idx ON public.support_threads USING btree (created_by_user_id, last_message_at DESC);

CREATE INDEX support_threads_status_idx ON public.support_threads USING btree (status, last_message_at DESC);

CREATE OR REPLACE VIEW public."v6191_xero_chart_export" WITH (security_invoker=true) AS
 SELECT business_id,
    account_code AS finlo_account_code,
    account_name AS finlo_account_name,
    account_type AS finlo_account_type,
    report_section,
    xero_account_code,
    xero_account_type,
    xero_tax_type,
    system_key,
    is_control,
    archived
   FROM accounting_accounts a
  WHERE COALESCE(archived, false) = false AND business_id = current_business_id();

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user();

CREATE TRIGGER v6151_auth_email_verified AFTER INSERT OR UPDATE OF email_confirmed_at ON auth.users FOR EACH ROW EXECUTE FUNCTION v6151_auth_email_verified();

CREATE TRIGGER trg_v61107w_owner_allocation_business_guard BEFORE INSERT OR UPDATE OF owner_id, business_id, allocation_type ON bank_reconciliation_allocations FOR EACH ROW EXECUTE FUNCTION v61107w_owner_allocation_business_guard();

CREATE TRIGGER trg_v61107v_owner_history_guard BEFORE INSERT OR UPDATE ON business_owner_history FOR EACH ROW EXECUTE FUNCTION v61107v_owner_history_guard();

CREATE TRIGGER community_ad_campaigns_blocked_text BEFORE INSERT OR UPDATE ON community_ad_campaigns FOR EACH ROW EXECUTE FUNCTION v61106_reject_blocked_community_text();

CREATE TRIGGER community_comments_blocked_text BEFORE INSERT OR UPDATE ON community_comments FOR EACH ROW EXECUTE FUNCTION v61106_reject_blocked_community_text();

CREATE TRIGGER community_messages_blocked_text BEFORE INSERT OR UPDATE ON community_messages FOR EACH ROW EXECUTE FUNCTION v61106_reject_blocked_community_text();

CREATE TRIGGER community_posts_blocked_text BEFORE INSERT OR UPDATE ON community_posts FOR EACH ROW EXECUTE FUNCTION v61106_reject_blocked_community_text();

CREATE TRIGGER community_profiles_blocked_text BEFORE INSERT OR UPDATE ON community_profiles FOR EACH ROW EXECUTE FUNCTION v61106_reject_blocked_community_text();

CREATE TRIGGER trg_v61107u_expense_payment_owner_guard BEFORE INSERT OR UPDATE OF funding_source, owner_id, business_id ON expense_payments FOR EACH ROW EXECUTE FUNCTION v61107u_expense_payment_owner_guard();

CREATE TRIGGER v61107aay_lock_issued_quote_billing_trg BEFORE UPDATE ON invoices FOR EACH ROW EXECUTE FUNCTION v61107aay_lock_issued_quote_billing();

CREATE TRIGGER v61107aay_quote_progress_guard BEFORE INSERT OR UPDATE OF source_quote_id, business_id, subtotal, quote_billing_ex_gst, lifecycle_state ON invoices FOR EACH ROW EXECUTE FUNCTION v61107aay_guard_quote_progress_invoice();

CREATE TRIGGER v61107aaz_direct_billing_guard BEFORE INSERT OR UPDATE OF billing_series_id, source_quote_id, business_id, subtotal, quote_billing_ex_gst, quote_original_ex_gst, lifecycle_state ON invoices FOR EACH ROW EXECUTE FUNCTION v61107aaz_guard_direct_billing_series();

CREATE TRIGGER trg_v61107t_owner_entry_business_guard BEFORE INSERT OR UPDATE ON owner_current_account_entries FOR EACH ROW EXECUTE FUNCTION v61107t_owner_entry_business_guard();

CREATE TRIGGER v61105_phase13a_post_payroll_journal AFTER UPDATE OF status ON payroll_pay_runs FOR EACH ROW EXECUTE FUNCTION v61105_phase13a_payroll_finalise_posting_trigger();

CREATE TRIGGER support_message_touch_thread AFTER INSERT ON support_messages FOR EACH ROW EXECUTE FUNCTION support_touch_thread();

CREATE POLICY "accounting_accounts_read" ON "public"."accounting_accounts" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

CREATE POLICY "accounting_accounts_write" ON "public"."accounting_accounts" AS PERMISSIVE FOR ALL TO "authenticated" USING (((business_id = current_business_id()) AND v6147_can_write_area(business_id, 'business_settings'::text))) WITH CHECK (((business_id = current_business_id()) AND v6147_can_write_area(business_id, 'business_settings'::text)));

CREATE POLICY "legacy_payroll_resolution_select" ON "public"."accounting_legacy_payroll_resolution_events" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((business_id = current_business_id()) AND v6169a_accountant_centre_access(business_id, false)));

CREATE POLICY "accounting_source_mappings_read" ON "public"."accounting_source_mappings" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

CREATE POLICY "accounting_source_mappings_write" ON "public"."accounting_source_mappings" AS PERMISSIVE FOR ALL TO "authenticated" USING (((business_id = current_business_id()) AND v6147_can_write_area(business_id, 'business_settings'::text))) WITH CHECK (((business_id = current_business_id()) AND v6147_can_write_area(business_id, 'business_settings'::text)));

CREATE POLICY "akahu_feed_accounts_service_only" ON "public"."akahu_feed_accounts" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "akahu_feed_connections_service_only" ON "public"."akahu_feed_connections" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "akahu_feed_sync_runs_service_only" ON "public"."akahu_feed_sync_runs" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "blinkpay_feed_accounts_service_only" ON "public"."blinkpay_feed_accounts" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "blinkpay_feed_connections_service_only" ON "public"."blinkpay_feed_connections" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "blinkpay_feed_sync_runs_service_only" ON "public"."blinkpay_feed_sync_runs" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);

CREATE POLICY "business_owner_history_read" ON "public"."business_owner_history" AS PERMISSIVE FOR SELECT TO PUBLIC USING (v6145_has_active_business_membership(business_id));

CREATE POLICY "business_owner_history_write" ON "public"."business_owner_history" AS PERMISSIVE FOR ALL TO PUBLIC USING ((v6147_current_business_role(business_id) = ANY (ARRAY['owner'::text, 'admin'::text, 'bookkeeper'::text]))) WITH CHECK ((v6147_current_business_role(business_id) = ANY (ARRAY['owner'::text, 'admin'::text, 'bookkeeper'::text])));

CREATE POLICY "business_owners_read" ON "public"."business_owners" AS PERMISSIVE FOR SELECT TO PUBLIC USING (v6145_has_active_business_membership(business_id));

CREATE POLICY "business_owners_write" ON "public"."business_owners" AS PERMISSIVE FOR ALL TO PUBLIC USING ((v6147_current_business_role(business_id) = ANY (ARRAY['owner'::text, 'admin'::text, 'bookkeeper'::text]))) WITH CHECK ((v6147_current_business_role(business_id) = ANY (ARRAY['owner'::text, 'admin'::text, 'bookkeeper'::text])));

CREATE POLICY "community_ad_campaigns_admin" ON "public"."community_ad_campaigns" AS PERMISSIVE FOR ALL TO "authenticated" USING (v61106_is_super_admin()) WITH CHECK (v61106_is_super_admin());

CREATE POLICY "community_ad_campaigns_select" ON "public"."community_ad_campaigns" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((v61106_is_super_admin() OR (status = 'active'::text)));

CREATE POLICY "community_ad_clicks_admin" ON "public"."community_ad_clicks" AS PERMISSIVE FOR SELECT TO "authenticated" USING (v61106_is_super_admin());

CREATE POLICY "community_ad_clicks_insert" ON "public"."community_ad_clicks" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((user_id = auth.uid()) OR (user_id IS NULL)));

CREATE POLICY "community_ad_impressions_admin" ON "public"."community_ad_impressions" AS PERMISSIVE FOR SELECT TO "authenticated" USING (v61106_is_super_admin());

CREATE POLICY "community_ad_impressions_insert" ON "public"."community_ad_impressions" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((user_id = auth.uid()) OR (user_id IS NULL)));

CREATE POLICY "community_ad_packages_admin" ON "public"."community_ad_packages" AS PERMISSIVE FOR ALL TO "authenticated" USING (v61106_is_super_admin()) WITH CHECK (v61106_is_super_admin());

CREATE POLICY "community_ad_packages_select" ON "public"."community_ad_packages" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((active = true) OR v61106_is_super_admin()));

CREATE POLICY "community_blocked_words_admin" ON "public"."community_blocked_words" AS PERMISSIVE FOR ALL TO "authenticated" USING (v61106_is_super_admin()) WITH CHECK (v61106_is_super_admin());

CREATE POLICY "community_comments_insert_member" ON "public"."community_comments" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM community_profiles cp
  WHERE ((cp.id = community_comments.author_profile_id) AND (cp.user_id = auth.uid()) AND (cp.suspended_at IS NULL)))));

CREATE POLICY "community_comments_select_active" ON "public"."community_comments" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((v61106_is_super_admin() OR (status = 'active'::text)));

CREATE POLICY "community_comments_update_admin" ON "public"."community_comments" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (v61106_is_super_admin()) WITH CHECK (v61106_is_super_admin());

CREATE POLICY "community_conversations_insert_participant" ON "public"."community_conversations" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((created_by_profile_id = v61106_current_community_profile_id()) AND (participant_profile_ids @> ARRAY[v61106_current_community_profile_id()])));

CREATE POLICY "community_conversations_select_participant" ON "public"."community_conversations" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((v61106_is_super_admin() OR (participant_profile_ids @> ARRAY[v61106_current_community_profile_id()])));

CREATE POLICY "community_conversations_update_participant" ON "public"."community_conversations" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((v61106_is_super_admin() OR (participant_profile_ids @> ARRAY[v61106_current_community_profile_id()]))) WITH CHECK ((v61106_is_super_admin() OR (participant_profile_ids @> ARRAY[v61106_current_community_profile_id()])));

CREATE POLICY "community_messages_insert_participant" ON "public"."community_messages" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((author_profile_id = v61106_current_community_profile_id()) AND (EXISTS ( SELECT 1
   FROM community_conversations c
  WHERE ((c.id = community_messages.conversation_id) AND (c.participant_profile_ids @> ARRAY[v61106_current_community_profile_id()]))))));

CREATE POLICY "community_messages_select_participant" ON "public"."community_messages" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((v61106_is_super_admin() OR (EXISTS ( SELECT 1
   FROM community_conversations c
  WHERE ((c.id = community_messages.conversation_id) AND (c.participant_profile_ids @> ARRAY[v61106_current_community_profile_id()]))))));

CREATE POLICY "community_messages_update_admin" ON "public"."community_messages" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (v61106_is_super_admin()) WITH CHECK (v61106_is_super_admin());

CREATE POLICY "community_messages_update_participant" ON "public"."community_messages" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM community_conversations c
  WHERE ((c.id = community_messages.conversation_id) AND (c.participant_profile_ids @> ARRAY[v61106_current_community_profile_id()]))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM community_conversations c
  WHERE ((c.id = community_messages.conversation_id) AND (c.participant_profile_ids @> ARRAY[v61106_current_community_profile_id()])))));

CREATE POLICY "community_posts_delete_admin" ON "public"."community_posts" AS PERMISSIVE FOR DELETE TO "authenticated" USING (v61106_is_super_admin());

CREATE POLICY "community_posts_insert_member" ON "public"."community_posts" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((v61106_is_super_admin() OR (EXISTS ( SELECT 1
   FROM community_profiles cp
  WHERE ((cp.id = community_posts.author_profile_id) AND (cp.user_id = auth.uid()) AND (cp.suspended_at IS NULL))))));

CREATE POLICY "community_posts_select_active" ON "public"."community_posts" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((v61106_is_super_admin() OR (status = 'active'::text)));

CREATE POLICY "community_posts_update_admin" ON "public"."community_posts" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (v61106_is_super_admin()) WITH CHECK (v61106_is_super_admin());

CREATE POLICY "community_profiles_insert_own" ON "public"."community_profiles" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM business_memberships bm
  WHERE ((bm.business_id = community_profiles.business_id) AND (bm.user_id = auth.uid()) AND (bm.status = 'active'::text))))));

CREATE POLICY "community_profiles_select" ON "public"."community_profiles" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((v61106_is_super_admin() OR (suspended_at IS NULL)));

CREATE POLICY "community_profiles_update_own_admin" ON "public"."community_profiles" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((v61106_is_super_admin() OR (user_id = auth.uid()))) WITH CHECK ((v61106_is_super_admin() OR (user_id = auth.uid())));

CREATE POLICY "community_reports_insert_own" ON "public"."community_reports" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((reporter_profile_id = v61106_current_community_profile_id()));

CREATE POLICY "community_reports_select_admin_own" ON "public"."community_reports" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((v61106_is_super_admin() OR (reporter_profile_id = v61106_current_community_profile_id())));

CREATE POLICY "community_reports_update_admin" ON "public"."community_reports" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (v61106_is_super_admin()) WITH CHECK (v61106_is_super_admin());

CREATE POLICY "community_settings_admin" ON "public"."community_settings" AS PERMISSIVE FOR ALL TO "authenticated" USING (v61106_is_super_admin()) WITH CHECK (v61106_is_super_admin());

CREATE POLICY "community_settings_read" ON "public"."community_settings" AS PERMISSIVE FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "email_delivery_events_select_business" ON "public"."email_delivery_events" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

CREATE POLICY "expense_revisions_member_read" ON "public"."expense_revisions" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((business_id = current_business_id()) AND COALESCE(v6147_can_read_area(business_id, 'core'::text), false)));

CREATE POLICY "gst_transition_reviews_insert_current_business" ON "public"."gst_transition_reviews" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((business_id = current_business_id()) AND (created_by = ( SELECT auth.uid() AS uid)) AND (previous_registered IS DISTINCT FROM new_registered)));

CREATE POLICY "gst_transition_reviews_select_current_business" ON "public"."gst_transition_reviews" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

CREATE POLICY "gst_transition_reviews_update_current_business" ON "public"."gst_transition_reviews" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((business_id = current_business_id())) WITH CHECK ((business_id = current_business_id()));

CREATE POLICY "invoice_auto_reminder_runs_select_business" ON "public"."invoice_auto_reminder_runs" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

CREATE POLICY "invoice_reminder_history_select_member" ON "public"."invoice_reminder_history" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

CREATE POLICY "v61107b_invoice_reminder_history_select" ON "public"."invoice_reminder_history" AS PERMISSIVE FOR SELECT TO "authenticated" USING (v6147_can_read_area(business_id, 'core'::text));

CREATE POLICY "ird_connect_settings_super_admin" ON "public"."ird_connect_settings" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = auth.uid()) AND (COALESCE(p.is_super_admin, false) = true)))));

CREATE POLICY "ird_filing_batches_select_business" ON "public"."ird_filing_batches" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

CREATE POLICY "ird_filing_events_select_business" ON "public"."ird_filing_events" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

CREATE POLICY "late_transaction_adjustments_select" ON "public"."late_transaction_adjustments" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((business_id = current_business_id()) AND v6147_can_read_area(business_id, 'expenses'::text)));

CREATE POLICY "owner_current_entries_read" ON "public"."owner_current_account_entries" AS PERMISSIVE FOR SELECT TO PUBLIC USING (v6145_has_active_business_membership(business_id));

CREATE POLICY "owner_current_entries_write" ON "public"."owner_current_account_entries" AS PERMISSIVE FOR ALL TO PUBLIC USING ((v6147_current_business_role(business_id) = ANY (ARRAY['owner'::text, 'admin'::text, 'bookkeeper'::text]))) WITH CHECK ((v6147_current_business_role(business_id) = ANY (ARRAY['owner'::text, 'admin'::text, 'bookkeeper'::text])));

CREATE POLICY "payroll_ird_filings_insert_member" ON "public"."payroll_ird_filings" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((business_id = current_business_id()));

CREATE POLICY "payroll_ird_filings_select_member" ON "public"."payroll_ird_filings" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((business_id = current_business_id()));

DROP POLICY "v22_plans_admin" ON "public"."plans";

CREATE POLICY "v22_plans_admin" ON "public"."plans" AS PERMISSIVE FOR ALL TO "authenticated" USING (is_super_admin()) WITH CHECK (is_super_admin());

CREATE POLICY "v61107aar_plans_public_read" ON "public"."plans" AS PERMISSIVE FOR SELECT TO "anon", "authenticated" USING (((is_public = true) OR (slug = 'trial'::text)));

CREATE POLICY "v61107aar_plans_super_admin_read" ON "public"."plans" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_super_admin());

CREATE POLICY "provisional_tax_instalments_business_all" ON "public"."provisional_tax_instalments" AS PERMISSIVE FOR ALL TO "authenticated" USING (((business_id = current_business_id()) AND v6169a_accountant_centre_access(business_id, true))) WITH CHECK (((business_id = current_business_id()) AND v6169a_accountant_centre_access(business_id, true)));

CREATE POLICY "provisional_tax_instalments_business_select" ON "public"."provisional_tax_instalments" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((business_id = current_business_id()) AND v6169a_accountant_centre_access(business_id, false)));

CREATE POLICY "provisional_tax_plans_business_all" ON "public"."provisional_tax_plans" AS PERMISSIVE FOR ALL TO "authenticated" USING (((business_id = current_business_id()) AND v6169a_accountant_centre_access(business_id, true))) WITH CHECK (((business_id = current_business_id()) AND v6169a_accountant_centre_access(business_id, true)));

CREATE POLICY "provisional_tax_plans_business_select" ON "public"."provisional_tax_plans" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((business_id = current_business_id()) AND v6169a_accountant_centre_access(business_id, false)));

CREATE POLICY "support_messages_insert_admin" ON "public"."support_messages" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((sender_user_id = auth.uid()) AND (sender_role = 'support'::text) AND is_super_admin() AND (EXISTS ( SELECT 1
   FROM support_threads t
  WHERE ((t.id = support_messages.thread_id) AND (t.business_id = t.business_id))))));

CREATE POLICY "support_messages_insert_customer" ON "public"."support_messages" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((sender_user_id = auth.uid()) AND (sender_role = 'customer'::text) AND (EXISTS ( SELECT 1
   FROM support_threads t
  WHERE ((t.id = support_messages.thread_id) AND (t.business_id = t.business_id) AND (t.created_by_user_id = auth.uid()) AND (t.status <> 'resolved'::text))))));

CREATE POLICY "support_messages_select" ON "public"."support_messages" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((is_super_admin() OR (EXISTS ( SELECT 1
   FROM support_threads t
  WHERE ((t.id = support_messages.thread_id) AND (t.created_by_user_id = auth.uid()))))));

CREATE POLICY "support_presence_admin_insert" ON "public"."support_presence" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((admin_user_id = auth.uid()) AND is_super_admin()));

CREATE POLICY "support_presence_admin_update" ON "public"."support_presence" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((admin_user_id = auth.uid()) AND is_super_admin())) WITH CHECK (((admin_user_id = auth.uid()) AND is_super_admin()));

CREATE POLICY "support_presence_read" ON "public"."support_presence" AS PERMISSIVE FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "support_threads_admin_update" ON "public"."support_threads" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (is_super_admin()) WITH CHECK (is_super_admin());

CREATE POLICY "support_threads_customer_insert" ON "public"."support_threads" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((created_by_user_id = auth.uid()) AND (business_id = current_business_id())));

CREATE POLICY "support_threads_customer_select" ON "public"."support_threads" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((created_by_user_id = auth.uid()) OR is_super_admin()));

CREATE POLICY "community_media_delete" ON "storage"."objects" AS PERMISSIVE FOR DELETE TO "authenticated" USING (((bucket_id = 'community-media'::text) AND (((storage.foldername(name))[1] = (auth.uid())::text) OR v61106_is_super_admin())));

CREATE POLICY "community_media_insert" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'community-media'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));

CREATE POLICY "community_media_update" ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((bucket_id = 'community-media'::text) AND (((storage.foldername(name))[1] = (auth.uid())::text) OR v61106_is_super_admin())));

CREATE POLICY "frindly_avatars_delete" ON "storage"."objects" AS PERMISSIVE FOR DELETE TO "authenticated" USING (((bucket_id = 'frindly-avatars'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text)));

CREATE POLICY "frindly_avatars_insert" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'frindly-avatars'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text)));

CREATE POLICY "frindly_avatars_select" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((bucket_id = 'frindly-avatars'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text)));

CREATE POLICY "frindly_avatars_update" ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((bucket_id = 'frindly-avatars'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text))) WITH CHECK (((bucket_id = 'frindly-avatars'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text)));

CREATE POLICY "frindly_documents_delete" ON "storage"."objects" AS PERMISSIVE FOR DELETE TO "authenticated" USING (((bucket_id = 'frindly-documents'::text) AND (EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND ((storage.foldername(objects.name))[1] = (COALESCE(p.active_business_id, p.business_id))::text))))));

CREATE POLICY "frindly_documents_insert" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'frindly-documents'::text) AND (EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND ((storage.foldername(objects.name))[1] = (COALESCE(p.active_business_id, p.business_id))::text))))));

CREATE POLICY "frindly_documents_select" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((bucket_id = 'frindly-documents'::text) AND (EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND ((storage.foldername(objects.name))[1] = (COALESCE(p.active_business_id, p.business_id))::text))))));

CREATE POLICY "frindly_documents_update" ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((bucket_id = 'frindly-documents'::text) AND (EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND ((storage.foldername(objects.name))[1] = (COALESCE(p.active_business_id, p.business_id))::text)))))) WITH CHECK (((bucket_id = 'frindly-documents'::text) AND (EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND ((storage.foldername(objects.name))[1] = (COALESCE(p.active_business_id, p.business_id))::text))))));

CREATE POLICY "support_attachment_customer_insert" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'support-attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));

CREATE POLICY "support_attachment_customer_read" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((bucket_id = 'support-attachments'::text) AND (((storage.foldername(name))[1] = (auth.uid())::text) OR is_super_admin())));

CREATE POLICY "v51_expense_docs_delete" ON "storage"."objects" AS PERMISSIVE FOR DELETE TO "authenticated" USING (((bucket_id = 'expense-documents'::text) AND ((((storage.foldername(name))[1])::uuid = current_business_id()) OR is_super_admin())));

CREATE POLICY "v51_expense_docs_insert" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'expense-documents'::text) AND ((((storage.foldername(name))[1])::uuid = current_business_id()) OR is_super_admin())));

CREATE POLICY "v51_expense_docs_select" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((bucket_id = 'expense-documents'::text) AND ((((storage.foldername(name))[1])::uuid = current_business_id()) OR is_super_admin())));

CREATE POLICY "v51_expense_docs_update" ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((bucket_id = 'expense-documents'::text) AND ((((storage.foldername(name))[1])::uuid = current_business_id()) OR is_super_admin()))) WITH CHECK (((bucket_id = 'expense-documents'::text) AND ((((storage.foldername(name))[1])::uuid = current_business_id()) OR is_super_admin())));

CREATE POLICY "v55_payroll_docs_delete" ON "storage"."objects" AS PERMISSIVE FOR DELETE TO "authenticated" USING (((bucket_id = 'payroll-documents'::text) AND v55_payroll_access(((storage.foldername(name))[1])::uuid)));

CREATE POLICY "v55_payroll_docs_insert" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'payroll-documents'::text) AND v55_payroll_access(((storage.foldername(name))[1])::uuid)));

CREATE POLICY "v55_payroll_docs_select" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((bucket_id = 'payroll-documents'::text) AND v55_payroll_access(((storage.foldername(name))[1])::uuid)));

CREATE POLICY "v55_payroll_docs_update" ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((bucket_id = 'payroll-documents'::text) AND v55_payroll_access(((storage.foldername(name))[1])::uuid))) WITH CHECK (((bucket_id = 'payroll-documents'::text) AND v55_payroll_access(((storage.foldername(name))[1])::uuid)));

ALTER TABLE public."accounting_accounts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_audit_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_destination_accounts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_export_mappings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_exports" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_journal_lines" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_journals" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_legacy_payroll_resolution_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_migration_exceptions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_periods" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."accounting_source_mappings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."akahu_feed_accounts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."akahu_feed_connections" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."akahu_feed_sync_runs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bank_accounts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bank_import_batches" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bank_reconciliation_allocations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bank_reconciliation_audit" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bank_reconciliation_groups" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bank_reconciliation_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bank_rules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bank_transactions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."bas_returns" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."batch_payment_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."batch_payments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."blinkpay_feed_accounts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."blinkpay_feed_connections" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."blinkpay_feed_sync_runs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_credits" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_invites" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_member_access_overrides" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_memberships" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_modules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_onboarding_state" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_owner_history" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_owners" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_referral_codes" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_referral_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_role_access_defaults" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_tax_compliance_sources" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_tax_compliance_updates" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_tax_ruleset_rules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."business_tax_rulesets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."businesses" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_ad_campaigns" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_ad_clicks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_ad_impressions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_ad_packages" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_blocked_words" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_comments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_conversations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_messages" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_posts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_profiles" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_reports" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."community_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."country_business_tax_rules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."country_payroll_rules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."customer_credit_note_counters" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."customer_credit_note_lines" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."customer_credit_notes" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."customer_payments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."customer_refund_counters" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."customer_refunds" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."customers" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."edge_function_rate_limits" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."email_delivery_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_ai_scans" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_attachments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_audit_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_categories" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_duplicate_reviews" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_lines" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_number_counters" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_payments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_reconciliations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expense_revisions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."expenses" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."financial_audit_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."financial_budget_lines" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."financial_budget_month_values" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."financial_budgets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."financial_category_mappings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."financial_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."finlo_credit_redemptions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."finlo_helper_module_controls" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."finlo_helper_plan_config" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."finlo_helper_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."finlo_helper_usage" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."finlo_live_voice_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."finlo_live_voice_usage" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."frindly_expense_correction_authorizations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."frindly_expense_correction_requests_v1" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."google_calendar_connections" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."google_calendar_event_links" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."google_calendar_sync_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."gst_adjustments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."gst_correction_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."gst_returns" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."gst_settings_history" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."gst_transition_reviews" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_batches" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_commit_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_mapping_profiles" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_mappings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_migration_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_record_links" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_record_members" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_records" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_rows" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."import_sheets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."invoice_auto_reminder_runs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."invoice_payment_links" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."invoice_payment_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."invoice_payment_transactions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."invoice_reminder_history" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."invoices" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."ird_connect_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."ird_filing_batches" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."ird_filing_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."job_activity" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."job_actual_costs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."job_costings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."job_recurrence_series" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."job_schedule_assignments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."job_schedules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."late_transaction_adjustments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."migration_historical_documents" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."modules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."optional_addon_entitlements" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."owner_current_account_entries" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payment_provider_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_alternative_holiday_entitlements" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_annual_holiday_entitlement_periods" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_audit_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_bereavement_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_compliance_audit" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_compliance_sources" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_compliance_updates" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_country_rules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_document_types" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_employee_documents" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_employee_leave" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_employee_work_patterns" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_employees" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_final_pay_calculations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_final_pay_components" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_financial_transactions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_ird_filings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_leave_transactions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_leave_types" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_migration_history" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_migration_opening_balances" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_owd_determinations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_pay_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_pay_run_employees" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_pay_run_lines" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_pay_runs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_payg_eligibility_determinations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_payslips" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_public_holiday_regions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_public_holiday_transfers" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_public_holidays" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_ruleset_rules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_rulesets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_statutory_leave_calculations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_statutory_leave_entitlements" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_timesheet_expenses" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."payroll_timesheets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."plan_public_features" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."plans" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."platform_industries" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."profiles" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."provisional_tax_instalments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."provisional_tax_plans" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."purchase_document_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."purchase_invoice_reviews" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."purchase_order_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."purchase_order_lines" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."purchase_orders" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."quotes" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."recurring_expense_rules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."recurring_rules" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."referral_audit_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."referral_campaign_versions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."referral_campaigns" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."referral_invites" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."referrals" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_activity" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_assets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_document_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_invoice_reviews" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_movements" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_reviews" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_rule_audit" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."se_rule_versions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."stripe_refund_processing" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."subscription_lifecycle_notifications" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."subscription_notification_scheduler_config" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."subscriptions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."supplier_credit_counters" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."supplier_credits" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."supplier_refund_allocations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."supplier_refund_counters" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."supplier_refunds" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."suppliers" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."support_audit_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."support_messages" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."support_operational_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."support_presence" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."support_threads" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."tax_export_mappings" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."accounting_accounts" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_accounts" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_accounts" TO "service_role";

REVOKE ALL ON TABLE public."accounting_audit_log" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_audit_log" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_audit_log" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_audit_log" TO "service_role";

REVOKE ALL ON SEQUENCE public."accounting_audit_log_id_seq" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."accounting_audit_log_id_seq" TO "anon";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."accounting_audit_log_id_seq" TO "authenticated";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."accounting_audit_log_id_seq" TO "service_role";

REVOKE ALL ON TABLE public."accounting_destination_accounts" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_destination_accounts" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_destination_accounts" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_destination_accounts" TO "service_role";

REVOKE ALL ON TABLE public."accounting_export_mappings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_export_mappings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_export_mappings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_export_mappings" TO "service_role";

REVOKE ALL ON TABLE public."accounting_exports" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_exports" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_exports" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_exports" TO "service_role";

REVOKE ALL ON TABLE public."accounting_journal_lines" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_journal_lines" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_journal_lines" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_journal_lines" TO "service_role";

REVOKE ALL ON TABLE public."accounting_journals" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_journals" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_journals" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_journals" TO "service_role";

REVOKE ALL ON TABLE public."accounting_legacy_payroll_resolution_events" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_legacy_payroll_resolution_events" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_legacy_payroll_resolution_events" TO "service_role";

REVOKE ALL ON TABLE public."accounting_migration_exceptions" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_migration_exceptions" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_migration_exceptions" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_migration_exceptions" TO "service_role";

REVOKE ALL ON SEQUENCE public."accounting_migration_exceptions_id_seq" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."accounting_migration_exceptions_id_seq" TO "anon";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."accounting_migration_exceptions_id_seq" TO "authenticated";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."accounting_migration_exceptions_id_seq" TO "service_role";

REVOKE ALL ON TABLE public."accounting_periods" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_periods" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_periods" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_periods" TO "service_role";

REVOKE ALL ON TABLE public."accounting_source_mappings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_source_mappings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."accounting_source_mappings" TO "service_role";

REVOKE ALL ON TABLE public."akahu_feed_accounts" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."akahu_feed_accounts" TO "service_role";

REVOKE ALL ON TABLE public."akahu_feed_connections" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."akahu_feed_connections" TO "service_role";

REVOKE ALL ON TABLE public."akahu_feed_sync_runs" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."akahu_feed_sync_runs" TO "service_role";

REVOKE ALL ON TABLE public."bank_accounts" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_accounts" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_accounts" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_accounts" TO "service_role";

REVOKE ALL ON TABLE public."bank_import_batches" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_import_batches" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_import_batches" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_import_batches" TO "service_role";

REVOKE ALL ON TABLE public."bank_reconciliation_allocations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_allocations" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_allocations" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_allocations" TO "service_role";

REVOKE ALL ON TABLE public."bank_reconciliation_audit" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_audit" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_audit" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_audit" TO "service_role";

REVOKE ALL ON TABLE public."bank_reconciliation_groups" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_groups" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_groups" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_groups" TO "service_role";

REVOKE ALL ON TABLE public."bank_reconciliation_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_settings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_settings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_reconciliation_settings" TO "service_role";

REVOKE ALL ON TABLE public."bank_rules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_rules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_rules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_rules" TO "service_role";

REVOKE ALL ON TABLE public."bank_transactions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_transactions" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_transactions" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bank_transactions" TO "service_role";

REVOKE ALL ON TABLE public."bas_returns" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."bas_returns" TO "service_role";

GRANT SELECT ON TABLE public."bas_returns" TO "authenticated";

REVOKE ALL ON TABLE public."batch_payment_items" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."batch_payment_items" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."batch_payment_items" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."batch_payment_items" TO "service_role";

REVOKE ALL ON TABLE public."batch_payments" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."batch_payments" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."batch_payments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."batch_payments" TO "service_role";

REVOKE ALL ON TABLE public."blinkpay_feed_accounts" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."blinkpay_feed_accounts" TO "service_role";

REVOKE ALL ON TABLE public."blinkpay_feed_connections" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."blinkpay_feed_connections" TO "service_role";

REVOKE ALL ON TABLE public."blinkpay_feed_sync_runs" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."blinkpay_feed_sync_runs" TO "service_role";

REVOKE ALL ON TABLE public."business_credits" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_credits" TO "service_role";

GRANT SELECT ON TABLE public."business_credits" TO "authenticated";

REVOKE ALL ON TABLE public."business_invites" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_invites" TO "service_role";

REVOKE ALL ON TABLE public."business_member_access_overrides" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_member_access_overrides" TO "service_role";

REVOKE ALL ON TABLE public."business_memberships" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_memberships" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_memberships" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_memberships" TO "service_role";

REVOKE ALL ON TABLE public."business_modules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_modules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_modules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_modules" TO "service_role";

REVOKE ALL ON TABLE public."business_onboarding_state" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_onboarding_state" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_onboarding_state" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_onboarding_state" TO "service_role";

REVOKE ALL ON TABLE public."business_owner_history" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_owner_history" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_owner_history" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_owner_history" TO "service_role";

REVOKE ALL ON TABLE public."business_owners" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_owners" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_owners" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_owners" TO "service_role";

REVOKE ALL ON TABLE public."business_referral_codes" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_referral_codes" TO "service_role";

GRANT SELECT ON TABLE public."business_referral_codes" TO "authenticated";

REVOKE ALL ON TABLE public."business_referral_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_referral_settings" TO "service_role";

GRANT SELECT ON TABLE public."business_referral_settings" TO "authenticated";

REVOKE ALL ON TABLE public."business_role_access_defaults" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_role_access_defaults" TO "service_role";

REVOKE ALL ON TABLE public."business_tax_compliance_sources" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_compliance_sources" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_compliance_sources" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_compliance_sources" TO "service_role";

REVOKE ALL ON TABLE public."business_tax_compliance_updates" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_compliance_updates" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_compliance_updates" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_compliance_updates" TO "service_role";

REVOKE ALL ON TABLE public."business_tax_ruleset_rules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_ruleset_rules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_ruleset_rules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_ruleset_rules" TO "service_role";

REVOKE ALL ON TABLE public."business_tax_rulesets" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_rulesets" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_rulesets" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."business_tax_rulesets" TO "service_role";

REVOKE ALL ON TABLE public."businesses" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."businesses" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."businesses" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."businesses" TO "service_role";

REVOKE ALL ON TABLE public."community_ad_campaigns" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_campaigns" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_campaigns" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_campaigns" TO "service_role";

REVOKE ALL ON TABLE public."community_ad_clicks" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_clicks" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_clicks" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_clicks" TO "service_role";

REVOKE ALL ON TABLE public."community_ad_impressions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_impressions" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_impressions" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_impressions" TO "service_role";

REVOKE ALL ON TABLE public."community_ad_packages" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_packages" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_packages" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_ad_packages" TO "service_role";

REVOKE ALL ON TABLE public."community_blocked_words" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_blocked_words" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_blocked_words" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_blocked_words" TO "service_role";

REVOKE ALL ON TABLE public."community_comments" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_comments" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_comments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_comments" TO "service_role";

REVOKE ALL ON TABLE public."community_conversations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_conversations" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_conversations" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_conversations" TO "service_role";

REVOKE ALL ON TABLE public."community_messages" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_messages" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_messages" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_messages" TO "service_role";

REVOKE ALL ON TABLE public."community_posts" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_posts" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_posts" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_posts" TO "service_role";

REVOKE ALL ON TABLE public."community_profiles" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_profiles" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_profiles" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_profiles" TO "service_role";

REVOKE ALL ON TABLE public."community_reports" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_reports" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_reports" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_reports" TO "service_role";

REVOKE ALL ON TABLE public."community_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_settings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_settings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."community_settings" TO "service_role";

REVOKE ALL ON TABLE public."country_business_tax_rules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."country_business_tax_rules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."country_business_tax_rules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."country_business_tax_rules" TO "service_role";

REVOKE ALL ON TABLE public."country_payroll_rules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."country_payroll_rules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."country_payroll_rules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."country_payroll_rules" TO "service_role";

REVOKE ALL ON TABLE public."customer_credit_note_counters" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_note_counters" TO "anon";

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_note_counters" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_note_counters" TO "service_role";

REVOKE ALL ON TABLE public."customer_credit_note_lines" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_note_lines" TO "anon";

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_note_lines" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_note_lines" TO "service_role";

REVOKE ALL ON TABLE public."customer_credit_notes" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_notes" TO "anon";

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_notes" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_credit_notes" TO "service_role";

REVOKE ALL ON TABLE public."customer_payments" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_payments" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_payments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_payments" TO "service_role";

REVOKE ALL ON TABLE public."customer_refund_counters" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_refund_counters" TO "service_role";

REVOKE ALL ON TABLE public."customer_refunds" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customer_refunds" TO "service_role";

GRANT SELECT ON TABLE public."customer_refunds" TO "authenticated";

REVOKE ALL ON TABLE public."customers" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customers" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customers" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."customers" TO "service_role";

REVOKE ALL ON TABLE public."edge_function_rate_limits" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."edge_function_rate_limits" TO "service_role";

REVOKE ALL ON TABLE public."email_delivery_events" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."email_delivery_events" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."email_delivery_events" TO "service_role";

REVOKE ALL ON TABLE public."expense_ai_scans" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_ai_scans" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_ai_scans" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_ai_scans" TO "service_role";

REVOKE ALL ON TABLE public."expense_attachments" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_attachments" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_attachments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_attachments" TO "service_role";

REVOKE ALL ON TABLE public."expense_audit_log" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_audit_log" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_audit_log" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_audit_log" TO "service_role";

REVOKE ALL ON TABLE public."expense_categories" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_categories" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_categories" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_categories" TO "service_role";

REVOKE ALL ON TABLE public."expense_duplicate_reviews" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_duplicate_reviews" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_duplicate_reviews" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_duplicate_reviews" TO "service_role";

REVOKE ALL ON TABLE public."expense_lines" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_lines" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_lines" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_lines" TO "service_role";

REVOKE ALL ON TABLE public."expense_number_counters" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_number_counters" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_number_counters" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_number_counters" TO "service_role";

REVOKE ALL ON TABLE public."expense_payments" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_payments" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_payments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_payments" TO "service_role";

REVOKE ALL ON TABLE public."expense_reconciliations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_reconciliations" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_reconciliations" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_reconciliations" TO "service_role";

REVOKE ALL ON TABLE public."expense_revisions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expense_revisions" TO "service_role";

GRANT SELECT ON TABLE public."expense_revisions" TO "authenticated";

REVOKE ALL ON TABLE public."expenses" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expenses" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expenses" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."expenses" TO "service_role";

REVOKE ALL ON TABLE public."financial_audit_log" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_audit_log" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_audit_log" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_audit_log" TO "service_role";

REVOKE ALL ON SEQUENCE public."financial_audit_log_id_seq" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."financial_audit_log_id_seq" TO "anon";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."financial_audit_log_id_seq" TO "authenticated";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."financial_audit_log_id_seq" TO "service_role";

REVOKE ALL ON TABLE public."financial_budget_lines" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budget_lines" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budget_lines" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budget_lines" TO "service_role";

REVOKE ALL ON TABLE public."financial_budget_month_values" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budget_month_values" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budget_month_values" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budget_month_values" TO "service_role";

REVOKE ALL ON TABLE public."financial_budgets" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budgets" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budgets" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_budgets" TO "service_role";

REVOKE ALL ON TABLE public."financial_category_mappings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_category_mappings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_category_mappings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_category_mappings" TO "service_role";

REVOKE ALL ON TABLE public."financial_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_settings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_settings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."financial_settings" TO "service_role";

REVOKE ALL ON TABLE public."finlo_credit_redemptions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_credit_redemptions" TO "service_role";

GRANT SELECT ON TABLE public."finlo_credit_redemptions" TO "authenticated";

REVOKE ALL ON TABLE public."finlo_helper_module_controls" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_helper_module_controls" TO "service_role";

REVOKE ALL ON TABLE public."finlo_helper_plan_config" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_helper_plan_config" TO "service_role";

REVOKE ALL ON TABLE public."finlo_helper_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_helper_settings" TO "service_role";

REVOKE ALL ON TABLE public."finlo_helper_usage" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_helper_usage" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_helper_usage" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_helper_usage" TO "service_role";

REVOKE ALL ON TABLE public."finlo_live_voice_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_live_voice_settings" TO "service_role";

REVOKE ALL ON TABLE public."finlo_live_voice_usage" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."finlo_live_voice_usage" TO "service_role";

REVOKE ALL ON TABLE public."frindly_expense_correction_authorizations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."frindly_expense_correction_authorizations" TO "service_role";

REVOKE ALL ON TABLE public."frindly_expense_correction_requests_v1" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."frindly_expense_correction_requests_v1" TO "service_role";

REVOKE ALL ON TABLE public."google_calendar_connections" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."google_calendar_connections" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."google_calendar_connections" TO "service_role";

REVOKE ALL ON TABLE public."google_calendar_event_links" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."google_calendar_event_links" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."google_calendar_event_links" TO "service_role";

REVOKE ALL ON TABLE public."google_calendar_sync_log" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."google_calendar_sync_log" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."google_calendar_sync_log" TO "service_role";

REVOKE ALL ON TABLE public."gst_adjustments" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_adjustments" TO "anon";

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_adjustments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_adjustments" TO "service_role";

REVOKE ALL ON TABLE public."gst_correction_items" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_correction_items" TO "anon";

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_correction_items" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_correction_items" TO "service_role";

REVOKE ALL ON TABLE public."gst_returns" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_returns" TO "anon";

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_returns" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_returns" TO "service_role";

REVOKE ALL ON TABLE public."gst_settings_history" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_settings_history" TO "anon";

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_settings_history" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_settings_history" TO "service_role";

REVOKE ALL ON TABLE public."gst_transition_reviews" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_transition_reviews" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."gst_transition_reviews" TO "service_role";

REVOKE ALL ON TABLE public."import_batches" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_batches" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_batches" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_batches" TO "service_role";

REVOKE ALL ON TABLE public."import_commit_events" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_commit_events" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_commit_events" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_commit_events" TO "service_role";

REVOKE ALL ON TABLE public."import_mapping_profiles" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_mapping_profiles" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_mapping_profiles" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_mapping_profiles" TO "service_role";

REVOKE ALL ON TABLE public."import_mappings" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_mappings" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_mappings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_mappings" TO "service_role";

REVOKE ALL ON TABLE public."import_migration_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_migration_settings" TO "service_role";

REVOKE ALL ON TABLE public."import_record_links" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_record_links" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_record_links" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_record_links" TO "service_role";

REVOKE ALL ON TABLE public."import_record_members" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_record_members" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_record_members" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_record_members" TO "service_role";

REVOKE ALL ON TABLE public."import_records" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_records" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_records" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_records" TO "service_role";

REVOKE ALL ON TABLE public."import_rows" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_rows" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_rows" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_rows" TO "service_role";

REVOKE ALL ON TABLE public."import_sheets" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_sheets" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_sheets" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."import_sheets" TO "service_role";

REVOKE ALL ON TABLE public."invoice_auto_reminder_runs" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_auto_reminder_runs" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_auto_reminder_runs" TO "service_role";

REVOKE ALL ON TABLE public."invoice_payment_links" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_links" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_links" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_links" TO "service_role";

REVOKE ALL ON TABLE public."invoice_payment_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_settings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_settings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_settings" TO "service_role";

REVOKE ALL ON TABLE public."invoice_payment_transactions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_transactions" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_transactions" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_payment_transactions" TO "service_role";

REVOKE ALL ON TABLE public."invoice_reminder_history" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_reminder_history" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_reminder_history" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoice_reminder_history" TO "service_role";

REVOKE ALL ON TABLE public."invoices" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoices" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoices" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."invoices" TO "service_role";

REVOKE ALL ON TABLE public."ird_connect_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."ird_connect_settings" TO "service_role";

GRANT SELECT ON TABLE public."ird_connect_settings" TO "authenticated";

REVOKE ALL ON TABLE public."ird_filing_batches" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."ird_filing_batches" TO "service_role";

GRANT SELECT ON TABLE public."ird_filing_batches" TO "authenticated";

REVOKE ALL ON TABLE public."ird_filing_events" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."ird_filing_events" TO "service_role";

GRANT SELECT ON TABLE public."ird_filing_events" TO "authenticated";

REVOKE ALL ON TABLE public."job_activity" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_activity" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_activity" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_activity" TO "service_role";

REVOKE ALL ON TABLE public."job_actual_costs" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_actual_costs" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_actual_costs" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_actual_costs" TO "service_role";

REVOKE ALL ON TABLE public."job_costings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_costings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_costings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_costings" TO "service_role";

REVOKE ALL ON TABLE public."job_recurrence_series" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_recurrence_series" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_recurrence_series" TO "service_role";

REVOKE ALL ON TABLE public."job_schedule_assignments" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_schedule_assignments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_schedule_assignments" TO "service_role";

REVOKE ALL ON TABLE public."job_schedules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_schedules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."job_schedules" TO "service_role";

REVOKE ALL ON TABLE public."late_transaction_adjustments" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."late_transaction_adjustments" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."late_transaction_adjustments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."late_transaction_adjustments" TO "service_role";

REVOKE ALL ON TABLE public."migration_historical_documents" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."migration_historical_documents" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."migration_historical_documents" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."migration_historical_documents" TO "service_role";

REVOKE ALL ON TABLE public."modules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."modules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."modules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."modules" TO "service_role";

REVOKE ALL ON TABLE public."optional_addon_entitlements" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."optional_addon_entitlements" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."optional_addon_entitlements" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."optional_addon_entitlements" TO "service_role";

REVOKE ALL ON TABLE public."owner_current_account_entries" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."owner_current_account_entries" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."owner_current_account_entries" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."owner_current_account_entries" TO "service_role";

REVOKE ALL ON TABLE public."payment_provider_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payment_provider_settings" TO "service_role";

REVOKE ALL ON TABLE public."payroll_alternative_holiday_entitlements" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_alternative_holiday_entitlements" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_alternative_holiday_entitlements" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_alternative_holiday_entitlements" TO "service_role";

REVOKE ALL ON TABLE public."payroll_annual_holiday_entitlement_periods" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_annual_holiday_entitlement_periods" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_annual_holiday_entitlement_periods" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_annual_holiday_entitlement_periods" TO "service_role";

REVOKE ALL ON TABLE public."payroll_audit_log" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_audit_log" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_audit_log" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_audit_log" TO "service_role";

REVOKE ALL ON SEQUENCE public."payroll_audit_log_id_seq" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."payroll_audit_log_id_seq" TO "anon";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."payroll_audit_log_id_seq" TO "authenticated";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE public."payroll_audit_log_id_seq" TO "service_role";

REVOKE ALL ON TABLE public."payroll_bereavement_events" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_bereavement_events" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_bereavement_events" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_bereavement_events" TO "service_role";

REVOKE ALL ON TABLE public."payroll_compliance_audit" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_audit" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_audit" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_audit" TO "service_role";

REVOKE ALL ON TABLE public."payroll_compliance_sources" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_sources" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_sources" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_sources" TO "service_role";

REVOKE ALL ON TABLE public."payroll_compliance_updates" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_updates" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_updates" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_compliance_updates" TO "service_role";

REVOKE ALL ON TABLE public."payroll_country_rules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_country_rules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_country_rules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_country_rules" TO "service_role";

REVOKE ALL ON TABLE public."payroll_document_types" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_document_types" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_document_types" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_document_types" TO "service_role";

REVOKE ALL ON TABLE public."payroll_employee_documents" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_documents" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_documents" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_documents" TO "service_role";

REVOKE ALL ON TABLE public."payroll_employee_leave" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_leave" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_leave" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_leave" TO "service_role";

REVOKE ALL ON TABLE public."payroll_employee_work_patterns" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_work_patterns" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_work_patterns" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employee_work_patterns" TO "service_role";

REVOKE ALL ON TABLE public."payroll_employees" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employees" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employees" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_employees" TO "service_role";

REVOKE ALL ON TABLE public."payroll_final_pay_calculations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_final_pay_calculations" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_final_pay_calculations" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_final_pay_calculations" TO "service_role";

REVOKE ALL ON TABLE public."payroll_final_pay_components" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_final_pay_components" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_final_pay_components" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_final_pay_components" TO "service_role";

REVOKE ALL ON TABLE public."payroll_financial_transactions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_financial_transactions" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_financial_transactions" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_financial_transactions" TO "service_role";

REVOKE ALL ON TABLE public."payroll_ird_filings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_ird_filings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_ird_filings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_ird_filings" TO "service_role";

REVOKE ALL ON TABLE public."payroll_leave_transactions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_leave_transactions" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_leave_transactions" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_leave_transactions" TO "service_role";

REVOKE ALL ON TABLE public."payroll_leave_types" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_leave_types" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_leave_types" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_leave_types" TO "service_role";

REVOKE ALL ON TABLE public."payroll_migration_history" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_migration_history" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_migration_history" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_migration_history" TO "service_role";

REVOKE ALL ON TABLE public."payroll_migration_opening_balances" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_migration_opening_balances" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_migration_opening_balances" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_migration_opening_balances" TO "service_role";

REVOKE ALL ON TABLE public."payroll_owd_determinations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_owd_determinations" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_owd_determinations" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_owd_determinations" TO "service_role";

REVOKE ALL ON TABLE public."payroll_pay_items" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_items" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_items" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_items" TO "service_role";

REVOKE ALL ON TABLE public."payroll_pay_run_employees" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_run_employees" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_run_employees" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_run_employees" TO "service_role";

REVOKE ALL ON TABLE public."payroll_pay_run_lines" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_run_lines" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_run_lines" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_run_lines" TO "service_role";

REVOKE ALL ON TABLE public."payroll_pay_runs" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_runs" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_runs" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_pay_runs" TO "service_role";

REVOKE ALL ON TABLE public."payroll_payg_eligibility_determinations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_payg_eligibility_determinations" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_payg_eligibility_determinations" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_payg_eligibility_determinations" TO "service_role";

REVOKE ALL ON TABLE public."payroll_payslips" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_payslips" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_payslips" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_payslips" TO "service_role";

REVOKE ALL ON TABLE public."payroll_public_holiday_regions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holiday_regions" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holiday_regions" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holiday_regions" TO "service_role";

REVOKE ALL ON TABLE public."payroll_public_holiday_transfers" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holiday_transfers" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holiday_transfers" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holiday_transfers" TO "service_role";

REVOKE ALL ON TABLE public."payroll_public_holidays" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holidays" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holidays" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_public_holidays" TO "service_role";

REVOKE ALL ON TABLE public."payroll_ruleset_rules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_ruleset_rules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_ruleset_rules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_ruleset_rules" TO "service_role";

REVOKE ALL ON TABLE public."payroll_rulesets" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_rulesets" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_rulesets" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_rulesets" TO "service_role";

REVOKE ALL ON TABLE public."payroll_settings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_settings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_settings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_settings" TO "service_role";

REVOKE ALL ON TABLE public."payroll_statutory_leave_calculations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_statutory_leave_calculations" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_statutory_leave_calculations" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_statutory_leave_calculations" TO "service_role";

REVOKE ALL ON TABLE public."payroll_statutory_leave_entitlements" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_statutory_leave_entitlements" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_statutory_leave_entitlements" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_statutory_leave_entitlements" TO "service_role";

REVOKE ALL ON TABLE public."payroll_timesheet_expenses" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_timesheet_expenses" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_timesheet_expenses" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_timesheet_expenses" TO "service_role";

REVOKE ALL ON TABLE public."payroll_timesheets" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_timesheets" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_timesheets" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."payroll_timesheets" TO "service_role";

REVOKE ALL ON TABLE public."plan_public_features" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."plan_public_features" TO "service_role";

REVOKE ALL ON TABLE public."plans" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."plans" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."plans" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."plans" TO "service_role";

REVOKE ALL ON TABLE public."platform_industries" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."platform_industries" TO "anon";

GRANT SELECT, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."platform_industries" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."platform_industries" TO "service_role";

REVOKE ALL ON TABLE public."profiles" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."profiles" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."profiles" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."profiles" TO "service_role";

REVOKE ALL ON TABLE public."provisional_tax_instalments" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."provisional_tax_instalments" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."provisional_tax_instalments" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."provisional_tax_instalments" TO "service_role";

REVOKE ALL ON TABLE public."provisional_tax_plans" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."provisional_tax_plans" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."provisional_tax_plans" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."provisional_tax_plans" TO "service_role";

REVOKE ALL ON TABLE public."purchase_document_items" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_document_items" TO "service_role";

GRANT SELECT ON TABLE public."purchase_document_items" TO "authenticated";

REVOKE ALL ON TABLE public."purchase_invoice_reviews" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_invoice_reviews" TO "service_role";

GRANT SELECT ON TABLE public."purchase_invoice_reviews" TO "authenticated";

REVOKE ALL ON TABLE public."purchase_order_events" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_order_events" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_order_events" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_order_events" TO "service_role";

REVOKE ALL ON TABLE public."purchase_order_lines" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_order_lines" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_order_lines" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_order_lines" TO "service_role";

REVOKE ALL ON TABLE public."purchase_orders" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_orders" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_orders" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."purchase_orders" TO "service_role";

REVOKE ALL ON TABLE public."quotes" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."quotes" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."quotes" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."quotes" TO "service_role";

REVOKE ALL ON TABLE public."recurring_expense_rules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."recurring_expense_rules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."recurring_expense_rules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."recurring_expense_rules" TO "service_role";

REVOKE ALL ON TABLE public."recurring_rules" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."recurring_rules" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."recurring_rules" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."recurring_rules" TO "service_role";

REVOKE ALL ON TABLE public."referral_audit_log" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."referral_audit_log" TO "service_role";

REVOKE ALL ON TABLE public."referral_campaign_versions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."referral_campaign_versions" TO "service_role";

GRANT SELECT ON TABLE public."referral_campaign_versions" TO "authenticated";

REVOKE ALL ON TABLE public."referral_campaigns" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."referral_campaigns" TO "service_role";

GRANT SELECT ON TABLE public."referral_campaigns" TO "authenticated";

REVOKE ALL ON TABLE public."referral_invites" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."referral_invites" TO "service_role";

GRANT SELECT ON TABLE public."referral_invites" TO "authenticated";

REVOKE ALL ON TABLE public."referrals" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."referrals" TO "service_role";

GRANT SELECT ON TABLE public."referrals" TO "authenticated";

REVOKE ALL ON TABLE public."se_activity" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_activity" TO "service_role";

GRANT SELECT ON TABLE public."se_activity" TO "authenticated";

REVOKE ALL ON TABLE public."se_assets" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_assets" TO "service_role";

GRANT SELECT ON TABLE public."se_assets" TO "authenticated";

REVOKE ALL ON TABLE public."se_document_items" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_document_items" TO "service_role";

GRANT SELECT ON TABLE public."se_document_items" TO "authenticated";

REVOKE ALL ON TABLE public."se_invoice_reviews" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_invoice_reviews" TO "service_role";

GRANT SELECT ON TABLE public."se_invoice_reviews" TO "authenticated";

REVOKE ALL ON TABLE public."se_items" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_items" TO "service_role";

GRANT SELECT ON TABLE public."se_items" TO "authenticated";

REVOKE ALL ON TABLE public."se_movements" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_movements" TO "service_role";

GRANT SELECT ON TABLE public."se_movements" TO "authenticated";

REVOKE ALL ON TABLE public."se_reviews" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_reviews" TO "service_role";

GRANT SELECT ON TABLE public."se_reviews" TO "authenticated";

REVOKE ALL ON TABLE public."se_rule_audit" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_rule_audit" TO "service_role";

GRANT SELECT ON TABLE public."se_rule_audit" TO "authenticated";

REVOKE ALL ON TABLE public."se_rule_versions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."se_rule_versions" TO "service_role";

GRANT SELECT ON TABLE public."se_rule_versions" TO "authenticated";

REVOKE ALL ON TABLE public."stripe_refund_processing" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."stripe_refund_processing" TO "service_role";

REVOKE ALL ON TABLE public."subscription_lifecycle_notifications" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."subscription_lifecycle_notifications" TO "service_role";

REVOKE ALL ON TABLE public."subscription_notification_scheduler_config" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."subscription_notification_scheduler_config" TO "service_role";

REVOKE ALL ON TABLE public."subscriptions" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."subscriptions" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."subscriptions" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."subscriptions" TO "service_role";

REVOKE ALL ON TABLE public."supplier_credit_counters" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."supplier_credit_counters" TO "service_role";

REVOKE ALL ON TABLE public."supplier_credits" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."supplier_credits" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."supplier_credits" TO "service_role";

REVOKE ALL ON TABLE public."supplier_refund_allocations" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."supplier_refund_allocations" TO "service_role";

GRANT SELECT ON TABLE public."supplier_refund_allocations" TO "authenticated";

REVOKE ALL ON TABLE public."supplier_refund_counters" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."supplier_refund_counters" TO "service_role";

REVOKE ALL ON TABLE public."supplier_refunds" FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."supplier_refunds" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."supplier_refunds" TO "service_role";

REVOKE ALL ON TABLE public."suppliers" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."suppliers" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."suppliers" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."suppliers" TO "service_role";

REVOKE ALL ON TABLE public."support_audit_log" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_audit_log" TO "service_role";

REVOKE ALL ON TABLE public."support_messages" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_messages" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_messages" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_messages" TO "service_role";

REVOKE ALL ON TABLE public."support_operational_events" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_operational_events" TO "service_role";

REVOKE ALL ON TABLE public."support_presence" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_presence" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_presence" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_presence" TO "service_role";

REVOKE ALL ON TABLE public."support_threads" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_threads" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_threads" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."support_threads" TO "service_role";

REVOKE ALL ON TABLE public."tax_export_mappings" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."tax_export_mappings" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."tax_export_mappings" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."tax_export_mappings" TO "service_role";

REVOKE ALL ON TABLE public."v6191_xero_chart_export" FROM PUBLIC, anon, authenticated, service_role;

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."v6191_xero_chart_export" TO "anon";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."v6191_xero_chart_export" TO "authenticated";

GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public."v6191_xero_chart_export" TO "service_role";
