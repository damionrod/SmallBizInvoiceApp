/* Read-only employee payslip viewer. It never loads the accounting or Payroll application. */
(()=>{
 'use strict';
 const $=id=>document.getElementById(id),esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const number=v=>typeof v==='number'&&Number.isFinite(v)?v:null;
 function create(options){
  const state={generation:0,offset:0,total:0,selected:null,busy:false,context:null};
  const msg=s=>{const n=$('elPayslipMessage');n.textContent=s||'';n.hidden=!s;};
  const context=()=>{const c=options.getContext();if(!c?.user||!c?.link||!c?.enabled)throw Error('Payslip access is unavailable. Ask your employer to check access.');return c;};
  const current=(c,g)=>{const n=context();if(g!==state.generation||n.user!==c.user||n.link!==c.link||!n.enabled)throw Error('Your account or workplace changed. Reopen payslips.');};
  const money=(v,currency)=>{const n=number(v);if(n===null)return 'Unavailable';if(typeof currency!=='string'||!/^[A-Z]{3}$/.test(currency))return `${n.toFixed(2)} (currency unavailable)`;try{return new Intl.NumberFormat(undefined,{style:'currency',currency}).format(n);}catch{return `${n.toFixed(2)} ${currency}`;}};
  const controls=()=>{$('elPayslipPrevious').disabled=state.busy||state.offset===0;$('elPayslipNext').disabled=state.busy||state.offset+100>=state.total;};
  function reset(){state.generation++;state.offset=0;state.total=0;state.selected=null;state.busy=false;state.context=null;$('elPayslips').innerHTML='';$('elPayslipDetail').innerHTML='';$('elPayslipDetail').hidden=true;$('elPayslips').hidden=false;$('elPayslipBack').hidden=true;$('elPayslipPages').hidden=false;$('elPayslipPage').textContent='';msg('');controls();}
  function renderList(data){
   state.total=Number(data.total)||0;
   $('elPayslips').innerHTML=(data.payslips||[]).map(p=>p.available?`<button class="el-payslip-row" data-payslip="${esc(p.id)}"><span><strong>${esc(p.payslip_number)}</strong><br><span class="el-note">Pay date ${esc(p.pay_date)}</span></span><span>${esc(p.period_start)} – ${esc(p.period_end)}</span><span class="el-money">${esc(money(p.net,p.currency))}</span></button>`:`<div class="el-payslip-row"><span><strong>${esc(p.payslip_number)}</strong><br><span class="el-note">Pay date ${esc(p.pay_date)}</span></span><span>${esc(p.period_start)} – ${esc(p.period_end)}</span><span class="el-review">Needs employer review</span></div>`).join('')||'<p class="el-note">No finalised payslips on this page.</p>';
   for(const b of $('elPayslips').querySelectorAll('[data-payslip]'))b.onclick=()=>open(b.dataset.payslip,b);
   $('elPayslipPage').textContent=state.total?`${state.offset+1}–${Math.min(state.offset+100,state.total)} of ${state.total}`:'0 payslips';controls();
  }
  async function showList(){
   const c=context(),g=++state.generation;state.busy=true;state.selected=null;state.context=c;$('elPayslips').innerHTML='';$('elPayslipDetail').hidden=true;$('elPayslips').hidden=false;$('elPayslipBack').hidden=true;$('elPayslipPages').hidden=false;msg('Loading payslips…');controls();
   try{const {data,error}=await options.rpc('v6231_employee_payslips',{p_link:c.link,p_payslip:null,p_offset:state.offset});current(c,g);if(error)throw error;if(data?.link_id!==c.link||data?.mode!=='list')throw Error('Payslip response could not be verified.');msg('');renderList(data);}
   catch(e){if(g!==state.generation)return;$('elPayslips').innerHTML='';msg(e.message||'Payslips could not load.');}
   finally{if(g===state.generation){state.busy=false;controls();}}
  }
  const row=(label,value)=>`<dt>${esc(label)}</dt><dd>${esc(value)}</dd>`;
  async function open(id,source){
   if(state.busy||!id)return;const c=context(),g=++state.generation;state.busy=true;msg('Loading payslip…');controls();
   try{const {data,error}=await options.rpc('v6231_employee_payslips',{p_link:c.link,p_payslip:id,p_offset:0});current(c,g);if(error)throw error;if(data?.link_id!==c.link||data?.mode!=='detail'||data?.payslip?.id!==id)throw Error('Payslip response could not be verified.');const p=data.payslip;if(!p.available)throw Error('This payslip needs employer review before it can be shown.');
    const pay=p.pay||{},currency=p.currency,adjustments=Array.isArray(pay.adjustments)?pay.adjustments:[],work=Array.isArray(pay.work_details)?pay.work_details:[];
    $('elPayslipDetail').innerHTML=`<article class="el-payslip-detail"><h3>${esc(p.payslip_number)}</h3><p>${esc(p.employee_name)} · ${esc(p.period_start)} – ${esc(p.period_end)}</p><dl>${row('Pay date',p.pay_date)}${row('Gross pay',money(pay.gross,currency))}${row('PAYE',money(pay.paye,currency))}${row('KiwiSaver employee',money(pay.kiwisaver_employee,currency))}${row('Student loan',money(pay.student_loan,currency))}${row('Other deductions',money(pay.other_deductions,currency))}${row('Take-home pay',money(pay.net,currency))}</dl>${adjustments.length?`<h3>Adjustments</h3><dl>${adjustments.map(x=>row(x.description||x.type||'Adjustment',money(x.amount,currency))).join('')}</dl>`:''}${work.length?`<h3>Work details</h3><div>${work.map(x=>`<p>${esc(x.date)} · ${esc(x.job||'General')} · ${esc(x.hours)} hours · ${esc(money(x.amount,currency))}</p>`).join('')}</div>`:''}</article>`;
    state.selected={id,source};$('elPayslips').hidden=true;$('elPayslipDetail').hidden=false;$('elPayslipBack').hidden=false;$('elPayslipPages').hidden=true;msg('');$('elPayslipHeading').focus();
   }catch(e){if(g===state.generation)msg(e.message||'Payslip could not load.');}
   finally{if(g===state.generation){state.busy=false;controls();}}
  }
  function back(){const source=state.selected?.source;state.generation++;state.selected=null;$('elPayslipDetail').hidden=true;$('elPayslips').hidden=false;$('elPayslipBack').hidden=true;$('elPayslipPages').hidden=false;msg('');source?.focus?.();}
  $('elPayslipBack').onclick=back;$('elPayslipPrevious').onclick=()=>{state.offset=Math.max(0,state.offset-100);void showList();};$('elPayslipNext').onclick=()=>{state.offset+=100;void showList();};
  return Object.freeze({reset,showList,open});
 }
 window.FrindlyEmployeePayslips=Object.freeze({create});
})();
