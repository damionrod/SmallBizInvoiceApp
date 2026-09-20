const fs=require('fs'),assert=require('assert');
const j=fs.readFileSync('public/saas.js','utf8'),s=j,h=fs.readFileSync('public/index.html','utf8'),c=fs.readFileSync('public/styles.css','utf8');
const checks=[
['no billing tabs',()=>assert(!h.includes('planBillingMonthly')&&!h.includes('planBillingAnnual'))],
['monthly retained',()=>assert(j.includes('data-billing-interval="monthly"'))],
['annual retained',()=>assert(j.includes('data-billing-interval="annual"'))],
['same checkout path',()=>assert(j.includes("startCheckout(b.dataset.choosePlan,b,{billingInterval:b.dataset.billingInterval})"))],
['annual yearly charge',()=>assert(j.includes('/ year</small>'))],
['monthly equivalent',()=>assert(j.includes('/month equivalent'))],
['saving visible',()=>assert(j.includes('pricing-save-pill'))],
['current plan visible',()=>assert(j.includes('pricing-current-pill'))],
['trial no annual action',()=>assert(j.includes("isTrial?'':"))],
['card flex alignment',()=>assert(c.includes('display:flex;flex-direction:column'))],
['actions bottom aligned',()=>assert(c.includes('margin-top:auto'))],
['mobile one column',()=>assert(c.includes('@media(max-width:620px)'))],
['cache bust',()=>assert(s.includes('app.js?v=61.79-phase-b'))],
];
let n=0;for(const [x,f] of checks){try{f();n++;console.log('PASS',x)}catch(e){console.error('FAIL',x,e.message);process.exitCode=1}}console.log(`${n}/${checks.length} PASS`);
