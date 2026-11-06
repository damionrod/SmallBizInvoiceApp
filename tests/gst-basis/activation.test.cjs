const {test}=require('node:test');const assert=require('node:assert/strict');const fixture=require('./activation-fixture.cjs');
test('six NZ GST transitions activate, create one adjustment/transfer, and use existing settlements',async()=>{
 const {db,scalar,seed}=await fixture();try{
 for(const [old,basis,expected] of [['invoice','payments',-90],['payments','invoice',90],['invoice','hybrid',60],['hybrid','invoice',-60],['payments','hybrid',150],['hybrid','payments',-150]]){
  const f=await seed(old);await f.prior();const p=await f.preview(basis);assert.equal(p.can_apply,true,JSON.stringify(p.review_items));assert.equal(Number(p.provisional_net_adjustment),expected);
  const q=await f.request(basis);const applied=await f.apply(q);assert.equal(applied.status,'applied');assert.equal(Number(applied.applied_evidence.net_adjustment),expected);
  assert.equal((await f.apply(applied)).adjustment_id,applied.adjustment_id);assert.equal(Number(await scalar("select count(*) from gst_adjustments where business_id=$1 and status='active'",[f.b])),1);
  const saved=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null))");assert.equal(Number(saved.gst_net),expected);assert.equal(saved.snapshot.basis_activation_version,'nz-gst-activation-v2');
  const journal=saved.snapshot.settlement_journal_id;assert.ok(journal);assert.equal(Number(await scalar('select sum(debit-credit) from accounting_journal_lines where journal_id=$1',[journal])),0);
  const paid=await scalar("select public.frindly_record_liability_payment(gen_random_uuid(),'2026-11-01',$1,null,$2)",[f.bank,JSON.stringify([{kind:'gst',source_id:saved.id,account_id:saved.snapshot.settlement_account_id,amount:Math.abs(expected)}])]);assert.ok(paid);
  assert.equal(Number(await f.balance(saved.snapshot.settlement_account_id)),0);await assert.rejects(()=>scalar("update gst_returns set gst_net=123 where id=$1 returning id",[saved.id]),/immutable/);
  console.log('PASS',old,'->',basis,expected,'and settlement');
 }
 }finally{await db.close();}
});

test('partial payments, business use, fully paid sources, subsequent cash and repeated basis changes',async()=>{
 const {db,scalar,seed}=await fixture();try{
  let f=await seed('payments',{paidInvoice:575,paidExpense:230,fraction:.5});await f.prior();let p=await f.preview('invoice');assert.equal(p.can_apply,true,JSON.stringify(p.review_items));assert.equal(Number(p.provisional_net_adjustment),60);let q=await f.request('invoice');await f.apply(q);let filed=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null))");assert.equal(Number(filed.gst_net),60);
  // The pre-change payments-basis return remains payable using its actual snapshot.
  const prior=(await db.query("select * from gst_returns where business_id=$1 and period_end='2026-09-30'",[f.b])).rows[0];assert.equal(Number(prior.gst_net),60);
  await scalar("select public.frindly_record_liability_payment(gen_random_uuid(),'2026-11-01',$1,null,$2)",[f.bank,JSON.stringify([{kind:'gst',source_id:prior.id,account_id:f.out,amount:60}])]);
  console.log('PASS partial payments, private use and pre-change cash-return settlement');
  f=await seed('invoice',{paidInvoice:1150,paidExpense:460});await f.prior();p=await f.preview('payments');assert.equal(Number(p.provisional_net_adjustment),0);q=await f.request('payments');const applied=await f.apply(q);assert.equal(applied.adjustment_id,null);filed=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null))");assert.equal(Number(filed.gst_net),0);console.log('PASS fully paid sources need no duplicate adjustment');
  f=await seed('invoice');await f.prior();q=await f.request('payments');await f.apply(q);filed=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null))");assert.equal(Number(filed.gst_net),-90);
  await f.payInvoice(575,'2026-11-03');await f.payInvoice(575,'2026-11-05');await f.payExpense(460,'2026-11-07');
  const nov=await scalar("select public.frindly_gst_boundary_basis_v1('2026-11-01','2026-11-30',null)");assert.equal(Number(nov.gst_net),90);assert.equal(nov.review_items.filter(x=>x.severity==='blocking').length,0,JSON.stringify(nov.review_items));
  const novFile=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-11-01','2026-11-30','finalised',null))");assert.equal(Number(novFile.gst_net),90);const total=await scalar('select sum(gst_net) from gst_returns where business_id=$1 and status=\'finalised\'',[f.b]);assert.equal(Number(total),90);
  const pnL=await scalar("select sum(l.credit-l.debit) from accounting_journal_lines l join accounting_journals j on j.id=l.journal_id where j.business_id=$1 and j.source_type='gst_return_transfer' and l.account_id in ($2,$3)",[f.b,f.sales,f.cost]);assert.equal(Number(pnL),0);console.log('PASS later multiple cash receipts/purchases count once; no P&L transfer');
  f=await seed('payments');await f.prior();q=await f.request('invoice');await f.apply(q);await scalar("select public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null)");
  q=await f.request('payments','ird_change','2026-11-01','2026-11-30');const second=await f.apply(q);assert.equal(Number(second.applied_evidence.net_adjustment),-90);const last=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-11-01','2026-11-30','finalised',null))");assert.equal(Number(last.gst_net),-90);console.log('PASS earlier filed wash-up is recognised on a second basis change');
 }finally{await db.close();}
});

