/* Frindly native Leave Management: isolated RPCs only; never posts payroll or changes balances. */
(()=>{'use strict';
const el=id=>document.getElementById(id),client=()=>window.SAAS?.client?.(),bid=()=>window.SAAS?.state?.business?.id;
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let activeBusiness=null,employees=[],types=[],requests=[],payRuns=[],busy=false,selectedDays=new Set(),calendarMonth=new Date().toISOString().slice(0,7);
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
 '<fieldset style="border:1px solid #dbe2ef;border-radius:8px;padding:12px;margin:12px 0"><legend style="padding:0 6px">Leave duration</legend><div style="display:flex;flex-wrap:wrap;gap:10px 24px;align-items:center"><label style="display:inline-flex;align-items:center;gap:8px;width:auto;margin:0;cursor:pointer;line-height:1.4"><input type="radio" name="leaveMode" value="days" checked style="width:17px;height:17px;margin:0;flex:0 0 17px;accent-color:#4169e1"> <span>Whole working days</span></label><label style="display:inline-flex;align-items:center;gap:8px;width:auto;margin:0;cursor:pointer;line-height:1.4"><input type="radio" name="leaveMode" value="hours" style="width:17px;height:17px;margin:0;flex:0 0 17px;accent-color:#4169e1"> <span>Part day / hours</span></label></div></fieldset>'+
 '<div id="leaveCalendarSection"><div style="display:flex;align-items:center;justify-content:space-between;gap:12px;margin:8px 0"><strong>Select whole leave days</strong><button type="button" id="leaveClearDates">Clear</button></div><div id="leaveCalendar"></div><small>Select each day you need, including non-consecutive dates. Weekends cannot be selected; check public holidays and the employee roster.</small></div><div id="leaveHourlyDate" style="display:none"><label>Leave date<input name="from" type="date" disabled></label></div>'+
 '<div id="leaveHoursField" style="display:none"><label>Hours of leave<input name="hours" type="number" min="0.25" max="24" step="0.25" disabled></label><small>Enter the actual leave hours for this date.</small></div>'+
 '<p id="leaveDurationPreview" role="status" aria-live="polite">Choose leave dates to calculate the duration.</p>'+
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
 activeBusiness=b;employees=(a.data||[]).filter(x=>['active','on_leave'].includes(x.employment_status));types=t.data||[];requests=Array.isArray(r)?r:[];payRuns=p.error?[]:(p.data||[]);draw();renderLeaveCalendar();updateDuration();
 }catch(e){if(bid()===b)root().textContent='Leave Management unavailable: '+(e.message||'Permission denied')}
}
async function run(name,args,success){
 if(busy)return;if(bid()!==activeBusiness){await load();return}
 busy=true;note('Saving…');
 try{await rpc(name,args);busy=false;await load();note(success)}
 catch(e){note('Action failed: '+(e.message||'Permission denied'))}finally{busy=false}
}
function countWeekdays(from,to){
 if(!/^\d{4}-\d{2}-\d{2}$/.test(from)||!/^\d{4}-\d{2}-\d{2}$/.test(to)||to<from)return 0;
 const start=new Date(from+'T12:00:00Z'),end=new Date(to+'T12:00:00Z');
 if(!Number.isFinite(start.getTime())||!Number.isFinite(end.getTime()))return 0;
 const span=Math.round((end-start)/86400000);
 if(span>366)return 0;
 let days=0;for(let i=0;i<=span;i++){const dow=new Date(start.getTime()+i*86400000).getUTCDay();if(dow!==0&&dow!==6)days++}return days;
}
function renderLeaveCalendar(){
 const host=el('leaveCalendar');if(!host)return;
 const [y,m]=calendarMonth.split('-').map(Number),first=new Date(Date.UTC(y,m-1,1)),length=new Date(Date.UTC(y,m,0)).getUTCDate(),offset=(first.getUTCDay()+6)%7;
 const monthLabel=first.toLocaleDateString('en-NZ',{month:'long',year:'numeric',timeZone:'UTC'});
 let html='<div style="display:flex;align-items:center;justify-content:space-between;margin:8px 0"><button type="button" data-calendar-move="-1" aria-label="Previous month">‹</button><strong>'+esc(monthLabel)+'</strong><button type="button" data-calendar-move="1" aria-label="Next month">›</button></div>'+
 '<div style="display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:4px;text-align:center">';
 for(const day of ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'])html+='<small>'+day+'</small>';
 for(let i=0;i<offset;i++)html+='<span></span>';
 for(let d=1;d<=length;d++){
  const date=calendarMonth+'-'+String(d).padStart(2,'0'),dow=new Date(Date.UTC(y,m-1,d)).getUTCDay(),weekend=dow===0||dow===6,selected=selectedDays.has(date);
  html+='<button type="button" data-calendar-day="'+date+'" '+(weekend?'disabled title="Weekend"':'aria-pressed="'+selected+'"')+
   ' style="min-width:0;padding:9px 2px;border-radius:7px;border:1px solid '+(selected?'#4169e1':'#dbe2ef')+';background:'+(selected?'#4169e1':'transparent')+';color:'+(selected?'white':weekend?'#a9a9a9':'inherit')+';cursor:'+(weekend?'not-allowed':'pointer')+'">'+d+'</button>';
 }
 host.innerHTML=html+'</div>';
}
function updateDuration(){
 const form=el('leaveCreate');if(!form)return;
 const mode=form.querySelector('input[name="leaveMode"]:checked')?.value||'days';
 const from=form.elements.from.value,hours=Number(form.elements.hours.value);
 const calendar=el('leaveCalendarSection'),hourDate=el('leaveHourlyDate'),hourField=el('leaveHoursField'),preview=el('leaveDurationPreview');
 if(calendar)calendar.style.display=mode==='days'?'':'none';
 if(hourDate)hourDate.style.display=mode==='hours'?'':'none';
 if(hourField)hourField.style.display=mode==='hours'?'':'none';
 form.elements.from.disabled=mode==='days';form.elements.from.required=mode==='hours';
 form.elements.hours.disabled=mode!=='hours';form.elements.hours.required=mode==='hours';
 if(preview)preview.textContent=mode==='days'?(selectedDays.size?selectedDays.size+' full working day(s) selected: '+[...selectedDays].sort().join(', ')+'. Confirm roster and public holidays.':'Select the dates you need on the calendar.'):(from&&hours>0?hours+' hours on '+from:'Select a date and enter the hours of leave.');
}
document.addEventListener('change',e=>{if(e.target.closest('#leaveCreate'))updateDuration()});
document.addEventListener('input',e=>{if(e.target.closest('#leaveCreate'))updateDuration()});
document.addEventListener('submit',e=>{
 if(e.target.id!=='leaveCreate')return;e.preventDefault();
 const d=new FormData(e.target),mode=String(d.get('leaveMode')||'days'),from=String(d.get('from')||''),qty=mode==='hours'?Number(d.get('hours')):selectedDays.size,unit=mode==='hours'?'hours':'days';
 if(!Number.isFinite(qty)||qty<=0||(mode==='hours'&&(!from||qty>24))||(mode==='days'&&qty>31)){note('Select valid leave dates or hours (maximum 31 whole days).');return}
 const approve=e.submitter?.value==='approve';
 const dates=[...selectedDays].sort(),summary=mode==='days'?dates.join(', '):from+' ('+qty+' hours)';
 if(!confirm('Request '+qty+' '+unit+' for '+summary+'? Confirm roster, public holidays and entitlement. '+(approve?'Create and approve?':'Save draft?')+' No payroll records will be changed.'))return;
 if(mode==='days'){
  run('frindly_leave_request_create_selected_days',{p_employee:d.get('employee'),p_leave_type:d.get('type'),p_dates:dates,p_approve:approve},approve?'Selected leave days approved':'Selected leave days saved');
 }else{
  run(approve?'frindly_leave_request_create_and_approve':'frindly_leave_request_create',{p_employee:d.get('employee'),p_leave_type:d.get('type'),p_from:from,p_to:from,p_quantity:qty,p_unit:unit},approve?'Hourly leave approved':'Hourly leave draft saved');
 }
});
document.addEventListener('click',async e=>{
 const move=e.target.closest('[data-calendar-move]');
 if(move){const [y,m]=calendarMonth.split('-').map(Number);calendarMonth=new Date(Date.UTC(y,m-1+Number(move.dataset.calendarMove),1)).toISOString().slice(0,7);renderLeaveCalendar();return}
 const day=e.target.closest('[data-calendar-day]');
 if(day&&!day.disabled){const date=day.dataset.calendarDay;if(selectedDays.has(date))selectedDays.delete(date);else if(selectedDays.size<31)selectedDays.add(date);else{note('Maximum 31 dates per request');return}renderLeaveCalendar();updateDuration();return}
 if(e.target.closest('#leaveClearDates')){selectedDays.clear();renderLeaveCalendar();updateDuration();return}

 if(e.target.closest('#leaveReviewButton')){
   const runId=el('leaveReviewRun')?.value,out=el('leaveReviewResult');if(!runId||!out){note('Select a pay run to review');return}
   if(bid()!==activeBusiness){note('Business changed. Reload Leave Management.');return}
   out.textContent='Checking approved leave…';
   try{const result=await rpc('frindly_leave_payroll_review',{p_pay_run_id:runId});if(bid()!==activeBusiness)return;
     const rows=Array.isArray(result?.requests)?result.requests:[];
     out.innerHTML='<p>'+rows.length+' approved leave request(s) overlap this pay run. No financial records changed.</p>'+
       (rows.length?'<ul>'+rows.map(x=>'<li>'+esc(x.from)+' – '+esc(x.to)+' · '+esc(x.quantity)+' '+esc(x.unit)+' · '+esc(x.employment_type||'Employment type not set')+' · '+(x.existing_leave_transaction||x.already_in_pay_run?'<strong>Possible duplicate: inspect existing leave transaction</strong>':'Statutory entitlement and pay need confirmation')+' <button type="button" data-leave-preflight="'+esc(x.request_id)+'">Check payroll readiness</button><span id="leavePreflight-'+esc(x.request_id)+'"></span></li>').join('')+'</ul>':'<p>No approved leave requiring review in this pay run.</p>');
   }catch(error){out.textContent='Review unavailable: '+(error.message||'Permission denied')}
   return;
 }

 const preflight=e.target.closest('[data-leave-preflight]');
 if(preflight){
   const requestId=preflight.dataset.leavePreflight,runId=el('leaveReviewRun')?.value;
   const output=el('leavePreflight-'+requestId);
   if(!runId||!output||bid()!==activeBusiness)return;
   output.textContent=' Checking…';
   try{
     const data=await rpc('frindly_leave_payroll_preflight',{p_pay_run_id:runId,p_leave_request_id:requestId});
     if(bid()!==activeBusiness||el('leaveReviewRun')?.value!==runId)return;
     output.textContent=' '+(data?.existing_link_count?'Prior processing found; reconciliation required. ':'')+
       'Not ready for automatic posting: '+(Array.isArray(data?.requires_confirmation)?data.requires_confirmation.join(', '):'manual statutory and payroll verification required')+'.';
   }catch(error){output.textContent=' Readiness check failed: '+(error.message||'Permission denied')}
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