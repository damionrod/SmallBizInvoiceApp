const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
test('Dashboard and Cash Book use the same two bank groups without changing historical movements',async()=>{
 const server=(await import(require.resolve('@sparticuz/chromium'))).default;
 const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH||await server.executablePath(),args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{
 const page=await browser.newPage({viewport:{width:390,height:844}});await page.setContent('<table><tbody id="finCashBookRows"></tbody></table>');
 await page.addScriptTag({path:path.join(__dirname,'../../public/bank-ledger-view.js')});
 const dash=fs.readFileSync(path.join(__dirname,'../../public/dashboard.js'),'utf8'),fin=fs.readFileSync(path.join(__dirname,'../../public/financials.js'),'utf8');
 const result=await page.evaluate(async({dashFn,cashFn})=>{
  const accounts=[{id:'old',account_code:'090',account_name:'Business Bank',account_type:'bank'},{id:'generic',account_code:'1000',account_name:'Bank',system_key:'bank'},{id:'empty',account_code:'1001',account_name:'BNZ Main'},{id:'anz',account_code:'1002',account_name:'ANZ'},{id:'main',account_code:'1003',account_name:'BNZ'}];
  const banks=[{id:'bnz',name:'BNZ',accounting_account_id:'main'},{id:'anz-bank',name:'ANZ',accounting_account_id:'anz'}];
  const aliases=['old','generic','empty'].map(accounting_account_id=>({bank_account_id:'bnz',accounting_account_id}));
  const ledger=[['090',5],['1000',20],['1003',100]].map(([account_code,credit])=>({account_code,credit,debit:0,journal_date:'2026-09-10',source_reference:'History-'+account_code,source_type:'supplier_payment',description:'Historical payment'}));ledger.push({account_code:'1002',credit:0,debit:1,journal_date:'2026-01-01',source_reference:'Opening',source_type:'bank_opening'});
  const client=()=>({rpc:async name=>({data:name==='frindly_bank_ledger_aliases_v1'?aliases:ledger}),from:table=>({select(){return this},eq(){return this},then(resolve){resolve({data:table==='accounting_accounts'?accounts:banks})}})});
  const num=v=>Number(v||0),state={businessId:'business-a'},q=id=>document.getElementById(id),esc=s=>String(s??''),money=n=>'$'+Number(n).toFixed(2),currentRange=()=>({from:'2026-09-01',to:'2026-11-02'});
  const dashboard=eval('('+dashFn+')'),cashbook=eval('('+cashFn+')');
  const rows=await dashboard(client(),'business-a','2026-11-02');await cashbook();
  document.querySelector('[data-cashbook-expand="closing"]').click();
  const labels=[...document.querySelectorAll('[data-cashbook-code]')].map(e=>e.textContent);
  document.querySelector('[data-cashbook-code="1003"]').click();
  return {rows,labels,cashRows:state.cashBookRows,detailCount:document.querySelectorAll('[data-cashbook-transaction="closing:1003"]').length,text:document.body.textContent};
 },{dashFn:dash.slice(dash.indexOf('async function bankBookBalances('),dash.indexOf('function bankBookWidget(')),cashFn:fin.slice(fin.indexOf('async function renderCashBook(){'),fin.indexOf('async function renderStatementCashFlows(){'))});
 assert.deepEqual(result.rows,[{name:'ANZ',value:1},{name:'BNZ',value:-125}]);assert.deepEqual(result.labels,['▸ ANZ','▸ BNZ']);assert.equal(result.cashRows.length,3);assert.equal(result.cashRows.every(x=>x.code==='1003'&&x.cat==='BNZ'),true);assert.equal(result.detailCount,3);assert.match(result.text,/\$-124.00/);
 }finally{await browser.close()}
});