test('source credits and attributable refunds reconcile; missing evidence stays blocked',async()=>{
 const {db,scalar,seed,journal,line}=await fixture();try{
 let f=await seed('invoice');
 const cn=await scalar("insert into customer_credit_notes(business_id,original_invoice_id,credit_note_number,credit_date,ex_gst,gst_amount,total_amount,lifecycle_state) values($1,$2,'CN','2026-09-10',100,15,115,'issued') returning id",[f.b,f.inv]);
 const sc=await scalar("insert into supplier_credits(business_id,original_expense_id,applied_expense_id,credit_note_number,credit_date,ex_gst,gst_amount,total_amount,lifecycle_state) values($1,$2,$2,'SC','2026-09-10',40,6,46,'recorded') returning id",[f.b,f.exp]);
 await journal(f.b,'2026-09-10','customer_credit_note',cn,[line(f.sales,100,0),line(f.out,15,0),line(f.ar,0,115)]);await journal(f.b,'2026-09-10','supplier_credit',sc,[line(f.ap,46,0),line(f.cost,0,40),line(f.input,0,6)]);
 await f.prior();let p=await f.preview('payments');assert.equal(p.can_apply,true,JSON.stringify(p.review_items));assert.equal(Number(p.provisional_net_adjustment),-81);let q=await f.request('payments');await f.apply(q);console.log('PASS linked customer and supplier credits reduce the actual wash-up');
 f=await seed('invoice',{paidInvoice:1150});
 const cn2=await scalar("insert into customer_credit_notes(business_id,original_invoice_id,credit_note_number,credit_date,ex_gst,gst_amount,total_amount,lifecycle_state) values($1,$2,'CN-REF','2026-09-12',200,30,230,'issued') returning id",[f.b,f.inv]);await journal(f.b,'2026-09-12','customer_credit_note',cn2,[line(f.sales,200,0),line(f.out,30,0),line(f.ar,0,230)]);
 const refund=await scalar("insert into customer_refunds(business_id,customer_id,refund_date,amount,lifecycle_state) values($1,'20000000-0000-0000-0000-000000000001','2026-09-13',230,'recorded') returning id",[f.b]);await journal(f.b,'2026-09-13','customer_refund',refund,[line(f.ar,230,0),line(f.bankGl,0,230)]);await f.prior();p=await f.preview('payments');assert.equal(p.can_apply,true,JSON.stringify(p.review_items));assert.equal(Number(p.provisional_net_adjustment),60);console.log('PASS attributable customer refund clears credited overpayment without creating a false debtor');
 f=await seed('payments');p=await f.preview('invoice');assert.equal(p.can_apply,false);assert.ok(p.review_items.some(x=>x.code==='prior_period_missing'));console.log('PASS imported/missing prior filings block activation');
 f=await seed('payments');await f.payInvoice(575,'2026-09-12',true);await assert.rejects(()=>f.prior(),/blocking/);p=await f.preview('invoice');assert.equal(p.can_apply,false);assert.ok(p.review_items.some(x=>x.code==='payment_evidence'));console.log('PASS estimated historical payment evidence is rejected');
 }finally{await db.close();}
});

