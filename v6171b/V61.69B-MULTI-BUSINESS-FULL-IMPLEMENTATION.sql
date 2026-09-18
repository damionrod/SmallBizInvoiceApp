-- Finlo V61.69B — Gates C–F multi-business implementation
-- Exact baseline: approved V61.69A. Additive only; preserves V61.69A active-business hardening.

begin;

-- One Stripe customer/subscription identifier must never belong to two Finlo businesses.
create unique index if not exists v6169b_subscriptions_stripe_customer_unique
  on public.subscriptions (stripe_customer_id)
  where nullif(btrim(stripe_customer_id),'') is not null;
create unique index if not exists v6169b_subscriptions_stripe_subscription_unique
  on public.subscriptions (stripe_subscription_id)
  where nullif(btrim(stripe_subscription_id),'') is not null;

-- Authenticated Owner-only, transactional tenant provisioning. No operational data is copied.
create or replace function public.v6169b_add_business(p_name text, p_country text default 'NZ')
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user uuid:=auth.uid();
  v_current uuid;
  v_role text;
  v_business uuid;
  v_trial_plan uuid;
  v_modules text[];
  v_trial_end timestamptz:=now()+interval '14 days';
  v_name text:=btrim(coalesce(p_name,''));
  v_country text:=upper(btrim(coalesce(p_country,'NZ')));
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if v_name='' or length(v_name)>160 then raise exception 'Enter a valid business name'; end if;
  if v_country !~ '^[A-Z]{2}$' then raise exception 'Country must be a 2-letter code'; end if;

  v_current:=public.current_business_id();
  if v_current is null then raise exception 'An active authorised business is required'; end if;
  select bm.role into v_role from public.business_memberships bm
   where bm.user_id=v_user and bm.business_id=v_current and bm.status='active';
  if v_role<>'owner' and not public.is_super_admin() then
    raise exception 'Only an Owner can add another business';
  end if;

  select p.id,p.included_modules into v_trial_plan,v_modules
    from public.plans p where p.slug='trial' limit 1;
  if v_trial_plan is null then raise exception 'Trial plan is not configured'; end if;

  insert into public.businesses(name,settings)
  values(v_name,jsonb_build_object('company',v_name,'trading',v_name,'country',v_country,'currency',case v_country when 'NZ' then 'NZD' when 'AU' then 'AUD' when 'GB' then 'GBP' when 'US' then 'USD' else 'NZD' end,'invoicePrefix','INV','_settingsBusinessId','pending'))
  returning id into v_business;

  -- Replace the temporary marker with the actual tenant ID before any client can enter it.
  update public.businesses
     set settings=jsonb_set(settings,'{_settingsBusinessId}',to_jsonb(v_business::text),true)
   where id=v_business;

  insert into public.business_memberships(business_id,user_id,role,status,joined_at)
  values(v_business,v_user,'owner','active',now());

  insert into public.subscriptions(business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end)
  values(v_business,v_trial_plan,'trialing',v_trial_end,now(),v_trial_end);

  insert into public.business_modules(business_id,module_id,status,trial_ends_at)
  select v_business,m.id,'trialing',v_trial_end
    from public.modules m
   where m.is_active=true and m.slug=any(coalesce(v_modules,array[]::text[]));

  -- These defaults previously depended on profile insertion. Additional businesses share one profile,
  -- so provision the same business-scoped defaults explicitly inside this transaction.
  insert into public.financial_settings(business_id) values(v_business) on conflict(business_id) do nothing;
  insert into public.financial_category_mappings(business_id,source_type,source_key,display_name,classification)
  values
    (v_business,'payroll_type','wage_expense','Payroll Wages','direct_cost'),
    (v_business,'payroll_type','employer_contribution_expense','Employer Contributions','indirect_cost'),
    (v_business,'payroll_type','reimbursement_expense','Payroll Reimbursements','direct_cost'),
    (v_business,'payroll_type','paye_payable','PAYE Payable','liability'),
    (v_business,'payroll_type','kiwisaver_payable','KiwiSaver Payable','liability')
  on conflict do nothing;

  insert into public.expense_categories(business_id,name,group_name,sort_order,created_by,updated_by) values
    (v_business,'Materials & Supplies','Direct Costs',10,null,null),(v_business,'Subcontractors','Direct Costs',20,null,null),
    (v_business,'Labour','Direct Costs',30,null,null),(v_business,'Fuel','Direct Costs',40,null,null),
    (v_business,'Equipment Hire','Direct Costs',50,null,null),(v_business,'Job Expenses','Direct Costs',60,null,null),
    (v_business,'Advertising & Marketing','Operating Expenses',110,null,null),(v_business,'Vehicle Expenses','Operating Expenses',120,null,null),
    (v_business,'Insurance','Operating Expenses',130,null,null),(v_business,'Rent','Operating Expenses',140,null,null),
    (v_business,'Utilities','Operating Expenses',150,null,null),(v_business,'Phone & Internet','Operating Expenses',160,null,null),
    (v_business,'Software & Subscriptions','Operating Expenses',170,null,null),(v_business,'Bank Fees','Operating Expenses',180,null,null),
    (v_business,'Accounting & Legal','Operating Expenses',190,null,null),(v_business,'Office Expenses','Operating Expenses',200,null,null),
    (v_business,'Repairs & Maintenance','Operating Expenses',210,null,null),(v_business,'Training','Operating Expenses',220,null,null),
    (v_business,'Travel','Operating Expenses',230,null,null),(v_business,'Other','Operating Expenses',999,null,null)
  on conflict(business_id,name) do nothing;

  -- Payroll settings are clean tenant defaults. Detailed document/leave/pay-item defaults are seeded on first Payroll use by the existing Payroll path, after this business becomes active.
  insert into public.payroll_settings(business_id,country_code,currency)
  values(v_business,v_country,case v_country when 'NZ' then 'NZD' when 'AU' then 'AUD' when 'GB' then 'GBP' when 'US' then 'USD' else 'NZD' end)
  on conflict(business_id) do nothing;

  -- Enter the new tenant only after every required bootstrap row has succeeded.
  update public.profiles set active_business_id=v_business,updated_at=now() where id=v_user;
  return v_business;
end;
$$;
revoke all on function public.v6169b_add_business(text,text) from public,anon;
grant execute on function public.v6169b_add_business(text,text) to authenticated;

notify pgrst,'reload schema';
commit;
