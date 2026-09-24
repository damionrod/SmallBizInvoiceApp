const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

function reviewHarness(){
 const script=fs.readFileSync('public/purchase-review.js','utf8').replace('window.PurchaseReview={open};','window.PurchaseReview={open,__test:{allocations,rowHtml,state}};');
 const window={SAAS:{state:{business:{id:'bingo'}}}};
 vm.runInNewContext(script,{window,document:{},console});
 return window.PurchaseReview.__test;
}
test('ordered page proposals retain individual item amounts, categories and use suggestions',()=>{
 const {allocations,rowHtml,state}=reviewHarness();
 const rows=allocations([{description:'Bucket',amount:20,amount_basis:'ex_gst',gst_treatment:'taxable',page_number:1,suggested_use:'supplies'},{description:'Mop',amount:80,amount_basis:'ex_gst',gst_treatment:'taxable',page_number:2,suggested_use:'stock'}],{ex_gst:100,gst_amount:15,total_amount:115,category_id:'original'});
 assert.equal(JSON.stringify(rows.map(x=>[x.description,x.page_number,x.kind,x.category_id,x.ex_gst,x.gst])),JSON.stringify([['Bucket',1,'supplies','original','20.00','3.00'],['Mop',2,'stock','original','80.00','12.00']]));
 state.categories=[{id:'original',name:'Original',group_name:'Operating Expenses'},{id:'changed',name:'Changed',group_name:'Direct Costs'}];
 assert.match(rowHtml(rows[0],0),/value="original" selected/);
 assert.match(rowHtml(rows[0],0),/value="changed"/);
 assert.match(rowHtml(rows[0],0),/name="use-0" value="supplies" checked/);
});
test('inclusive, zero GST and ambiguous mixed GST invoice items never invent mixed tax',()=>{
 const {allocations}=reviewHarness();
 const inclusive=allocations([{description:'A',amount:23,amount_basis:'incl_gst',gst_treatment:'taxable'},{description:'B',amount:92,amount_basis:'incl_gst',gst_treatment:'taxable'}],{ex_gst:100,gst_amount:15,total_amount:115});
 assert.equal(JSON.stringify(inclusive.map(x=>[x.ex_gst,x.gst])),JSON.stringify([['20.00','3.00'],['80.00','12.00']]));
 const zero=allocations([{description:'A',amount:50,amount_basis:'unknown',gst_treatment:'unknown'}],{ex_gst:50,gst_amount:0,total_amount:50});
 assert.equal(zero[0].gst,'0.00');
 const mixed=allocations([{description:'A',amount:80,amount_basis:'ex_gst',gst_treatment:'unknown'},{description:'B',amount:20,amount_basis:'ex_gst',gst_treatment:'no_gst'}],{ex_gst:100,gst_amount:12,total_amount:112});
 assert.equal(mixed[0].gst,'');
});
test('expenses entry, optional register and reported estimate are wired to the same confirmed review',()=>{
 const expenses=fs.readFileSync('public/expenses.js','utf8'),stock=fs.readFileSync('public/stock-equipment.js','utf8'),finance=fs.readFileSync('public/financials.js','utf8'),sql=fs.readFileSync('supabase/migrations/20260924130000_v6190_purchase_review_core.sql','utf8');
 assert.match(expenses,/data-exp-review/);assert.match(expenses,/window\.PurchaseReview\?\.open/);
 assert.match(stock,/Review in Expenses/);
 assert.match(finance,/purchase_invoice_reviews/);assert.match(finance,/if\(review\)\{for\(const row/);
 assert.match(sql,/if v_stock_enabled then/);assert.match(sql,/perform public\.se_review_invoice/);
 assert.match(sql,/v_ex_total<>v_bill\.ex_gst or v_gst_total<>v_bill\.gst_amount/);
});
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
});