test('historical corrections, stale evidence, filed locks, zero GST and tenant/permission isolation',async()=>{
 const {db,scalar,seed,uid}=await fixture();try{
 let f=await seed('invoice');
 await db.query("insert into gst_settings_history(business_id,effective_from,gst_registered,accounting_basis,filing_frequency,jurisdiction) values($1,'2026-09-20',true,'payments','monthly','NZ')",[f.b]);
 let p=await f.preview('payments','correction','2026-09-01','2026-09-30');assert.equal(p.can_apply,true,JSON.stringify(p.review_items));let q=await f.request('payments','correction','2026-09-01','2026-09-30');await f.apply(q);assert.equal(Number(await scalar('select count(*) from gst_adjustments where business_id=$1',[f.b])),0);const corrected=await scalar("select public.frindly_gst_boundary_basis_v1('2026-09-01','2026-09-30',null)");assert.equal(Number(corrected.gst_net),0);assert.equal(corrected.review_items.filter(x=>x.severity==='blocking').length,0);
 const correctedFile=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-09-01','2026-09-30','finalised',null))");assert.equal(Number(correctedFile.gst_net),0);console.log('PASS unfiled configuration correction uses existing settings without a wash-up');
 f=await seed('invoice');await f.prior();q=await f.request('payments');let applied=await f.apply(q);const oldAdjustment=applied.adjustment_id;await f.payInvoice(575,'2026-09-25');
 let review=await scalar('select public.frindly_gst_basis_request_review_v1($1)',[q.id]);assert.equal(review.unchanged,false);assert.equal(review.can_apply,true);applied=await f.apply(applied);assert.equal(Number(applied.applied_evidence.net_adjustment),-15);assert.notEqual(applied.adjustment_id,oldAdjustment);assert.equal(await scalar('select status from gst_adjustments where id=$1',[oldAdjustment]),'reversed');assert.equal(Number(await scalar("select count(*) from gst_adjustments where business_id=$1 and status='active'",[f.b])),1);console.log('PASS changed unfiled evidence replaces the adjustment with an audited reversal');
 let filed=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null))");const original=JSON.stringify(filed.snapshot);
 await assert.rejects(()=>scalar("update gst_settings_history set accounting_basis='hybrid' where business_id=$1 and effective_from='2026-10-01' returning id",[f.b]),/filed return/);
 await assert.rejects(()=>scalar("update gst_adjustments set gst_amount=1 where id=$1 returning id",[applied.adjustment_id]),/immutable/);
 await assert.rejects(()=>scalar("update accounting_journals set status='reversed' where id=$1 returning id",[filed.snapshot.settlement_journal_id]),/immutable/);
 const locked=await scalar("select public.frindly_gst_boundary_basis_v1('2026-10-01','2026-10-31','hybrid')");assert.equal(Number(locked.gst_net),-15);assert.equal(locked.locked_snapshot,true);
 await f.payInvoice(100,'2026-09-26');review=await scalar('select public.frindly_gst_basis_request_review_v1($1)',[q.id]);assert.equal(review.can_apply,false);await assert.rejects(()=>f.apply(applied),/after a filed return/);assert.equal(JSON.stringify(await scalar('select snapshot from gst_returns where id=$1',[filed.id])),original);console.log('PASS filed snapshots, settings, adjustments and transfer journals remain locked');
 f=await seed('payments',{zeroTax:true});await f.prior();p=await f.preview('invoice');assert.equal(p.can_apply,true,JSON.stringify(p.review_items));assert.equal(Number(p.provisional_net_adjustment),0);console.log('PASS zero-tax sources do not manufacture GST');
 f=await seed('payments');await f.prior();q=await f.request('invoice');
 const other=await seed('invoice');await assert.rejects(()=>scalar('select public.frindly_apply_gst_basis_change_v1($1,$2,true)',[q.id,'wrong']),/not found/);await scalar('select public.frindly_cancel_gst_basis_request_v1($1)',[q.id]);assert.equal(await scalar('select status from gst_basis_change_requests where id=$1',[q.id]),'pending_verification');
 await db.query('update profiles set active_business_id=$1 where id=$2',[f.b,uid]);await db.query("update business_memberships set role='viewer' where business_id=$1 and user_id=$2",[f.b,uid]);await db.query("insert into business_member_access_overrides(business_id,membership_id,area,can_read,can_write) select business_id,id,'financials',true,false from business_memberships where business_id=$1 and user_id=$2",[f.b,uid]);await assert.rejects(()=>f.apply(q),/write access denied/);console.log('PASS cross-tenant apply/cancel and read-only users cannot activate a change');
 }finally{await db.close();}
});

