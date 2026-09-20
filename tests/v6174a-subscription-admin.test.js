const fs=require('fs'),assert=require('assert');
const admin=fs.readFileSync('public/saas.js','utf8'),css=fs.readFileSync('public/styles.css','utf8'),html=fs.readFileSync('public/index.html','utf8');
const C=[
['delegated save',()=>assert(admin.includes("addEventListener('click',event=>"))],
['save target',()=>assert(admin.includes("closest('[data-plan-save]')"))],
['save rpc',()=>assert(admin.includes("v6175_admin_upsert_plan"))],
['saving state',()=>assert(admin.includes("'Saving…'"))],
['error recovery',()=>assert(admin.includes("Could not save plan:"))],
['monthly summary',()=>assert(admin.includes("<small>MONTHLY</small>"))],
['annual summary',()=>assert(admin.includes("<small>ANNUAL</small>"))],
['saving dollars',()=>assert(admin.includes("${ap.saving.toFixed(2)} per year"))],
['saving pct',()=>assert(admin.includes("Save ${Math.round(ap.pct)}%"))],
['custom override',()=>assert(admin.includes("p.annual_saving_message||"))],
['unset annual',()=>assert(admin.includes("Annual rate not set"))],
['monthly equivalent',()=>assert(admin.includes("/ month equivalent"))],
['button type',()=>assert(admin.includes('type="button"'))],
['highlight css',()=>assert(css.includes(".subscription-admin-saving.has-saving"))],
['responsive css',()=>assert(css.includes("@media(max-width:720px)"))],
['no admin billing tabs',()=>assert(!admin.includes("data-admin-billing-tab"))],
];
let n=0;for(const [x,f] of C){try{f();n++;console.log('PASS',x)}catch(e){console.error('FAIL',x,e.message);process.exitCode=1}}console.log(`${n}/${C.length} PASS`);
