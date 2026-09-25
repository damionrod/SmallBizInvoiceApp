const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync('public/app.js','utf8');
const saveSource=source.slice(source.indexOf('async function save(){'),source.indexOf('\nasync function allInvoices()',source.indexOf('async function save(){')));

async function saveWithCustomer(formAddress,customerAddress,wasEdit){
 const customer={id:'saved-customer',name:'Example Customer',address:customerAddress,email:'billing@example.nz'};
 const invoice={id:wasEdit?'draft-invoice':null,customer_id:customer.id,customer_name:customer.name,customer_address:formAddress,customer_email:'other@example.nz'};
 let saved,recurring;
 const window={SAAS:{canCreateInvoice:async()=>({ok:true}),refreshUsage:()=>{}}};
 const context={window,currentId:invoice.id,selectedCustomerId:customer.id,validate:()=>true,payload:()=>({...invoice}),
  ensureInvoiceCustomer:async()=>customer,billingContact:()=>null,
  persistInvoice:async(p,isEdit)=>{saved={...p,isEdit};return{id:p.id||'new-invoice',...p}},
  syncRecurringRule:async x=>{recurring=x},console};
 vm.runInNewContext(saveSource+';globalThis.run=save;',context);
 const result=await context.run();
 return{result,saved,recurring,customer};
}
test('saving a new invoice retains an edited invoice address and does not change its customer contact',async()=>{
 const {saved,recurring,customer}=await saveWithCustomer('Job site, Wellington','Head office, Porirua',false);
 assert.equal(saved.customer_id,customer.id);
 assert.equal(saved.customer_address,'Job site, Wellington');
 assert.equal(customer.address,'Head office, Porirua');
 assert.equal(recurring.customer_address,'Job site, Wellington');
});
test('draft edit and unchanged address preserve the chosen invoice address',async()=>{
 const edited=await saveWithCustomer('New billing address','Original billing address',true);
 assert.equal(edited.saved.customer_address,'New billing address');
 assert.equal(edited.saved.isEdit,true);
 const unchanged=await saveWithCustomer('Original billing address','Original billing address',false);
 assert.equal(unchanged.saved.customer_address,'Original billing address');
});
test('invoice preview and PDF use the saved invoice address',()=>{
 assert.match(source,/esc\(inv\.customer_address\)\.replace/);
 assert.match(source,/host\.innerHTML=previewHtml\(inv\)/);
});
test('invoice PDF renders sharper lossless pages and keeps the logo proportions',async()=>{
 const css=fs.readFileSync('public/styles.css','utf8');
 assert.match(css,/\.invoice-pdf-render-host \.invoice-pdf-sheet \.preview-top img\{[^}]*width:auto;height:auto;max-width:125px;max-height:76px;object-fit:contain;flex:none/);
 const pdfSource=source.slice(source.indexOf('async function makePdf('),source.indexOf('\nfunction previewHtml(',source.indexOf('async function makePdf(')));
 const calls=[];
 const sheet={scrollWidth:794,scrollHeight:1000,querySelectorAll:()=>[],classList:{add:()=>{}}};
 const host={firstElementChild:sheet,remove:()=>{}};
 const canvas={width:1985,height:2800};
 const document={fonts:{ready:Promise.resolve()},body:{appendChild:()=>{}},createElement:tag=>tag==='div'?host:{width:0,height:0,getContext:()=>({fillRect:()=>{},drawImage:()=>{}}),toDataURL:type=>{calls.push(['image',type]);return 'data:image/png;base64,AA=='}}};
 const window={jspdf:{jsPDF:class{addImage(...args){calls.push(['pdf',...args])}save(){}}},html2canvas:async(s,options)=>{assert.equal(s,sheet);assert.equal(options.scale,2.5);return canvas}};
 const context={window,document,previewHtml:()=>'<div></div>',payload:()=>({}),console};
 vm.runInNewContext(pdfSource+';globalThis.run=makePdf;',context);
 await context.run({invoice_number:'INV-1',customer_name:'Customer'});
 assert.deepEqual(calls[0],['image','image/png']);
 assert.equal(calls[1][2],'PNG');
 assert.equal(calls[1][3],10);
 assert.equal(calls[1][5],190);
});