test('supplier refunds, ambiguous allocations, mixed credits and external filings retain evidence controls',async()=>{
 const {db,scalar,seed,journal,line}=await fixture();try{
 let f=await seed('invoice',{paidExpense:460});
 const cn=await scalar("insert into supplier_credits(business_id,original_expense_id,applied_expense_id,credit_date,ex_gst,gst_amount,total_amount,lifecycle_state) values($1,$2,$2,'2026-09-12',40,6,46,'recorded') returning id",[f.b,f.exp]);await journal(f.b,'2026-09-12','supplier_credit',cn,[line(f.ap,46,0),line(f.cost,0,40),line(f.input,0,6)]);
 const ref=await scalar("insert into supplier_refunds(business_id,refund_date,amount,lifecycle_state) values($1,'2026-09-13',46,'recorded') returning id",[f.b]);await db.query('insert into supplier_refund_allocations(business_id,supplier_refund_id,supplier_credit_id,amount) values($1,$2,$3,46)',[f.b,ref,cn]);await journal(f.b,'2026-09-13','supplier_refund',ref,[line(f.bankGl,46,0),line(f.ap,0,46)]);await f.prior();let p=await f.preview('payments');assert.equal(p.can_apply,true,JSON.stringify(p.review_items));assert.equal(Number(p.provisional_net_adjustment),-150);console.log('PASS allocated supplier refunds do not leave a false unpaid creditor');
 f=await seed('invoice');const bad=await scalar("insert into customer_credit_notes(business_id,original_invoice_id,credit_date,ex_gst,gst_amount,total_amount,lifecycle_state) values($1,$2,'2026-09-12',115,0,115,'issued') returning id",[f.b,f.inv]);await journal(f.b,'2026-09-12','customer_credit_note',bad,[line(f.sales,115,0),line(f.ar,0,115)]);await f.prior();p=await f.preview('payments');assert.equal(p.can_apply,false);assert.ok(p.review_items.some(x=>x.code==='mixed_credit'));console.log('PASS non-proportional credit GST requires allocation review');
 f=await seed('invoice');await f.prior();await db.query("insert into ird_filing_batches(business_id,filing_type,status,period_start,period_end) values($1,'gst_return','filed_in_myir','2026-10-01','2026-10-31')",[f.b]);p=await f.preview('payments');assert.equal(p.can_apply,false);assert.equal(p.filed_conflict,true);await assert.rejects(()=>f.request('payments'),/already filed/);console.log('PASS externally filed periods cannot be overwritten');
 f=await seed('invoice');await f.prior();await db.query("insert into gst_adjustments(business_id,adjustment_date,adjustment_type,direction,gst_amount,reason,status) values($1,'2026-10-01','manual','credit',90,'Basis transition already entered','active')",[f.b]);p=await f.preview('payments');assert.equal(p.can_apply,false);assert.ok(p.review_items.some(x=>x.code==='existing_transition_adjustment'));console.log('PASS a pre-existing manual transition adjustment blocks duplicate wash-up');
 }finally{await db.close();}
});

