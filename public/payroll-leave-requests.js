/* Manager review reuses Payroll permissions; no payroll calculation or balance writes. */
(()=>{
 'use strict';
 const $=id=>document.getElementById(id),esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const state={business:null,user:null,request:0,epoch:0,data:null,offset:0,status:'pending',busy:false,pending:null};
 const context=()=>({business:window.SAAS?.state?.business?.id,user:window.SAAS?.state?.user?.id});
 const client=()=>window.SAAS?.client?.();
 function guard(){const c=context(),epoch=state.epoch;return()=>{const n=context();if(!c.business||!c.user||c.business!==n.business||c.user!==n.user||c.business!==state.business||c.user!==state.user||epoch!==state.epoch)throw Error('Your account or business changed. Reopen Leave requests.');};}
 function message(s){$('plrMessage').textContent=s||'';$('plrMessage').hidden=!s;}
 function controls(){for(const el of $('payroll-panel-leave').querySelectorAll('button,input,select'))el.disabled=state.busy;for(const el of $('plrRequests').querySelectorAll('button'))el.disabled=state.busy||!!state.pending||!state.data?.can_review;$('plrRetry').hidden=!state.pending;$('plrPrevious').disabled=state.busy||state.offset===0;$('plrNext').disabled=state.busy||!state.data||state.offset+100>=Number(state.data.total);}
 function clear(){state.request++;state.epoch++;state.data=null;state.pending=null;state.offset=0;$('plrRequests').innerHTML='';$('plrEmployee').innerHTML='';$('plrLinked').textContent='';$('plrEmail').value='';$('plrAccess').hidden=true;}
 function selected(){return state.data?.employees?.find(x=>x.id===$('plrEmployee').value);}
 function employeeSelected(){const e=selected();$('plrEmail').value=e?.linked_email||'';$('plrLinked').textContent=e?.link_id?`${e.active?'Access enabled':'Access disabled'} · ${e.linked_email||'Account unavailable'}`:'No account linked';$('plrRevoke').disabled=state.busy||!e?.active;}
 function render(){
  const d=state.data;$('plrAccess').hidden=!d.can_link;$('plrEmployee').innerHTML='<option value="">Choose employee</option>'+(d.employees||[]).map(e=>`<option value="${esc(e.id)}">${esc(e.name)}${['active','on_leave'].includes(e.status)?'':' ('+esc(e.status)+')'}</option>`).join('');employeeSelected();
  $('plrRequests').innerHTML=(d.requests||[]).map(r=>`<article class="el-request"><div><strong>${esc(r.employee_name)}</strong> <span class="el-status">${esc(r.status)}</span><p>${esc(r.leave_name)} · ${esc(r.date_from)} – ${esc(r.date_to)}</p><p>${esc(r.quantity)} ${esc(r.unit)} requested</p>${r.decision_note?`<p>${esc(r.decision_note)}</p>`:''}${r.status==='approved'?'<p class="el-note">Request approved. Process the leave through the existing payroll workflow separately.</p>':''}</div>${r.status==='pending'&&d.can_review?`<div class="el-actions"><button class="el-primary" data-plr-approve="${esc(r.id)}">Approve request</button><button data-plr-decline="${esc(r.id)}">Decline</button></div>`:''}</article>`).join('')||'<p class="el-note">No requests on this page.</p>';
  for(const b of $('plrRequests').querySelectorAll('[data-plr-approve]'))b.onclick=()=>decide(b.dataset.plrApprove,'approve');for(const b of $('plrRequests').querySelectorAll('[data-plr-decline]'))b.onclick=()=>decide(b.dataset.plrDecline,'decline');
  $('plrPage').textContent=d.total?`${state.offset+1}–${Math.min(state.offset+100,Number(d.total))} of ${d.total}`:'0 requests';controls();employeeSelected();
 }
 async function load(){
  const c=context();if(c.business!==state.business||c.user!==state.user){clear();state.business=c.business;state.user=c.user;}
  const check=guard(),request=++state.request;
  try{check();const {data,error}=await client().rpc('v6229_leave_manager_read',{p_status:state.status,p_offset:state.offset});check();if(request!==state.request)return;if(error)throw error;if(data?.business_id!==c.business)throw Error('Leave-request context could not be verified.');state.data=data;render();}
  catch(e){if(request!==state.request)return;try{check();}catch{clear();return;}state.data=null;$('plrRequests').innerHTML='';$('plrAccess').hidden=true;message(e.message||'Leave requests could not load.');controls();}
 }
 async function command(args){
  if(state.busy)return;const check=guard();if(state.pending&&JSON.stringify(state.pending)!==JSON.stringify(args))return message('Retry the previous decision before starting another.');state.pending=state.pending||args;state.busy=true;controls();
  try{check();const {data,error}=await client().rpc('v6229_leave_request_command',state.pending);check();if(error){state.pending=null;throw error;}if(!data?.id)throw Error('Decision response could not be verified. Retry the previous decision.');state.pending=null;message('Decision saved. Payroll figures have not been changed.');await load();}
  catch(e){try{check();message(state.pending?'The result is uncertain. Retry the previous decision safely. '+(e.message||''):e.message||'Decision could not be saved.');}catch{clear();}}
  finally{state.busy=false;controls();employeeSelected();}
 }
 async function decide(id,action){
  if(state.busy||state.pending)return;const check=guard(),r=state.data?.requests?.find(x=>x.id===id);if(!r||!state.data.can_review)return;let note='';
  try{check();if(action==='decline'){note=await window.FrindlyDialogs.prompt('Short explanation for the employee (no private medical details):','');check();if(note===null)return;if(!note.trim()||note.trim().length>500)return message('Enter a short explanation of up to 500 characters.');}
   else{const ok=await window.FrindlyDialogs.confirm(`Approve ${r.employee_name}'s request for ${r.quantity} ${r.unit}, ${r.date_from} to ${r.date_to}? This records the decision only; process the leave in payroll separately.`);check();if(!ok)return;}
   return await command({p_link:r.link_id,p_request:r.id,p_operation:crypto.randomUUID(),p_action:action,p_expected_revision:r.revision,p_values:note.trim()?{note:note.trim()}:{}});
  }catch(e){message(e.message);}
 }
 async function link(active){
  if(state.busy||!state.data?.can_link)return;const check=guard(),e=selected(),email=$('plrEmail').value.trim();if(!e)return message('Choose an employee.');if(active&&!email)return message('Enter the exact email of an existing confirmed account.');
  try{const ok=await window.FrindlyDialogs.confirm(active?`Link ${e.name} to ${email}? Verify this is the employee's own login. This gives access only to their leave requests; no business membership or Payroll access is granted.`:`Disable employee leave access for ${e.name}? Requests and decisions will be retained.`);check();if(!ok)return;state.busy=true;controls();const {error}=await client().rpc('v6229_set_employee_portal_link',{p_employee:e.id,p_email:email,p_active:active,p_expected_revision:e.link_revision??null});check();if(error)throw error;message(active?'Employee leave access linked. No invitation was sent.':'Employee leave access disabled.');await load();}
  catch(e){try{check();message((e.message||'Access could not be saved.')+' Refresh access before trying again.');}catch{clear();}}finally{state.busy=false;controls();employeeSelected();}
 }
 function open(){
  if(!$('payroll-panel-leave'))return;
  $('plrFilter').onchange=()=>{state.status=$('plrFilter').value;state.offset=0;void load();};$('plrRefresh').onclick=()=>load();$('plrPrevious').onclick=()=>{state.offset=Math.max(0,state.offset-100);void load();};$('plrNext').onclick=()=>{state.offset+=100;void load();};$('plrRetry').onclick=()=>state.pending&&command(state.pending);$('plrEmployee').onchange=employeeSelected;$('plrLinkForm').onsubmit=e=>{e.preventDefault();void link(true);};$('plrRevoke').onclick=()=>link(false);message('');return load();
 }
 window.PayrollLeaveRequests=Object.freeze({open});
})();
