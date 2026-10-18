'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto');
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve};}
function harness(){
 const nodes={prId:{value:''},prPayDate:{value:'2026-10-08'},prStart:{value:'2026-10-01'},prEnd:{value:'2026-10-07'},prFrequency:{value:'weekly'}};
 const employee={id:'employee-a',employee_number:'EMP-1',first_name:'Pat',hourly_rate:10,pay_type:'hourly',pay_frequency:'weekly'};
 const pay={employee,hours:10,ordinaryH:10,overtimeH:0,rate:10,ordinary:100,overtime:0,holiday:0,allowances:0,reimbursements:5,gross:100,paye:20,kiwiEmp:0,student:0,otherDeductions:0,deductions:20,net:85,employerGross:3,employerNet:2.7,esct:.3,cost:108,timesheets:[{id:'time-a',total_hours:10,work_date:'2026-10-01'}],manualLines:[{line_type:'reimbursement',quantity:1,rate:5,amount:5,taxable:false},{line_type:'earning',description:'Sick Leave',quantity:1,rate:100,amount:100,taxable:true,statutory_leave_code:'sick_leave',statutory_calculation_id:'statutory-a'}],p7Tax:{status:'calculated'}};
 const state={businessId:'business-a',settings:{country_code:'NZ'},runs:[],jobs:[],runCalc:[pay],calculatedRunKey:'current'};
 const calls=[],messages=[];let latest,handler;
 const ctx={state,runSave:{busy:false,pending:null},runFormEpoch:1,window:{SAAS:{state:{user:{id:'user-a'}}}},biz:()=>({id:'business-a',name:'Fixture'}),$:id=>nodes[id],toast:x=>messages.push(x),runCalculationKey:()=> 'current',selectedRunCalc:()=>state.runCalc,calculateRun(){},validateNoDuplicateFinalisedPay:async()=>null,currentRunDef:()=>({}),nextRunNo:async()=> 'PAY-1',activeRuleSnapshot:()=>({version:'unchanged'}),currency:()=> 'NZD',appSettings:()=>({}),displayName:e=>e.first_name,human:x=>x,num:v=>Number(v)||0,trunc2:v=>Math.floor((Number(v)+1e-9)*100)/100,crypto,console,close(){},setTab(){},initialiseRun(){ctx.runFormEpoch++;},load:async()=>{if(latest)state.runs=[latest];}};
 const rpc=async(name,args)=>{calls.push({name,args});if(handler)return handler(name,args);if(name==='frindly_payroll_period_ready')return {data:true};latest={...args.p_payload.run,id:'run-a',updated_at:'revision-2',status:args.p_payload.finalise?'finalised':'calculated'};return{data:{run:latest,needs_approval:false}};};
 ctx.client=()=>({rpc,from(){throw Error('Unexpected split database write');}});
 const src=fs.readFileSync('public/payroll.js','utf8');vm.runInNewContext(src.slice(src.indexOf('  async function saveRun(finalise=false){'),src.indexOf('  function payrollReviewGuard()')),ctx);
 return{ctx,state,pay,nodes,calls,messages,setHandler:h=>handler=h,setLatest:r=>latest=r,save:flag=>ctx.saveRun(flag)};
}
test('pay run saves one complete bundle with the existing calculations and line links',async()=>{
 const h=harness();await h.save(true);assert.equal(h.calls.length,2);assert.equal(h.calls[0].name,'frindly_payroll_period_ready');const c=h.calls[1];assert.equal(c.name,'v6226_save_pay_run');const p=c.args.p_payload;
 assert.equal(p.run.gross_pay,100);assert.equal(p.run.net_pay,85);assert.equal(p.run.total_employment_cost,108);assert.equal(p.run.employer_contributions,3);
 assert.equal(p.employees[0].employee.employer_contributions,2.7);assert.equal(p.employees[0].employee.calculation_snapshot.p7_tax.status,'calculated');assert.equal(p.employees[0].employee.calculation_snapshot.statutory_leave[0].statutory_calculation_id,'statutory-a');assert.equal(p.employees[0].lines[0].timesheet_id,'time-a');assert.equal(p.employees[0].lines[1].taxable,false);assert.equal(p.employees[0].lines[2].statutory_calculation_id,'statutory-a');assert.equal(p.employees[0].payslip.data.pay.net,85);assert.equal(p.financial.find(x=>x.type==='kiwisaver_payable').amount,2.7);assert.equal(p.run.updated_at,undefined);assert.match(h.messages.at(-1),/Pay run finalised/);
});
test('calculated save sends no payslips or financial posting entries',async()=>{const h=harness();await h.save(false);assert.equal(h.calls.length,1);assert.equal(h.calls[0].args.p_payload.employees[0].payslip,null);assert.equal(h.calls[0].args.p_payload.financial.length,0);});
test('double-click during save cannot issue a second write',async()=>{const h=harness(),d=deferred();h.setHandler(()=>d.promise);const p=h.save(false);await Promise.resolve();await h.save(false);assert.equal(h.calls.length,1);d.resolve({error:{code:'40001',message:'stale'}});await assert.rejects(()=>p);assert.equal(h.ctx.runSave.busy,false);});
test('business change during finalise readiness blocks the save',async()=>{const h=harness();h.setHandler(async()=>{h.state.businessId='business-b';return{data:true};});await assert.rejects(()=>h.save(true),/business or pay-run form changed/);assert.equal(h.calls.length,1);});
test('unconfirmed save retries the same identifier and rejects changed figures',async()=>{
 const h=harness();h.setHandler(async()=>{throw Error('network');});await assert.rejects(()=>h.save(false));const id=h.calls[0].args.p_request;
 h.pay.net=86;await assert.rejects(()=>h.save(false),/previous pay-run save/);assert.equal(h.calls.length,1);h.pay.net=85;
 await assert.rejects(()=>h.save(false));assert.equal(h.calls[1].args.p_request,id);
});
test('definite database rollback releases retry identifier',async()=>{const h=harness();h.setHandler(async()=>({error:{code:'40001',message:'stale'}}));await assert.rejects(()=>h.save(false));assert.equal(h.ctx.runSave.pending,null);assert.equal(h.ctx.runSave.busy,false);});
test('existing run save includes the loaded revision',async()=>{const h=harness();h.nodes.prId.value='run-a';h.state.runs=[{id:'run-a',status:'calculated',pay_run_number:'PAY-1',updated_at:'revision-1'}];await h.save(false);assert.equal(h.calls[0].args.p_run_id,'run-a');assert.equal(h.calls[0].args.p_expected_updated_at,'revision-1');});
test('approval submission reports waiting for review rather than finalised',async()=>{
 const h=harness();h.setHandler(async(name,args)=>{if(name==='frindly_payroll_period_ready')return{data:true};const run={...args.p_payload.run,id:'run-a',status:'calculated'};h.setLatest(run);return{data:{run,needs_approval:true}};});await h.save(true);assert.match(h.messages.at(-1),/saved for review/);assert.equal(h.state.runs[0].status,'calculated');
});
test('unresolved statutory calculation and closed accounting period still block finalisation',async()=>{
 const h=harness();h.pay.statutoryUnresolved=true;await h.save(true);assert.equal(h.calls.length,0);h.pay.statutoryUnresolved=false;h.setHandler(async()=>({data:false}));await h.save(true);assert.equal(h.calls.length,1);assert.match(h.messages.at(-1),/no open accounting period/);
});