test('GST transfers preserve P&L and balance sheet, payments reverse and bank matching does not repost',async()=>{
 const {db,scalar,seed,account,journal,line}=await fixture();try{
 const f=await seed('payments');await f.prior();const before=await scalar("select to_jsonb(p) from public.v6170b_profit_loss('2026-01-01','2026-12-31') p");const beforeBs=await scalar("select to_jsonb(p) from public.v6170b_balance_sheet('2026-10-31') p");assert.equal(beforeBs.balances,true);
 const q=await f.request('invoice');await f.apply(q);const filed=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null))");
 const after=await scalar("select to_jsonb(p) from public.v6170b_profit_loss('2026-01-01','2026-12-31') p");assert.deepEqual(after,before);const bs=await scalar("select to_jsonb(p) from public.v6170b_balance_sheet('2026-10-31') p");assert.equal(bs.balances,true);assert.equal(Number(bs.assets)-Number(bs.liabilities)-Number(bs.equity)-Number(bs.current_profit),0);
 const args=[f.bank,JSON.stringify([{kind:'gst',source_id:filed.id,account_id:filed.snapshot.settlement_account_id,amount:90}])];
 let pay=await scalar("select public.frindly_record_liability_payment(gen_random_uuid(),'2026-11-01',$1,null,$2)",args);const pj=await scalar('select accounting_journal_id from liability_payments where id=$1',[pay]);await scalar("select public.frindly_reverse_gst_settlement($1,'Isolated reversal test',false)",[pj]);
 assert.equal(Number(await f.balance(filed.snapshot.settlement_account_id)),90);pay=await scalar("select public.frindly_record_liability_payment(gen_random_uuid(),'2026-11-01',$1,null,$2)",args);
 const count=Number(await scalar('select count(*) from accounting_journals where business_id=$1',[f.b]));const tx=await scalar("insert into bank_transactions(business_id,bank_account_id,transaction_date,amount,import_fingerprint) values($1,$2,'2026-11-01',-90,'gst-activation-match') returning id",[f.b,f.bank]);await scalar('select public.frindly_reconcile_liability_payment($1,$2)',[tx,pay]);assert.equal(Number(await scalar('select count(*) from accounting_journals where business_id=$1',[f.b])),count);assert.equal(Number(await f.balance(filed.snapshot.settlement_account_id)),0);
 const finalBs=await scalar("select to_jsonb(p) from public.v6170b_balance_sheet('2026-11-01') p");assert.equal(finalBs.balances,true);console.log('PASS existing P&L/Balance Sheet engines, reversal and bank match without duplicate journal');
 // Existing payroll settlement branch remains usable after the GST extension.
 const wages=await account(f.b,'payroll_net_payable','Wages payable','liability');const run=await scalar("insert into payroll_pay_runs(business_id,pay_run_number,pay_date,status,net_pay) values($1,'REGRESSION-PAY','2026-11-02','finalised',100) returning id",[f.b]);await journal(f.b,'2026-11-02','payroll',run,[line(f.cost,100,0),line(wages,0,100)]);await scalar("select public.frindly_record_liability_payment(gen_random_uuid(),'2026-11-03',$1,null,$2)",[f.bank,JSON.stringify([{kind:'wages',source_id:run,account_id:wages,amount:100}])]);assert.equal(Number(await f.balance(wages)),0);console.log('PASS payroll settlement remains unchanged');
 // New request table is enforced by RLS, not merely by application filtering.
 await db.exec('grant usage on schema auth to authenticated;set role authenticated');assert.equal(Number(await scalar('select count(*) from gst_basis_change_requests where business_id<>public.current_business_id()')),0);await assert.rejects(()=>db.query("update gst_basis_change_requests set evidence_reference='tamper'"),/permission denied/);await db.exec('reset role');console.log('PASS authenticated table writes denied and cross-business request reads filtered');
 }finally{await db.close();}
});

