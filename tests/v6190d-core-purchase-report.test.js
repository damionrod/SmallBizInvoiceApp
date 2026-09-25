const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

const source=fs.readFileSync('public/financials.js','utf8');
const begin=source.indexOf('function confirmedPurchaseAllocation(');
const end=source.indexOf('\nfunction renderPurchaseAllocations(',begin);
assert.ok(begin>0&&end>begin);

test('core report uses latest confirmed rows once and works without Stock & Equipment',()=>{
 const bills=[
  {id:'first',invoice_date:'2026-09-10',payment_status:'unpaid',lifecycle_state:'recorded',ex_gst:100},
  {id:'second',invoice_date:'2026-09-11',payment_status:'paid',lifecycle_state:'recorded',ex_gst:60},
  {id:'unreviewed',invoice_date:'2026-09-12',payment_status:'unpaid',lifecycle_state:'recorded',ex_gst:40},
  {id:'void',invoice_date:'2026-09-13',payment_status:'paid',lifecycle_state:'voided',ex_gst:900}
 ];
 const state={purchaseReviews:[
  {expense_id:'first',revision:2,rows:[{kind:'regular',ex_gst:20},{kind:'stock',ex_gst:40},{kind:'supplies',ex_gst:30},{kind:'equipment',ex_gst:10}]},
  {expense_id:'first',revision:1,rows:[{kind:'regular',ex_gst:100}]},
  {expense_id:'second',revision:1,rows:[{kind:'regular',ex_gst:30},{kind:'low_value_equipment',ex_gst:30}]},
  {expense_id:'void',revision:1,rows:[{kind:'regular',ex_gst:900}]}
 ]};
 const sandbox={state,expenseRows:()=>bills.filter(x=>x.lifecycle_state==='recorded'),expenseBusinessRatio:x=>x.id==='second'?.5:1,num:Number,Object};
 vm.runInNewContext(source.slice(begin,end)+';globalThis.run=confirmedPurchaseAllocation',sandbox);
 const a=sandbox.run('2026-09-01','2026-09-30');
 assert.equal(JSON.stringify(a.totals),JSON.stringify({regular:35,stock:40,supplies:30,equipment:10,low_value_equipment:15}));
 assert.equal(a.reviewed,2);assert.equal(a.unreviewed,1);
 assert.equal(bills[0].ex_gst,100);
});

test('missing core reviews never silently revert Financials Summary to the original bill',()=>{
 assert.match(source,/state\.purchaseReviewError=page\.error\.message/);
 assert.match(source,/if\(state\.purchaseReviewError\)return;const \{from,to\}=currentRange\(\)/);
 assert.match(fs.readFileSync('public/index.html','utf8'),/id="finPurchaseReviewError"/);
});
