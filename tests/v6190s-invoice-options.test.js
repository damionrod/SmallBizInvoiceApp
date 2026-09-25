const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../public/app.js'),'utf8');
const body=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
function context(){
 const nodes={};const $=id=>nodes[id]??=( {value:'',checked:false,open:true,style:{},textContent:''} );
 const c={$,currentId:null,selectedCustomerId:null,sourceQuoteId:null,sourceJobCostingId:null,settings:{dueDays:3,trading:'Example',invoiceText:{defaultNote:'Thank you'}},
  nextInvoiceNo:async()=> 'INV-0001',isoDate:()=> '2026-09-25',addDays:()=> '2026-09-28',refreshInvoiceTaxRuntime:async()=>{},
  addItem:()=>{},updateTaxLabels:()=>{},recalc:()=>{},refreshCustomerPickers:()=>{},renderItems:()=>{},switchView:()=>{},toast:()=>{},
  num:Number,isIssuedInvoice:()=>false};
 vm.createContext(c);
 vm.runInContext(body('async function newInvoice(){','function addItem('),c);
 vm.runInContext(body('async function loadForEdit(x){','let lastInvoiceView='),c);
 return {c,$};
}
test('new invoice keeps default fields and closes only the optional panel',async()=>{
 const {c,$}=context();await c.newInvoice();
 assert.equal($('invoiceNumber').value,'INV-0001');
 assert.equal($('invoiceDate').value,'2026-09-25');
 assert.equal($('dueDate').value,'2026-09-28');
 assert.equal($('customerNote').value,'Thank you');
 assert.equal($('invoiceMoreOptions').open,false);
});
test('draft with discount, payment or recurrence opens options with saved values',async()=>{
 for(const option of [{discount_value:5,discount_type:'fixed'},{amount_paid:12},{recurring:true,recurring_frequency:'monthly'}]){
  const {c,$}=context();$('invoiceMoreOptions').open=false;
  await c.loadForEdit({id:'draft',invoice_number:'INV-0005',invoice_date:'2026-09-20',due_date:'2026-09-27',customer_name:'Example',customer_note:'Saved note',items:[],...option});
  assert.equal($('invoiceMoreOptions').open,true);
  assert.equal($('customerNote').value,'Saved note');
  if(option.discount_value)assert.equal($('discountValue').value,5);
  if(option.amount_paid)assert.equal($('amountPaid').value,12);
  if(option.recurring)assert.equal($('recurringOptions').style.display,'block');
 }
});
test('draft without optional amounts keeps options closed while retaining message',async()=>{
 const {c,$}=context();await c.loadForEdit({id:'draft',invoice_number:'INV-0006',invoice_date:'2026-09-20',due_date:'2026-09-27',customer_note:'Visible in message field',items:[]});
 assert.equal($('invoiceMoreOptions').open,false);
 assert.equal($('customerNote').value,'Visible in message field');
});
