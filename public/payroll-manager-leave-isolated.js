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
 action.append(save);form.append(action);wrap.append(notice,form);target.append(wrap);
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
   }catch(err){if(!destroyed)notice.textContent='Unable to load leave form: '+(err.message||'Access denied');}
 }
 form.addEventListener('submit',async event=>{
   event.preventDefault();
   if(save.disabled)return;
   const q=Number(qty.value);
   if(!validDate(from.value)||!validDate(to.value)||to.value<from.value||!Number.isFinite(q)||q<=0||q>10000||Math.round(q*100)!==q*100){
     notice.textContent='Enter valid dates and a positive quantity (up to two decimals).';return;
   }
   save.disabled=true;notice.textContent='Saving draft…';
   try{
     const {error}=await client.rpc('v6236_manager_leave_draft_create',{
       p_employee:employee.value,p_leave_type:leave.value,p_from:from.value,
       p_to:to.value,p_quantity:q,p_unit:unit.value
     });
     if(error)throw error;
     notice.textContent='Leave draft saved in isolated testing. No payroll balances were changed.';
     form.reset();
   }catch(err){notice.textContent='Draft not saved: '+(err.message||'Access denied');}
   finally{if(!destroyed)save.disabled=false;}
 });
 init();
 return {destroy(){destroyed=true;target.replaceChildren();}};
}
root.FrindlyManagerLeaveDrafts=Object.freeze({mount});
})(typeof window!=='undefined'?window:globalThis);
