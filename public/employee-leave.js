/* A separate own-record page: never loads the accounting/Payroll application. */
(()=>{
 'use strict';
 const $=id=>document.getElementById(id),esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const state={user:null,link:null,data:null,offset:0,read:0,epoch:0,busy:false,pending:null,view:'leave'};let client,payslips;
 function message(s){$('elMessage').textContent=s||'';$('elMessage').className='el-message';$('elMessage').hidden=!s;}
 function guard(){const user=state.user,link=state.link,epoch=state.epoch;return()=>{if(user!==state.user||link!==state.link||epoch!==state.epoch)throw Error('Your account or workplace changed. Refresh your requests.');};}
 function datesValid(from,to){return /^\d{4}-\d{2}-\d{2}$/.test(from)&&/^\d{4}-\d{2}-\d{2}$/.test(to)&&from<=to;}
 function controls(){const disabled=state.busy||!!state.pending;for(const el of $('elRequestForm').querySelectorAll('input,select,button'))el.disabled=disabled;for(const el of $('elRequests').querySelectorAll('button'))el.disabled=disabled;$('elWorkplace').disabled=disabled;$('elRetry').hidden=!state.pending;$('elRetry').disabled=state.busy;$('elPrevious').disabled=state.busy||state.offset===0;$('elNext').disabled=state.busy||!state.data||state.offset+100>=Number(state.data.total||0);}
 function setView(view){const enabled=!!state.data?.links?.find(x=>x.id===state.link)?.payslips_enabled;state.view=view==='payslips'&&enabled?'payslips':'leave';$('elLeaveSection').hidden=state.view!=='leave';$('elPayslipSection').hidden=state.view!=='payslips';$('elShowLeave').classList?.toggle('el-primary',state.view==='leave');$('elShowLeave').setAttribute?.('aria-pressed',String(state.view==='leave'));$('elShowPayslips').classList?.toggle('el-primary',state.view==='payslips');$('elShowPayslips').setAttribute?.('aria-pressed',String(state.view==='payslips'));if(state.view==='payslips')void payslips.showList();}
 function clear(){state.read++;state.epoch++;$('elRequestForm').reset();state.link=null;state.data=null;state.offset=0;state.pending=null;state.view='leave';payslips?.reset();$('elWorkplace').innerHTML='';$('elEmployeeName').textContent='';$('elAvailability').textContent='';$('elRequests').innerHTML='';$('elRequestForm').hidden=true;$('elShowPayslips').hidden=true;$('elLeaveSection').hidden=false;$('elPayslipSection').hidden=true;}
 function showSession(user){state.user=user?.id||null;clear();$('elPassword').value='';$('elLogin').hidden=!!user;$('elWorkspace').hidden=!user;$('elSignOut').hidden=!user;message('');if(user)void load();}
 async function load(){
  const current=guard(),read=++state.read;if(!state.user)return;
  try{const {data,error}=await client.rpc('v6229_employee_leave_read',{p_link:state.link,p_offset:state.offset});current();if(read!==state.read)return;if(error)throw error;
   const links=data?.links||[];state.data=data;$('elWorkplace').innerHTML=links.map(x=>`<option value="${esc(x.id)}">${esc(x.business_name)}</option>`).join('');
   if(!state.link&&links.length){state.link=links[0].id;state.offset=0;return load();}
   if(state.link&&!links.some(x=>x.id===state.link))throw Error('Employee access is unavailable. Ask your employer to check the account link.');
   $('elWorkplace').value=state.link||'';const selected=links.find(x=>x.id===state.link);$('elEmployeeName').textContent=selected?.employee_name||'No active employee access. Ask your employer to link your existing account.';$('elShowPayslips').hidden=!selected?.payslips_enabled;if(!selected?.payslips_enabled&&state.view==='payslips')setView('leave');
   const options=data.leave_types||[],leaveValue=$('elLeaveType').value;$('elLeaveType').innerHTML='<option value="">Choose leave type</option>'+options.map(x=>`<option value="${esc(x.id)}">${esc(x.name)}</option>`).join('');if(options.some(x=>x.id===leaveValue))$('elLeaveType').value=leaveValue;$('elRequestForm').hidden=!state.link||!options.length;$('elAvailability').textContent=state.link&&!options.length?'No leave types are available yet. Ask your employer to check Payroll settings.':'';
   $('elRequests').innerHTML=(data.requests||[]).map(r=>`<article class="el-request"><div><strong>${esc(r.leave_name)}</strong> <span class="el-status">${esc(r.status)}</span><p>${esc(r.date_from)} – ${esc(r.date_to)} · ${esc(r.quantity)} ${esc(r.unit)}</p>${r.decision_note?`<p>${esc(r.decision_note)}</p>`:''}${r.status==='approved'?'<p class="el-note">Approved request. Your employer processes the leave in payroll separately.</p>':''}</div>${r.status==='pending'?`<button data-el-cancel="${esc(r.id)}">Cancel request</button>`:''}</article>`).join('')||'<p class="el-note">No leave requests on this page.</p>';
   for(const b of $('elRequests').querySelectorAll('[data-el-cancel]'))b.onclick=()=>cancel(b.dataset.elCancel);
   $('elPage').textContent=data.total?`${state.offset+1}–${Math.min(state.offset+100,Number(data.total))} of ${data.total}`:'0 requests';controls();
  }catch(e){if(read!==state.read)return;state.data=null;$('elRequests').innerHTML='';$('elRequestForm').hidden=true;message(e.message||'Requests could not load.');controls();}
 }
 async function command(args){
  if(state.busy)return;const check=guard();if(state.pending&&JSON.stringify(state.pending.args)!==JSON.stringify(args))return message('Retry the previous action before starting another one.');
  state.pending=state.pending||{args};state.busy=true;controls();
  try{check();const {data,error}=await client.rpc('v6229_leave_request_command',state.pending.args);check();if(error){state.pending=null;throw error;}if(!data?.id)throw Error('The response could not be verified. Retry the previous action.');state.pending=null;if(args.p_action==='create')$('elRequestForm').reset();message('Request updated.');await load();}
  catch(e){try{check();message(state.pending?'The result is uncertain. Retry the previous action safely, or refresh to check your history. '+(e.message||''):e.message||'Request could not be saved.');}catch{/* Account/workplace changed: never show the old result. */}}
  finally{state.busy=false;controls();}
 }
 function create(event){event?.preventDefault();if(!state.link||state.busy||state.pending)return;const from=$('elFrom').value,to=$('elTo').value,q=$('elQuantity').value;if(!datesValid(from,to)||!/^\d+(?:\.\d{1,2})?$/.test(q)||Number(q)<=0||Number(q)>10000||!$('elLeaveType').value)return message('Choose leave, valid dates and a positive amount with at most two decimals.');return command({p_link:state.link,p_request:crypto.randomUUID(),p_operation:crypto.randomUUID(),p_action:'create',p_expected_revision:null,p_values:{leave_type_id:$('elLeaveType').value,date_from:from,date_to:to,quantity:q,unit:$('elUnit').value}});}
 function cancel(id){if(state.busy||state.pending)return;const r=state.data?.requests?.find(x=>x.id===id);if(!r||r.status!=='pending'||!window.confirm('Cancel this pending leave request?'))return;return command({p_link:state.link,p_request:id,p_operation:crypto.randomUUID(),p_action:'cancel',p_expected_revision:r.revision,p_values:{}});}
 async function start(){
  const c=window.APP_CONFIG;if(c?.environment!=='market'||c.projectRef!=='smvvevrtjqkflyqkyape'||!window.supabase?.createClient)return message('The isolated employee page is unavailable.');
  client=window.supabase.createClient(c.supabaseUrl,c.supabaseKey,{auth:{storageKey:'frindly-market-employee',persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
  payslips=window.FrindlyEmployeePayslips.create({rpc:(name,args)=>client.rpc(name,args),getContext:()=>({user:state.user,link:state.link,enabled:!!state.data?.links?.find(x=>x.id===state.link)?.payslips_enabled})});
  $('elRequestForm').onsubmit=create;$('elRefresh').onclick=()=>state.view==='payslips'?payslips.showList():load();$('elRetry').onclick=()=>state.pending&&command(state.pending.args);$('elShowLeave').onclick=()=>setView('leave');$('elShowPayslips').onclick=()=>setView('payslips');
  $('elWorkplace').onchange=()=>{if(state.busy||state.pending)return;state.link=$('elWorkplace').value||null;state.offset=0;state.data=null;state.view='leave';payslips.reset();$('elRequestForm').reset();void load();};
  $('elPrevious').onclick=()=>{state.offset=Math.max(0,state.offset-100);void load();};$('elNext').onclick=()=>{state.offset+=100;void load();};
  $('elLogin').onsubmit=async e=>{e.preventDefault();const button=$('elLogin').querySelector('button');if(button.disabled)return;button.disabled=true;message('');try{const r=await client.auth.signInWithPassword({email:$('elEmail').value.trim(),password:$('elPassword').value});$('elPassword').value='';if(r.error)throw r.error;showSession(r.data.user);}catch(e){message(e.message||'Sign-in failed.');}finally{button.disabled=false;}};
  $('elSignOut').onclick=async()=>{state.user=null;clear();$('elWorkspace').hidden=true;const {error}=await client.auth.signOut({scope:'local'});if(error)message('Sign-out could not complete. Close this page and try again.');else showSession(null);};
  client.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT')showSession(null);else if(session?.user?.id!==state.user)showSession(session?.user||null);});
  const {data,error}=await client.auth.getSession();if(error)return message('Session could not load. Please sign in again.');showSession(data.session?.user||null);
 }
 window.FrindlyEmployeeLeave=Object.freeze({start});if($('employeeLeaveApp'))void start();
})();
