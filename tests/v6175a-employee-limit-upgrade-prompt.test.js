const fs=require('fs'),assert=require('assert');
const s=fs.readFileSync('public/saas.js','utf8'),p=fs.readFileSync('public/payroll.js','utf8'),c=fs.readFileSync('public/styles.css','utf8');
const C=[
['limit enforcement retained',()=>assert(p.includes('function canAddEmployee()'))],
['add guard retained',()=>assert(p.includes('function openNewEmployee()'))],
['save guard retained',()=>assert(p.includes("!$('payrollEmployeeId').value&&!canAddEmployee()"))],
['upgrade prompt called',()=>assert(p.includes('showEmployeeLimitUpgrade()'))],
['next plan calculated',()=>assert(p.includes('function nextEmployeePlan()'))],
['limit message',()=>assert(p.includes('Employee limit reached'))],
['upgrade wording',()=>assert(p.includes('Upgrade to ${next.name} for up to ${Number(next.employee_limit)} employees.'))],
['modal helper',()=>assert(s.includes('function showPlanUpgradePrompt'))],
['upgrade button',()=>assert(s.includes("primaryLabel='Upgrade plan'"))],
['not now button',()=>assert(s.includes('>Not now</button>'))],
['upgrade opens plans',()=>assert(s.includes("modal.classList.remove('open');showPlans()"))],
['existing checkout unchanged',()=>assert(s.includes("startCheckout(b.dataset.choosePlan,b,{billingInterval:b.dataset.billingInterval})"))],
['prompt css isolated',()=>assert(c.includes('#planUpgradePrompt .plan-upgrade-prompt-card'))],
['mobile prompt',()=>assert(c.includes('@media(max-width:520px)'))],
];
let n=0;for(const [x,f] of C){try{f();n++;console.log('PASS',x)}catch(e){console.error('FAIL',x,e.message);process.exitCode=1}}console.log(`${n}/${C.length} PASS`);