test('closed periods roll back filing, skipped periods are blocked and request/adjustment identity is unique',async()=>{
 const {db,scalar,seed}=await fixture();try{
 let f=await seed('payments');await f.prior();let q=await f.request('invoice');let applied=await f.apply(q);
 const draft=await scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','draft',null))");
 await db.query("update accounting_periods set status='closed' where business_id=$1",[f.b]);await assert.rejects(()=>scalar("select public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null)"),/locked|unavailable/);
 assert.equal(await scalar('select status from gst_returns where id=$1',[draft.id]),'draft');assert.equal(Number(await scalar("select count(*) from accounting_journals where business_id=$1 and source_type='gst_return_transfer'",[f.b])),0);assert.equal(await scalar('select included_return_id from gst_adjustments where id=$1',[applied.adjustment_id]),null);console.log('PASS filing failure leaves its draft, adjustment and journals unchanged');
 await db.query("update accounting_periods set status='open' where business_id=$1",[f.b]);await assert.rejects(()=>scalar("select public.frindly_save_gst_basis_v1('2026-11-01','2026-11-30','finalised',null)"),/earlier GST periods/);await assert.rejects(()=>db.query("insert into gst_adjustments(business_id,adjustment_date,direction,gst_amount,reason,source_type,source_id,status) values($1,'2026-10-01','debit',90,'duplicate','gst_basis_transition',$2,'active')",[f.b,q.id]),/unique|duplicate/);
 console.log('PASS no skipped transition periods or duplicate active wash-up');
 f=await seed('invoice');await f.prior();q=await f.request('payments');await scalar("select set_config('request.jwt.claim.sub','',false)");await assert.rejects(()=>scalar('select public.frindly_apply_gst_basis_change_v1($1,$2,true)',[q.id,'any']),/access denied/);console.log('PASS unauthenticated activation is denied');
 }finally{await db.close();}
});

test('ambiguous refunds and unknown zero-GST classifications are reviewable rather than guessed',async()=>{
 const {db,scalar,seed,journal,line}=await fixture();try{
 let f=await seed('invoice',{paidInvoice:1150});
 const cn=await scalar("insert into customer_credit_notes(business_id,original_invoice_id,credit_date,ex_gst,gst_amount,total_amount,lifecycle_state) values($1,$2,'2026-09-12',200,30,230,'issued') returning id",[f.b,f.inv]);await journal(f.b,'2026-09-12','customer_credit_note',cn,[line(f.sales,200,0),line(f.out,30,0),line(f.ar,0,230)]);
 const ref=await scalar("insert into customer_refunds(business_id,customer_id,refund_date,amount,lifecycle_state) values($1,'20000000-0000-0000-0000-000000000001','2026-09-13',230,'recorded') returning id",[f.b]);await journal(f.b,'2026-09-13','customer_refund',ref,[line(f.ar,230,0),line(f.bankGl,0,230)]);
 const other=await scalar("insert into invoices(business_id,customer_id,invoice_number,invoice_date,total,gst,lifecycle_state,amount_paid) values($1,'20000000-0000-0000-0000-000000000001','OTHER','2026-09-20',115,0,'issued',0) returning id",[f.b]);await journal(f.b,'2026-09-20','invoice',other,[line(f.ar,115,0),line(f.sales,0,115)]);await f.prior();let p=await f.preview('payments');assert.equal(p.can_apply,false);assert.ok(p.review_items.some(x=>x.code==='refund_allocation'));console.log('PASS customer refunds with ambiguous invoice allocation are blocked');
 f=await seed('payments',{zeroTax:true});await f.prior();let q=await f.request('invoice');await f.apply(q);await scalar("select public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null)");
 const zero=await scalar("insert into invoices(business_id,invoice_number,invoice_date,total,gst,lifecycle_state,amount_paid) values($1,'ZERO-UNKNOWN','2026-11-01',100,0,'issued',0) returning id",[f.b]);await journal(f.b,'2026-11-01','invoice',zero,[line(f.ar,100,0),line(f.sales,0,100)]);
 const calc=await scalar("select public.frindly_gst_boundary_basis_v1('2026-11-01','2026-11-30',null)");assert.equal(Number(calc.gst_collected),0);assert.ok(calc.review_items.some(x=>x.code==='zero_gst_classification'));await assert.rejects(()=>scalar("select public.frindly_save_gst_basis_v1('2026-11-01','2026-11-30','finalised',null)"),/blocking review/);console.log('PASS zero-rated/exempt treatment is not inferred from a zero GST amount');
 }finally{await db.close();}
});

