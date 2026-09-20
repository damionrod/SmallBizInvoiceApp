const fs=require('fs'),assert=require('assert');
const e=fs.readFileSync('public/expenses.js','utf8'),h=fs.readFileSync('public/index.html','utf8'),s=fs.readFileSync('public/saas.js','utf8');
const C=[
['payables chart widget',()=>assert(h.includes('data-report-widget="aged-payables-chart"'))],
['payables table widget',()=>assert(h.includes('data-report-widget="aged-payables-table"'))],
['supplier heading',()=>assert(h.includes('Bills I Owe by Supplier')&&h.includes('Aged Payables'))],
['five buckets',()=>['Current (Not Overdue)','1–30 Days Past Due','31–60 Days Past Due','61–90 Days Past Due','91+ Days Past Due'].forEach(x=>assert(h.includes(x)))],
['total owed',()=>assert(h.includes('Total Owed'))],
['existing adjusted outstanding used',()=>assert(e.includes('const balance=supplierCreditAdjustedOutstanding(e)'))],
['draft excluded',()=>assert(e.includes("e.payment_status==='draft'||balance<=0.005"))],
['due date aging',()=>assert(e.includes("e.due_date?new Date(e.due_date+'T12:00:00')"))],
['supplier aggregation',()=>assert(e.includes("e.supplier_name||'Unknown supplier'"))],
['all outstanding state used',()=>assert(e.includes('state.expenses.forEach(e=>'))],
['renderer called',()=>assert(e.includes('renderAgedPayables()}'))],
['chart state isolated',()=>assert(e.includes('charts:{month:null,category:null,payables:null}'))],
['expense cache bust',()=>assert(s.includes('expenses.js?v=61.77-aged-payables'))],
['existing movable widget handles retained',()=>assert((h.match(/data-report-widget="aged-payables-/g)||[]).length===2&&h.includes('title="Drag to rearrange"'))],
];
let n=0;for(const[x,f]of C){try{f();n++;console.log('PASS',x)}catch(err){console.error('FAIL',x,err.message);process.exitCode=1}}console.log(`${n}/${C.length} PASS`);
