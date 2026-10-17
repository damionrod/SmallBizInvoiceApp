'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto');
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve};}
function harness(){
 const nodes=new Map(),node=id=>{if(!nodes.has(id))nodes.set(id,{value:'',innerHTML:'',disabled:false,querySelectorAll:()=>[],classList:{add(){},remove(){}}});return nodes.get(id);};
 const calls=[],messages=[],prompts=[];let read=async()=>({data:[],error:null}),rpc=async()=>({data:[],error:null});
 const client={from(table){const q={select(){return q},eq(){return q},order(){return q},limit(){return q},then(resolve,reject){return read(table).then(resolve,reject)}};return q;},rpc(name,args){calls.push({name,args});return rpc(name,args);}};
 const window={SAAS:{state:{business:{id:'business-a'},user:{id:'user-a'}},client:()=>client},toast:x=>messages.push(x),FrindlyDialogs:{prompt:async()=>{const p=prompts.shift();return typeof p==='function'?p():p;}}};
 const document={getElementById:node,addEventListener(){},querySelector:()=>null,querySelectorAll:()=>[]};
 let source=fs.readFileSync('public/payroll.js','utf8').replace('window.Payroll={init,onShow','window.__leave={state,leaveView,renderLeaveFields,renderLeaveHistory,recordLeave,saveLeaveBalances,submitLeaveHours,leaveContext,close};window.Payroll={init,onShow');
 vm.runInNewContext(source,{window,document,console,crypto,Date,Map,Number,JSON});
 const api=window.__leave;api.state.businessId='business-a';api.state.leaveTypes=[{id:'annual',name:'Annual hours'},{id:'sick',name:'Sick hours'}];node('payrollEmployeeId').value='employee-a';
 return{api,node,window,calls,messages,prompts,setRead:x=>read=x,setRpc:x=>rpc=x};
}
test('a leave entry uses one atomic RPC and no separate balance writes',async()=>{
 const h=harness();h.prompts.push('1','accrual','12.5','2026-10-01','Opening hours');await h.api.recordLeave();
 assert.equal(h.calls.length,1);assert.equal(h.calls[0].name,'v6226_apply_leave_hours');assert.equal(h.calls[0].args.p_changes[0].hours,'12.5');assert.equal(h.calls[0].args.p_employee,'employee-a');assert.match(h.messages.at(-1),/history and hours balance updated/);
});
test('double-click while a leave prompt is open creates one entry',async()=>{
 const h=harness(),d=deferred();h.prompts.push(()=>d.promise,'accrual','1','2026-10-01','');const p=h.api.recordLeave();await h.api.recordLeave();d.resolve('1');await p;assert.equal(h.calls.length,1);
});
test('changing business during a leave prompt prevents its save',async()=>{
 const h=harness();h.prompts.push(()=>{h.window.SAAS.state.business.id='business-b';return '1';});await h.api.recordLeave();assert.equal(h.calls.length,0);assert.match(h.messages[0],/business changed/);
});
test('a late balance response cannot populate another employee',async()=>{
 const h=harness(),d=deferred();h.setRead(()=>d.promise);const p=h.api.renderLeaveFields('employee-a');h.node('payrollEmployeeId').value='employee-b';h.node('peLeaveBalances').innerHTML='Employee B';d.resolve({data:[{leave_type_id:'annual',balance_hours:999}]});await p;assert.equal(h.node('peLeaveBalances').innerHTML,'Employee B');
});
test('closing the employee form invalidates an unfinished request',async()=>{
 const h=harness(),d=deferred();h.setRead(()=>d.promise);const p=h.api.renderLeaveFields('employee-a');h.api.close('payrollEmployeeModal');h.node('peLeaveBalances').innerHTML='Closed';d.resolve({data:[]});await p;assert.equal(h.node('peLeaveBalances').innerHTML,'Closed');
});
test('statutory units are shown read-only and never recast as editable hours',async()=>{
 const h=harness();h.setRead(async()=>({data:[{leave_type_id:'sick',balance_hours:24,statutory_quantity:3,statutory_unit:'days',statutory_leave_code:'sick_leave'}]}));await h.api.renderLeaveFields('employee-a');const html=h.node('peLeaveBalances').innerHTML;assert.match(html,/3 days/);assert.doesNotMatch(html,/data-leave-id="sick"/);assert.match(html,/data-leave-id="annual"/);
});
test('balance correction sends only changed balances and their loaded revisions',async()=>{
 const h=harness();h.setRead(async()=>({data:[{leave_type_id:'annual',balance_hours:10,updated_at:'2026-10-01T00:00:00Z'},{leave_type_id:'sick',balance_hours:4,updated_at:'2026-10-02T00:00:00Z'}]}));await h.api.renderLeaveFields('employee-a');
 h.node('peLeaveBalances').querySelectorAll=()=>[{dataset:{leaveId:'annual'},value:'12'},{dataset:{leaveId:'sick'},value:'4'}];h.prompts.push('Correct original entry');await h.api.saveLeaveBalances();
 assert.equal(h.calls.length,1);const c=h.calls[0].args.p_changes;assert.equal(c.length,1);assert.equal(c[0].expected_updated_at,'2026-10-01T00:00:00Z');assert.equal(c[0].notes,'Correct original entry');
});
test('ambiguous network failure retries with the same save identifier',async()=>{
 const h=harness(),guard=h.api.leaveContext('employee-a'),changes=[{mode:'entry',leave_type_id:'annual',hours:'1'}];h.setRpc(async()=>{throw Error('network unavailable');});
 await assert.rejects(()=>h.api.submitLeaveHours('employee-a',changes,guard));const id=h.calls[0].args.p_request;
 await assert.rejects(()=>h.api.submitLeaveHours('employee-a',[{...changes[0],hours:'2'}],guard),/previous leave save/);assert.equal(h.calls.length,1);
 h.setRpc(async()=>({data:[],error:null}));await h.api.submitLeaveHours('employee-a',changes,guard);assert.equal(h.calls[1].args.p_request,id);assert.equal(h.api.leaveView.pending,null);
});
test('invalid hours cannot be silently converted to zero',async()=>{
 const h=harness();h.prompts.push('1','accrual','not a number');await h.api.recordLeave();assert.equal(h.calls.length,0);assert.match(h.messages[0],/valid hours/);
});
