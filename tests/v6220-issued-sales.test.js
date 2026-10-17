const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../public/app.js'),'utf8');
function take(start,end){const a=source.indexOf(start),b=source.indexOf(end,a);assert.ok(a>=0&&b>a,`Missing source boundary: ${start}`);return source.slice(a,b)}
function fixture(invoices=[]){
  const elements={},charts={},context={
    $:id=>elements[id]??=( {value:id==='reportFrom'?'2026-10-01':id==='reportTo'?'2026-10-31':'',textContent:'',innerHTML:''} ),
    allInvoices:async()=>invoices,currentReportInvoices:[],num:v=>Number(v)||0,money:v=>Number(v).toFixed(2),esc:String,
    monthKey:v=>v.slice(0,7),monthLabel:String,invoiceCalcFrom:x=>({extraFee:Number(x.extra_fee)||0}),activeReportTab:'sales',toast(){},
    renderSalesChart(months,groups){charts.months=months;charts.groups=groups},renderBusinessPerformance:async()=>{},
    renderInvoiceIssuedPaidChart(months,rows){charts.activity=rows},renderAgedReceivables(rows){charts.receivables=rows},
  };
  vm.createContext(context);
  vm.runInContext(take('function isC1ManagedInvoice(inv)','function invoiceOwnerStatus('),context);
  vm.runInContext(take('function isSalesActivityInvoice(inv)','async function runReport()'),context);
  vm.runInContext(take('async function runReport()','async function renderShareholderSummary('),context);
  return {context,elements,charts};
}
test('sales activity includes issued and legacy records while drafts, voids and unknown managed states are excluded',()=>{
  const {context}=fixture();
  for(const [inv,expected] of [
    [{lifecycle_version:1,lifecycle_state:'issued'},true],
    [{lifecycle_version:1,lifecycle_state:'draft'},false],
    [{lifecycle_version:1,lifecycle_state:'voided'},false],
    [{lifecycle_version:1,lifecycle_state:'unexpected'},false],
    [{lifecycle_version:1,lifecycle_state:null},false],
    [{lifecycle_version:null,lifecycle_state:null},true],
    [{invoice_number:'legacy'},true],
    [{lifecycle_version:null,lifecycle_state:'draft'},false],
    [{lifecycle_version:1,lifecycle_state:'issued',voided_at:'2026-10-17T00:00:00Z'},false],
  ])assert.equal(context.isSalesActivityInvoice(inv),expected,JSON.stringify(inv));
});
test('actual report totals, rows, charts and receivables share the lifecycle rule without changing invoice amounts',async()=>{
  const base={invoice_date:'2026-10-16',total:115,gst:15,amount_paid:0,lifecycle_version:1,lifecycle_state:'issued'};
  const invoices=[{...base,id:'issued'},{...base,id:'draft',lifecycle_state:'draft',total:999},{...base,id:'voided',lifecycle_state:'voided',total:888},{...base,id:'legacy',total:230,gst:30,lifecycle_version:null,lifecycle_state:null},{...base,id:'older-issued',invoice_date:'2026-09-20'}];
  const before=JSON.stringify(invoices),f=fixture(invoices);await f.context.runReport();
  assert.equal(f.elements.reportNet.textContent,'300.00');assert.equal(f.elements.reportGst.textContent,'45.00');
  assert.equal(f.elements.reportTotal.textContent,'345.00');assert.equal(f.elements.reportCount.textContent,2);
  assert.deepEqual(Array.from(f.context.currentReportInvoices,x=>x.id),['issued','legacy']);
  assert.deepEqual(Array.from(f.charts.activity,x=>x.id),['issued','legacy']);
  assert.deepEqual(Array.from(f.charts.receivables,x=>x.id),['issued','legacy','older-issued']);
  assert.match(f.elements.reportPeriodLabel.textContent,/Issued sales/);assert.equal(JSON.stringify(invoices),before);
});
test('an empty issued-sales period shows zero instead of counting a saved draft',async()=>{
  const f=fixture([{invoice_date:'2026-10-16',total:322,gst:42,lifecycle_state:'draft',lifecycle_version:1}]);
  await f.context.runReport();assert.equal(f.elements.reportTotal.textContent,'0.00');assert.equal(f.elements.reportCount.textContent,0);
});
