-- Transactional Market fixtures: all writes are rolled back, including deliberately forced failures.
do $test$
declare
 u uuid;b uuid:=gen_random_uuid();other_b uuid:=gen_random_uuid();plan uuid;bank uuid:=gen_random_uuid();
 tx uuid:=gen_random_uuid();inv uuid:=gen_random_uuid();pay uuid:=gen_random_uuid();alloc uuid:=gen_random_uuid();
 rev timestamptz;r jsonb;denied boolean;n integer;a1 uuid:=gen_random_uuid();a2 uuid:=gen_random_uuid();j uuid;
begin
 if public.frindly_market_environment_status()->>'project_ref'<>'smvvevrtjqkflyqkyape' then raise exception 'Market only';end if;
 select id into u from auth.users a where not exists(select 1 from public.profiles p where p.id=a.id) order by id limit 1;
 select id into plan from public.plans order by cardinality(included_modules) desc nulls last limit 1;
 if u is null or plan is null then raise exception 'Market fixture prerequisites missing';end if;
 begin
  insert into public.businesses(id,name) values(b,'Market undo rollback fixture'),(other_b,'Market undo other fixture');
  insert into public.profiles(id,business_id,active_business_id,role,is_super_admin) values(u,b,b,'owner',false);
  insert into public.business_memberships(business_id,user_id,role,status) values(b,u,'owner','active');
  insert into public.subscriptions(business_id,plan_id,status,current_period_end,trial_ends_at) values(b,plan,'trialing',now()+interval '30 days',now()+interval '30 days');
  insert into public.bank_accounts(id,business_id,name,currency) values(bank,b,'Rollback bank','NZD');
  insert into public.accounting_periods(business_id,period_start,period_end,financial_year,status) values(b,'2026-04-01','2027-03-31',2027,'open');
  insert into public.invoices(id,business_id,invoice_number,invoice_date,customer_name,subtotal,gst,total,balance_due,lifecycle_state,lifecycle_version)
   values(inv,b,'MARKET-UNDO-FIXTURE','2026-10-01','Rollback customer',100,15,115,115,null,null);
  insert into public.customer_payments(id,business_id,invoice_id,payment_date,amount,notes) values(pay,b,inv,'2026-10-02',115,'Created by bank reconciliation');
  insert into public.bank_transactions(id,business_id,bank_account_id,transaction_date,amount,description,status,reconciliation_type,import_fingerprint)
   values(tx,b,bank,'2026-10-02',115,'Rollback fixture','reconciled','invoice','market-fixture-'||tx::text);
  insert into public.bank_reconciliation_allocations(id,business_id,bank_transaction_id,allocation_type,amount,invoice_id,customer_payment_id)
   values(alloc,b,tx,'invoice',115,inv,pay);
  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details)
   values(b,tx,'reconciled',jsonb_build_object('target_id',inv,'existing_payment',false));
  select updated_at into rev from public.bank_transactions where id=tx;
  perform set_config('request.jwt.claim.sub',u::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  denied:=false;begin perform public.v6222_undo_legacy_bank_transaction(other_b,tx,'Cross business');exception when insufficient_privilege then denied:=true;end;
  if not denied then raise exception 'Cross-business undo accepted';end if;
  denied:=false;begin perform public.v6222_undo_legacy_bank_transaction(b,tx,'Stale version',rev-interval '1 second');exception when serialization_failure then denied:=true;end;
  if not denied then raise exception 'Stale undo accepted';end if;
  execute 'reset role';
  update public.business_memberships set role='viewer' where business_id=b and user_id=u;
  execute 'set local role authenticated';
  denied:=false;begin perform public.v6222_undo_legacy_bank_transaction(b,tx,'Viewer denied');exception when insufficient_privilege then denied:=true;end;
  if not denied then raise exception 'Viewer undo accepted';end if;
  execute 'reset role';update public.business_memberships set role='owner' where business_id=b and user_id=u;
  -- Unknown origin must preserve both money and bank evidence.
  update public.customer_payments set notes='Payment entered manually' where id=pay;
  execute 'set local role authenticated';
  denied:=false;begin perform public.v6222_undo_legacy_bank_transaction(b,tx,'Unknown origin');exception when others then if sqlerrm like '%origin could not be verified%' then denied:=true;else raise;end if;end;
  if not denied then raise exception 'Unknown-origin payment was removed';end if;
  execute 'reset role';
  if not exists(select 1 from public.customer_payments where id=pay) or not exists(select 1 from public.bank_reconciliation_allocations where id=alloc) then raise exception 'Failed undo changed records';end if;
  update public.customer_payments set notes='Created by bank reconciliation' where id=pay;
  -- Closed periods cannot have their generated payments removed.
  update public.accounting_periods set status='closed' where business_id=b;
  execute 'set local role authenticated';
  denied:=false;begin perform public.v6222_undo_legacy_bank_transaction(b,tx,'Closed period');exception when others then if sqlerrm like '%closed or unavailable accounting period%' then denied:=true;else raise;end if;end;
  if not denied then raise exception 'Closed-period undo accepted';end if;
  execute 'reset role';update public.accounting_periods set status='open' where business_id=b;
  -- Existing immutable ledger postings require their own reversal workflow.
  begin
   insert into public.accounting_accounts(id,business_id,account_code,account_name,account_type,normal_balance)
    values(a1,b,'991','Undo fixture asset','asset','debit'),(a2,b,'992','Undo fixture equity','equity','credit');
   j:=public.v6192_create_posted_journal(b,'2026-10-02','customer_payment','customer_payment',pay,'UNDO-TEST','Rollback test',jsonb_build_array(
    jsonb_build_object('account_id',a1,'debit',115,'credit',0),jsonb_build_object('account_id',a2,'debit',0,'credit',115)));
   execute 'set local role authenticated';
   denied:=false;begin perform public.v6222_undo_legacy_bank_transaction(b,tx,'Posted payment');exception when others then if sqlerrm like '%posted accounting entries%' then denied:=true;else raise;end if;end;
   if not denied then raise exception 'Posted payment removed';end if;
   execute 'reset role';raise exception 'ROLL_BACK_POSTED_FIXTURE' using errcode='ZX223';
  exception when sqlstate 'ZX223' then null;
  end;
  -- A deliberately denied final audit proves the entire operation rolls back after earlier DELETEs.
  execute 'create or replace function pg_temp.deny_market_undo_audit() returns trigger language plpgsql as $f$ begin if new.action=''legacy_undo_atomic'' then raise exception ''MARKET_FORCED_AUDIT_FAILURE'';end if;return new;end $f$';
  execute 'create trigger market_undo_audit_failure before insert on public.bank_reconciliation_audit for each row execute function pg_temp.deny_market_undo_audit()';
  execute 'set local role authenticated';
  denied:=false;begin perform public.v6222_undo_legacy_bank_transaction(b,tx,'Forced failure');exception when others then if sqlerrm='MARKET_FORCED_AUDIT_FAILURE' then denied:=true;else raise;end if;end;
  if not denied then raise exception 'Forced failure not reached';end if;
  execute 'reset role';execute 'drop trigger market_undo_audit_failure on public.bank_reconciliation_audit';
  if not exists(select 1 from public.customer_payments where id=pay) or not exists(select 1 from public.bank_reconciliation_allocations where id=alloc) or not exists(select 1 from public.bank_transactions where id=tx and status='reconciled') then raise exception 'Partial undo escaped rollback';end if;
  execute 'set local role authenticated';
  r:=public.v6222_undo_legacy_bank_transaction(b,tx,'Verified fixture undo',rev);
  if not (r->>'ok')::boolean or (r->>'removed_payment_count')::integer<>1 then raise exception 'Atomic undo failed';end if;
  r:=public.v6222_undo_legacy_bank_transaction(b,tx,'Retry fixture undo',rev);
  if not (r->>'replayed')::boolean then raise exception 'Retry was not idempotent';end if;
  execute 'reset role';
  if exists(select 1 from public.customer_payments where id=pay) or exists(select 1 from public.bank_reconciliation_allocations where id=alloc) then raise exception 'Undo failed to remove only generated evidence';end if;
  if (select balance_due from public.invoices where id=inv)<>115 then raise exception 'Invoice balance was not restored';end if;
  if (select count(*) from public.bank_reconciliation_audit where bank_transaction_id=tx and action='legacy_undo_atomic')<>1 then raise exception 'Audit replay duplicated';end if;
  -- Existing customer payments remain intact when only a bank match is detached.
  insert into public.customer_payments(id,business_id,invoice_id,payment_date,amount,notes) values(pay,b,inv,'2026-10-02',115,'Existing customer payment');
  update public.bank_transactions set status='reconciled',reconciliation_type='invoice' where id=tx;
  insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,invoice_id,existing_customer_payment_id) values(b,tx,'invoice',115,inv,pay);
  execute 'set local role authenticated';r:=public.v6222_undo_legacy_bank_transaction(b,tx,'Preserve existing payment');execute 'reset role';
  if not exists(select 1 from public.customer_payments where id=pay) then raise exception 'Existing payment removed';end if;
  raise exception 'MARKET_UNDO_FIXTURES_OK' using errcode='ZX222';
 exception when sqlstate 'ZX222' then null;
 end;
 if exists(select 1 from public.businesses where id in(b,other_b)) then raise exception 'Fixture leaked';end if;
end $test$;
select 'legacy_bank_undo_rollback_checks_passed' result;
