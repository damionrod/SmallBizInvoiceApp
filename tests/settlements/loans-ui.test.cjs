const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {chromium}=require('playwright');

test('loan register shows lender schedule and opens the shared repayment form with the unpaid split',async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH,args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844}});
  await page.setContent('<div id="financial-panel-loans"></div>');
  for(const file of ['styles-core.css','styles.css'])await page.addStyleTag({path:path.join(__dirname,'../../public',file)});
  await page.evaluate(()=>{
   window.loanCalls=[];
   window.crypto.randomUUID=()=>String(Math.random());
   const loan=window.testLoan={id:'loan',account_id:'liability',bank_id:'bank',name:'Van loan',lender:'BNZ',original_amount:1000,owing:900,terms:{regular:250,rate:8,frequency:'monthly',classification:'scheduled',classificationFrom:'2026-10-01',schedule:[{due:'2026-10-01',total:25000,principal:20000,interest:5000,remaining:80000},{due:'2028-10-01',total:80000,principal:80000,interest:0,remaining:0}]}};
   const banks=[{id:'bank',name:'BNZ',is_default:true,accounting_account_id:'ledger'}];
   window.FinloCore={format:{money:n=>'$'+Number(n).toFixed(2)},ui:{toast(){}}};
   window.SAAS={state:{business:{id:'company',settings:{currency:'NZD'}}},client:()=>({
    rpc:async(name,args)=>{
     if(name==='frindly_loan_register')return {data:{loans:[loan],can_write:true}};
     if(name==='frindly_cash_snapshot')return {data:{can_write:true,entity_type:'company',transactions:[{id:'partial',purpose:'loan_repayment',status:'recorded',description:'Partial loan payment',amount:120,interest_amount:20,request_payload:{date:'2026-10-01',loan_id:'loan',loan_due_date:'2026-10-01'}}]}};
     if(name==='frindly_financeable_asset_bills')return {data:[{id:'bill',expense_number:'A-1',supplier_name:'Equipment seller',outstanding:500}]};
     window.loanCalls.push({name,args});
     return {data:'saved'};
    },
    from:()=>({select(){return this},eq(){return this},order:async()=>({data:banks})})
   })};
  });
  for(const file of ['loans-finance.js','cash-transactions.js'])await page.addScriptTag({path:path.join(__dirname,'../../public',file)});
  await page.evaluate(()=>LoansFinance.render());
  await page.click('[data-fin-loan="loan"]');
  assert.equal(await page.locator('details').filter({hasText:'Repayment schedule'}).getAttribute('open'),'');
  await page.getByRole('columnheader',{name:'Principal (capital)'}).waitFor();
  assert.match(await page.locator('#financial-panel-loans').innerText(),/Partially paid/);
  await page.click('[data-loan-instalment="0"]');
  assert.equal(await page.inputValue('#ctLoan'),'loan');
  assert.equal(await page.inputValue('#ctAmount'),'130');
  assert.equal(await page.inputValue('#ctInterest'),'30');
  assert.equal(await page.inputValue('#ctBank'),'bank');
  assert.equal(await page.evaluate(()=>{const dialog=document.querySelector('#cashTransactionModal .modal-box');return dialog.scrollWidth<=dialog.clientWidth+1;}),true);
  await page.click('#ctSave');
  await page.waitForFunction(()=>loanCalls.length===1);
  const [{name,args}]=await page.evaluate(()=>loanCalls);
  assert.equal(name,'frindly_record_cash_transaction');
  assert.equal(args.p_transaction.loan_due_date,'2026-10-01');
  assert.equal(args.p_transaction.interest_amount,30);
  assert.equal(args.p_transaction.loan_id,'loan');
  const split=await page.evaluate(async()=>Object.fromEntries(await LoansFinance.classifications('2026-11-04')));
  assert.deepEqual(split.liability,{current:100,longTerm:800});
  await page.evaluate(()=>{testLoan.owing=950;});
  const incomplete=await page.evaluate(async()=>Object.fromEntries(await LoansFinance.classifications('2026-11-04')));
  assert.equal(incomplete.liability,null);
  await page.click('#finDirectFinanceOpen');
  await page.selectOption('#finDirectFinance select[name=bill]','bill');
  assert.equal(await page.inputValue('#finDirectFinance input[name=amount]'),'500');
  await page.fill('#finDirectFinance input[name=amount]','400');
  await page.click('#finDirectFinance button[type=submit]');
  await page.waitForFunction(()=>loanCalls.length===2);
  const direct=await page.evaluate(()=>loanCalls[1]);
  assert.equal(direct.name,'frindly_record_direct_asset_finance');
  assert.equal(direct.args.p_expense,'bill');
  assert.equal(direct.args.p_loan,'loan');
  assert.equal(direct.args.p_amount,400);
 }finally{await browser.close();}
});
