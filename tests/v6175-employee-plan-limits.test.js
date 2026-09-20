const fs=require('fs'),assert=require('assert');
const s=fs.readFileSync('public/saas.js','utf8'),p=fs.readFileSync('public/payroll.js','utf8'),h=fs.readFileSync('public/index.html','utf8');
const C=[
['admin employee limit field',()=>assert(s.includes('data-plan-employee-limit'))],
['admin saves employee limit',()=>assert(s.includes('p_employee_limit:'))],
['new admin rpc',()=>assert(s.includes("v6175_admin_upsert_plan"))],
['customer allowance',()=>assert(s.includes('Up to ${Number(p.employee_limit)} employees'))],
['payroll plans only',()=>assert(s.includes("includes('payroll')&&p.employee_limit!=null"))],
['limit helper',()=>assert(p.includes('function payrollEmployeeLimit()'))],
['usage ignores archived',()=>assert(p.includes('state.employees.filter(e=>!e.archived).length'))],
['add precheck',()=>assert(p.includes('function openNewEmployee()'))],
['save insert precheck',()=>assert(p.includes("!$('payrollEmployeeId').value&&!canAddEmployee()"))],
['upgrade guidance',()=>assert(p.includes('showEmployeeLimitUpgrade()'))],
['saas cache',()=>assert(s.includes('app.js?v=61.79-phase-b'))],
['payroll cache',()=>assert(s.includes('payroll.js?v=61.75A-employee-limit-upgrade-prompt'))],
];
let n=0;for(const [x,f] of C){try{f();n++;console.log('PASS',x)}catch(e){console.error('FAIL',x,e.message);process.exitCode=1}}console.log(`${n}/${C.length} PASS`);
