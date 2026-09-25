const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

function reviewHarness(){
 const script=fs.readFileSync('public/purchase-review.js','utf8').replace('window.PurchaseReview={showList,open};','window.PurchaseReview={showList,open,__test:{allocations,rowHtml,state}};');
 const window={SAAS:{state:{business:{id:'bingo',settings:{country:'NZ'}}}}};vm.runInNewContext(script,{window,document:{getElementById:()=>null}});return window.PurchaseReview.__test;
}
test('confirmed review saves bill allocations through the shared atomic RPC',()=>{const source=fs.readFileSync('public/purchase-review.js','utf8'),sql=fs.readFileSync('supabase/migrations/20260924130000_v6190_purchase_review_core.sql','utf8');assert.match(source,/rpc\('v6190_review_purchase'/);assert.match(source,/state\.expanded\.delete\(bill\.id\)/);assert.match(sql,/if v_stock_enabled then/);assert.match(sql,/perform public\.se_review_invoice/);assert.match(sql,/v_ex_total<>v_bill\.ex_gst or v_gst_total<>v_bill\.gst_amount/)});
test('signed discounts use a validated charge target, and the optional register receives net costs',()=>{const sql=fs.readFileSync('supabase/migrations/20260925120000_v6190f_invoice_discounts.sql','utf8');assert.match(sql,/v_target:=p_rows->v_index/);assert.match(sql,/discount_for.*v_target->>'kind'/);assert.match(sql,/v_ex_total<>v_bill\.ex_gst or v_gst_total<>v_bill\.gst_amount/);assert.match(sql,/v_net_rows:=public\.v6190_net_purchase_rows\(p_rows\)/);assert.match(sql,/perform public\.se_review_invoice\(p_business_id,p_expense_id,v_se_revision,v_net_rows,p_reason\)/);assert.match(sql,/raise exception 'A discount exceeds its linked charge/)});
test('estimated report changes only after whole-bill review while source GST stays intact',()=>{
 const source=fs.readFileSync('public/financials.js','utf8');
 const body=source.slice(source.indexOf('function calcPeriod('),source.indexOf('\nfunction groupCosts(',source.indexOf('function calcPeriod(')));
 const bill={id:'b1',invoice_date:'2026-09-24',payment_status:'unpaid',lifecycle_state:'recorded',category_id:'cat',ex_gst:100,gst_amount:15,total_amount:115,is_split:false};
 const state={invoices:[],expenses:[bill],purchaseReviews:[],categories:[{id:'cat',name:'Supplies',group_name:'Operating Expenses'}],expenseLines:[],payrollTx:[]};
 const c={state,num:Number,inRange:()=>true,expenseRows:()=>state.expenses,mappingForCategory:()=> 'indirect_cost',expenseBusinessRatio:()=>1,allocatedExpense:e=>e,payrollCostRows:()=>[],estimatedTax:()=>0,payrollDate:()=>'',console};
 vm.runInNewContext(body+';globalThis.run=calcPeriod;',c);
 const before=c.run('2026-09-01','2026-09-30');assert.equal(before.indirect,100);assert.equal(before.gstPaid,15);
 state.purchaseReviews=[{expense_id:'b1',rows:[{kind:'regular',category_id:'cat',description:'Detergent',ex_gst:40,gst:6},{kind:'stock',category_id:'cat',description:'Candles',ex_gst:60,gst:9}]}];
 const after=c.run('2026-09-01','2026-09-30');assert.equal(after.indirect,40);assert.equal(after.gstPaid,15);assert.equal(bill.ex_gst,100);
 state.purchaseReviews=[{expense_id:'b1',rows:[{kind:'regular',category_id:'cat',description:'Charge',ex_gst:115,gst:17.25},{kind:'discount',discount_for:'regular',discount_target_index:0,category_id:'cat',description:'Invoice discount',ex_gst:-15,gst:-2.25}]}];
 const discounted=c.run('2026-09-01','2026-09-30');assert.equal(discounted.indirect,100);assert.equal(discounted.gstPaid,15);assert.equal(bill.ex_gst,100);
});
test('Review Items stays an optional Expenses page without changing bills and expenses',()=>{const html=fs.readFileSync('public/index.html','utf8'),expenses=fs.readFileSync('public/expenses.js','utf8'),stock=fs.readFileSync('public/stock-equipment.js','utf8');assert.match(html,/data-exp-tab="review"/);assert.match(html,/id="expense-panel-review"/);assert.doesNotMatch(html,/data-se-tab="review"/);assert.doesNotMatch(expenses,/data-exp-review/);assert.match(expenses,/switchTab\('bills'\)/);assert.doesNotMatch(stock,/se_review_invoice/)});