test('an unfiled historical configuration can be corrected from the first affected period',async()=>{
 const {db,scalar,seed}=await fixture();try{
 const f=await seed('payments');
 await db.query("delete from gst_settings_history where business_id=$1",[f.b]);
 await db.query("insert into gst_settings_history(business_id,effective_from,gst_registered,accounting_basis,filing_frequency,balance_date_month,balance_date_day,jurisdiction) values($1,'2026-09-28',true,'invoice','monthly',3,31,'NZ'),($1,'2026-10-27',true,'payments','monthly',3,31,'NZ')",[f.b]);
 const p=await f.preview('payments','correction','2026-09-01','2026-09-30');assert.equal(p.can_apply,true,JSON.stringify(p.review_items));const q=await f.request('payments','correction','2026-09-01','2026-09-30');await f.apply(q);assert.equal(Number(await scalar("select count(*) from gst_settings_history where business_id=$1 and effective_from>='2026-09-01' and accounting_basis<>'payments'",[f.b])),0);assert.equal(Number(await scalar('select count(*) from gst_adjustments where business_id=$1',[f.b])),0);console.log('PASS incorrect unfiled historical snapshots do not masquerade as real IRD basis changes');
 }finally{await db.close();}
});

test('effective-dated activation preserves the old fallback before the first recorded settings snapshot',async()=>{
 const {db,scalar,seed}=await fixture();try{
 const f=await seed('invoice');await db.query("update gst_settings_history set effective_from='2026-11-01' where business_id=$1",[f.b]);await f.prior();
 const before=await scalar("select public.v6170e_gst_settings('2026-09-15')");const q=await f.request('payments');await f.apply(q);const old=await scalar("select public.v6170e_gst_settings('2026-09-15')");assert.deepEqual(old,before);assert.equal((await scalar("select public.v6170e_gst_settings('2026-10-15')")).accounting_basis,'payments');
 await f.payInvoice(575,'2026-09-25');const reviewed=await scalar('select public.frindly_gst_basis_request_review_v1($1)',[q.id]);assert.equal(reviewed.can_apply,true);await f.apply({...q,status:'applied'});console.log('PASS old GST defaults remain unchanged before an effective-dated change');
 }finally{await db.close();}
});

test('alternate filing paths cannot bypass the transfer and ordinary invoice users need no Financials access',async()=>{
 const {db,scalar,seed,journal,line,uid}=await fixture();try{
 const f=await seed('payments');await f.prior();const q=await f.request('invoice');await f.apply(q);
 await assert.rejects(()=>db.query("insert into gst_returns(business_id,period_start,period_end,status,gst_net,snapshot) values($1,'2026-10-01','2026-10-31','finalised',90,'{}')",[f.b]),/verified GST return save/);
 await db.query("insert into business_member_access_overrides(business_id,membership_id,area,can_read,can_write) select business_id,id,'financials',false,false from business_memberships where business_id=$1 and user_id=$2",[f.b,uid]);
 const invoice=await scalar("insert into invoices(business_id,invoice_number,invoice_date,total,gst,lifecycle_state,amount_paid) values($1,'STAFF-SALE','2026-11-01',115,15,'issued',0) returning id",[f.b]);const posted=await journal(f.b,'2026-11-01','invoice',invoice,[line(f.ar,115,0),line(f.sales,0,100),line(f.out,0,15)]);assert.ok(posted);console.log('PASS legacy/direct finalisation is guarded while invoice posting remains independent of Financials access');
 }finally{await db.close();}
});
