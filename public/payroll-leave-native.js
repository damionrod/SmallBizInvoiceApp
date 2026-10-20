/* Native, read-only Leave Management shell. Does not post leave or payroll entries. */
(()=>{
'use strict';
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let loading=false,lastBusiness='';
async function load(){
 const root=$('frindlyLeaveNative');if(!root||loading||!$('payroll-panel-leave')?.classList.contains('active'))return;
 const client=window.SAAS?.client?.(),business=window.SAAS?.state?.business,bid=business?.id;
 if(!client||!bid){root.textContent='Select a business and open Payroll to view leave information.';return}
 loading=true;lastBusiness=bid;root.textContent='Loading employees and leave types…';
 try{
  const [er,tr]=await Promise.all([
   client.from('payroll_employees').select('id,first_name,last_name,preferred_name,employment_status,archived').eq('business_id',bid).eq('archived',false).order('last_name').limit(500),
   client.from('payroll_leave_types').select('id,name').eq('business_id',bid).eq('archived',false).order('name').limit(100)
  ]);
  if(er.error)throw er.error;if(tr.error)throw tr.error;
  if(window.SAAS?.state?.business?.id!==bid)return;
  const employees=(er.data||[]).filter(e=>e.employment_status==='active');
  const types=tr.data||[];
  root.innerHTML='<div style="display:flex;flex-wrap:wrap;gap:16px;margin:0 0 16px"><div class="card" style="padding:12px;flex:1;min-width:160px"><strong>'+employees.length+'</strong><div>Active employees</div></div><div class="card" style="padding:12px;flex:1;min-width:160px"><strong>'+types.length+'</strong><div>Configured leave types</div></div></div>'+
   '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px"><section><h3>Employees</h3><div style="max-height:320px;overflow:auto">'+(employees.length?employees.map(e=>'<div style="padding:8px 0;border-bottom:1px solid #e2e8f0">'+esc([e.preferred_name||e.first_name,e.last_name].filter(Boolean).join(' '))+'</div>').join(''):'No active employees found')+'</div></section>'+
   '<section><h3>Leave types</h3><div style="max-height:320px;overflow:auto">'+(types.length?types.map(t=>'<div style="padding:8px 0;border-bottom:1px solid #e2e8f0">'+esc(t.name)+'</div>').join(''):'No leave types configured')+'</div></section></div>'+
   '<p style="margin-top:18px;color:var(--muted,#64748b)">Requests, approvals, evidence and team calendar will be enabled after the leave backend passes production permissions and migration checks. No leave or payroll data is changed on this page.</p>';
 }catch(err){root.textContent='Leave information could not load: '+(err?.message||'Access unavailable')+' — no changes were made.'}
 finally{loading=false}
}
document.addEventListener('click',e=>{if(e.target.closest('[data-payroll-tab="leave"]'))setTimeout(load,0)});
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&$('payroll-panel-leave')?.classList.contains('active')&&lastBusiness!==window.SAAS?.state?.business?.id)load()});
})();