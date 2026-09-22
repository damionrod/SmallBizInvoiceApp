const fs=require('fs'),assert=require('assert');
const html=fs.readFileSync('public/index.html','utf8');
const admin=fs.readFileSync('public/saas.js','utf8');
const checks=[
  ['subscriber summary container',()=>assert(html.includes('id="adminBillingSummary"'))],
  ['active subscriber metric',()=>assert(html.includes('id="adminBillingActive"'))],
  ['monthly recurring metric',()=>assert(html.includes('id="adminBillingMonthlyTotal"'))],
  ['annual recurring metric',()=>assert(html.includes('id="adminBillingAnnualTotal"'))],
  ['subscriber mix metric',()=>assert(html.includes('id="adminBillingMix"'))],
  ['billing interval loaded',()=>assert(admin.includes('subscriptions(id,status,billing_interval'))],
  ['plan prices loaded',()=>assert(admin.includes('monthly_price,annual_price'))],
  ['active-only revenue totals',()=>assert(admin.includes("filter(sub=>sub.status==='active')"))],
  ['monthly total calculation',()=>assert(admin.includes('monthlyTotal=monthlySubs.reduce'))],
  ['annual total calculation',()=>assert(admin.includes('annualTotal=annualSubs.reduce'))],
  ['period dates displayed',()=>assert(admin.includes('Start: ${formatAdminDate(sub.current_period_start)}'))],
  ['mobile table remains scrollable',()=>assert(fs.readFileSync('public/styles.css','utf8').includes('#view-admin .table-scroll'))],
];
let n=0;for(const [name,fn] of checks){try{fn();n++;console.log('PASS',name)}catch(e){console.error('FAIL',name,e.message);process.exitCode=1}}
console.log(`${n}/${checks.length} PASS`);
