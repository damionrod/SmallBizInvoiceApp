/* Frindly Payroll Leave Drafts — isolated manager UI, v6236.
 * Opt-in only. No route registration or existing payroll file changes.
 * Mount with: FrindlyManagerLeaveDrafts.mount(element, {client: supabaseClient})
 * Hard-restricted to isolated Supabase project.
 */
(function(root){
'use strict';
const EXPECTED_PROJECT='smvvevrtjqkflyqkyape';
const css=`
.fr-leave{font:inherit;max-width:860px;color:inherit}
.fr-leave *{box-sizing:border-box}
.fr-leave h2{margin:0 0 12px;font-size:1.2rem}
.fr-leave form{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
.fr-leave label{display:flex;flex-direction:column;gap:5px;font-size:.9rem}
.fr-leave input,.fr-leave select{width:100%;min-height:42px;padding:8px 10px;border:1px solid #b7beca;border-radius:8px;background:#fff;color:#182335;font:inherit}
.fr-leave button{min-height:42px;border:0;border-radius:8px;padding:9px 18px;background:#6035a5;color:white;font:inherit;cursor:pointer}
.fr-leave button:disabled{opacity:.55;cursor:wait}
.fr-leave .wide{grid-column:1/-1}
.fr-leave .notice{margin:10px 0;font-size:.9rem;white-space:pre-wrap}
 .fr-leave .draft-item{border:1px solid #d9dce4;border-radius:9px;padding:12px;margin:10px 0} .fr-leave .draft-item p{margin:6px 0 10px} 
 .fr-leave .history-entry{border-bottom:1px solid #e2e4ea;padding:7px 0;margin:0;font-size:.9rem}
@media(max-width:600px){.fr-leave form{grid-template-columns:minmax(0,1fr)}}
`;
function node(tag,attrs={},text){
 const el=document.createElement(tag);
 for(const [k,v] of Object.entries(attrs)){if(k==='class')el.className=v;else el.setAttribute(k,v);}
 if(text!==undefined)el.textContent=String(text);
 return el;
}
function validDate(s){return /^\d{4}-\d{2}-\d{2}$/.test(s)&&!Number.isNaN(Date.parse(s+'T12:00:00Z'))}
function mount(target,{client}={}){
 if(!target||typeof target.appendChild!=='function')throw Error('Mount target required');
 if(!client||typeof client.rpc!=='function')throw Error('Supabase client required');
 const host=new URL(client.supabaseUrl||'https://invalid.example').hostname;
 if(host!==EXPECTED_PROJECT+'.supabase.co')throw Error('This screen is restricted to the isolated payroll environment');
 target.replaceChildren();
 const wrap=node('section',{class:'fr-leave'});
 const style=node('style');style.textContent=css;wrap.append(style,node('h2',{},'Create leave draft'));
 const notice=node('p',{class:'notice',role:'status','aria-live':'polite'},'Loading payroll employees and leave types…');
 const form=node('form');form.hidden=true;
 function field(title,type,required=true){
   const label=node('label');label.append(node('span',{},title));
   const input=node(type==='select'?'select':'input',type==='select'?{}:{type});
   if(required)input.required=true;
   label.append(input);form.append(label);return input;
 }
 const employee=field('Employee','select'),leave=field('Leave type','select'),
 from=field('Start date','date'),to=field('End date','date'),
 qty=field('Quantity','number'),unit=field('Unit','select');
 qty.min='0.01';qty.max='10000';qty.step='0.01';
 for(const [v,label] of [['hours','Hours'],['days','Days'],['weeks','Weeks']]){
   const opt=node('option',{value:v},label);unit.append(opt);
 }
 const action=node('div',{class:'wide'}),save=node('button',{type:'submit'},'Save draft');
 const cancel=node('button',{type:'button'},'Cancel edit');cancel.hidden=true;cancel.style.marginLeft='8px';
 action.append(save,cancel);form.append(action);wrap.append(notice,form);
 const heading=node('h2',{},'Saved drafts'),draftList=node('div',{class:'draft-list'});
 const approvalHeading=node('h2',{},'Leave approvals'),approvalList=node('div',{class:'approval-list'});
 const historyHeading=node('h2',{},'Draft activity'),historyList=node('div',{class:'draft-history'});
 wrap.append(heading,draftList,approvalHeading,approvalList,historyHeading,historyList);target.append(wrap);
 let editing=null;
 cancel.addEventListener('click',()=>{editing=null;form.reset();save.textContent='Save draft';cancel.hidden=true;});
 async function approvalAction(draftId,action){
   const {error}=await client.rpc('v6239_manager_leave_approval_command',{p_draft_id:draftId,p_action:action});
   if(error)throw error;
   await loadDrafts();await loadApprovals();
   notice.textContent='Request '+(action==='submit'?'submitted':action==='approve'?'approved':'declined')+' in isolated testing. Payroll unchanged.';
 }
 async function loadApprovals(){
   const {data,error}=await client.rpc('v6239_manager_leave_approvals_read');
   if(destroyed)return;
   approvalList.replaceChildren();
   if(error){approvalList.append(node('p',{},'Unable to load approvals: '+error.message));return;}
   const rows=Array.isArray(data)?data:[];
   if(!rows.length){approvalList.append(node('p',{},'No submitted requests yet.'));return;}
   for(const a of rows){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},a.employee+' — '+a.leave_type+' · '+a.status));
     item.append(node('p',{},a.date_from+' to '+a.date_to+' · '+a.quantity+' '+a.unit));
     if(a.status==='pending'){
       for(const [action,label] of [['approve','Approve'],['decline','Decline']]){
         const btn=node('button',{type:'button'},label);btn.style.marginRight='8px';
         btn.addEventListener('click',async()=>{
           if(save.disabled||btn.disabled)return;
           if(!window.confirm(label+' this leave request?'))return;
           save.disabled=true;btn.disabled=true;
           try{await approvalAction(a.draft_id,action);}
           catch(err){notice.textContent=label+' failed: '+(err.message||'Unknown error');btn.disabled=false;}
           finally{save.disabled=false;}
         });
         item.append(btn);
       }
     }
     approvalList.append(item);
   }
 }
 async function loadHistory(){
   const {data,error}=await client.rpc('v6238_manager_leave_draft_history');
   if(destroyed)return;
   historyList.replaceChildren();
   if(error){historyList.append(node('p',{},'Unable to load activity: '+error.message));return;}
   const rows=Array.isArray(data)?data:[];
   if(!rows.length){historyList.append(node('p',{},'No draft activity yet.'));return;}
   for(const a of rows){
     const entry=node('p',{class:'history-entry'},(a.action==='create'?'Created':a.action==='update'?'Edited':'Deleted')+' draft · '+new Date(a.created_at).toLocaleString());
     historyList.append(entry);
   }
 }
 async function loadDrafts(){
   const {data,error}=await client.rpc('v6237_manager_leave_drafts_read');
   if(destroyed)return;
   draftList.replaceChildren();
   if(error){draftList.append(node('p',{},'Unable to load drafts: '+error.message));return;}
   const drafts=Array.isArray(data)?data:[];
   heading.textContent='Saved drafts ('+drafts.length+')';
   if(!drafts.length){draftList.append(node('p',{},'No saved drafts yet.'));return;}
   for(const d of drafts){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},d.employee_name+' — '+d.leave_type));
     item.append(node('p',{},d.date_from+' to '+d.date_to+' · '+d.quantity+' '+d.unit));
     const edit=node('button',{type:'button'},'Edit');
     edit.addEventListener('click',()=>{
       editing=d.id;employee.value=d.employee_id;leave.value=d.leave_type_id;
       from.value=d.date_from;to.value=d.date_to;qty.value=d.quantity;unit.value=d.unit;
       save.textContent='Update draft';cancel.hidden=false;
       form.scrollIntoView({behavior:'smooth',block:'start'});
     });
     const del=node('button',{type:'button'},'Delete');
     del.style.marginLeft='8px';
     del.addEventListener('click',async()=>{
       if(del.disabled||save.disabled)return;
       if(!window.confirm('Permanently delete this draft? This cannot be undone.'))return;
       edit.disabled=true;del.disabled=true;save.disabled=true;
       const {error}=await client.rpc('v6237_manager_leave_draft_delete',{p_id:d.id});
       if(error){notice.textContent='Delete failed: '+error.message;edit.disabled=false;del.disabled=false;save.disabled=false;return;}
       if(editing===d.id)cancel.click();
       notice.textContent='Draft deleted; audit entry retained.';
       try{await loadDrafts();await loadApprovals();await loadHistory();}finally{save.disabled=false;}
     });
     const submit=node('button',{type:'button'},'Submit for approval');submit.style.marginLeft='8px';
     submit.addEventListener('click',async()=>{
       if(save.disabled||submit.disabled)return;
       if(!window.confirm('Submit this draft? It will be locked against edits and deletion.'))return;
       save.disabled=true;submit.disabled=true;
       try{await approvalAction(d.id,'submit');if(editing===d.id)cancel.click();}
       catch(err){notice.textContent='Submission failed: '+(err.message||'Unknown error');submit.disabled=false;}
       finally{save.disabled=false;}
     });
     item.append(edit,del,submit);draftList.append(item);
   }
 }

 let destroyed=false;
 async function init(){
   try{
     const [employeesRes,leaveRes]=await Promise.all([
       client.from('payroll_employees').select('id,first_name,last_name').eq('archived',false).in('employment_status',['active','on_leave']).order('first_name').limit(500),
       client.from('payroll_leave_types').select('id,name').eq('archived',false).order('name').limit(200)
     ]);
     if(employeesRes.error)throw employeesRes.error;
     if(leaveRes.error)throw leaveRes.error;
     if(destroyed)return;
     const employees=employeesRes.data||[],types=leaveRes.data||[];
     for(const e of employees)employee.append(node('option',{value:e.id},[e.first_name,e.last_name].filter(Boolean).join(' ')));
     for(const t of types)leave.append(node('option',{value:t.id},t.name));
     if(!employees.length||!types.length){notice.textContent='No eligible employees or leave types are available.';return;}
     form.hidden=false;notice.textContent='Draft only — this does not approve leave or change payroll balances.';
     await loadDrafts();await loadApprovals();await loadHistory();
   }catch(err){if(!destroyed)notice.textContent='Unable to load leave form: '+(err.message||'Access denied');}
 }
 form.addEventListener('submit',async event=>{
   event.preventDefault();
   if(save.disabled)return;
   const q=Number(qty.value);
   if(!validDate(from.value)||!validDate(to.value)||to.value<from.value||!Number.isFinite(q)||q<=0||q>10000||!/^\d+(?:\.\d{1,2})?$/.test(qty.value)){
     notice.textContent='Enter valid dates and a positive quantity (up to two decimals).';return;
   }
   save.disabled=true;notice.textContent='Saving draft…';
   try{
     const {error}=await client.rpc(editing?'v6237_manager_leave_draft_update':'v6236_manager_leave_draft_create',{
       ...(editing?{p_id:editing}:{}),p_employee:employee.value,p_leave_type:leave.value,p_from:from.value,
       p_to:to.value,p_quantity:q,p_unit:unit.value
     });
     if(error)throw error;
     notice.textContent='Leave draft saved in isolated testing. No payroll balances were changed.';
     cancel.click();await loadDrafts();await loadApprovals();await loadHistory();
   }catch(err){notice.textContent='Draft not saved: '+(err.message||'Access denied');}
   finally{if(!destroyed)save.disabled=false;}
 });
 init();
 return {destroy(){destroyed=true;target.replaceChildren();}};
}
root.FrindlyManagerLeaveDrafts=Object.freeze({mount});
})(typeof window!=='undefined'?window:globalThis);
