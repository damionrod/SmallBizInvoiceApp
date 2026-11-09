const {test}=require('node:test'),path=require('node:path');
const assert=require('node:assert/strict'),fs=require('node:fs'),{chromium}=require('playwright');
test('deposit refund suggestion groups both lines and opens existing confirmation',async()=>{
 const browser=await chromium.launch({executablePath:process.env.SETTLEMENT_CHROMIUM_PATH,args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{
  const page=await browser.newPage({viewport:{width:390,height:820}});
  await page.setContent('<div id="brUnreconciledList"></div><div id="bankReconModal"><div id="brModalBody"></div></div>');
  await page.evaluate(()=>{
   window.out={id:'out',bank_account_id:'bank',amount:-706.48,transaction_date:'2026-10-22',payee:'CROSS COUNTRY RENTAL',reference:'4.34667E+11'};
   window.refund={...out,id:'refund',amount:408.46,transaction_date:'2026-10-24'};
   window.expense={id:'expense',expense_number:'EXP-0108',invoice_date:'2026-10-22',supplier_name:'Cross Country',total_amount:298.02,payment_status:'paid',outstanding_balance:0};
   window.calls=[];window.allocations=[];
   window.FinloCore={format:{money:v=>'$'+Number(v).toFixed(2)},ui:{toast:m=>window.message=m}};
   window.SAAS={state:{business:{id:'fixfast'}},client:()=>({
    from(table){const q={select:()=>q,eq:()=>q,gt:()=>q,neq:()=>q,or:()=>q,limit:()=>q,then(resolve){return Promise.resolve({data:table==='expenses'?[expense]:table==='bank_transactions'?[refund]:allocations}).then(resolve)}};return q},
    rpc:async(name,args)=>{calls.push({name,args});return {error:{message:'Fixture stopped after request'}}}
   })};
  });
  const source=fs.readFileSync(path.join(__dirname,'../../public/bank-reconciliation.js'),'utf8');
  await page.addScriptTag({content:source.replace('window.BankReconciliation={','window.fixture={state,renderQueue,depositRefundSuggestions};window.BankReconciliation={')});
  await page.evaluate(()=>{fixture.state.transactions=[refund,out];fixture.state.depositRefundExpenses=[expense];fixture.renderQueue()});
  assert.equal(await page.locator('.br-matchset').count(),1);
  assert.equal(await page.locator('.br-match-bank-card').count(),2);
  assert.match(await page.locator('.br-matchset').textContent(),/EXP-0108/);
  assert.deepEqual(await page.evaluate(()=>[...document.querySelectorAll('.br-match-bank-card b')].map(x=>x.textContent)),['−$706.48','$408.46']);
  await page.click('[data-br-deposit-suggestion]');
  assert.equal(await page.inputValue('#brDepositRefundTx'),'refund');
  assert.equal(await page.inputValue('#brDepositRefundExpense'),'expense');
  assert.equal(await page.evaluate(()=>calls.length),0);
  await page.click('#brDepositRefundSave');
  assert.deepEqual(await page.evaluate(()=>calls[0]),{name:'v61107i_reconcile_expense_deposit_refund',args:{p_money_out_transaction_id:'out',p_refund_transaction_id:'refund',p_expense_id:'expense',p_note:null}});
  await page.click('#brDepositRefundCancel');
  await page.click('[data-br-dismiss]');
  assert.equal(await page.locator('.br-matchset').count(),2);
  const rejected=await page.evaluate(()=>{
   const test=(bank,exp=[expense],reserved=[])=>fixture.depositRefundSuggestions(bank,exp,new Set(reserved),new Set()).length;
   return [test([out,refund,{...refund,id:'other'}]),test([out,refund],[expense,{...expense,id:'duplicate'}]),test([out,{...refund,bank_account_id:'different'}]),test([out,{...refund,amount:408.45}]),test([out,refund],[expense],['refund']),test([out,{...refund,transaction_date:'2026-10-21'}])];
  });
  assert.deepEqual(rejected,[0,0,0,0,0,0]);
  console.log('Pass: paired suggestion, confirmation, existing RPC, dismissal and ambiguous/ineligible pairs');
 }finally{await browser.close()}
});
