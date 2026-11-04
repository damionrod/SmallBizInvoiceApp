/* GST/payroll settlement UI. Uses existing expense modal classes and bank account source. */
(()=>{
 'use strict';
 const $=id=>document.getElementById(id), sb=()=>window.SAAS?.client?.(), bid=()=>window.SAAS?.state?.business?.id;
 const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
 const cents=v=>Math.round(Number(v||0)*100), money=v=>window.FinloCore.format.money(Number(v||0),{currency:window.SAAS?.state?.business?.settings?.currency||'NZD'});
 const toast=m=>{if(window.FinloCore?.ui?.toast)window.FinloCore.ui.toast(m);else window.showToast?.(m);};
 const today=()=>new Intl.DateTimeFormat('en-CA',{timeZone:window.SAAS?.state?.business?.settings?.timezone||'Pacific/Auckland',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 let context=null,sequence=0;
 function modal(){let m=$('liabilityPaymentModal');if(m)return m;m=document.createElement('div');m.id='liabilityPaymentModal';m.className='modal';m.setAttribute('role','dialog');m.setAttribute('aria-modal','true');m.setAttribute('aria-label','Record Payment');m.innerHTML='<div class="modal-box small-modal"><button class="close" id="lpClose" aria-label="Close">×</button><div id="lpContent"></div></div>';document.body.append(m);$('lpClose').onclick=close;m.addEventListener('click',e=>{if(e.target===m)close()});return m;}
 function close(){if(context?.busy)return;const b=$('lpClose');if(b)b.disabled=false;sequence++;context=null;modal().classList.remove('open');}
 async function rpc(name,args){const r=await sb().rpc(name,args);if(r.error)throw new Error(r.error.message);return r.data;}
 function active(c){return context===c&&bid()===c.bid;}
 function error(c,e){if(!active(c))return;const el=$('lpError');if(el){el.textContent=e.message||String(e);el.hidden=false;}else toast(e.message||String(e));}
 async function banks(c){const select=$('lpBank');const r=await sb().from('bank_accounts').select('id,name,account_number,is_default,archived,accounting_account_id').eq('business_id',c.bid).eq('archived',false).order('name');if(!active(c))return;if(r.error)throw new Error(r.error.message);select.replaceChildren(new Option('Select a bank account',''));for(const b of r.data||[]){const o=new Option(b.name+(b.account_number?' · '+b.account_number:'')+(!b.accounting_account_id?' (ledger setup required)':''),b.id);o.disabled=!b.accounting_account_id;select.add(o);}const defaults=(r.data||[]).filter(b=>b.accounting_account_id&&b.is_default);if(c.tx)select.value=c.tx.bank_account_id;else if(defaults.length===1)select.value=defaults[0].id;select.disabled=!!c.tx;}
 function allocations(c){if(c.obligations.length===1)return [{...c.obligations[0],amount:Number($('lpAmount').value)}];return c.obligations.map((o,i)=>({...o,amount:Number($('lpAllocation'+i)?.value||0)})).filter(o=>o.amount>0);}
 function refreshAmount(c){if(!active(c)||c.obligations.length===1)return;$('lpAmount').value=(c.obligations.reduce((s,o,i)=>s+cents($('lpAllocation'+i)?.value),0)/100).toFixed(2);}
 // Read the same settlement balances used by the dialog; never infer payment from finalisation.
 let buttonRefreshSequence=0;
 async function refreshButtons(){
  const businessId=bid(),token=++buttonRefreshSequence;
  const buttons=[...document.querySelectorAll('[data-liability-kind][data-liability-source]')];
  if(!businessId||!buttons.length)return;
  const kinds=[...new Set(buttons.map(b=>b.dataset.liabilityKind))];
  await Promise.all(kinds.map(async kind=>{
   let data;
   try{data=await rpc('frindly_settlement_snapshot',{p_kind:kind,p_source_id:null});}
   catch{return;} // Keep the normal payment action if its status cannot be confirmed.
   if(bid()!==businessId||token!==buttonRefreshSequence)return;
   const grouped=new Map();
   for(const o of data?.obligations||[]){if(o.kind!==kind)continue;const key=String(o.source_id);if(!grouped.has(key))grouped.set(key,[]);grouped.get(key).push(o);}
   for(const b of buttons){
    if(!b.isConnected||b.dataset.liabilityKind!==kind)continue;
    const rows=grouped.get(b.dataset.liabilitySource)||[];
    if(!rows.length||rows.some(o=>o.outstanding==null||!Number.isFinite(Number(o.outstanding))||o.total==null||!Number.isFinite(Number(o.total))))continue;
    const total=rows.reduce((n,o)=>n+cents(o.total),0),remaining=rows.reduce((n,o)=>n+cents(o.outstanding),0),paid=rows.reduce((n,o)=>n+cents(o.paid),0);
    const legacy=rows.some(o=>o.notice&&o.account_id===null),refund=kind==='gst'&&rows.every(o=>o.direction==='refund');
    const suffix=kind==='wages'?' · Wages':kind==='ird'?' · IRD':'';
    const settled=total>0&&remaining===0&&paid>0&&!legacy;
    const partial=paid>0&&remaining>0&&!legacy;
    b.textContent=(legacy?'Bank posted':settled?(refund?'Refund Received':'Paid'):partial?(refund?'Partially Refunded':'Partially Paid'):total===0?'No payment due':refund?'Record Refund Received':'Record Payment')+suffix;
    b.dataset.paymentStatus=legacy?'legacy':settled?'paid':partial?'partial':total===0?'not_due':'unpaid';
    b.title=legacy?'Bank was already credited by legacy payroll. View details.':settled?'Fully settled. View payment history.':partial?'Partially settled. View history or record the remaining payment.':'View payment details';
    b.style.color=settled?'#16794b':'';b.style.borderColor=settled?'#b6dfc8':'';b.style.backgroundColor=settled?'#effaf3':'';
   }
  }));
 }
 function history(c){const rows=[...(c.data.payments||[]),...(c.data.existing_settlements||[])];return '<h3>Payment history</h3><div class="table-scroll"><table><thead><tr><th>Date</th><th>Amount</th><th>Reference</th><th>Bank match</th></tr></thead><tbody>'+ (rows.map(p=>`<tr><td>${esc(p.payment_date)}</td><td>${esc(money(p.amount))}</td><td>${esc(p.reference||'—')}</td><td>${p.matched?(p.legacy?'Matched · legacy bank posting':'Matched'):'Waiting for bank match'}</td></tr>`).join('')||'<tr><td colspan="4">No payments recorded.</td></tr>')+'</tbody></table></div>';}
 async function open(kind,sourceId=null,tx=null){
  const token=++sequence,c={bid:bid(),kind,sourceId,tx,requestId:crypto.randomUUID(),busy:false};context=c;modal().classList.add('open');$('lpContent').innerHTML='<p class="hint">Loading payment details…</p><p id="lpError" role="alert" hidden></p>';
  try{c.data=await rpc('frindly_settlement_snapshot',{p_kind:kind,p_source_id:sourceId});if(!active(c)||token!==sequence)return;
   c.obligations=(c.data.obligations||[]).filter(o=>o.outstanding>0&&!o.notice&&o.account_id&&(!tx||(o.direction==='payment')===(tx.amount<0)));
   const all=c.data.obligations||[],total=all.reduce((s,o)=>s+cents(o.total),0),paid=all.reduce((s,o)=>s+cents(o.paid),0),remaining=all.reduce((s,o)=>s+cents(o.outstanding),0),refund=c.obligations[0]?.direction==='refund',label=refund?'Record Refund Received':'Record Payment';
   $('lpContent').innerHTML=`<h2>${label}</h2><p class="hint">${esc(kind==='gst'?'GST return':kind==='wages'?'Employee net wages':'IRD obligations')}${sourceId&&all[0]?' · '+esc(all[0].label):''}</p>${c.data.filing_status?`<p class="hint">Filing: ${esc(c.data.filing_status)}</p>`:''}<p><strong>${!all.length?'Posting review required':all.some(o=>o.notice&&o.account_id===null)?'Bank posted (legacy)':remaining===0?'Paid':paid>0?'Partially Paid':'Unpaid'}</strong> · Outstanding ${esc(money(remaining/100))}</p>${all.filter(o=>o.notice).map(o=>`<p class="hint">${esc(o.notice)}</p>`).join('')}<p id="lpError" role="alert" hidden></p>${c.obligations.length?`<div class="form-grid compact"><label>Payment date<input id="lpDate" type="date" required value="${esc(tx?.transaction_date||today())}" ${tx?'disabled':''}></label><label>Amount<input id="lpAmount" type="number" min="0.01" step="0.01" inputmode="decimal" value="${c.obligations.length===1?Number(tx?(refund&&cents(tx.amount)-cents(c.obligations[0].outstanding)===1?Math.abs(tx.amount):Math.min(Math.abs(tx.amount),c.obligations[0].outstanding)):c.obligations[0].outstanding).toFixed(2):'0.00'}" ${c.obligations.length>1?'readonly':''}></label><label>Payment method<input value="Bank transfer" readonly></label><label>Bank account<select id="lpBank" required><option value="">Loading bank accounts…</option></select></label><label>Reference<input id="lpReference" value="${esc(tx?.reference||'')}"></label></div>${refund&&c.obligations.length===1?'<label><input type="checkbox" id="lpConfirmRounding"> myIR confirms the extra 1 cent is rounding</label>':''}${c.obligations.length>1?`<h3>Allocate payment</h3><div class="table-scroll"><table><thead><tr><th>Pay run / return</th><th>Outstanding</th><th>Pay now</th></tr></thead><tbody>${c.obligations.map((o,i)=>`<tr><td>${esc(o.label)}</td><td>${esc(money(o.outstanding))}</td><td><input id="lpAllocation${i}" aria-label="Allocate to ${esc(o.label)}" type="number" min="0" max="${Number(o.outstanding).toFixed(2)}" step="0.01" inputmode="decimal" value="0.00"></td></tr>`).join('')}</tbody></table></div>`:''}${kind==='ird'&&sourceId?'<button type="button" class="secondary" id="lpOtherRuns">Allocate across multiple pay runs</button>':''}<p class="hint">Use the actual payment date for historical payments. Filing or finalising does not record payment.</p>`:''}${history(c)}<div class="actions"><button class="secondary" id="lpCancel">Cancel</button>${c.obligations.length?`<button class="primary" id="lpSave">${tx?'Record & Match':label}</button>`:''}</div>`;
   $('lpCancel').onclick=close;if($('lpOtherRuns'))$('lpOtherRuns').onclick=()=>open('ird',null,tx);
   if(!all.length){error(c,new Error('No posted liability was found. Review the source posting before recording payment.'));return;}if(!c.obligations.length)return;await banks(c);if(!active(c))return;
   c.obligations.forEach((o,i)=>$('lpAllocation'+i)?.addEventListener('input',()=>refreshAmount(c)));$('lpSave').onclick=()=>save(c);
  }catch(e){error(c,e);}
 }
 async function save(c){if(!active(c)||c.busy)return;const bank=$('lpBank'),date=$('lpDate').value,a=allocations(c),sum=a.reduce((s,o)=>s+cents(o.amount),0);if(!date)return error(c,new Error('Enter the payment date.'));if(!bank.value||bank.selectedOptions[0]?.disabled)return error(c,new Error('Select a bank account linked to the accounting ledger.'));if(!a.length||sum<=0||a.some(o=>!Number.isFinite(o.amount)||o.amount<=0||Math.abs(o.amount*100-cents(o.amount))>0.00001))return error(c,new Error('Enter valid amounts within the outstanding balances.'));
  let rounding=0;
  const excess=a.find(o=>cents(o.amount)>cents(o.outstanding));
  if(excess){
   if(excess.kind==='gst'&&excess.direction==='refund'){
    const difference=(cents(excess.amount)-cents(excess.outstanding))/100;
    if(a.length===1&&difference===0.01&&$('lpConfirmRounding')?.checked)rounding=difference;
    else return error(c,new Error(`The refund entered is ${money(excess.amount)}, which is ${money(difference)} more than the ${money(excess.outstanding)} outstanding on this return. Check the bank deposit and myIR refund details.${a.length===1&&difference===0.01?' If myIR confirms rounding, tick the rounding confirmation and try again.':''}`));
   }else return error(c,new Error('Enter valid amounts within the outstanding balances.'));
  }if(c.tx&&sum!==cents(Math.abs(c.tx.amount)))return error(c,new Error('Allocations must equal the bank transaction amount.'));
  const payload=a.map(o=>({kind:o.kind,source_id:o.source_id,account_id:o.account_id,amount:rounding?Number(o.outstanding):o.amount,...(rounding?{gst_refund_rounding:rounding}:{})}));c.busy=true;$('lpSave').disabled=true;$('lpClose').disabled=true;$('lpCancel').disabled=true;$('lpError').hidden=true;
  try{if(c.tx)await rpc('frindly_reconcile_liability_payment',{p_bank_transaction_id:c.tx.id,p_payment_id:null,p_request_id:c.requestId,p_allocations:payload});else await rpc('frindly_record_liability_payment',{p_request_id:c.requestId,p_date:date,p_bank_id:bank.value,p_reference:$('lpReference').value.trim()||null,p_allocations:payload});if(!active(c))return;c.busy=false;close();toast('Payment recorded');window.dispatchEvent(new CustomEvent('frindly:settlement-recorded'));await Promise.allSettled([window.Payroll?.refresh?.(),window.Financials?.refresh?.(),window.Dashboard?.refresh?.()]);await refreshButtons();}catch(e){error(c,e);}finally{c.busy=false;if($('lpSave'))$('lpSave').disabled=false;$('lpClose').disabled=false;if($('lpCancel'))$('lpCancel').disabled=false;}
 }
 async function reconcile(tx,onDone){const c={bid:bid(),tx,busy:false};context=c;++sequence;modal().classList.add('open');$('lpContent').innerHTML='<h2>GST / Payroll payment</h2><p class="hint">Loading recorded payments…</p><p id="lpError" role="alert" hidden></p>';try{const data=await rpc('frindly_settlement_snapshot',{p_kind:'all',p_source_id:null});if(!active(c))return;const payments=(data.payments||[]).filter(p=>!p.matched&&p.bank_account_id===tx.bank_account_id&&cents(p.amount)===cents(Math.abs(tx.amount))&&(p.direction==='payment')===(tx.amount<0));$('lpContent').innerHTML=`<h2>GST / Payroll payment</h2><p class="hint">${esc(tx.transaction_date)} · ${esc(money(tx.amount))}</p><p id="lpError" role="alert" hidden></p><div class="form-grid compact"><label class="wide">Match recorded payment<select id="lpExisting"><option value="">Select a recorded payment</option>${payments.map(p=>`<option value="${esc(p.id)}">${esc(p.payment_date)} · ${esc(money(p.amount))} · ${esc(p.reference||'No reference')}</option>`).join('')}</select></label></div><div class="actions"><button class="primary" id="lpMatch" ${payments.length?'':'disabled'}>Match Payment</button></div><h3>Record a new settlement</h3><p class="hint">Check existing payment history before creating another settlement.</p><div class="actions"><button class="secondary" id="lpNewGst">GST ${tx.amount>0?'refund':'payment'}</button>${tx.amount<0?'<button class="secondary" id="lpNewWages">Wages</button><button class="secondary" id="lpNewIrd">IRD obligations</button>':''}<button class="secondary" id="lpCancel">Cancel</button></div>`;$('lpCancel').onclick=close;for(const [id,kind] of [['lpNewGst','gst'],['lpNewWages','wages'],['lpNewIrd','ird']])if($(id))$(id).onclick=()=>open(kind,null,tx);$('lpMatch').onclick=async()=>{const pid=$('lpExisting').value;if(!pid||c.busy)return;c.busy=true;$('lpMatch').disabled=true;try{await rpc('frindly_reconcile_liability_payment',{p_bank_transaction_id:tx.id,p_payment_id:pid});c.busy=false;close();toast('Payment matched');onDone?.();}catch(e){c.busy=false;$('lpMatch').disabled=false;error(c,e);}};}catch(e){error(c,e);}}
 window.LiabilityPayments={open,reconcile,refreshButtons};
 document.addEventListener('click',e=>{const b=e.target.closest('[data-liability-kind]');if(b)open(b.dataset.liabilityKind,b.dataset.liabilitySource||null);});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&context)close();});
})();
