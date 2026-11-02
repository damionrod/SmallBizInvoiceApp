const {test}=require('node:test');
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const path=require('node:path');
const fs=require('node:fs');

test('shared settlement dialog: banks, partial payments, allocation, history, retries and tenant guard',async()=>{
 const serverChromium=(await import(process.env.SETTLEMENT_CHROMIUM_MODULE||require.resolve('@sparticuz/chromium'))).default;
 const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH||await serverChromium.executablePath(),args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{
 const page=await browser.newPage({viewport:{width:390,height:844}});
 await page.setContent('<html><head></head><body><div id="toast"></div></body></html>');
 await page.addStyleTag({content:fs.readFileSync(path.join(__dirname,'../../public/styles.css'),'utf8')});
 await page.evaluate(()=>{
  window.calls=[];window.failSave=false;window.holdSave=false;let uuid=0;window.crypto.randomUUID=()=>`90000000-0000-0000-0000-${String(++uuid).padStart(12,'0')}`;
  window.FinloCore={format:{money:v=>'$'+Number(v).toFixed(2)},ui:{toast:m=>document.getElementById('toast').textContent=m}};
  window.fixture={business_id:'business-a',obligations:[{kind:'gst',source_id:'gst-a',account_id:'gst-account',label:'GST period',total:100,paid:0,outstanding:100,direction:'payment',notice:null}],payments:[]};
  const banks=[{id:'other',name:'Another bank',accounting_account_id:'gl-other'},{id:'default',name:'Default bank',is_default:true,accounting_account_id:'gl-default'},{id:'unmapped',name:'Unmapped bank'}];
  const client={from:()=>({select(){return this},eq(){return this},order:async()=>({data:banks})}),rpc:async(name,args)=>{
   if(name==='frindly_settlement_snapshot'){const data=structuredClone(window.fixture);data.obligations=(data.obligations||[]).filter(o=>(args.p_kind==='all'||o.kind===args.p_kind)&&(!args.p_source_id||o.source_id===args.p_source_id));if(window.holdStatusSnapshot&&args.p_kind==='wages')await new Promise(r=>window.releaseStatusSnapshot=r);return{data};}
   window.calls.push({name,args});
   if(window.holdSave)await new Promise(r=>window.releaseSave=r);
   if(window.failSave)return{error:{message:'Accounting period is locked'}};if(window.updateFixtureOnSave&&name==='frindly_record_liability_payment')for(const a of args.p_allocations){const row=window.fixture.obligations.find(o=>o.kind===a.kind&&o.source_id===a.source_id&&o.account_id===a.account_id);row.paid+=a.amount;row.outstanding-=a.amount;}
   return{data:'payment-a'};
  }};
  window.SAAS={state:{business:{id:'business-a',settings:{currency:'NZD'}}},client:()=>client};
 });
 await page.addScriptTag({path:path.join(__dirname,'../../public/liability-payments.js')});
 const open=()=>page.evaluate(()=>window.LiabilityPayments.open('gst','gst-a'));
 await open();assert.equal(await page.inputValue('#lpBank'),'default');assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=390),true);
 assert.equal(await page.$eval('#lpBank option[value="unmapped"]',o=>o.disabled),true);
 await page.fill('#lpAmount','101');await page.click('#lpSave');assert.match(await page.textContent('#lpError'),/within the outstanding/);assert.equal(await page.evaluate(()=>calls.length),0);
 await page.fill('#lpAmount','40');await page.selectOption('#lpBank','other');await page.fill('#lpDate','2026-10-01');await page.fill('#lpReference','Historical transfer');
 await page.evaluate(()=>{window.holdSave=true;document.getElementById('lpSave').click();document.getElementById('lpSave').click()});
 assert.equal(await page.evaluate(()=>calls.length),1);assert.equal(await page.locator('#lpSave').isDisabled(),true);
 await page.evaluate(()=>{window.holdSave=false;window.releaseSave()});await page.waitForFunction(()=>!document.getElementById('liabilityPaymentModal').classList.contains('open'));
 const call=await page.evaluate(()=>calls[0]);assert.equal(call.args.p_bank_id,'other');assert.equal(call.args.p_date,'2026-10-01');assert.equal(call.args.p_allocations[0].amount,40);assert.equal(call.args.p_reference,'Historical transfer');
 await open();await page.evaluate(()=>window.failSave=true);await page.click('#lpSave');await page.waitForFunction(()=>!document.getElementById('lpSave').disabled);assert.match(await page.textContent('#lpError'),/locked/);await page.click('#lpSave');await page.waitForFunction(()=>!document.getElementById('lpSave').disabled);assert.equal(await page.evaluate(()=>calls[1].args.p_request_id===calls[2].args.p_request_id),true);
 await page.evaluate(()=>{window.failSave=false;window.fixture.obligations[0].direction='refund';window.fixture.obligations[0].total=100;window.fixture.obligations[0].paid=40;window.fixture.obligations[0].outstanding=60;window.fixture.payments=[{payment_date:'2026-10-01',amount:40,reference:'first',matched:false}]});
 await open();assert.match(await page.textContent('#lpContent'),/Record Refund Received/);assert.match(await page.textContent('#lpContent'),/Partially Paid/);assert.match(await page.textContent('#lpContent'),/Waiting for bank match/);
 await page.evaluate(()=>window.SAAS.state.business.id='business-b');await page.click('#lpSave');assert.equal(await page.evaluate(()=>calls.length),3);
 await page.evaluate(()=>{window.SAAS.state.business.id='business-a';window.fixture.obligations=[1,2].map(i=>({kind:'ird',source_id:'run-'+i,account_id:'ird',label:'PAY-'+i,total:100,paid:0,outstanding:100,direction:'payment'}));window.fixture.payments=[];});
 await page.evaluate(()=>window.LiabilityPayments.open('ird'));
 await page.fill('#lpAllocation0','30');await page.fill('#lpAllocation1','70');assert.equal(await page.inputValue('#lpAmount'),'100.00');await page.click('#lpSave');await page.waitForFunction(()=>!document.getElementById('liabilityPaymentModal').classList.contains('open'));assert.equal(await page.evaluate(()=>calls[3].args.p_allocations.length),2);
 await page.evaluate(()=>{window.fixture.obligations=[{kind:'wages',source_id:'legacy',account_id:null,label:'PAY-0002',total:136.34,paid:136.34,outstanding:0,direction:'payment',notice:'Legacy payroll already credited bank'}]});await page.evaluate(()=>window.LiabilityPayments.open('wages','legacy'));assert.equal(await page.locator('#lpSave').count(),0);assert.match(await page.textContent('#lpContent'),/Bank posted \(legacy\)/);
 await page.evaluate(()=>{window.fixture.obligations=[];window.fixture.payments=[{id:'recorded-a',bank_account_id:'default',amount:40,direction:'payment',payment_date:'2026-10-01',matched:false,reference:'Wages'}]});
 await page.evaluate(()=>window.LiabilityPayments.reconcile({id:'bank-tx',bank_account_id:'default',amount:-40,transaction_date:'2026-10-02'},()=>window.matchDone=true));await page.selectOption('#lpExisting','recorded-a');await page.click('#lpMatch');await page.waitForFunction(()=>window.matchDone);assert.equal(await page.evaluate(()=>calls.at(-1).name),'frindly_reconcile_liability_payment');assert.equal(await page.evaluate(()=>calls.at(-1).args.p_payment_id),'recorded-a');

 // List actions use persisted balances, stay clickable, and update after successful saves.
 await page.evaluate(()=>{
  window.fixture.obligations=[
   {kind:'wages',source_id:'run-a',account_id:'wages',total:100,paid:0,outstanding:100,direction:'payment'},
   {kind:'ird',source_id:'run-a',account_id:'ird',total:20,paid:0,outstanding:20,direction:'payment'},
   {kind:'gst',source_id:'gst-a',account_id:'gst',total:100,paid:40,outstanding:60,direction:'payment'},
   {kind:'gst',source_id:'refund-a',account_id:'gst-in',total:10,paid:10,outstanding:0,direction:'refund'},
   {kind:'wages',source_id:'legacy-a',account_id:null,total:50,paid:50,outstanding:0,direction:'payment',notice:'Legacy bank credit'}
  ];window.fixture.payments=[];window.updateFixtureOnSave=true;
  const root=document.createElement('div');root.id='statusList';root.innerHTML=[['wageDesktop','wages','run-a'],['wageMobile','wages','run-a'],['irdStatus','ird','run-a'],['gstStatus','gst','gst-a'],['refundStatus','gst','refund-a'],['legacyStatus','wages','legacy-a'],['unknownStatus','wages','unknown']].map(([id,kind,source])=>`<button id="${id}" class="secondary" data-liability-kind="${kind}" data-liability-source="${source}">Record Payment</button>`).join('');document.body.append(root);
 });
 await page.evaluate(()=>window.LiabilityPayments.refreshButtons());
 assert.equal(await page.textContent('#wageDesktop'),'Record Payment · Wages');assert.equal(await page.textContent('#irdStatus'),'Record Payment · IRD');assert.equal(await page.textContent('#gstStatus'),'Partially Paid');assert.equal(await page.textContent('#refundStatus'),'Refund Received');assert.equal(await page.textContent('#legacyStatus'),'Bank posted · Wages');assert.equal(await page.textContent('#unknownStatus'),'Record Payment');
 await page.evaluate(()=>window.LiabilityPayments.open('wages','run-a'));await page.fill('#lpAmount','40');await page.click('#lpSave');await page.waitForFunction(()=>document.getElementById('wageDesktop').textContent==='Partially Paid · Wages');assert.equal(await page.textContent('#wageMobile'),'Partially Paid · Wages');assert.equal(await page.textContent('#irdStatus'),'Record Payment · IRD');
 await page.evaluate(()=>window.LiabilityPayments.open('wages','run-a'));await page.click('#lpSave');await page.waitForFunction(()=>document.getElementById('wageDesktop').textContent==='Paid · Wages');assert.equal(await page.textContent('#wageMobile'),'Paid · Wages');assert.equal(await page.locator('#wageDesktop').isDisabled(),false);
 await page.click('#wageDesktop');await page.waitForFunction(()=>document.getElementById('lpContent').textContent.includes('Outstanding $0.00'));assert.equal(await page.locator('#lpSave').count(),0);await page.click('#lpCancel');
 await page.evaluate(()=>{document.getElementById('wageDesktop').textContent='Record Payment';return window.LiabilityPayments.refreshButtons()});assert.equal(await page.textContent('#wageDesktop'),'Paid · Wages');
 await page.evaluate(async()=>{window.holdStatusSnapshot=true;document.getElementById('wageDesktop').textContent='New business';const pending=window.LiabilityPayments.refreshButtons();window.SAAS.state.business.id='business-b';window.releaseStatusSnapshot();await pending;window.holdStatusSnapshot=false;});assert.equal(await page.textContent('#wageDesktop'),'New business');

 }finally{await browser.close()}
});
