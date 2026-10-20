/* Frindly native Leave Management: isolated RPCs only; never posts payroll or changes balances. */
(()=>{'use strict';
const el=id=>document.getElementById(id),client=()=>window.SAAS?.client?.(),bid=()=>window.SAAS?.state?.business?.id;
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let activeBusiness=null,employees=[],types=[],requests=[],payRuns=[],busy=false;
const panel=()=>el('payroll-panel-leave'),root=()=>el('frindlyLeaveNative');
const note=s=>{if(el('leaveNotice'))el('leaveNotice').textContent=s};
async function rpc(name,args){const {data,error}=await client().rpc(name,args||{});if(error)throw error;return data}
function draw(){
 const options=rows=>rows.map(x=>'<option value="'+esc(x.id)+'">'+esc(x.label)+'</option>').join('');
 const people=employees.map(x=>({id:x.id,label:[x.preferred_name||x.first_name,x.last_name].filter(Boolean).join(' ')}));
 root().innerHTML='<p>Requests are recorded separately from payroll. Approval does not post pay or deduct balances.</p>'+
 '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:16px"><section class="card" style="padding:14px"><h3>Create leave draft</h3>'+
 '<form id="leaveCreate"><label>Employee<select name="employee" required><option value="">Select</option>'+options(people)+'</select></label>'+
 '<label>Leave type<select name="type" required><option value="">Select</option>'+options(types.map(x=>({id:x.id,label:x.name})))+'</select></label>'+
 '<label>From<input name="from" type="date" required></label><label>To<input name="to" type="date" required></label>'+
 '<label>Quantity<input name="quantity" type="number" min="0.01" max="10000" step="0.01" required></label>'+
 '<label>Unit<select name="unit"><option value="days">Days</option><option value="hours">Hours</option><option value="weeks">Weeks</option></select></label>'+
 '<button class="primary" type="submit" '+(!people.length||!types.length?'disabled':'')+'>Save draft</button> <button class="primary" type="submit" name="leaveIntent" value="approve" '+(!people.length||!types.length?'disabled':'')+'>Create and approve</button></form></section>'+
 '<section><h3>Requests ('+requests.length+')</h3>'+(requests.length?requests.map(r=>'<div class="card" style="padding:12px;margin-bottom:8px"><strong>'+esc(r.employee)+'</strong> · '+esc(r.status)+
 '<p>'+esc(r.leave_type)+' · '+esc(r.date_from)+' – '+esc(r.date_to)+' · '+esc(r.quantity)+' '+esc(r.unit)+'</p>'+
 (r.status==='draft'?'<button type="button" data-leave-action="submit" data-id="'+esc(r.id)+'">Submit</button>':'')+
 (r.status==='pending'?'<button type="button" data-leave-action="approve" data-id="'+esc(r.id)+'">Approve</button> <button type="button" data-leave-action="decline" data-id="'+esc(r.id)+'">Decline</button>':'')+'</div>').join(''):'No requests yet')+'</section></div>'+
 '<section class="card" style="padding:14px;margin-top:14px"><h3>Payroll leave review</h3><p>Check approved leave against a pay run before processing. Review only — no pay, balances or statutory entitlements are changed.</p><label>Pay run<select id="leaveReviewRun"><option value="">Select a pay run</option>'+options(payRuns.map(x=>({id:x.id,label:(x.pay_run_number||'Pay run')+' · '+x.period_start+' – '+x.period_end+' ('+x.status+')'})))+'</select></label> <button type="button" id="leaveReviewButton">Review approved leave</button><div id="leaveReviewResult" role="status" aria-live="polite"></div></section>'+ 
 '<h3>Approved leave calendar</h3>'+(requests.filter(r=>r.status==='approved').sort((a,b)=>String(a.date_from).localeCompare(String(b.date_from))).map(r=>'<p>'+esc(r.date_from)+' – '+esc(r.date_to)+' · '+esc(r.employee)+'</p>').join('')||'<p>No approved dates yet</p>')+
 '<p id="leaveNotice" role="status" aria-live="polite"></p>';
}
async function load(){
 if(!panel()?.classList.contains('active')||busy||!root())return;
 const b=bid();if(!b||!client()){root().textContent='Sign in and select a business.';return}
 root().textContent='Loading Leave Management…';
 try{
 const [a,t,r,p]=await Promise.all([
 client().from('payroll_employees').select('id,first_name,last_name,preferred_name,employment_status').eq('business_id',b).eq('archived',false).order('last_name').limit(500),
 client().from('payroll_leave_types').select('id,name').eq('business_id',b).eq('archived',false).order('name').limit(100),
 rpc('frindly_leave_requests_read'),
 client().from('payroll_pay_runs').select('id,pay_run_number,period_start,period_end,status').eq('business_id',b).order('period_start',{ascending:false}).limit(40)]);
 if(a.error)throw a.error;if(t.error)throw t.error;if(bid()!==b)return;
 activeBusiness=b;employees=(a.data||[]).filter(x=>['active','on_leave'].includes(x.employment_status));types=t.data||[];requests=Array.isArray(r)?r:[];payRuns=p.error?[]:(p.data||[]);draw();
 }catch(e){if(bid()===b)root().textContent='Leave Management unavailable: '+(e.message||'Permission denied')}
}
async function run(name,args,success){
 if(busy)return;if(bid()!==activeBusiness){await load();return}
 busy=true;note('Saving…');
 try{await rpc(name,args);busy=false;await load();note(success)}
 catch(e){note('Action failed: '+(e.message||'Permission denied'))}finally{busy=false}
}
document.addEventListener('submit',e=>{
 if(e.target.id!=='leaveCreate')return;e.preventDefault();
 const d=new FormData(e.target),from=String(d.get('from')||''),to=String(d.get('to')||''),qty=Number(d.get('quantity'));
 if(!from||!to||to<from||!Number.isFinite(qty)||qty<=0){note('Invalid dates or quantity');return}
 const approve=e.submitter?.value==='approve';
 if(!confirm(approve?'Create and approve this leave request? This does not post to payroll.':'Save leave draft? No payroll records will be changed.'))return;
 run(approve?'frindly_leave_request_create_and_approve':'frindly_leave_request_create',{p_employee:d.get('employee'),p_leave_type:d.get('type'),p_from:from,p_to:to,p_quantity:qty,p_unit:d.get('unit')},approve?'Leave approved':'Draft saved');
});
document.addEventListener('click',async e=>{
 if(e.target.closest('#leaveReviewButton')){
   const runId=el('leaveReviewRun')?.value,out=el('leaveReviewResult');if(!runId||!out){note('Select a pay run to review');return}
   if(bid()!==activeBusiness){note('Business changed. Reload Leave Management.');return}
   out.textContent='Checking approved leave…';
   try{const result=await rpc('frindly_leave_payroll_review',{p_pay_run_id:runId});if(bid()!==activeBusiness)return;
     const rows=Array.isArray(result?.requests)?result.requests:[];
     out.innerHTML='<p>'+rows.length+' approved leave request(s) overlap this pay run. No financial records changed.</p>'+
       (rows.length?'<ul>'+rows.map(x=>'<li>'+esc(x.from)+' – '+esc(x.to)+' · '+esc(x.quantity)+' '+esc(x.unit)+' · '+esc(x.employment_type||'Employment type not set')+' · '+(x.existing_leave_transaction||x.already_in_pay_run?'<strong>Possible duplicate: inspect existing leave transaction</strong>':'Statutory entitlement and pay need confirmation')+'</li>').join('')+'</ul>':'<p>No approved leave requiring review in this pay run.</p>');
   }catch(error){out.textContent='Review unavailable: '+(error.message||'Permission denied')}
   return;
 }

 if(e.target.closest('[data-payroll-tab="leave"]')){setTimeout(load,0);return}
 const btn=e.target.closest('[data-leave-action]');if(!btn||!panel()?.classList.contains('active'))return;
 const action=btn.dataset.leaveAction,id=btn.dataset.id;
 if(!['submit','approve','decline'].includes(action)||!requests.some(r=>r.id===id))return;
 if(!confirm('Confirm '+action+'? This does not post to payroll.'))return;
 run('frindly_leave_request_action',{p_draft_id:id,p_action:action},'Request '+action+' completed');
});
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&panel()?.classList.contains('active')&&bid()!==activeBusiness)load()});
})();