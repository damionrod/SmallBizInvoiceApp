# Database Function Audit v61.97

Date: 2026-09-26

Scope: read-only comparison of live Supabase `public` schema functions against current frontend `.rpc('name')` callers in `/public/*.js`.

Important: no `DROP FUNCTION` statements were run and no cleanup migration was created. This report only identifies functions with zero current frontend RPC callers. Some of these may still be required as trigger functions, policy helpers, internal SQL helpers, migration utilities, or Edge Function dependencies.

## Summary

| Check | Count |
| --- | ---: |
| Live public schema functions | 271 |
| Current frontend RPC names in `/public/*.js` | 93 |
| Live functions with no current frontend RPC caller | 180 |
| Frontend RPC names missing from live public schema | 2 |

## Frontend RPC Names Missing From Live Public Schema

These are called by current frontend code but were not present in the live `public` schema function list.

- `se_preview_access_status`
- `v33_admin_extend_trial`

## Live Functions With No Current Frontend RPC Caller

These live functions have zero direct `.rpc('name')` callers in current `/public/*.js` files.

- `enforce_invoice_subscription`
- `enforce_payroll_employee_plan_limit`
- `handle_new_user`
- `has_active_business_membership`
- `is_super_admin`
- `mark_quote_won_from_invoice`
- `se_confirm_purchase`
- `se_correct_purchase`
- `se_create_asset`
- `se_create_item`
- `se_create_opening_asset`
- `se_guard_reviewed_bill`
- `se_guard_reviewed_expense_line`
- `se_publish_rule`
- `se_record_disposal`
- `se_record_movement`
- `se_require_access`
- `se_review_invoice`
- `se_save_document_items`
- `se_save_rule_draft`
- `v33_admin_upsert_plan`
- `v34_get_payment_provider_secret`
- `v50_protect_profile_security_fields`
- `v51_enforce_expense_business`
- `v51_expense_audit_trigger`
- `v51_expense_total_change_trigger`
- `v51_new_business_expense_defaults`
- `v51_payment_change_trigger`
- `v51_refresh_expense_payment_totals`
- `v51_seed_expense_categories`
- `v51_validate_attachment_path`
- `v51_validate_batch_item_refs`
- `v51_validate_credit_refs`
- `v51_validate_expense_child`
- `v51_validate_expense_refs`
- `v51_validate_line_refs`
- `v51_validate_payment_refs`
- `v51_validate_reconciliation_refs`
- `v51_validate_recurring_refs`
- `v51_validate_supplier_defaults`
- `v55_lock_finalised_pay_run`
- `v55_lock_finalised_payroll_child`
- `v55_payroll_access`
- `v55_validate_payroll_refs`
- `v58_financial_audit_trigger`
- `v58_financials_access`
- `v58_financials_tenant_guard`
- `v58_lock_finalised_gst`
- `v58_seed_financial_category_mapping`
- `v58_seed_financials_for_profile`
- `v58_validate_financial_refs`
- `v60_customer_payment_guard`
- `v60_refresh_invoice_paid`
- `v6114_prevent_duplicate_finalised_pay`
- `v6135_bank_module_enabled`
- `v6135_validate_bank_allocation`
- `v6144_touch_business_membership_updated_at`
- `v6145_can_manage_team`
- `v6145_has_active_business_membership`
- `v6147_add_restrictive_policies`
- `v6147_can_read_area`
- `v6147_can_write_area`
- `v6148_add_payroll_restrictive`
- `v6148_role_default_read`
- `v6148_role_default_write`
- `v6149_effective_role_default_read`
- `v6149_effective_role_default_write`
- `v6150_admin_delete_business_internal`
- `v6151_auth_email_verified`
- `v6151_get_or_create_referral_code`
- `v6151_issue_referral_rewards_internal`
- `v6151_process_referral_event`
- `v6151_process_referral_event_internal`
- `v6151_register_referral_signup_internal`
- `v6151_reward_amount`
- `v6152_complete_credit_redemption`
- `v6152_complete_credit_redemption_internal`
- `v6152_release_credit_redemption`
- `v6152_release_credit_redemption_internal`
- `v6152_reserve_credits`
- `v6152_reserve_credits_internal`
- `v6167_invoice_job_guard`
- `v6167_record_source_activity`
- `v6167_sync_job_from_quote`
- `v6167_validate_job_business`
- `v6168b_activate_ruleset`
- `v6168b_create_draft_ruleset`
- `v6168b_set_ruleset_status`
- `v6169a_accountant_centre_access`
- `v6169a_validate_invoice_business_refs`
- `v6170_accounting_bank_mapping_guard`
- `v6170_bank_mapping_validate`
- `v6170a_bootstrap_current_business`
- `v6170a_guard_journal_line_insert`
- `v6170a_guard_journal_status_transition`
- `v6170a_guard_posted_journal_mutation`
- `v6170a_guard_posted_line_mutation`
- `v6170a_period_is_open`
- `v6170a_post_journal`
- `v6170a_reverse_journal`
- `v6170a_seed_accounts`
- `v6170a_validate_source_owner`
- `v6170b_account`
- `v6170b_ap`
- `v6170b_ar`
- `v6170b_ar_ap_reconciliation`
- `v6170b_bootstrap_current_business`
- `v6170b_expense_eligible`
- `v6170b_general_ledger`
- `v6170b_invoice_effective_fee`
- `v6170b_invoice_eligible`
- `v6170b_mark_source_resolved`
- `v6170b_payment_account`
- `v6170b_payroll_lines`
- `v6170b_post_bank_evidence`
- `v6170b_post_source`
- `v6170b_readiness`
- `v6170b_seed_accounts`
- `v6170b_unresolved_ap`
- `v6170b_unresolved_ar`
- `v6170c1_expense_delete_guard`
- `v6170c1_expense_lifecycle_guard`
- `v6170c1_expense_line_guard`
- `v6170c1_invoice_delete_guard`
- `v6170c1_invoice_lifecycle_guard`
- `v6170c1_issue_invoice`
- `v6170c1_seal_expense_lines`
- `v6170c2_next_credit_number`
- `v6170c2_rebuild_credit_lines`
- `v6170c3_guard_refund_mutation`
- `v6170c3_next_refund_number`
- `v6170c45_create_supplier_refund`
- `v6170c45_expense_payment_guard`
- `v6170c45_next_supplier_credit_number`
- `v6170c45_supplier_credit`
- `v6170c45_supplier_credit_available`
- `v6170e_create_gst_correction`
- `v6170e_guard_gst_return_mutation`
- `v6170f_bas_due_date`
- `v6170f_business_country`
- `v6170f_default_new_au_financial_settings`
- `v6170f_guard_au_expense_line_tax`
- `v6170f_guard_au_expense_tax`
- `v6170f_guard_au_invoice_tax`
- `v6170f_guard_bas_immutability`
- `v6170f_preserve_au_credit_tax_classification`
- `v6171_onboarding_dismiss_getting_started`
- `v6171_onboarding_get`
- `v6171_onboarding_save`
- `v6171_seed_new_business_onboarding`
- `v6171b_admin_import_overview`
- `v6171b_admin_import_save`
- `v6171b_apply_mapping`
- `v6171b_confirm_import`
- `v6171b_import_config`
- `v6171b_import_get`
- `v6171b_import_history`
- `v6171c_helper_business_context`
- `v6173p2_validate_payroll_foundation_refs`
- `v6173p4b_validate_refs`
- `v6173p5b_validate_refs`
- `v6173p6b_protect_finalised`
- `v6173p6b_protect_finalised_component`
- `v6173p6b_validate_refs`
- `v6174_admin_upsert_plan`
- `v6179_is_iana_timezone`
- `v6179_schedule_entitled`
- `v6179_schedule_role_allowed`
- `v6179_smallint_array_is_unique`
- `v6179_validate_google_refs`
- `v6179_validate_schedule_assignment_refs`
- `v6179_validate_schedule_refs`
- `v6181_invoice_payments_enabled`
- `v6181_record_online_invoice_payment`
- `v6187_guard_subscription_write`
- `v6187_subscription_read_only`
- `v6188_register_signup_referral`
- `v6190_net_purchase_rows`
- `v6192_account_id`
- `v6192_create_posted_journal`

## Recommended Next Step

Before any cleanup migration, classify each no-frontend-caller function as one of:

- trigger or auth hook
- RLS/helper function
- internal function called by another SQL function
- Edge Function or backend caller
- truly orphaned old version

Only the final group should be considered for a future `DROP FUNCTION` migration.
