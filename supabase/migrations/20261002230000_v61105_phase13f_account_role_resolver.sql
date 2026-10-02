-- Frindly v61.105 Phase 13F
-- Applied live. Compatibility-only accounting account resolver.
-- No accounting_accounts rows or historical journals are renumbered, merged, deleted or rewritten.
-- Canonical role resolver supports both legacy (1000/1500/2100/6200) and newer (090/150/260/315) Frindly charts.
-- Live migration also updates v6192_post_operational_ledger, se_record_asset_event and
-- se_create_opening_asset_v61105 to use this resolver for compatible account roles.
create or replace function public.v61105_account_role_id(p_business_id uuid,p_role text)
returns uuid language plpgsql stable security definer set search_path='' as $$
declare v_role text:=lower(trim(coalesce(p_role,'')));v_id uuid;
begin
 if auth.uid() is null or public.current_business_id() is distinct from p_business_id then raise exception 'Business access denied';end if;
 if not public.v6169a_accountant_centre_access(p_business_id,false) then raise exception 'Accounting access denied';end if;
 select a.id into v_id from public.accounting_accounts a where a.business_id=p_business_id and coalesce(a.archived,false)=false and case v_role
 when 'bank' then a.system_key in('bank_main','bank') or a.account_code in('090','1000')
 when 'accounts_receivable' then a.system_key='accounts_receivable' or a.account_code in('120','1100')
 when 'accounts_payable' then a.system_key='accounts_payable' or a.account_code='2000'
 when 'gst_output' then a.system_key in('gst_collected','gst_payable') or a.account_code in('260','2100')
 when 'gst_input' then a.system_key in('gst_paid','gst_receivable') or a.account_code in('261','1200')
 when 'fixed_equipment' then a.system_key in('fixed_assets_equipment','fixed_assets') or a.account_code in('150','1500')
 when 'accum_depreciation' then a.system_key in('accum_depn_equipment','accumulated_depreciation') or a.account_code in('155','1590')
 when 'depreciation_expense' then a.system_key in('depreciation_expense','depreciation') or a.account_code in('315','6200')
 when 'owner_drawings' then a.system_key='owner_drawings' or a.account_code in('800','3100')
 when 'owner_funds' then a.system_key in('owner_funds','opening_balance_equity') or a.account_code in('3000','859')
 when 'sales' then a.system_key='sales' or a.account_code in('200','4000')
 when 'general_expense' then a.system_key in('general_expenses','business_expenses') or a.account_code in('429','6000')
 when 'payroll_liability' then a.system_key='payroll_liability' or a.account_code='265' else false end
 order by case when v_role='bank' and a.system_key='bank_main' then 0 when v_role='bank' and a.system_key='bank' then 1 when v_role='gst_output' and a.system_key='gst_collected' then 0 when v_role='gst_output' and a.system_key='gst_payable' then 1 when v_role='gst_input' and a.system_key='gst_paid' then 0 when v_role='gst_input' and a.system_key='gst_receivable' then 1 when v_role='fixed_equipment' and a.system_key='fixed_assets_equipment' then 0 when v_role='fixed_equipment' and a.system_key='fixed_assets' then 1 when v_role='accum_depreciation' and a.system_key='accum_depn_equipment' then 0 when v_role='accum_depreciation' and a.system_key='accumulated_depreciation' then 1 when v_role='depreciation_expense' and a.system_key='depreciation_expense' then 0 when v_role='depreciation_expense' and a.system_key='depreciation' then 1 when v_role='general_expense' and a.system_key='general_expenses' then 0 when v_role='general_expense' and a.system_key='business_expenses' then 1 else 2 end,a.account_code limit 1;
 return v_id;
end $$;
revoke execute on function public.v61105_account_role_id(uuid,text) from public,anon;
grant execute on function public.v61105_account_role_id(uuid,text) to authenticated;
