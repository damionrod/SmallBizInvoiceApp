const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const app=fs.readFileSync(path.join(__dirname,'../public/app.js'),'utf8');
const html=fs.readFileSync(path.join(__dirname,'../public/index.html'),'utf8');
const css=fs.readFileSync(path.join(__dirname,'../public/styles.css'),'utf8');
const source=(a,b)=>app.slice(app.indexOf(a),app.indexOf(b,app.indexOf(a)));
const code=source('function activeCountry(){','function updateTaxLabels(){')+source('function validate(){','function makeLocalId(){');
function context(country,currency){
  const nodes={invoiceAuTaxClassLabel:{hidden:false,style:{display:'block',setProperty(name,value){this[name]=value},removeProperty(name){this[name]=''}}},invoiceAuTaxClass:{value:'gst_taxable',querySelector:()=>({disabled:false,textContent:''})},invoiceAuTaxHint:{textContent:'',classList:{toggle(){}}},invoiceDate:{value:'2026-09-25'},customerName:{value:'Test'},customerEmail:{value:''}};
  let rpc=0;let message='';const sb={rpc:async(name)=>{rpc++;return{data:name==='v61105_effective_tax_status'?{jurisdiction:'NZ',gst_registered:true,effective_rate_percent:15,statutory_rate_percent:15,effective_from:'2026-01-01'}:{jurisdiction:'AU',gst_registered:true,gst_rate_percent:10,effective_from:'2026-01-01'}}}};
  const c={window:{SAAS:{state:{business:{id:'company-one',settings:{country,currency}}}}},settings:{currency:'NZD'},invoiceTaxRuntime:{ready:false},sb,$:id=>nodes[id],isoDate:()=> '2026-09-25',num:Number,taxConfig:()=>({gstRate:15}),updateTaxLabels(){},recalc(){},toast:s=>{message=s},items:[{qty:1,unit_price:10,description:'Test'}]};
  vm.createContext(c);vm.runInContext(code,c);
  return {c,nodes,called:()=>rpc,message:()=>message};
}
test('NZ invoices hide Australian selector even when labels have display styling',async()=>{
  assert.match(html,/id="invoiceAuTaxClassLabel" hidden style="display:none"/);
  assert.match(css,/#view-create \.invoice-details-card\.invoice-details-compact label#invoiceAuTaxClassLabel\[hidden\]\{display:none!important\}/);
  const x=context('NZ','NZD');await x.c.refreshInvoiceTaxRuntime();
  assert.equal(x.nodes.invoiceAuTaxClassLabel.hidden,true);
  assert.equal(x.nodes.invoiceAuTaxClassLabel.style.display,'none');
  assert.equal(x.called(),1);
  assert.equal(x.c.invoiceTaxRuntime.source,'v61105_effective_tax_status');
  assert.equal(x.c.invoiceTaxRuntime.gstRate,15);
  assert.equal(x.c.validate(),true);
});
test('AU business in AUD retains registered GST lookup and classification',async()=>{
  const x=context('AU','AUD');await x.c.refreshInvoiceTaxRuntime();
  assert.equal(x.nodes.invoiceAuTaxClassLabel.hidden,false);
  assert.equal(x.nodes.invoiceAuTaxClassLabel.style.display,'');
  assert.equal(x.called(),1);
  assert.equal(x.nodes.invoiceAuTaxClass.value,'gst_taxable');
  assert.equal(x.c.invoiceTaxRuntime.gstRate,10);
  assert.equal(x.c.validate(),true);
});
test('AU business in a different currency cannot request AU GST or save',async()=>{
  const x=context('AU','NZD');await x.c.refreshInvoiceTaxRuntime();
  assert.equal(x.called(),0);
  assert.equal(x.nodes.invoiceAuTaxClassLabel.hidden,true);
  assert.equal(x.nodes.invoiceAuTaxClassLabel.style.display,'none');
  assert.equal(x.c.invoiceTaxRuntime.ready,false);
  assert.match(x.c.invoiceTaxRuntime.error,/currency to be AUD/);
  assert.equal(x.c.validate(),false);
  assert.match(x.message(),/Update Account Settings/);
});
test('invoice totals preserve discount, fee, payment and zero-rated behavior',async()=>{
 const x=context('NZ','NZD');await x.c.refreshInvoiceTaxRuntime();
 vm.runInContext(source('function calcTotals(', 'function recalc('),x.c);
 x.c.taxConfig=()=>({gstRate:15,extraFeeEnabled:true,extraFeeRate:10});
 const rows=[{qty:2,unit_price:100}];
 const total=x.c.calcTotals(rows,{},'percent',25,40);
 assert.equal(total.subtotal,200);assert.equal(total.discountAmount,50);
 assert.equal(total.extraFee,15);assert.equal(total.gst,24.75);
 assert.equal(total.total,189.75);assert.equal(total.balanceDue,149.75);
 assert.equal(x.c.calcTotals(rows,{},'fixed',300,0).total,0);
 assert.equal(x.c.calcTotals(rows,{},'percent',0,1000).balanceDue,0);
 x.c.invoiceTaxRuntime.gstRegistered=false;x.c.invoiceTaxRuntime.gstRate=0;
 assert.equal(x.c.calcTotals(rows,{},'percent',0,0).gst,0);
});
test('unchanged amount calculation uses NZ GST for NZ and configured AU rate for AU in AUD',async()=>{
  const nz=context('NZ','NZD');const au=context('AU','AUD');
  vm.runInContext(source('function calcTotals(', 'function recalc('),nz.c);
  vm.runInContext(source('function calcTotals(', 'function recalc('),au.c);
  await nz.c.refreshInvoiceTaxRuntime();await au.c.refreshInvoiceTaxRuntime();
  for(const x of [nz,au]){
    x.nodes.discountType={value:'percent'};x.nodes.discountValue={value:'0'};x.nodes.amountPaid={value:'0'};
  }
  assert.equal(nz.c.calcTotals([{description:'Service',qty:1,unit_price:100}]).gst,15);
  assert.equal(au.c.calcTotals([{description:'Service',qty:1,unit_price:100}]).gst,10);
});
