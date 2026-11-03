const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {chromium}=require('playwright');
test('money hub reuses linked receipt, bill, refund and settlement forms without posting',async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH||'/tmp/chromium',args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{const page=await browser.newPage({viewport:{width:390,height:844}});await page.setContent('<div id="finCashFlowBody" class="ct-workspace"></div><button id="finManualJournalTab">Journals</button>');
 await page.addStyleTag({path:path.join(__dirname,'../../public/styles-core.css')});await page.addStyleTag({path:path.join(__dirname,'../../public/styles.css')});
 await page.evaluate(()=>{
  window.crypto.randomUUID=()=>String(Math.random());window.calls=[];window.opened=[];window.canWrite=true;window.held=false;window.fixture=[];
  window.FinloCore={format:{money:n=>'$'+Number(n).toFixed(2)},ui:{toast:s=>window.message=s}};
  window.SAAS={state:{business:{id:'a',settings:{}}},client:()=>({rpc:async(name,args)=>{calls.push({name,args});if(name==='frindly_cash_snapshot'){if(window.held)await new Promise(r=>window.release=r);return {data:{can_write:canWrite,transactions:[],owners:[],categories:[]}};}if(name==='frindly_cash_ledger')return {data:fixture};if(name==='frindly_settlement_snapshot')return {data:{obligations:[{source_id:'refund',label:'GST refund',outstanding:100,account_id:'g',kind:'gst',direction:'refund'},{source_id:'gstpay',label:'GST payable',outstanding:20,account_id:'g',kind:'gst',direction:'payment'}]}};throw Error('Unexpected write '+name);},from:()=>({select(){return this},eq(){return this},order:async()=>({data:[{id:'bnz',name:'BNZ',is_default:true,accounting_account_id:'gl'}]})})})};
  window.FrindlyInvoices={moneyChoices:async()=>[{id:'inv',label:'INV-1 · Customer · $50'}],openPayment:async id=>opened.push(['invoice',id]),openRefunds:async()=>opened.push(['customer_refund'])};
  window.Expenses={moneyChoices:async kind=>[{id:kind==='refund'?'credit':'bill',label:kind}],openMoneyPayment:async id=>opened.push(['expense',id]),openMoneyRefund:async id=>opened.push(['supplier_refund',id]),switchTab:tab=>opened.push(['expense_tab',tab])};
  window.LiabilityPayments={open:async(kind,id)=>opened.push([kind,id])};window.switchView=async v=>{opened.push(['view',v]);return true;};document.getElementById('finManualJournalTab').onclick=()=>opened.push(['journal']);
 });
 await page.addScriptTag({path:path.join(__dirname,'../../public/cash-transactions.js')});
 const select=async(kind,route)=>{await page.evaluate(k=>CashTransactions.choose(k),kind);await page.click(`[data-money-route="${route}"]`);};
 await select('in','invoice_payment');await page.click('[data-money-pick="inv"]');assert.deepEqual(await page.evaluate(()=>opened.at(-1)),['invoice','inv']);assert.equal(await page.locator('#cashTransactionModal').evaluate(m=>m.classList.contains('open')),false);
 await select('out','expense_payment');await page.click('[data-money-pick="bill"]');assert.deepEqual(await page.evaluate(()=>opened.at(-1)),['expense','bill']);
 await select('in','supplier_refund');await page.click('[data-money-pick="credit"]');assert.deepEqual(await page.evaluate(()=>opened.at(-1)),['supplier_refund','credit']);
 await select('out','customer_refund');assert.deepEqual(await page.evaluate(()=>opened.at(-1)),['customer_refund']);
 await select('in','gst_refund');assert.equal(await page.locator('[data-money-pick="gstpay"]').count(),0);await page.click('[data-money-pick="refund"]');assert.deepEqual(await page.evaluate(()=>opened.at(-1)),['gst','refund']);
 await select('out','gst_payment');assert.equal(await page.locator('[data-money-pick="refund"]').count(),0);await page.click('[data-money-pick="gstpay"]');assert.deepEqual(await page.evaluate(()=>opened.at(-1)),['gst','gstpay']);
 await select('out','purchase');assert.deepEqual(await page.evaluate(()=>opened.slice(-2)),[['view','expenses'],['expense_tab','add']]);
 await select('in','capital_contribution');assert.equal(await page.inputValue('#ctPurpose'),'capital_contribution');await page.click('#ctCancel');
 await select('out','advanced');assert.match(await page.textContent('#ctContent'),/accountant/);await page.click('#ctAdvanced');assert.deepEqual(await page.evaluate(()=>opened.at(-1)),['journal']);
 await page.evaluate(()=>CashTransactions.choose('in'));await page.fill('#ctRouteSearch','GST');assert.equal(await page.locator('[data-money-route]').count(),1);await page.click('#ctCancel');
 assert.equal(await page.evaluate(()=>calls.some(c=>/record|post|match/.test(c.name))),false);
 // Source journals are grouped by bank, avoiding a double receipt from multiple bank lines.
 await page.evaluate(()=>{fixture=[{journal_id:'j',journal_date:'2026-11-01',account_code:'100',bank_name:'BNZ',source_type:'customer_payment',source_id:'p',description:'INV 1',debit:20,credit:0,status:'posted'},{journal_id:'j',journal_date:'2026-11-01',account_code:'100',bank_name:'BNZ',source_type:'customer_payment',source_id:'p',description:'INV 1',debit:30,credit:0,status:'posted'},{journal_id:'open',journal_date:'2026-11-01',bank_name:'BNZ',source_type:'bank_opening_balance',debit:100,credit:0,status:'posted'}];return CashTransactions.render('2026-11-01','2026-11-03');});
 assert.equal(await page.locator('#ctHistoryRows tr').count(),1);assert.match(await page.textContent('#ctHistoryRows'),/50.00/);assert.equal(await page.locator('[data-cash-journal="j"]').count(),1);await page.click('[data-cash-journal="j"]');assert.match(await page.textContent('#ctContent'),/INV 1/);await page.click('#ctCancel');
 await page.evaluate(()=>{canWrite=false;return CashTransactions.choose('out')});assert.match(await page.textContent('#ctError'),/permission/);assert.equal(await page.locator('[data-money-route]').count(),0);await page.click('#ctClose');
 await page.evaluate(()=>{canWrite=true;held=true;window.waiting=CashTransactions.choose('in')});await page.waitForFunction(()=>window.release);await page.evaluate(()=>{SAAS.state.business.id='b';release()});await page.evaluate(()=>waiting);assert.equal(await page.locator('[data-money-route]').count(),0);
 }finally{await browser.close();}
});
