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
REVOKE ALL ON FUNCTION public."current_business_id"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."current_business_id"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."current_business_id"() TO "service_role";

REVOKE ALL ON FUNCTION public."enforce_invoice_subscription"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."enforce_invoice_subscription"() TO "service_role";

REVOKE ALL ON FUNCTION public."enforce_payroll_employee_plan_limit"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."enforce_payroll_employee_plan_limit"() TO "service_role";

REVOKE ALL ON FUNCTION public."frindly_expense_assessment_combined_v1"(p_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."frindly_expense_assessment_combined_v1"(p_expense_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."frindly_expense_assessment_combined_v1"(p_expense_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."frindly_expense_assessment_timing_v1"(p_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."frindly_expense_assessment_timing_v1"(p_expense_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."handle_new_user"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."handle_new_user"() TO "service_role";

REVOKE ALL ON FUNCTION public."has_active_business_membership"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."has_active_business_membership"(p_business_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."has_active_business_membership"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."is_super_admin"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."is_super_admin"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."is_super_admin"() TO "service_role";

REVOKE ALL ON FUNCTION public."se_correct_purchase"(p_business_id uuid, p_review_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_correct_purchase"(p_business_id uuid, p_review_id uuid, p_reason text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."se_correct_purchase"(p_business_id uuid, p_review_id uuid, p_reason text) TO "service_role";

REVOKE ALL ON FUNCTION public."se_create_asset"(p_business_id uuid, p_item_id uuid, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_create_asset"(p_business_id uuid, p_item_id uuid, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."se_create_asset"(p_business_id uuid, p_item_id uuid, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric) TO "service_role";

REVOKE ALL ON FUNCTION public."se_create_item"(p_business_id uuid, p_kind text, p_name text, p_sku text, p_unit text, p_low_stock_at numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_create_item"(p_business_id uuid, p_kind text, p_name text, p_sku text, p_unit text, p_low_stock_at numeric) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."se_create_item"(p_business_id uuid, p_kind text, p_name text, p_sku text, p_unit text, p_low_stock_at numeric) TO "service_role";

REVOKE ALL ON FUNCTION public."se_create_opening_asset"(p_business_id uuid, p_name text, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_create_opening_asset"(p_business_id uuid, p_name text, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."se_create_opening_asset"(p_business_id uuid, p_name text, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric) TO "service_role";

REVOKE ALL ON FUNCTION public."se_create_opening_asset_v61105"(p_business_id uuid, p_name text, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric, p_opening_date date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_create_opening_asset_v61105"(p_business_id uuid, p_name text, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric, p_opening_date date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."se_create_opening_asset_v61105"(p_business_id uuid, p_name text, p_original_cost numeric, p_gst_amount numeric, p_purchased_on date, p_available_on date, p_business_use numeric, p_condition text, p_category text, p_book_opening numeric, p_tax_opening numeric, p_opening_date date) TO "service_role";

REVOKE ALL ON FUNCTION public."se_guard_reviewed_bill"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_guard_reviewed_bill"() TO "service_role";

REVOKE ALL ON FUNCTION public."se_guard_reviewed_expense_line"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_guard_reviewed_expense_line"() TO "service_role";

REVOKE ALL ON FUNCTION public."se_publish_rule"(p_id uuid, p_note text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_publish_rule"(p_id uuid, p_note text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."se_publish_rule"(p_id uuid, p_note text) TO "service_role";

REVOKE ALL ON FUNCTION public."se_record_disposal"(p_business_id uuid, p_asset_id uuid, p_disposed_on date, p_proceeds numeric, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_record_disposal"(p_business_id uuid, p_asset_id uuid, p_disposed_on date, p_proceeds numeric, p_reason text) TO "service_role";

REVOKE ALL ON FUNCTION public."se_record_movement"(p_business_id uuid, p_item_id uuid, p_kind text, p_quantity numeric, p_unit_cost numeric, p_occurred_on date, p_reason text, p_invoice_id uuid, p_job_id uuid, p_invoice_line_index integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_record_movement"(p_business_id uuid, p_item_id uuid, p_kind text, p_quantity numeric, p_unit_cost numeric, p_occurred_on date, p_reason text, p_invoice_id uuid, p_job_id uuid, p_invoice_line_index integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."se_record_movement"(p_business_id uuid, p_item_id uuid, p_kind text, p_quantity numeric, p_unit_cost numeric, p_occurred_on date, p_reason text, p_invoice_id uuid, p_job_id uuid, p_invoice_line_index integer) TO "service_role";

REVOKE ALL ON FUNCTION public."se_save_rule_draft"(p_effective_from date, p_low_value numeric, p_boost_percent numeric, p_boost_from date, p_source_url text, p_note text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."se_save_rule_draft"(p_effective_from date, p_low_value numeric, p_boost_percent numeric, p_boost_from date, p_source_url text, p_note text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."se_save_rule_draft"(p_effective_from date, p_low_value numeric, p_boost_percent numeric, p_boost_from date, p_source_url text, p_note text) TO "service_role";

REVOKE ALL ON FUNCTION public."v33_admin_set_subscription"(p_business_id uuid, p_plan_id uuid, p_status text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v33_admin_set_subscription"(p_business_id uuid, p_plan_id uuid, p_status text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v33_admin_set_subscription"(p_business_id uuid, p_plan_id uuid, p_status text) TO "service_role";

REVOKE ALL ON FUNCTION public."v33_admin_set_suspension"(p_business_id uuid, p_suspend boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v33_admin_set_suspension"(p_business_id uuid, p_suspend boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v33_admin_set_suspension"(p_business_id uuid, p_suspend boolean) TO "service_role";

REVOKE ALL ON FUNCTION public."v33_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_invoice_limit integer, p_included_modules text[], p_stripe_price_id text, p_is_public boolean, p_sort_order integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v33_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_invoice_limit integer, p_included_modules text[], p_stripe_price_id text, p_is_public boolean, p_sort_order integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v33_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_invoice_limit integer, p_included_modules text[], p_stripe_price_id text, p_is_public boolean, p_sort_order integer) TO "service_role";

REVOKE ALL ON FUNCTION public."v34_get_payment_provider_secret"(p_provider text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v34_get_payment_provider_secret"(p_provider text) TO "service_role";

REVOKE ALL ON FUNCTION public."v35_checkout_available"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v35_checkout_available"() TO "anon";
GRANT EXECUTE ON FUNCTION public."v35_checkout_available"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v35_checkout_available"() TO "service_role";

REVOKE ALL ON FUNCTION public."v50_protect_profile_security_fields"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v50_protect_profile_security_fields"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_enforce_expense_business"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_enforce_expense_business"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_expense_audit_trigger"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_expense_audit_trigger"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_expense_total_change_trigger"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_expense_total_change_trigger"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_new_business_expense_defaults"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_new_business_expense_defaults"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_next_expense_number"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_next_expense_number"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v51_next_expense_number"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_payment_change_trigger"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_payment_change_trigger"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_refresh_expense_payment_totals"(p_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_refresh_expense_payment_totals"(p_expense_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v51_seed_expense_categories"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_seed_expense_categories"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_attachment_path"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_attachment_path"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_batch_item_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_batch_item_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_credit_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_credit_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_expense_child"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_expense_child"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_expense_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_expense_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_line_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_line_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_payment_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_payment_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_reconciliation_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_reconciliation_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_recurring_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_recurring_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v51_validate_supplier_defaults"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v51_validate_supplier_defaults"() TO "service_role";

REVOKE ALL ON FUNCTION public."v55_seed_payroll_defaults"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v55_seed_payroll_defaults"(p_business_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v55_seed_payroll_defaults"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v58_financial_audit_trigger"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v58_financial_audit_trigger"() TO "service_role";

REVOKE ALL ON FUNCTION public."v58_financials_tenant_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v58_financials_tenant_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v58_lock_finalised_gst"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v58_lock_finalised_gst"() TO "service_role";

REVOKE ALL ON FUNCTION public."v58_seed_financial_category_mapping"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v58_seed_financial_category_mapping"() TO "service_role";

REVOKE ALL ON FUNCTION public."v58_seed_financials_for_profile"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v58_seed_financials_for_profile"() TO "service_role";

REVOKE ALL ON FUNCTION public."v58_validate_financial_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v58_validate_financial_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v60_customer_payment_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v60_customer_payment_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v60_refresh_invoice_paid"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v60_refresh_invoice_paid"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6114_prevent_duplicate_finalised_pay"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6114_prevent_duplicate_finalised_pay"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6135_validate_bank_allocation"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6135_validate_bank_allocation"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6144_touch_business_membership_updated_at"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6144_touch_business_membership_updated_at"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6145_can_manage_team"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6145_can_manage_team"(p_business_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6145_can_manage_team"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6145_has_active_business_membership"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6145_has_active_business_membership"(p_business_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6145_has_active_business_membership"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6145_list_business_team"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6145_list_business_team"(p_business_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6145_list_business_team"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6145_update_business_member"(p_business_id uuid, p_membership_id uuid, p_role text, p_status text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6145_update_business_member"(p_business_id uuid, p_membership_id uuid, p_role text, p_status text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6145_update_business_member"(p_business_id uuid, p_membership_id uuid, p_role text, p_status text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6147_add_restrictive_policies"(p_table text, p_area text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6147_add_restrictive_policies"(p_table text, p_area text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6147_can_read_area"(p_business_id uuid, p_area text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6147_can_read_area"(p_business_id uuid, p_area text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6147_can_read_area"(p_business_id uuid, p_area text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6147_can_write_area"(p_business_id uuid, p_area text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6147_can_write_area"(p_business_id uuid, p_area text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6147_can_write_area"(p_business_id uuid, p_area text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6147_current_business_role"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6147_current_business_role"(p_business_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6147_current_business_role"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6148_add_payroll_restrictive"(p_table text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6148_add_payroll_restrictive"(p_table text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6148_list_member_access"(p_business_id uuid, p_membership_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6148_list_member_access"(p_business_id uuid, p_membership_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6148_list_member_access"(p_business_id uuid, p_membership_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6148_my_effective_access"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6148_my_effective_access"(p_business_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6148_my_effective_access"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6148_reset_member_access"(p_business_id uuid, p_membership_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6148_reset_member_access"(p_business_id uuid, p_membership_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6148_reset_member_access"(p_business_id uuid, p_membership_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6148_role_default_read"(p_role text, p_area text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6148_role_default_read"(p_role text, p_area text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6148_role_default_read"(p_role text, p_area text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6148_role_default_write"(p_role text, p_area text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6148_role_default_write"(p_role text, p_area text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6148_role_default_write"(p_role text, p_area text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6148_set_member_access"(p_business_id uuid, p_membership_id uuid, p_area text, p_level text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6148_set_member_access"(p_business_id uuid, p_membership_id uuid, p_area text, p_level text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6148_set_member_access"(p_business_id uuid, p_membership_id uuid, p_area text, p_level text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6149_effective_role_default_read"(p_business_id uuid, p_role text, p_area text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6149_effective_role_default_read"(p_business_id uuid, p_role text, p_area text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6149_effective_role_default_write"(p_business_id uuid, p_role text, p_area text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6149_effective_role_default_write"(p_business_id uuid, p_role text, p_area text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6149_list_role_permissions"(p_business_id uuid, p_role text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6149_list_role_permissions"(p_business_id uuid, p_role text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6149_list_role_permissions"(p_business_id uuid, p_role text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6149_reset_role_permissions"(p_business_id uuid, p_role text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6149_reset_role_permissions"(p_business_id uuid, p_role text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6149_reset_role_permissions"(p_business_id uuid, p_role text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6149_set_role_permission"(p_business_id uuid, p_role text, p_area text, p_level text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6149_set_role_permission"(p_business_id uuid, p_role text, p_area text, p_level text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6149_set_role_permission"(p_business_id uuid, p_role text, p_area text, p_level text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6150_admin_delete_business_internal"(p_business_id uuid, p_confirmation_name text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6150_admin_delete_business_internal"(p_business_id uuid, p_confirmation_name text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_admin_dashboard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_admin_dashboard"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6151_admin_dashboard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_admin_manual_credit"(p_business_id uuid, p_amount numeric, p_note text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_admin_manual_credit"(p_business_id uuid, p_amount numeric, p_note text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6151_admin_manual_credit"(p_business_id uuid, p_amount numeric, p_note text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_admin_referral_action"(p_referral_id uuid, p_action text, p_note text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_admin_referral_action"(p_referral_id uuid, p_action text, p_note text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6151_admin_referral_action"(p_referral_id uuid, p_action text, p_note text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_admin_save_campaign"(p_campaign_id uuid, p_name text, p_active boolean, p_start timestamp with time zone, p_end timestamp with time zone, p_nav_label text, p_title text, p_promo text, p_email_heading text, p_email_text text, p_qualification text, p_expiry_days integer, p_ref_type text, p_ref_value numeric, p_new_enabled boolean, p_new_type text, p_new_value numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_admin_save_campaign"(p_campaign_id uuid, p_name text, p_active boolean, p_start timestamp with time zone, p_end timestamp with time zone, p_nav_label text, p_title text, p_promo text, p_email_heading text, p_email_text text, p_qualification text, p_expiry_days integer, p_ref_type text, p_ref_value numeric, p_new_enabled boolean, p_new_type text, p_new_value numeric) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6151_admin_save_campaign"(p_campaign_id uuid, p_name text, p_active boolean, p_start timestamp with time zone, p_end timestamp with time zone, p_nav_label text, p_title text, p_promo text, p_email_heading text, p_email_text text, p_qualification text, p_expiry_days integer, p_ref_type text, p_ref_value numeric, p_new_enabled boolean, p_new_type text, p_new_value numeric) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_admin_update_credit"(p_credit_id uuid, p_action text, p_note text, p_expiry timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_admin_update_credit"(p_credit_id uuid, p_action text, p_note text, p_expiry timestamp with time zone) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6151_admin_update_credit"(p_credit_id uuid, p_action text, p_note text, p_expiry timestamp with time zone) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_auth_email_verified"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_auth_email_verified"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_get_or_create_referral_code"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_get_or_create_referral_code"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_issue_referral_rewards_internal"(p_referral_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_issue_referral_rewards_internal"(p_referral_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_process_referral_event"(p_business_id uuid, p_event text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_process_referral_event"(p_business_id uuid, p_event text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_process_referral_event_internal"(p_business_id uuid, p_event text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_process_referral_event_internal"(p_business_id uuid, p_event text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_referral_portal"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_referral_portal"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6151_referral_portal"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_register_referral_signup_internal"(p_business_id uuid, p_user_id uuid, p_email text, p_code text, p_invite_token text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_register_referral_signup_internal"(p_business_id uuid, p_user_id uuid, p_email text, p_code text, p_invite_token text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_reward_amount"(p_business_id uuid, p_type text, p_value numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_reward_amount"(p_business_id uuid, p_type text, p_value numeric) TO "service_role";

REVOKE ALL ON FUNCTION public."v6151_set_referral_shortcut"(p_show boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6151_set_referral_shortcut"(p_show boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6151_set_referral_shortcut"(p_show boolean) TO "service_role";

REVOKE ALL ON FUNCTION public."v6152_complete_credit_redemption"(p_application_id uuid, p_stripe_balance_transaction_id text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6152_complete_credit_redemption"(p_application_id uuid, p_stripe_balance_transaction_id text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6152_complete_credit_redemption_internal"(p_application_id uuid, p_stripe_balance_transaction_id text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6152_complete_credit_redemption_internal"(p_application_id uuid, p_stripe_balance_transaction_id text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6152_release_credit_redemption"(p_application_id uuid, p_error text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6152_release_credit_redemption"(p_application_id uuid, p_error text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6152_release_credit_redemption_internal"(p_application_id uuid, p_error text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6152_release_credit_redemption_internal"(p_application_id uuid, p_error text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6152_reserve_credits"(p_business_id uuid, p_stripe_invoice_id text, p_stripe_customer_id text, p_currency text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6152_reserve_credits"(p_business_id uuid, p_stripe_invoice_id text, p_stripe_customer_id text, p_currency text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6152_reserve_credits_internal"(p_business_id uuid, p_stripe_invoice_id text, p_stripe_customer_id text, p_currency text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6152_reserve_credits_internal"(p_business_id uuid, p_stripe_invoice_id text, p_stripe_customer_id text, p_currency text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6167_invoice_job_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6167_invoice_job_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6167_record_source_activity"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6167_record_source_activity"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6167_sync_job_from_quote"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6167_sync_job_from_quote"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6167_validate_job_business"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6167_validate_job_business"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6168a_activate_ruleset"(p_ruleset_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6168a_activate_ruleset"(p_ruleset_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6168a_activate_ruleset"(p_ruleset_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6168a_create_draft_ruleset"(p_update_id uuid, p_name text, p_version text, p_effective_from date, p_effective_to date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6168a_create_draft_ruleset"(p_update_id uuid, p_name text, p_version text, p_effective_from date, p_effective_to date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6168a_create_draft_ruleset"(p_update_id uuid, p_name text, p_version text, p_effective_from date, p_effective_to date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6168a_mark_update_no_impact"(p_update_id uuid, p_notes text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6168a_mark_update_no_impact"(p_update_id uuid, p_notes text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6168a_mark_update_no_impact"(p_update_id uuid, p_notes text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6168a_set_ruleset_status"(p_ruleset_id uuid, p_status text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6168a_set_ruleset_status"(p_ruleset_id uuid, p_status text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6168a_set_ruleset_status"(p_ruleset_id uuid, p_status text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6168b_activate_ruleset"(p_ruleset_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6168b_activate_ruleset"(p_ruleset_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6168b_activate_ruleset"(p_ruleset_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6168b_create_draft_ruleset"(p_update_id uuid, p_name text, p_version text, p_effective_from date, p_effective_to date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6168b_create_draft_ruleset"(p_update_id uuid, p_name text, p_version text, p_effective_from date, p_effective_to date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6168b_create_draft_ruleset"(p_update_id uuid, p_name text, p_version text, p_effective_from date, p_effective_to date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6168b_set_ruleset_status"(p_ruleset_id uuid, p_status text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6168b_set_ruleset_status"(p_ruleset_id uuid, p_status text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6168b_set_ruleset_status"(p_ruleset_id uuid, p_status text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6169a_accountant_centre_access"(p_business_id uuid, p_write boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6169a_accountant_centre_access"(p_business_id uuid, p_write boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6169a_accountant_centre_access"(p_business_id uuid, p_write boolean) TO "service_role";

REVOKE ALL ON FUNCTION public."v6169a_validate_invoice_business_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6169a_validate_invoice_business_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6169b_add_business"(p_name text, p_country text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6169b_add_business"(p_name text, p_country text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6169b_add_business"(p_name text, p_country text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170_accounting_bank_mapping_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170_accounting_bank_mapping_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170_bank_mapping_validate"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170_bank_mapping_validate"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_bootstrap_current_business"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_bootstrap_current_business"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170a_bootstrap_current_business"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_guard_journal_line_insert"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_guard_journal_line_insert"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_guard_journal_status_transition"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_guard_journal_status_transition"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_guard_posted_journal_mutation"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_guard_posted_journal_mutation"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_guard_posted_line_mutation"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_guard_posted_line_mutation"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_period_is_open"(p_business_id uuid, p_date date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_period_is_open"(p_business_id uuid, p_date date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_post_journal"(p_journal_date date, p_source_type text, p_source_id uuid, p_source_reference text, p_description text, p_journal_type text, p_lines jsonb, p_posting_version integer, p_migration_origin text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_post_journal"(p_journal_date date, p_source_type text, p_source_id uuid, p_source_reference text, p_description text, p_journal_type text, p_lines jsonb, p_posting_version integer, p_migration_origin text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170a_post_journal"(p_journal_date date, p_source_type text, p_source_id uuid, p_source_reference text, p_description text, p_journal_type text, p_lines jsonb, p_posting_version integer, p_migration_origin text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_seed_accounts"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_seed_accounts"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170a_validate_source_owner"(p_business_id uuid, p_source_type text, p_source_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170a_validate_source_owner"(p_business_id uuid, p_source_type text, p_source_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_account"(p_bid uuid, p_key text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_account"(p_bid uuid, p_key text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_ap"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_ap"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_ap"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_ar"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_ar"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_ar"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_ar_ap_reconciliation"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_ar_ap_reconciliation"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_ar_ap_reconciliation"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_bootstrap_current_business"(p_origin text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_bootstrap_current_business"(p_origin text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_bootstrap_current_business"(p_origin text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_expense_eligible"(p_bid uuid, p_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_expense_eligible"(p_bid uuid, p_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_general_ledger"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_general_ledger"(p_from date, p_to date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_general_ledger"(p_from date, p_to date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_invoice_effective_fee"(p_bid uuid, p_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_invoice_effective_fee"(p_bid uuid, p_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_invoice_eligible"(p_bid uuid, p_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_invoice_eligible"(p_bid uuid, p_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_mark_source_resolved"(p_business_id uuid, p_source_type text, p_source_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_mark_source_resolved"(p_business_id uuid, p_source_type text, p_source_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_payroll_lines"(p_bid uuid, p_wage numeric, p_reimb numeric, p_emp numeric, p_paye numeric, p_kiwi numeric, p_net numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_payroll_lines"(p_bid uuid, p_wage numeric, p_reimb numeric, p_emp numeric, p_paye numeric, p_kiwi numeric, p_net numeric) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_post_bank_evidence"(p_bank_transaction_id uuid, p_migration_origin text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_post_bank_evidence"(p_bank_transaction_id uuid, p_migration_origin text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_post_bank_evidence"(p_bank_transaction_id uuid, p_migration_origin text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_post_source"(p_source_type text, p_source_id uuid, p_migration_origin text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_post_source"(p_source_type text, p_source_id uuid, p_migration_origin text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_post_source"(p_source_type text, p_source_id uuid, p_migration_origin text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_profit_loss"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_profit_loss"(p_from date, p_to date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_profit_loss"(p_from date, p_to date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_readiness"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_readiness"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_readiness"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_seed_accounts"(p_business_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_seed_accounts"(p_business_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_trial_balance"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_trial_balance"(p_from date, p_to date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_trial_balance"(p_from date, p_to date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_unresolved_ap"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_unresolved_ap"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_unresolved_ap"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170b_unresolved_ar"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170b_unresolved_ar"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170b_unresolved_ar"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c1_expense_delete_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c1_expense_delete_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c1_expense_line_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c1_expense_line_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c1_invoice_delete_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c1_invoice_delete_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c1_invoice_lifecycle_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c1_invoice_lifecycle_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c1_issue_invoice"(p_invoice_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c1_issue_invoice"(p_invoice_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c1_issue_invoice"(p_invoice_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c1_seal_expense_lines"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c1_seal_expense_lines"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c2_create_credit_note"(p_invoice_id uuid, p_credit_type text, p_total numeric, p_reason text, p_credit_date date, p_idempotency_key uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c2_create_credit_note"(p_invoice_id uuid, p_credit_type text, p_total numeric, p_reason text, p_credit_date date, p_idempotency_key uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c2_create_credit_note"(p_invoice_id uuid, p_credit_type text, p_total numeric, p_reason text, p_credit_date date, p_idempotency_key uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c2_credit_summary"(p_invoice_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c2_credit_summary"(p_invoice_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c2_credit_summary"(p_invoice_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c2_delete_draft_credit_note"(p_credit_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c2_delete_draft_credit_note"(p_credit_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c2_delete_draft_credit_note"(p_credit_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c2_issue_credit_note"(p_credit_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c2_issue_credit_note"(p_credit_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c2_issue_credit_note"(p_credit_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c2_next_credit_number"(p_bid uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c2_next_credit_number"(p_bid uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c2_rebuild_credit_lines"(p_credit_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c2_rebuild_credit_lines"(p_credit_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c2_update_credit_note"(p_credit_id uuid, p_total numeric, p_reason text, p_credit_type text, p_credit_date date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c2_update_credit_note"(p_credit_id uuid, p_total numeric, p_reason text, p_credit_type text, p_credit_date date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c2_update_credit_note"(p_credit_id uuid, p_total numeric, p_reason text, p_credit_type text, p_credit_date date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c2_void_credit_note"(p_credit_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c2_void_credit_note"(p_credit_id uuid, p_reason text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c2_void_credit_note"(p_credit_id uuid, p_reason text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_create_refund"(p_customer_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_create_refund"(p_customer_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_create_refund"(p_customer_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_customer_credit"(p_customer_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_customer_credit"(p_customer_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_customer_credit"(p_customer_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_delete_draft_refund"(p_refund_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_delete_draft_refund"(p_refund_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_delete_draft_refund"(p_refund_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_match_refund"(p_bank_transaction_id uuid, p_refund_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_match_refund"(p_bank_transaction_id uuid, p_refund_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_match_refund"(p_bank_transaction_id uuid, p_refund_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_next_refund_number"(p_bid uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_next_refund_number"(p_bid uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_next_refund_number"(p_bid uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_record_refund"(p_refund_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_record_refund"(p_refund_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_record_refund"(p_refund_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_undo_refund_match"(p_bank_transaction_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_undo_refund_match"(p_bank_transaction_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_undo_refund_match"(p_bank_transaction_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_update_refund"(p_refund_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_update_refund"(p_refund_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_update_refund"(p_refund_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c3_void_refund"(p_refund_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c3_void_refund"(p_refund_id uuid, p_reason text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c3_void_refund"(p_refund_id uuid, p_reason text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c45_create_supplier_credit"(p_expense_id uuid, p_credit_type text, p_total numeric, p_credit_date date, p_supplier_reference text, p_reason text, p_idempotency_key uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_create_supplier_credit"(p_expense_id uuid, p_credit_type text, p_total numeric, p_credit_date date, p_supplier_reference text, p_reason text, p_idempotency_key uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_create_supplier_credit"(p_expense_id uuid, p_credit_type text, p_total numeric, p_credit_date date, p_supplier_reference text, p_reason text, p_idempotency_key uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_create_supplier_refund"(p_supplier_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_create_supplier_refund"(p_supplier_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_create_supplier_refund"(p_supplier_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_create_supplier_refund_for_credit"(p_supplier_credit_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_create_supplier_refund_for_credit"(p_supplier_credit_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c45_create_supplier_refund_for_credit"(p_supplier_credit_id uuid, p_amount numeric, p_refund_date date, p_method text, p_reference text, p_notes text, p_idempotency_key uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c45_delete_draft_supplier_credit"(p_credit_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_delete_draft_supplier_credit"(p_credit_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_delete_draft_supplier_credit"(p_credit_id uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_expense_payment_guard"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_expense_payment_guard"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c45_general_ledger"(p_from date, p_to date, p_account_code text, p_source_type text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_general_ledger"(p_from date, p_to date, p_account_code text, p_source_type text) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_general_ledger"(p_from date, p_to date, p_account_code text, p_source_type text) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_match_supplier_refund"(p_bank_transaction_id uuid, p_refund_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_match_supplier_refund"(p_bank_transaction_id uuid, p_refund_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_match_supplier_refund"(p_bank_transaction_id uuid, p_refund_id uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_next_supplier_credit_number"(p_bid uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_next_supplier_credit_number"(p_bid uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c45_record_supplier_credit"(p_credit_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_record_supplier_credit"(p_credit_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_record_supplier_credit"(p_credit_id uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_record_supplier_refund"(p_refund_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_record_supplier_refund"(p_refund_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_record_supplier_refund"(p_refund_id uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_supplier_credit"(p_supplier_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_supplier_credit"(p_supplier_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_supplier_credit"(p_supplier_id uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_supplier_credit_available"(p_supplier_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_supplier_credit_available"(p_supplier_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_supplier_credit_available"(p_supplier_id uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_supplier_credit_available_for_credit"(p_supplier_credit_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_supplier_credit_available_for_credit"(p_supplier_credit_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170c45_supplier_credit_available_for_credit"(p_supplier_credit_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170c45_undo_supplier_refund_match"(p_bank_transaction_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_undo_supplier_refund_match"(p_bank_transaction_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_undo_supplier_refund_match"(p_bank_transaction_id uuid) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_update_supplier_credit"(p_credit_id uuid, p_total numeric, p_credit_date date, p_supplier_reference text, p_reason text, p_credit_type text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_update_supplier_credit"(p_credit_id uuid, p_total numeric, p_credit_date date, p_supplier_reference text, p_reason text, p_credit_type text) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_update_supplier_credit"(p_credit_id uuid, p_total numeric, p_credit_date date, p_supplier_reference text, p_reason text, p_credit_type text) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_void_expense"(p_expense_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_void_expense"(p_expense_id uuid, p_reason text) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_void_expense"(p_expense_id uuid, p_reason text) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_void_supplier_credit"(p_credit_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_void_supplier_credit"(p_credit_id uuid, p_reason text) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_void_supplier_credit"(p_credit_id uuid, p_reason text) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170c45_void_supplier_refund"(p_refund_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170c45_void_supplier_refund"(p_refund_id uuid, p_reason text) TO "service_role";
GRANT EXECUTE ON FUNCTION public."v6170c45_void_supplier_refund"(p_refund_id uuid, p_reason text) TO "authenticated";

REVOKE ALL ON FUNCTION public."v6170e_create_gst_adjustment"(p_date date, p_type text, p_direction text, p_gst_amount numeric, p_reason text, p_reference text, p_evidence text, p_source_type text, p_source_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170e_create_gst_adjustment"(p_date date, p_type text, p_direction text, p_gst_amount numeric, p_reason text, p_reference text, p_evidence text, p_source_type text, p_source_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170e_create_gst_adjustment"(p_date date, p_type text, p_direction text, p_gst_amount numeric, p_reason text, p_reference text, p_evidence text, p_source_type text, p_source_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170e_create_gst_correction"(p_return_id uuid, p_source_type text, p_source_id uuid, p_original numeric, p_corrected numeric, p_gst_difference numeric, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170e_create_gst_correction"(p_return_id uuid, p_source_type text, p_source_id uuid, p_original numeric, p_corrected numeric, p_gst_difference numeric, p_reason text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170e_create_gst_correction"(p_return_id uuid, p_source_type text, p_source_id uuid, p_original numeric, p_corrected numeric, p_gst_difference numeric, p_reason text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170e_gst_settings"(p_on date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170e_gst_settings"(p_on date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170e_gst_settings"(p_on date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170e_save_gst_return"(p_from date, p_to date, p_status text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170e_save_gst_return"(p_from date, p_to date, p_status text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170e_save_gst_return"(p_from date, p_to date, p_status text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170e_set_gst_settings"(p_registered boolean, p_gst_number text, p_basis text, p_frequency text, p_balance_month smallint, p_balance_day smallint, p_effective_from date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170e_set_gst_settings"(p_registered boolean, p_gst_number text, p_basis text, p_frequency text, p_balance_month smallint, p_balance_day smallint, p_effective_from date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170e_set_gst_settings"(p_registered boolean, p_gst_number text, p_basis text, p_frequency text, p_balance_month smallint, p_balance_day smallint, p_effective_from date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170e_year_end_readiness"(p_year_end date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170e_year_end_readiness"(p_year_end date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170e_year_end_readiness"(p_year_end date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_bas_calculate"(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_bas_calculate"(p_from date, p_to date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170f_bas_calculate"(p_from date, p_to date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_bas_settings"(p_on date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_bas_settings"(p_on date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170f_bas_settings"(p_on date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_business_country"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_business_country"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170f_business_country"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_expense_tax_config"(p_on date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_expense_tax_config"(p_on date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170f_expense_tax_config"(p_on date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_guard_au_expense_line_tax"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_guard_au_expense_line_tax"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_guard_au_expense_tax"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_guard_au_expense_tax"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_guard_au_invoice_tax"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_guard_au_invoice_tax"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_invoice_tax_config"(p_on date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_invoice_tax_config"(p_on date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170f_invoice_tax_config"(p_on date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_save_bas_return"(p_from date, p_to date, p_status text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_save_bas_return"(p_from date, p_to date, p_status text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170f_save_bas_return"(p_from date, p_to date, p_status text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6170f_set_bas_settings"(p_registered boolean, p_abn text, p_basis text, p_frequency text, p_balance_month smallint, p_balance_day smallint, p_effective_from date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6170f_set_bas_settings"(p_registered boolean, p_abn text, p_basis text, p_frequency text, p_balance_month smallint, p_balance_day smallint, p_effective_from date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6170f_set_bas_settings"(p_registered boolean, p_abn text, p_basis text, p_frequency text, p_balance_month smallint, p_balance_day smallint, p_effective_from date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6171_admin_helper_overview"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171_admin_helper_overview"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171_admin_helper_overview"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6171_admin_helper_plan_save"(p_plan_id uuid, p_eligible boolean, p_included boolean, p_allowance integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171_admin_helper_plan_save"(p_plan_id uuid, p_eligible boolean, p_included boolean, p_allowance integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171_admin_helper_plan_save"(p_plan_id uuid, p_eligible boolean, p_included boolean, p_allowance integer) TO "service_role";

REVOKE ALL ON FUNCTION public."v6171_onboarding_dismiss_getting_started"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171_onboarding_dismiss_getting_started"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171_onboarding_dismiss_getting_started"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6171_onboarding_get"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171_onboarding_get"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171_onboarding_get"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6171_onboarding_save"(p_step smallint, p_payload jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171_onboarding_save"(p_step smallint, p_payload jsonb) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171_onboarding_save"(p_step smallint, p_payload jsonb) TO "service_role";

REVOKE ALL ON FUNCTION public."v6171_seed_new_business_onboarding"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171_seed_new_business_onboarding"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_admin_import_overview"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_admin_import_overview"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_admin_import_overview"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_admin_import_save"(p_enabled boolean, p_max_upload_bytes integer, p_max_rows integer, p_ai_mapping_enabled boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_admin_import_save"(p_enabled boolean, p_max_upload_bytes integer, p_max_rows integer, p_ai_mapping_enabled boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_admin_import_save"(p_enabled boolean, p_max_upload_bytes integer, p_max_rows integer, p_ai_mapping_enabled boolean) TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_apply_mapping"(p_batch uuid, p_sheet uuid, p_record_type text, p_mapping jsonb, p_cutover date, p_mode text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_apply_mapping"(p_batch uuid, p_sheet uuid, p_record_type text, p_mapping jsonb, p_cutover date, p_mode text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_apply_mapping"(p_batch uuid, p_sheet uuid, p_record_type text, p_mapping jsonb, p_cutover date, p_mode text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_confirm_import"(p_batch uuid, p_duplicate_action text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_confirm_import"(p_batch uuid, p_duplicate_action text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_confirm_import"(p_batch uuid, p_duplicate_action text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_import_config"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_import_config"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_import_config"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_import_get"(p_batch uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_import_get"(p_batch uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_import_get"(p_batch uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_import_history"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_import_history"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_import_history"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_p6_admin_live_voice_entitlement"(p_business_id uuid, p_entitlement text, p_allowance integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_p6_admin_live_voice_entitlement"(p_business_id uuid, p_entitlement text, p_allowance integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_p6_admin_live_voice_entitlement"(p_business_id uuid, p_entitlement text, p_allowance integer) TO "service_role";

REVOKE ALL ON FUNCTION public."v6171b_p6_admin_live_voice_save"(p_enabled boolean, p_emergency boolean, p_model text, p_voice text, p_max_minutes integer, p_monthly_limit integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6171b_p6_admin_live_voice_save"(p_enabled boolean, p_emergency boolean, p_model text, p_voice text, p_max_minutes integer, p_monthly_limit integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6171b_p6_admin_live_voice_save"(p_enabled boolean, p_emergency boolean, p_model text, p_voice text, p_max_minutes integer, p_monthly_limit integer) TO "service_role";

REVOKE ALL ON FUNCTION public."v6173p2_validate_payroll_foundation_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6173p2_validate_payroll_foundation_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6173p4b_validate_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6173p4b_validate_refs"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6173p4b_validate_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6173p5b_validate_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6173p5b_validate_refs"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6173p5b_validate_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6173p6b_protect_finalised"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6173p6b_protect_finalised"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6173p6b_protect_finalised"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6173p6b_protect_finalised_component"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6173p6b_protect_finalised_component"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6173p6b_protect_finalised_component"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6173p6b_validate_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6173p6b_validate_refs"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6173p6b_validate_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6174_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_annual_price numeric, p_annual_saving_message text, p_invoice_limit integer, p_included_modules text[], p_stripe_monthly_price_id text, p_stripe_annual_price_id text, p_is_public boolean, p_sort_order integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6174_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_annual_price numeric, p_annual_saving_message text, p_invoice_limit integer, p_included_modules text[], p_stripe_monthly_price_id text, p_stripe_annual_price_id text, p_is_public boolean, p_sort_order integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6174_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_annual_price numeric, p_annual_saving_message text, p_invoice_limit integer, p_included_modules text[], p_stripe_monthly_price_id text, p_stripe_annual_price_id text, p_is_public boolean, p_sort_order integer) TO "service_role";

REVOKE ALL ON FUNCTION public."v6175_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_annual_price numeric, p_annual_saving_message text, p_invoice_limit integer, p_employee_limit integer, p_included_modules text[], p_stripe_monthly_price_id text, p_stripe_annual_price_id text, p_is_public boolean, p_sort_order integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6175_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_annual_price numeric, p_annual_saving_message text, p_invoice_limit integer, p_employee_limit integer, p_included_modules text[], p_stripe_monthly_price_id text, p_stripe_annual_price_id text, p_is_public boolean, p_sort_order integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6175_admin_upsert_plan"(p_id uuid, p_slug text, p_name text, p_description text, p_monthly_price numeric, p_annual_price numeric, p_annual_saving_message text, p_invoice_limit integer, p_employee_limit integer, p_included_modules text[], p_stripe_monthly_price_id text, p_stripe_annual_price_id text, p_is_public boolean, p_sort_order integer) TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_dashboard_summary"(p_as_of_date date, p_timezone text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_dashboard_summary"(p_as_of_date date, p_timezone text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_dashboard_summary"(p_as_of_date date, p_timezone text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_is_iana_timezone"(p_timezone text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_is_iana_timezone"(p_timezone text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_is_iana_timezone"(p_timezone text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_save_schedule_with_assignments"(p_schedule_id uuid, p_schedule jsonb, p_employee_ids uuid[]) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_save_schedule_with_assignments"(p_schedule_id uuid, p_schedule jsonb, p_employee_ids uuid[]) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_save_schedule_with_assignments"(p_schedule_id uuid, p_schedule jsonb, p_employee_ids uuid[]) TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_schedule_role_allowed"(p_business_id uuid, p_write boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_schedule_role_allowed"(p_business_id uuid, p_write boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_schedule_role_allowed"(p_business_id uuid, p_write boolean) TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_smallint_array_is_unique"(p_values smallint[]) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_smallint_array_is_unique"(p_values smallint[]) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_smallint_array_is_unique"(p_values smallint[]) TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_unscheduled_schedule_count"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_unscheduled_schedule_count"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_unscheduled_schedule_count"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_validate_google_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_validate_google_refs"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_validate_google_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_validate_schedule_assignment_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_validate_schedule_assignment_refs"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_validate_schedule_assignment_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6179_validate_schedule_refs"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6179_validate_schedule_refs"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6179_validate_schedule_refs"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6187_guard_subscription_write"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6187_guard_subscription_write"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6188_register_signup_referral"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6188_register_signup_referral"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6190_net_purchase_rows"(p_rows jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6190_net_purchase_rows"(p_rows jsonb) TO "service_role";

REVOKE ALL ON FUNCTION public."v6190_save_purchase_scan"(p_business_id uuid, p_expense_id uuid, p_attachment_ids uuid[], p_items jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6190_save_purchase_scan"(p_business_id uuid, p_expense_id uuid, p_attachment_ids uuid[], p_items jsonb) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6190_save_purchase_scan"(p_business_id uuid, p_expense_id uuid, p_attachment_ids uuid[], p_items jsonb) TO "service_role";

REVOKE ALL ON FUNCTION public."v6192_create_posted_journal"(p_business_id uuid, p_journal_date date, p_journal_type text, p_source_type text, p_source_id uuid, p_source_reference text, p_description text, p_lines jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6192_create_posted_journal"(p_business_id uuid, p_journal_date date, p_journal_type text, p_source_type text, p_source_id uuid, p_source_reference text, p_description text, p_lines jsonb) TO "service_role";

REVOKE ALL ON FUNCTION public."v6201_import_bank_csv"(p_business_id uuid, p_bank_account_id uuid, p_filename text, p_mapping jsonb, p_rows jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6201_import_bank_csv"(p_business_id uuid, p_bank_account_id uuid, p_filename text, p_mapping jsonb, p_rows jsonb) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6201_import_bank_csv"(p_business_id uuid, p_bank_account_id uuid, p_filename text, p_mapping jsonb, p_rows jsonb) TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_create_expense_draft"(p_currency text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_create_expense_draft"(p_currency text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_create_expense_draft"(p_currency text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_create_expense_from_bank"(p_bank_transaction_id uuid, p_category_id uuid, p_description text, p_gst_treatment text, p_gst_rate numeric, p_ex_gst numeric, p_gst_amount numeric, p_total numeric, p_create_anyway boolean, p_request_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_create_expense_from_bank"(p_bank_transaction_id uuid, p_category_id uuid, p_description text, p_gst_treatment text, p_gst_rate numeric, p_ex_gst numeric, p_gst_amount numeric, p_total numeric, p_create_anyway boolean, p_request_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_create_expense_from_bank"(p_bank_transaction_id uuid, p_category_id uuid, p_description text, p_gst_treatment text, p_gst_rate numeric, p_ex_gst numeric, p_gst_amount numeric, p_total numeric, p_create_anyway boolean, p_request_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_edit_recorded_expense"(p_expense_id uuid, p_changes jsonb, p_lines jsonb, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_edit_recorded_expense"(p_expense_id uuid, p_changes jsonb, p_lines jsonb, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_edit_recorded_expense"(p_expense_id uuid, p_changes jsonb, p_lines jsonb, p_expected_updated_at timestamp with time zone, p_request_id uuid, p_reason text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_expense_duplicate_candidates"(p_supplier_id uuid, p_supplier_name text, p_reference text, p_invoice_date date, p_total numeric, p_content_sha256 text, p_exclude_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_expense_duplicate_candidates"(p_supplier_id uuid, p_supplier_name text, p_reference text, p_invoice_date date, p_total numeric, p_content_sha256 text, p_exclude_expense_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_expense_duplicate_candidates"(p_supplier_id uuid, p_supplier_name text, p_reference text, p_invoice_date date, p_total numeric, p_content_sha256 text, p_exclude_expense_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_expense_edit_preflight"(p_expense_id uuid, p_new_invoice_date date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_expense_edit_preflight"(p_expense_id uuid, p_new_invoice_date date) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_expense_edit_preflight"(p_expense_id uuid, p_new_invoice_date date) TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_group_reconcile"(p_bank_transaction_ids uuid[], p_allocations jsonb, p_request_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_group_reconcile"(p_bank_transaction_ids uuid[], p_allocations jsonb, p_request_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_group_reconcile"(p_bank_transaction_ids uuid[], p_allocations jsonb, p_request_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_reconciliation_statuses"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_reconciliation_statuses"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_reconciliation_statuses"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_record_duplicate_decision"(p_candidate_expense_id uuid, p_existing_expense_id uuid, p_score integer, p_reasons jsonb, p_decision text, p_decision_reason text, p_source text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_record_duplicate_decision"(p_candidate_expense_id uuid, p_existing_expense_id uuid, p_score integer, p_reasons jsonb, p_decision text, p_decision_reason text, p_source text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_record_duplicate_decision"(p_candidate_expense_id uuid, p_existing_expense_id uuid, p_score integer, p_reasons jsonb, p_decision text, p_decision_reason text, p_source text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_set_expense_payment_requirement"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_set_expense_payment_requirement"() TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_set_expense_payment_requirement"() TO "service_role";

REVOKE ALL ON FUNCTION public."v6203_undo_reconciliation_group"(p_group_id uuid, p_reason text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6203_undo_reconciliation_group"(p_group_id uuid, p_reason text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6203_undo_reconciliation_group"(p_group_id uuid, p_reason text) TO "service_role";

REVOKE ALL ON FUNCTION public."v6204_expense_duplicate_candidates"(p_supplier_id uuid, p_supplier_name text, p_reference text, p_invoice_date date, p_total numeric, p_content_sha256 text, p_exclude_expense_id uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6204_expense_duplicate_candidates"(p_supplier_id uuid, p_supplier_name text, p_reference text, p_invoice_date date, p_total numeric, p_content_sha256 text, p_exclude_expense_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6204_expense_duplicate_candidates"(p_supplier_id uuid, p_supplier_name text, p_reference text, p_invoice_date date, p_total numeric, p_content_sha256 text, p_exclude_expense_id uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6215_import_get"(p_batch uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6215_import_get"(p_batch uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6215_import_get"(p_batch uuid) TO "service_role";

REVOKE ALL ON FUNCTION public."v6215_set_record_action"(p_record uuid, p_action text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."v6215_set_record_action"(p_record uuid, p_action text) TO "authenticated";
GRANT EXECUTE ON FUNCTION public."v6215_set_record_action"(p_record uuid, p_action text) TO "service_role";
