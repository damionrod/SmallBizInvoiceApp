-- Administrator-only, single-business repair. Caller MUST set transaction-local
-- frindly.cleanup_owner_email from the owner's explicit instruction.
-- Run within BEGIN/ROLLBACK first; use BEGIN/COMMIT only after reviewing assertions.
-- No posted journals, journal lines, invoice totals or payroll figures are rewritten.
do $repair$
declare
 owner_email text:=current_setting('frindly.cleanup_owner_email',true);
 b uuid; actor uuid; target public.bank_accounts%rowtype; other public.bank_accounts%rowtype; configured public.bank_accounts%rowtype;
 old_ids uuid[]; ledger_before text; tx_before text; other_before text; records_before bigint; total_before numeric;
 run_id uuid:=gen_random_uuid(); r record; changed int;
begin
 if nullif(owner_email,'') is null then raise exception 'Owner email must be supplied explicitly';end if;
 select p.business_id,p.id into strict b,actor from auth.users u join public.profiles p on p.id=u.id where lower(u.email)=lower(owner_email);
 if exists(select 1 from public.accounting_audit_log where business_id=b and action='owner_bank_consolidation_completed') then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('frindly-settlement:'||b::text,0));
 lock table public.bank_accounts,public.bank_transactions,public.accounting_journals,public.accounting_journal_lines in share row exclusive mode;
 perform 1 from public.bank_accounts where business_id=b for update;
 if (select count(*) from public.bank_accounts where business_id=b and not archived and is_default)<>1 then raise exception 'Exactly one current default bank is required';end if;
 select * into strict target from public.bank_accounts where business_id=b and not archived and is_default;
 select * into strict configured from public.bank_accounts where business_id=b and not archived and configured_for_invoice and name in ('BNZ','ANZ') and regexp_replace(coalesce(account_number,''),'[^0-9]','','g')=regexp_replace(coalesce(target.account_number,''),'[^0-9]','','g');
 select * into strict other from public.bank_accounts where business_id=b and not archived and configured_for_invoice and name in ('BNZ','ANZ') and name<>configured.name;
 if target.accounting_account_id is null or other.accounting_account_id is null then raise exception 'Both retained banks require ledger links';end if;
 if configured.id<>target.id and coalesce(configured.opening_balance,0)<>0 then raise exception 'A second non-zero opening balance needs a separate evidence-backed review';end if;
 if exists(select 1 from public.bank_accounts where business_id=b and not archived and id not in (target.id,other.id) and account_number is not null and account_number !~ '^TEST-' and regexp_replace(account_number,'[^0-9]','','g') not in (regexp_replace(target.account_number,'[^0-9]','','g'),regexp_replace(other.account_number,'[^0-9]','','g'))) then raise exception 'Unexpected additional real bank number requires review';end if;
 if exists(select 1 from public.bank_transactions where business_id=b group by import_fingerprint having count(*)>1) or exists(select 1 from public.bank_transactions where business_id=b and external_transaction_id is not null group by source_provider,external_transaction_id having count(*)>1) then raise exception 'Consolidation would collide with imported transaction identifiers';end if;
 select array_agg(id) into old_ids from public.bank_accounts where business_id=b and id not in(target.id,other.id);
 select md5(coalesce(string_agg(to_jsonb(j)::text,'|' order by j.id),'')) into ledger_before from public.accounting_journals j where business_id=b;
 ledger_before:=ledger_before||':'||(select md5(coalesce(string_agg(to_jsonb(l)::text,'|' order by l.id),'')) from public.accounting_journal_lines l where business_id=b);
 select count(*),coalesce(sum(amount),0),md5(coalesce(string_agg((to_jsonb(t)-'bank_account_id'-'transfer_bank_account_id'-'updated_at'-'updated_by')::text,'|' order by id),'')) into records_before,total_before,tx_before from public.bank_transactions t where business_id=b;
 select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by id),'')) into other_before from public.bank_accounts x where business_id<>b;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by)
 values(b,'bank_account',run_id,'owner_bank_consolidation_before',jsonb_build_object('banks',(select jsonb_agg(to_jsonb(x)) from public.bank_accounts x where business_id=b),'settings',(select settings->'bankAccounts' from public.businesses where id=b),'default_bank_id',target.id,'journal_hash',ledger_before,'transaction_hash',tx_before),actor);
 -- Retain the current default's existing ID and GL: existing recorded payments stay linked.
 update public.bank_accounts set name=configured.name,configured_for_invoice=true,opening_balance=coalesce(target.opening_balance,configured.opening_balance),opening_balance_date=coalesce(target.opening_balance_date,configured.opening_balance_date),opening_balance_journal_id=coalesce(target.opening_balance_journal_id,configured.opening_balance_journal_id),updated_at=now(),updated_by=actor where business_id=b and id=target.id;
 update public.accounting_accounts set account_name=configured.name,updated_at=now(),updated_by=actor where business_id=b and id=target.accounting_account_id;
 -- Link all historical bank ledgers except the separately retained bank's ledger.
 for r in select a.id from public.accounting_accounts a where a.business_id=b and a.id not in(target.accounting_account_id,other.accounting_account_id) and (a.account_type='bank' or a.account_subtype='bank' or a.system_key in('bank','bank_main') or a.system_account_key in('bank','bank_main') or a.id in(select accounting_account_id from public.bank_accounts where business_id=b)) loop
  insert into public.bank_account_ledger_links(business_id,bank_account_id,accounting_account_id,reason,created_by) values(b,target.id,r.id,'Owner-authorised historical bank consolidation; original journals preserved',actor);
 end loop;
 -- Move only bank routing references. Counterparty bank numbers are never touched.
 for r in select * from (values
 ('bank_transactions','bank_account_id'),('bank_transactions','transfer_bank_account_id'),
 ('bank_import_batches','bank_account_id'),('bank_reconciliation_allocations','transfer_bank_account_id'),
 ('bank_rules','transfer_bank_account_id'),('blinkpay_feed_accounts','bank_account_id'),('akahu_feed_accounts','bank_account_id'),
 ('customer_payments','bank_account_id'),('invoice_payment_settings','stripe_payout_bank_account_id'),('liability_payments','bank_account_id')
 ) as fields(tbl,col) loop
  execute format('insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) select $1,$4,%I,''owner_bank_reference_reassigned'',jsonb_build_object(''field'',$5,''before'',%I,''after'',$2,''run_id'',$6),$7 from public.%I where business_id=$1 and %I=any($3)',case when r.tbl='invoice_payment_settings' then 'business_id' else 'id' end,r.col,r.tbl,r.col) using b,target.id,old_ids,r.tbl,r.col,run_id,actor;
  execute format('update public.%I set %I=$2 where business_id=$1 and %I=any($3)',r.tbl,r.col,r.col) using b,target.id,old_ids;
 end loop;
 -- Expense/batch funding UUIDs pointing to an obsolete row (if any) use the retained ID.
 -- Historical blank/free-text payment details remain unchanged; their posted ledger
 -- history is associated through bank_account_ledger_links, without revalidating amounts.
 for r in select * from (values('expense_payments'),('batch_payments')) as fields(tbl) loop
  execute format('select count(*) from public.%I where business_id=$1 and bank_account=any(select x::text from unnest($2::uuid[]) x)',r.tbl) into changed using b,old_ids;
  if changed<>0 then raise exception 'Obsolete UUID funding references in % require an audited metadata repair before consolidation',r.tbl;end if;
 end loop;
 update public.bank_accounts set archived=true,is_default=false,configured_for_invoice=false,updated_at=now(),updated_by=actor where business_id=b and id=any(old_ids);
 update public.bank_accounts set configured_for_invoice=true,updated_at=now(),updated_by=actor where business_id=b and id=other.id;
 update public.businesses set settings=jsonb_set(settings,'{bankAccounts}',(select jsonb_agg(jsonb_build_object('bankAccountId',id,'name',name,'account',account_number,'isDefault',is_default,'openingBalance',coalesce(opening_balance::text,''),'openingDate',coalesce(opening_balance_date::text,'')) order by is_default desc,name) from public.bank_accounts where business_id=b and not archived)),updated_at=now() where id=b;
 if (select count(*) from public.bank_accounts where business_id=b and not archived)<>2 then raise exception 'Expected exactly two active banks';end if;
 if (select count(*) from public.bank_accounts where business_id=b and not archived and name in('BNZ','ANZ') and configured_for_invoice)<>2 then raise exception 'Configured bank identity check failed';end if;
 if ledger_before<>((select md5(coalesce(string_agg(to_jsonb(j)::text,'|' order by j.id),'')) from public.accounting_journals j where business_id=b)||':'||(select md5(coalesce(string_agg(to_jsonb(l)::text,'|' order by l.id),'')) from public.accounting_journal_lines l where business_id=b)) then raise exception 'Posted ledger changed unexpectedly';end if;
 if tx_before<>(select md5(coalesce(string_agg((to_jsonb(t)-'bank_account_id'-'transfer_bank_account_id'-'updated_at'-'updated_by')::text,'|' order by id),'')) from public.bank_transactions t where business_id=b) or records_before<>(select count(*) from public.bank_transactions where business_id=b) or total_before<>(select coalesce(sum(amount),0) from public.bank_transactions where business_id=b) then raise exception 'Imported transaction history changed unexpectedly';end if;
 if other_before<>(select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by id),'')) from public.bank_accounts x where business_id<>b) then raise exception 'Another business changed unexpectedly';end if;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'bank_account',run_id,'owner_bank_consolidation_completed',jsonb_build_object('default_bank_id',target.id,'retained_other_bank_id',other.id,'archived_bank_ids',old_ids,'historical_bank_ledgers',(select jsonb_agg(accounting_account_id) from public.bank_account_ledger_links where business_id=b),'transaction_count',records_before,'transaction_total',total_before,'journal_hash',ledger_before),actor);
end $repair$;
