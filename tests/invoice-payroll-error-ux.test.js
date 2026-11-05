const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const read=name=>fs.readFileSync(path.join(__dirname,'../public',name),'utf8');
const app=read('app.js'),payroll=read('payroll.js');
const take=(source,start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));

function sendFixture(email){
  const counts={save:0,reset:0,clearDraft:0,send:0,render:0},errors=[],notices=[];
  const elements={customerEmail:{value:email,focus(){this.focused=true}},emailInvoice:{textContent:'Send Invoice',disabled:false,classList:{add(){},remove(){}}}};
  const context={
    $:id=>elements[id],invoiceSendBusy:false,sb:{},window:{FrindlyDialogs:{alert:message=>{errors.push(message);return new Promise(()=>{})}},DraftProtection:{clear(){counts.clearDraft++}},SAAS:{invokeAuthenticatedDocumentFunction:async()=>{counts.send++;return {error:null}}}},
    save:async()=>{counts.save++;return {id:'invoice-1',customer_email:email}},newInvoice:async()=>{counts.reset++},renderInvoiceList:async()=>{counts.render++},
    makePdf:async()=>({blob:{}}),markInvoiceEmailed:async inv=>inv,refreshInvoiceFromCloud:async inv=>inv,
    edgeFunctionErrorMessage:async error=>error.message,toast:message=>notices.push(message),setTimeout:fn=>fn(),console
  };
  vm.createContext(context);
  vm.runInContext(take(app,'function invoiceError(','function flashButton('),context);
  vm.runInContext(take(app,"$('emailInvoice').onclick=",'document.querySelectorAll(\'[data-invoice-list-tab]\')'),context);
  return {context,elements,counts,errors,notices,send:()=>elements.emailInvoice.onclick()};
}

for(const email of ['', '   '])test(`missing email ${JSON.stringify(email)} preserves the form without saving`,async()=>{
  const f=sendFixture(email);await f.send();
  assert.deepEqual(f.errors,['Enter a customer email address']);
  assert.deepEqual(f.counts,{save:0,reset:0,clearDraft:0,send:0,render:0});
  assert.equal(f.elements.customerEmail.focused,true);
  assert.equal(f.elements.emailInvoice.disabled,false);
  assert.equal(f.elements.emailInvoice.textContent,'Send Invoice');
  assert.equal(f.context.invoiceSendBusy,false);
});

test('valid email follows the existing save, send and reset path once',async()=>{
  const f=sendFixture('customer@example.com');await f.send();
  assert.equal(f.counts.save,1);assert.equal(f.counts.send,1);assert.equal(f.counts.reset,1);
  assert.deepEqual(f.errors,[]);assert.match(f.notices[0],/emailed successfully/);
  assert.equal(f.context.invoiceSendBusy,false);assert.equal(f.elements.emailInvoice.disabled,false);
});

test('send failure remains dismissible and does not reset the invoice',async()=>{
  const f=sendFixture('customer@example.com');
  f.context.window.SAAS.invokeAuthenticatedDocumentFunction=async()=>({error:{message:'Email service unavailable'}});
  await f.send();
  assert.equal(f.counts.reset,0);assert.match(f.errors[0],/email failed: Email service unavailable/);
  assert.equal(f.elements.emailInvoice.disabled,false);
});

test('payroll validation reports a persistent error without writing data',async()=>{
  const errors=[];
  const context={$:()=>({value:''}),calcHours:()=>0,window:{FrindlyDialogs:{alert:message=>{errors.push(message);return new Promise(()=>{})}}}};
  vm.createContext(context);
  vm.runInContext(payroll.match(/const payrollError=message=>\{[^\n]+/)[0],context);
  vm.runInContext(take(payroll,'  async function saveTimesheet(){','  async function deleteTimesheet('),context);
  assert.equal(await context.saveTimesheet(),undefined);
  assert.deepEqual(errors,['Employee and date are required.']);
});

test('existing error dialog stays open without a timer and closes on acknowledgement',async()=>{
  const elements=[];
  const document={activeElement:null,documentElement:{},getElementById:id=>elements.find(el=>el.id===id),createElement:tag=>{
    const el={tag,children:[],isConnected:true,listeners:{},setAttribute(){},append(...nodes){this.children.push(...nodes)},appendChild(node){this.children.push(node)},addEventListener(type,fn){this.listeners[type]=fn},removeEventListener(type){delete this.listeners[type]},focus(){document.activeElement=this},remove(){this.isConnected=false}};
    elements.push(el);return el;
  }};
  document.body=document.createElement('body');document.head=document.createElement('head');
  const context={document,window:{alert(){}},setTimeout(){throw new Error('Persistent errors must not schedule dismissal')}};
  vm.createContext(context);vm.runInContext(read('frindly-dialogs.js'),context);
  let dismissed=false;const pending=context.window.FrindlyDialogs.alert('Please correct this error').then(()=>{dismissed=true});
  await Promise.resolve();assert.equal(dismissed,false);
  const overlay=elements.find(el=>el.className==='frindly-dialog-overlay');assert.equal(overlay.isConnected,true);
  elements.find(el=>el.tag==='button'&&el.textContent==='OK').listeners.click();await pending;
  assert.equal(dismissed,true);assert.equal(overlay.isConnected,false);
});
