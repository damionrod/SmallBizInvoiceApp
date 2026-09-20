const fs=require('fs'),assert=require('assert');
const a=fs.readFileSync('public/app.js','utf8'),s=fs.readFileSync('public/saas.js','utf8'),h=fs.readFileSync('public/index.html','utf8'),c=fs.readFileSync('public/styles.css','utf8');
const C=[
['aged chart widget',()=>assert(h.includes('data-report-widget="aged-receivables-chart"'))],
['aged table widget',()=>assert(h.includes('data-report-widget="aged-receivables-table"'))],
['all 5 buckets',()=>['Current (Not Overdue)','1–30 Days Past Due','31–60 Days Past Due','61–90 Days Past Due','91+ Days Past Due'].forEach(x=>assert(h.includes(x)))],
['total owed',()=>assert(h.includes('Total Owed'))],
['uses balance due',()=>assert(a.includes('Math.max(0,c.balanceDue)'))],
['uses due date',()=>assert(a.includes("inv.due_date?new Date(inv.due_date+'T12:00:00')"))],
['all invoices source',()=>assert(a.includes('renderAgedReceivables(allInvoiceRows)'))],
['chart renderer',()=>assert(a.includes('function renderAgedReceivables(invoices)'))],
['customer aggregation',()=>assert(a.includes("inv.customer_name||'Unnamed customer'"))],
['pointer drag',()=>assert(a.includes("grid.addEventListener('pointerdown'"))],
['pointer move',()=>assert(a.includes("grid.addEventListener('pointermove'"))],
['handle only',()=>assert(a.includes("closest('.report-widget-handle')"))],
['saved order',()=>assert(a.includes('saveReportWidgetOrder(grid)'))],
['tenant layout retained',()=>assert(a.includes('tenantStorageKey(`report_widget_layout_${name}`)'))],
['one binding',()=>assert(a.includes("grid.dataset.widgetDragBound==='1'"))],
['touch drag',()=>assert(c.includes('.report-widget-handle{touch-action:none}'))],
['cache bust',()=>assert(s.includes('app.js?v=61.79-phase-b'))],
];
let n=0;for(const[x,f]of C){try{f();n++;console.log('PASS',x)}catch(e){console.error('FAIL',x,e.message);process.exitCode=1}}console.log(`${n}/${C.length} PASS`);
