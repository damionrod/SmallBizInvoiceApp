const fs=require('fs'),assert=require('assert');
const j=fs.readFileSync('public/saas.js','utf8'),h=fs.readFileSync('public/index.html','utf8'),c=fs.readFileSync('public/styles.css','utf8');
const checks=[
['monthly tab removed',()=>assert(!h.includes('id="planBillingMonthly"'))],
['annual tab removed',()=>assert(!h.includes('id="planBillingAnnual"'))],
['monthly shown in card',()=>assert(j.includes("pricing-eyebrow\">${isTrial?'Price':'Pay monthly'}"))],
['annual shown in card',()=>assert(j.includes('pricing-eyebrow">Pay annually'))],
['annual yearly rate',()=>assert(j.includes('<small>/ year</small>'))],
['annual equivalent',()=>assert(j.includes('/month equivalent'))],
['saving badge retained',()=>assert(j.includes('pricing-save-pill'))],
['monthly checkout retained',()=>assert(j.includes('data-billing-interval="monthly"'))],
['annual checkout retained',()=>assert(j.includes('data-billing-interval="annual"'))],
['checkout function untouched interface',()=>assert(j.includes("billingInterval=opts.billingInterval==='annual'?'annual':'monthly'"))],
['responsive pricing',()=>assert(c.includes('#planModal .pricing-actions'))],
['no showPlans toggle bind',()=>{const x=j.slice(j.indexOf('async function showPlans()'),j.indexOf('async function startCheckout'));assert(!x.includes('bindBillingToggle'))}],
];
let n=0;for(const [x,f] of checks){try{f();n++;console.log('PASS',x)}catch(e){console.error('FAIL',x,e.message);process.exitCode=1}}console.log(`${n}/${checks.length} PASS`);
