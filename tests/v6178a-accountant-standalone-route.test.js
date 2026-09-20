const fs=require('fs'),assert=require('assert');
const h=fs.readFileSync('public/index.html','utf8'),a=fs.readFileSync('public/app.js','utf8'),s=fs.readFileSync('public/saas.js','utf8');
const C=[
['standalone accountant view',()=>assert(h.includes('id="view-accountant" class="view"'))],
['accountant panel retained',()=>assert(h.includes('id="report-panel-accountant"'))],
['accountant no longer report panel',()=>assert(!h.includes('class="report-panel" id="report-panel-accountant"'))],
['reports view remains',()=>assert(h.includes('id="view-reports" class="view"'))],
['direct accountant route',()=>assert(a.includes("function openForMyAccountant(){window.switchView?.('accountant')}"))],
['old reports route removed',()=>assert(!a.includes("window.switchView?.('reports');switchReportTab('accountant')"))],
['accountant init on standalone view',()=>assert(a.includes("if(v==='accountant'){if(!$('financialsNav')?.hidden)window.Financials?.init?.();window.AccountantCentre?.onShow?.()}"))],
['financials entry retained',()=>assert(h.includes('id="finAccountantBtn"'))],
['account menu entry retained',()=>assert(h.includes('id="accountForAccountant"'))],
['accountant centre ids retained',()=>['accountantFrom','accountantTo','prepareXeroExport','downloadAccountantPack','accountingMappingRows','accountingExportHistory','finYearEndRun'].forEach(id=>assert(h.includes(`id="${id}"`)))],
['cache loader bumped',()=>assert(s.includes('app.js?v=61.79-phase-b'))],
];let n=0;for(const[x,f]of C){try{f();n++;console.log('PASS',x)}catch(e){console.error('FAIL',x,e.message);process.exitCode=1}}console.log(`${n}/${C.length} PASS`);
