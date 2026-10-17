-- Isolated Frindly Market only. Fixture rows are rolled back by a subtransaction.
-- No email, payment, bank-provider or other network operation is called.
DO $market_test$
DECLARE
  u_a uuid; u_b uuid; b_a uuid:=gen_random_uuid(); b_b uuid:=gen_random_uuid();
  p uuid; c_a uuid:=gen_random_uuid(); c_b uuid:=gen_random_uuid();
  a_debit uuid:=gen_random_uuid(); a_credit uuid:=gen_random_uuid(); b_account uuid:=gen_random_uuid();
  period_id uuid:=gen_random_uuid(); j uuid; n bigint; denied boolean;
  lines jsonb; settings_result jsonb; settings_revision timestamptz; bank_result jsonb; bank_a uuid:=gen_random_uuid(); bank_b uuid:=gen_random_uuid(); bank_usd uuid:=gen_random_uuid(); bank_revision timestamptz; tax_result jsonb; tax_values jsonb; financial_revision timestamptz; history_before bigint;
BEGIN
  IF public.frindly_market_environment_status()->>'project_ref' <> 'smvvevrtjqkflyqkyape' THEN
    RAISE EXCEPTION 'Not the isolated Market project';
  END IF;
  SELECT id INTO u_a FROM auth.users u WHERE NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=u.id) ORDER BY id LIMIT 1;
  SELECT id INTO u_b FROM auth.users u WHERE u.id<>u_a AND NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=u.id) ORDER BY id LIMIT 1;
  SELECT id INTO p FROM public.plans ORDER BY cardinality(included_modules) DESC NULLS LAST LIMIT 1;
  IF u_a IS NULL OR u_b IS NULL OR p IS NULL THEN RAISE EXCEPTION 'Rollback-test prerequisites missing'; END IF;
  BEGIN
    INSERT INTO public.businesses(id,name) VALUES(b_a,'Market rollback fixture A'),(b_b,'Market rollback fixture B');
    INSERT INTO public.profiles(id,business_id,active_business_id,full_name,role,is_super_admin)
      VALUES(u_a,b_a,b_a,'Market fixture A','owner',false),(u_b,b_b,b_b,'Market fixture B','owner',false);
    INSERT INTO public.business_memberships(business_id,user_id,role,status)
      VALUES(b_a,u_a,'owner','active'),(b_b,u_b,'owner','active');
    INSERT INTO public.subscriptions(business_id,plan_id,status,current_period_end,trial_ends_at)
      VALUES(b_a,p,'trialing',now()+interval '30 days',now()+interval '30 days'),
            (b_b,p,'trialing',now()+interval '30 days',now()+interval '30 days');
    INSERT INTO public.customers(id,business_id,customer_number,name)
      VALUES(c_a,b_a,'MARKET-A-'||left(c_a::text,8),'Market customer A'),
            (c_b,b_b,'MARKET-B-'||left(c_b::text,8),'Market customer B');
    INSERT INTO public.accounting_accounts(id,business_id,account_code,account_name,account_type,normal_balance)
      VALUES(a_debit,b_a,'991','Market test asset','asset','debit'),
            (a_credit,b_a,'992','Market test equity','equity','credit'),
            (b_account,b_b,'991','Market other-business asset','asset','debit');
    INSERT INTO public.accounting_periods(id,business_id,period_start,period_end,financial_year,status)
      VALUES(period_id,b_a,'2026-04-01','2027-03-31',2027,'open');
    PERFORM set_config('request.jwt.claim.sub',u_a::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u_a::text,'role','authenticated')::text,true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user<>'authenticated' OR public.current_business_id()<>b_a THEN RAISE EXCEPTION 'Owner A context incorrect'; END IF;
    SELECT updated_at INTO settings_revision FROM public.businesses WHERE id=b_a;
    settings_result:=public.v6221_save_business_settings(b_a,settings_revision,jsonb_build_object('company','Market settings fixture','address','','phone','','_settingsBusinessId',b_a));
    IF settings_result->>'name'<>'Market settings fixture' OR settings_result->>'address'<>'' THEN RAISE EXCEPTION 'Settings projection or blank clearing failed'; END IF;
    denied:=false;
    BEGIN PERFORM public.v6221_save_business_settings(b_a,settings_revision,'{"company":"Stale overwrite"}'::jsonb);
    EXCEPTION WHEN serialization_failure THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Stale settings overwrite accepted'; END IF;
    denied:=false;
    BEGIN PERFORM public.v6221_save_business_settings(b_b,settings_revision,'{}'::jsonb);
    EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Cross-business settings write accepted'; END IF;
    denied:=false;
    BEGIN PERFORM public.v6221_save_business_settings(b_a,(settings_result->>'updated_at')::timestamptz,'{"is_super_admin":true}'::jsonb);
    EXCEPTION WHEN invalid_parameter_value THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Unknown settings key accepted'; END IF;
    EXECUTE 'RESET ROLE';
    SELECT count(*) INTO n FROM public.financial_audit_log WHERE business_id=b_a AND action='settings_updated' AND NOT(after_data ? 'settings') AND after_data ? 'changed_fields';
    IF n<>1 THEN RAISE EXCEPTION 'Redacted settings audit missing'; END IF;
    UPDATE public.business_memberships SET role='viewer' WHERE business_id=b_a AND user_id=u_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    denied:=false;
    BEGIN PERFORM public.v6221_save_business_settings(b_a,(settings_result->>'updated_at')::timestamptz,'{}'::jsonb);
    EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Viewer settings write accepted'; END IF;
    EXECUTE 'RESET ROLE';
    UPDATE public.business_memberships SET role='owner' WHERE business_id=b_a AND user_id=u_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    bank_result:=public.v6221_save_bank_account(b_a,bank_a,null,'save','{"name":"Fixture account A","currency":"NZD","account_number":"00-TEST-A"}');
    bank_revision:=(bank_result->'account'->>'updated_at')::timestamptz;
    IF NOT (bank_result->'account'->>'is_default')::boolean THEN RAISE EXCEPTION 'First bank account not default'; END IF;
    bank_result:=public.v6221_save_bank_account(b_a,bank_a,null,'save','{"name":"Fixture account A","currency":"NZD","account_number":"00-TEST-A"}');
    IF (bank_result->'account'->>'updated_at')::timestamptz IS DISTINCT FROM bank_revision THEN RAISE EXCEPTION 'Retry was not idempotent'; END IF;
    bank_result:=public.v6221_save_bank_account(b_a,bank_b,null,'save','{"name":"Fixture account B","currency":"NZD","account_number":"00-TEST-B"}');
    bank_result:=public.v6221_save_bank_account(b_a,bank_b,(bank_result->'account'->>'updated_at')::timestamptz,'default');
    SELECT count(*) INTO n FROM public.bank_accounts WHERE business_id=b_a AND is_default;
    IF n<>1 OR NOT (bank_result->'account'->>'is_default')::boolean THEN RAISE EXCEPTION 'Default switching failed'; END IF;
    bank_result:=public.v6221_save_bank_account(b_a,bank_usd,null,'save','{"name":"USD fixture","currency":"USD"}');
    denied:=false;
    BEGIN PERFORM public.v6221_save_bank_account(b_a,bank_usd,(bank_result->'account'->>'updated_at')::timestamptz,'default');
    EXCEPTION WHEN others THEN IF SQLERRM ILIKE '%business currency%' THEN denied:=true; ELSE RAISE; END IF; END;
    IF NOT denied THEN RAISE EXCEPTION 'Wrong currency default accepted'; END IF;
    SELECT count(*) INTO n FROM public.bank_accounts WHERE business_id=b_a AND id=bank_b AND is_default;
    IF n<>1 THEN RAISE EXCEPTION 'Failed default change cleared the old default'; END IF;
    denied:=false;
    BEGIN PERFORM public.v6221_save_bank_account(b_b,bank_a,bank_revision,'archive');
    EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Cross-business bank action accepted'; END IF;
    denied:=false;
    BEGIN PERFORM public.v6221_save_bank_account(b_a,bank_a,bank_revision,'archive');
    EXCEPTION WHEN serialization_failure THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Stale bank update accepted'; END IF;
    SELECT updated_at INTO bank_revision FROM public.bank_accounts WHERE id=bank_a;
    bank_result:=public.v6221_save_bank_account(b_a,bank_a,bank_revision,'archive');
    denied:=false;
    BEGIN PERFORM public.v6221_save_bank_account(b_a,bank_a,(bank_result->'account'->>'updated_at')::timestamptz,'default');
    EXCEPTION WHEN others THEN IF SQLERRM ILIKE '%archived%' THEN denied:=true; ELSE RAISE; END IF; END;
    IF NOT denied THEN RAISE EXCEPTION 'Archived account restored'; END IF;
    bank_result:=public.v6221_payment_accounts();
    IF jsonb_array_length(bank_result->'accounts')<>1 OR bank_result->'accounts'->0->>'account'<>'00-TEST-B' THEN RAISE EXCEPTION 'Payment projection includes archived or other-currency account'; END IF;
    SELECT updated_at INTO settings_revision FROM public.businesses WHERE id=b_a;
    settings_result:=public.v6221_save_business_settings(b_a,settings_revision,'{"bankAccounts":[{"account":"FORBIDDEN PROJECTION"}]}'::jsonb);
    IF settings_result->'settings'->'bankAccounts' IS DISTINCT FROM bank_result->'accounts' THEN RAISE EXCEPTION 'Generic settings replaced canonical bank accounts'; END IF;
    SELECT updated_at INTO settings_revision FROM public.businesses WHERE id=b_a;
    SELECT updated_at INTO financial_revision FROM public.financial_settings WHERE business_id=b_a;
    tax_values:='{"financial_year_start_month":4,"financial_year_start_day":1,"default_report_period":"fytd","business_entity_type":"company","estimated_tax_rate":28,"provisional_tax_enabled":true,"gst_registered":false,"gst_number":"49091850","gst_accounting_basis":"payments","gst_filing_frequency":"two_monthly","balance_date_month":3,"balance_date_day":31,"effective_from":"2026-04-01"}'::jsonb;
    tax_result:=public.v6221_save_tax_settings(b_a,settings_revision,financial_revision,tax_values);
    IF (tax_result->'business'->'settings'->>'gstRate')::numeric<>0 OR (tax_result->'financial_settings'->>'gst_registered')::boolean THEN RAISE EXCEPTION 'NZ GST current projection incorrect'; END IF;
    settings_revision:=(tax_result->'business'->>'updated_at')::timestamptz;financial_revision:=(tax_result->'financial_settings'->>'updated_at')::timestamptz;
    SELECT count(*) INTO history_before FROM public.gst_settings_history WHERE business_id=b_a;
    denied:=false;
    BEGIN PERFORM public.v6221_save_tax_settings(b_a,settings_revision,financial_revision,tax_values||'{"gst_registered":true,"effective_from":"2026-05-01"}',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'classification','asset')));
    EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Invalid mapping accepted'; END IF;
    SELECT count(*) INTO n FROM public.gst_settings_history WHERE business_id=b_a;
    IF n<>history_before OR (SELECT updated_at FROM public.businesses WHERE id=b_a) IS DISTINCT FROM settings_revision OR (SELECT updated_at FROM public.financial_settings WHERE business_id=b_a) IS DISTINCT FROM financial_revision THEN RAISE EXCEPTION 'Failed tax transaction left partial writes'; END IF;
    tax_result:=public.v6221_save_tax_settings(b_a,settings_revision,financial_revision,tax_values||'{"gst_registered":true,"effective_from":"2030-04-01"}');
    IF (tax_result->'current_tax_status'->>'gst_registered')::boolean OR (tax_result->'business'->'settings'->>'gstRate')::numeric<>0 OR (tax_result->'financial_settings'->>'gst_registered')::boolean THEN RAISE EXCEPTION 'Future GST change became active early'; END IF;
    denied:=false;
    BEGIN PERFORM public.v6221_save_tax_settings(b_a,settings_revision,financial_revision,tax_values);
    EXCEPTION WHEN serialization_failure THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Stale financial settings accepted'; END IF;
    EXECUTE 'RESET ROLE';
    UPDATE public.business_memberships SET role='viewer' WHERE business_id=b_a AND user_id=u_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    denied:=false;
    BEGIN PERFORM public.v6221_save_bank_account(b_a,gen_random_uuid(),null,'save','{"name":"Denied viewer account","currency":"NZD"}');
    EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Viewer bank write accepted'; END IF;
    denied:=false;
    BEGIN PERFORM public.v6221_save_tax_settings(b_a,null,null,tax_values);
    EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Viewer tax write accepted'; END IF;
    EXECUTE 'RESET ROLE';
    UPDATE public.business_memberships SET role='accountant' WHERE business_id=b_a AND user_id=u_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT updated_at INTO settings_revision FROM public.businesses WHERE id=b_a;
    SELECT updated_at INTO financial_revision FROM public.financial_settings WHERE business_id=b_a;
    tax_result:=public.v6221_save_tax_settings(b_a,settings_revision,financial_revision,tax_values);
    IF tax_result->'business'->>'id'<>b_a::text THEN RAISE EXCEPTION 'Accountant tax save failed'; END IF;
    EXECUTE 'RESET ROLE';
    UPDATE public.subscriptions SET trial_ends_at=now()-interval '1 day' WHERE business_id=b_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    denied:=false;
    BEGIN PERFORM public.v6221_save_tax_settings(b_a,null,null,tax_values);
    EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Read-only tax write accepted'; END IF;
    denied:=false;
    BEGIN PERFORM public.v6221_save_bank_account(b_a,gen_random_uuid(),null,'save','{"name":"Denied expired account","currency":"NZD"}');
    EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
    IF NOT denied THEN RAISE EXCEPTION 'Read-only bank write accepted'; END IF;
    denied:=false;
    BEGIN PERFORM public.v61117_post_manual_journal('2026-10-17','Read-only journal must not post',jsonb_build_array(jsonb_build_object('account_id',a_debit,'debit',1,'credit',0),jsonb_build_object('account_id',a_credit,'debit',0,'credit',1)));
    EXCEPTION WHEN others THEN IF SQLERRM ILIKE '%write access%' OR SQLERRM ILIKE '%read-only%' THEN denied:=true; ELSE RAISE; END IF; END;
    IF NOT denied THEN RAISE EXCEPTION 'Read-only manual journal write accepted'; END IF;

    EXECUTE 'RESET ROLE';
    UPDATE public.subscriptions SET trial_ends_at=now()+interval '30 days' WHERE business_id=b_a;
    UPDATE public.business_memberships SET role='owner' WHERE business_id=b_a AND user_id=u_a;
    IF has_function_privilege('anon','public.v6221_save_tax_settings(uuid,timestamp with time zone,timestamp with time zone,jsonb,jsonb)','EXECUTE') OR has_function_privilege('anon','public.v6221_save_bank_account(uuid,uuid,timestamp with time zone,text,jsonb)','EXECUTE') OR has_function_privilege('anon','public.v6221_save_business_settings(uuid,timestamp with time zone,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous settings execution allowed'; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM public.customers WHERE id=c_a;
    IF n<>1 THEN RAISE EXCEPTION 'Owner cannot read own customer'; END IF;
    SELECT count(*) INTO n FROM public.customers WHERE business_id=b_b;
    IF n<>0 THEN RAISE EXCEPTION 'Cross-business customer read allowed'; END IF;
    UPDATE public.customers SET address='Permitted fixture update' WHERE id=c_a;
    GET DIAGNOSTICS n=ROW_COUNT;
    IF n<>1 THEN RAISE EXCEPTION 'Owner cannot update own customer'; END IF;
    UPDATE public.customers SET address='Forbidden fixture update' WHERE id=c_b;
    GET DIAGNOSTICS n=ROW_COUNT;
    IF n<>0 THEN RAISE EXCEPTION 'Cross-business customer update allowed'; END IF;
    denied:=false;
    BEGIN
      INSERT INTO public.customers(business_id,customer_number,name) VALUES(b_b,'MARKET-CROSS-'||left(c_a::text,8),'Forbidden fixture customer');
    EXCEPTION WHEN insufficient_privilege THEN denied:=true;
    END;
    IF NOT denied THEN RAISE EXCEPTION 'Cross-business customer insert allowed'; END IF;
    lines:=jsonb_build_array(jsonb_build_object('account_id',a_debit,'debit',1,'credit',0),
                             jsonb_build_object('account_id',a_credit,'debit',0,'credit',1));
    j:=public.v61117_post_manual_journal('2026-10-17','Market rollback balanced journal',lines);
    SELECT count(*) INTO n FROM public.accounting_journals WHERE id=j AND status='posted';
    IF n<>1 THEN RAISE EXCEPTION 'Balanced journal was not posted'; END IF;
    SELECT count(*) INTO n FROM public.accounting_journal_lines WHERE journal_id=j;
    IF n<>2 THEN RAISE EXCEPTION 'Balanced journal line count incorrect'; END IF;
    denied:=false;
    BEGIN
      PERFORM public.v61117_post_manual_journal('2026-10-17','Market rollback unbalanced journal',
        jsonb_build_array(jsonb_build_object('account_id',a_debit,'debit',1,'credit',0),
                          jsonb_build_object('account_id',a_credit,'debit',0,'credit',0.99)));
    EXCEPTION WHEN others THEN
      IF SQLERRM ILIKE '%balance%' THEN denied:=true; ELSE RAISE; END IF;
    END;
    IF NOT denied THEN RAISE EXCEPTION 'Unbalanced journal accepted'; END IF;
    denied:=false;
    BEGIN
      PERFORM public.v61117_post_manual_journal('2026-10-17','Market rollback wrong-business journal',
        jsonb_build_array(jsonb_build_object('account_id',b_account,'debit',1,'credit',0),
                          jsonb_build_object('account_id',a_credit,'debit',0,'credit',1)));
    EXCEPTION WHEN others THEN
      IF SQLERRM ILIKE '%does not belong to this business%' THEN denied:=true; ELSE RAISE; END IF;
    END;
    IF NOT denied THEN RAISE EXCEPTION 'Wrong-business journal account accepted'; END IF;
    UPDATE public.accounting_periods SET status='closed',locked_at=now(),locked_by=u_a,lock_reason='Market rollback test' WHERE id=period_id;
    denied:=false;
    BEGIN
      PERFORM public.v61117_post_manual_journal('2026-10-17','Market rollback locked-period journal',lines);
    EXCEPTION WHEN others THEN
      IF SQLERRM ILIKE '%locked%' THEN denied:=true; ELSE RAISE; END IF;
    END;
    IF NOT denied THEN RAISE EXCEPTION 'Locked-period journal accepted'; END IF;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claim.sub',u_b::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u_b::text,'role','authenticated')::text,true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF public.current_business_id()<>b_b THEN RAISE EXCEPTION 'Owner B context incorrect'; END IF;
    SELECT count(*) INTO n FROM public.customers WHERE id=c_b;
    IF n<>1 THEN RAISE EXCEPTION 'Owner B cannot read own customer'; END IF;
    SELECT count(*) INTO n FROM public.customers WHERE business_id=b_a;
    IF n<>0 THEN RAISE EXCEPTION 'Reverse-direction customer isolation failed'; END IF;
    SELECT count(*) INTO n FROM public.accounting_journals WHERE business_id=b_a;
    IF n<>0 THEN RAISE EXCEPTION 'Cross-business journal read allowed'; END IF;
    EXECUTE 'RESET ROLE';
    UPDATE public.businesses SET settings=coalesce(settings,'{}'::jsonb)||'{"country":"AU","currency":"AUD"}'::jsonb,updated_at=clock_timestamp() WHERE id=b_b;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT updated_at INTO settings_revision FROM public.businesses WHERE id=b_b;
    SELECT updated_at INTO financial_revision FROM public.financial_settings WHERE business_id=b_b;
    tax_values:=tax_values||'{"financial_year_start_month":7,"gst_registered":true,"gst_number":"51824753556","gst_accounting_basis":"cash","gst_filing_frequency":"quarterly","balance_date_month":6,"balance_date_day":30,"effective_from":"2026-07-01"}'::jsonb;
    tax_result:=public.v6221_save_tax_settings(b_b,settings_revision,financial_revision,tax_values);
    IF tax_result->'current_tax_status'->>'jurisdiction'<>'AU' OR (tax_result->'business'->'settings'->>'gstRate')::numeric<>10 OR tax_result->'financial_settings'->>'gst_accounting_basis'<>'payments' THEN RAISE EXCEPTION 'Australian tax projection incorrect'; END IF;
    EXECUTE 'RESET ROLE';
    RAISE SQLSTATE 'PZ001' USING MESSAGE='Rollback all Market fixture records';
  EXCEPTION WHEN SQLSTATE 'PZ001' THEN NULL;
  END;
END;
$market_test$;
SELECT jsonb_build_object('passed',true,'checks',jsonb_build_array(
'settings save, projection and blank clearing','stale settings rejection','unknown settings rejection','redacted settings audit','viewer settings denial','idempotent bank creation','atomic bank default switching','wrong-currency default rollback','cross-business bank denial','stale bank denial','archived bank cannot restore implicitly','payment projection excludes archived and other-currency accounts','generic settings cannot replace bank projection','atomic NZ tax save','failed account mapping rolls back all tax writes','future GST remains future-dated','stale tax revision rejected','viewer bank and tax denial','accountant tax save permitted','read-only subscription blocks bank and tax writes','anonymous execution revoked','read-only accountant journal posting blocked','own-business read and write','two-business customer read isolation','cross-business update blocked',
'cross-business insert blocked','balanced journal posts','unbalanced journal blocked',
'foreign-business account blocked','locked-period journal blocked','reverse-direction isolation',
'cross-business journal read blocked','atomic Australian tax save and cash-basis compatibility','fixture records rolled back')) AS market_checks;
