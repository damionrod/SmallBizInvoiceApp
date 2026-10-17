-- Isolated Frindly Market only. Fixture rows are rolled back by a subtransaction.
-- No email, payment, bank-provider or other network operation is called.
DO $market_test$
DECLARE
  u_a uuid; u_b uuid; b_a uuid:=gen_random_uuid(); b_b uuid:=gen_random_uuid();
  p uuid; c_a uuid:=gen_random_uuid(); c_b uuid:=gen_random_uuid();
  a_debit uuid:=gen_random_uuid(); a_credit uuid:=gen_random_uuid(); b_account uuid:=gen_random_uuid();
  period_id uuid:=gen_random_uuid(); j uuid; n bigint; denied boolean;
  lines jsonb;
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
    RAISE SQLSTATE 'PZ001' USING MESSAGE='Rollback all Market fixture records';
  EXCEPTION WHEN SQLSTATE 'PZ001' THEN NULL;
  END;
END;
$market_test$;
SELECT jsonb_build_object('passed',true,'checks',jsonb_build_array(
'own-business read and write','two-business customer read isolation','cross-business update blocked',
'cross-business insert blocked','balanced journal posts','unbalanced journal blocked',
'foreign-business account blocked','locked-period journal blocked','reverse-direction isolation',
'cross-business journal read blocked','fixture records rolled back')) AS market_checks;
