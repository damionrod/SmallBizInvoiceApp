const fs=require('fs'),assert=require('assert');
const h=fs.readFileSync('public/index.html','utf8'),a=fs.readFileSync('public/app.js','utf8'),f=fs.readFileSync('public/financials.js','utf8'),s=fs.readFileSync('public/saas.js','utf8'),c=fs.readFileSync('public/styles.css','utf8');
const C=[
['five primary financial choices',()=>['overview','pnl','cashflow','gst','budget'].forEach(x=>assert(h.includes(`data-fin-tab="${x}"`)))],
['financial primary labels',()=>['Summary','Profit &amp; Loss','Money In &amp; Out','GST','Budget'].forEach(x=>assert(h.includes(`>${x}</button>`)))],
['four more financial reports',()=>['balance','cashbook','ledger','trial'].forEach(x=>assert(h.includes(`data-fin-tab="${x}"`)))],
['more reports accessible control',()=>{assert(h.includes('id="finMoreReports"'));assert(h.includes('aria-expanded="false"'));assert(f.includes("addEventListener('toggle'"))}],
['five primary reports',()=>['performance','sales','expenses','jobs','payroll'].forEach(x=>assert(h.includes(`data-report-tab="${x}"`)))],
['accountant not ordinary report tab',()=>assert(!h.includes('data-report-tab="accountant"'))],
['accountant panel retained',()=>assert(h.includes('id="report-panel-accountant"'))],
['accountant two entry points',()=>{assert(h.includes('id="finAccountantBtn"'));assert(h.includes('id="accountForAccountant"'));assert(a.includes('window.openForMyAccountant=openForMyAccountant'));assert(s.includes("q('accountForAccountant')"))}],
['year end moved to accountant',()=>{const acct=h.indexOf('id="report-panel-accountant"'),year=h.indexOf('id="finYearEndRun"'),gst=h.indexOf('id="financial-panel-gst"');assert(year>acct);assert(!(year>gst&&year<acct));assert(h.includes('Check My Records'))}],
['business performance owns monthly performance once',()=>{assert.strictEqual((h.match(/data-report-widget="sales-performance"/g)||[]).length,1);const bp=h.indexOf('id="report-panel-performance"'),widget=h.indexOf('data-report-widget="sales-performance"');assert(widget>bp)}],
['aged receivables retained',()=>{assert(h.includes('id="agedReceivablesChart"'));assert(h.includes('id="agedReceivablesRows"'));assert(h.includes('Aged Receivables'))}],
['aged payables retained',()=>{assert(h.includes('id="agedPayablesChart"'));assert(h.includes('id="agedPayablesRows"'));assert(h.includes('Aged Payables'))}],
['expenses by job moved once',()=>{assert.strictEqual((h.match(/data-report-widget="expense-job"/g)||[]).length,1);assert(h.indexOf('data-report-widget="expense-job"')>h.indexOf('id="report-panel-jobs"'))}],
['jobs routes to existing job costing',()=>assert(a.includes("window.JobCosting?.showTab?.('saved')"))],
['module entitlement hiding retained and extended',()=>{assert(a.includes("expenseBtn.hidden=!expenseAllowed"));assert(a.includes("payrollBtn.hidden=!payrollAllowed"));assert(a.includes("jobsBtn.hidden=!jobsAllowed"))}],
['important export controls retained',()=>['finPnlCsv','finLedgerCsv','finTrialCsv','finCashBookCsv','finGstCsv','finGstExcel','finGstPdf','finBudgetCsv','reportExportCsv','expenseExportCsv','payrollReportCsv','downloadAccountantPack'].forEach(id=>assert(h.includes(`id="${id}"`)))],
['widget dragging retained',()=>{assert(a.includes("grid.addEventListener('pointerdown'"));assert(a.includes('saveReportWidgetOrder(grid)'));assert(h.includes('data-report-layout="performance"'));assert(h.includes('data-report-layout="jobs"'))}],
['mobile nav no hover dependency',()=>{assert(c.includes('@media(max-width:760px)'));assert(c.includes('.report-module-tabs{display:grid;grid-template-columns:1fr 1fr'));assert(c.includes('min-height:44px'))}],
['business switch resets report nav',()=>assert(a.includes("if(lastReportBusinessId!==bid){activeReportTab='performance';lastReportBusinessId=bid}"))],
['business switch resets financial nav',()=>assert(f.includes("if(state.businessId!==bid)state.activeTab='overview'"))],
['money in out wording only',()=>{assert(h.includes('<h2>Money In &amp; Out</h2>'));assert(h.includes('Cash movement based on payments recorded in Frindly'))}],
['no migration reference added',()=>assert(![h,a,f,s,c].some(x=>/create table|alter table|create policy|drop policy/i.test(x)))]
];
let n=0;for(const[x,fn]of C){try{fn();n++;console.log('PASS',x)}catch(e){console.error('FAIL',x,e.message);process.exitCode=1}}console.log(`${n}/${C.length} PASS`);
