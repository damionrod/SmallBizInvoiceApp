/* Non-standard cash entry, shared with statement reconciliation. Existing payments keep their sources. */
(()=>{'use strict';
 const $=id=>document.getElementById(id),sb=()=>window.SAAS?.client?.(),bid=()=>window.SAAS?.state?.business?.id;
 const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
 const cents=n=>Math.round(Number(n||0)*100),money=n=>window.FinloCore.format.money(Number(n||0),{currency:window.SAAS?.state?.business?.settings?.currency||'NZD'});
 const today=()=>new Intl.DateTimeFormat('en-CA',{timeZone:window.SAAS?.state?.business?.settings?.timezone||'Pacific/Auckland',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 const toast=s=>window.FinloCore?.ui?.toast?.(s);
 const purposes={in:[['grant','Grant or subsidy'],['loan_received','Loan received'],['owner_funds_introduced','Owner/shareholder money added — repayable'],['capital_contribution','Investment / share capital received — permanent'],['interest','Bank interest received'],['income_tax_refund','Income-tax refund'],['deposit_return','Refundable deposit returned'],['other_receipt','Other money in — choose category']],out:[['income_tax','Provisional or other income tax'],['loan_repayment','Loan repayment'],['repay_owner_loan','Repay owner/shareholder funds'],['owner_drawings','Owner/shareholder withdrawal'],['deposit_paid','Refundable deposit or bond'],['share_buyback','Share Buyback'],['return_share_capital','Return of Share Capital'],['other_payment','Other money out — choose category']],transfer:[['transfer','Transfer between accounts']]};
 const label=p=>Object.values(purposes).flat().find(x=>x[0]===p)?.[1]||String(p||'').replaceAll('_',' ');
 let context=null,sequence=0,renderSequence=0,historyContext=null,linkedDialogObserver=null;
 function followLinkedDialog(id,businessId){linkedDialogObserver?.disconnect();const dialog=$(id);if(!dialog?.classList.contains('open'))return;linkedDialogObserver=new MutationObserver(()=>{if(dialog.classList.contains('open')&&bid()===businessId)return;linkedDialogObserver?.disconnect();linkedDialogObserver=null;if(bid()===businessId)Promise.allSettled([window.Financials?.refresh?.(),window.Dashboard?.refresh?.()]);});linkedDialogObserver.observe(dialog,{attributes:true,attributeFilter:['class']});}
 async function rpc(name,args={}){const r=await sb().rpc(name,args);if(r.error)throw new Error(r.error.message);return r.data;}
 async function snapshot(){return rpc('frindly_cash_snapshot');}
 function active(c){return context===c&&bid()===c.bid;}
 function modal(){let m=$('cashTransactionModal');if(m)return m;m=document.createElement('div');m.id='cashTransactionModal';m.className='modal';m.setAttribute('role','dialog');m.setAttribute('aria-modal','true');m.setAttribute('aria-label','Record bank transaction');m.innerHTML='<div class="modal-box small-modal"><button class="close" id="ctClose" aria-label="Close">×</button><div id="ctContent"></div></div>';document.body.append(m);$('ctClose').onclick=close;m.addEventListener('click',e=>{if(e.target===m)close()});return m;}
 function close(){if(context?.busy)return;sequence++;context=null;modal().classList.remove('open');}
 function error(c,e){if(!active(c))return;const el=$('ctError');if(el){el.textContent=e.message||String(e);el.hidden=false;if(el.tabIndex===-1&&el.classList.contains('notice'))el.focus();}else toast(e.message||String(e));}
 function field(name,title,html,wide=false){return `<label class="${wide?'wide':''}">${title}${html}</label>`;}
 function options(rows,valueKey='id',nameKey='name'){return rows.map(x=>`<option value="${esc(x[valueKey])}">${esc(x[nameKey])}</option>`).join('');}
 async function banks(c){const r=await sb().from('bank_accounts').select('id,name,account_number,is_default,accounting_account_id,currency').eq('business_id',c.bid).eq('archived',false).order('name');if(r.error)throw new Error(r.error.message);return (r.data||[]).filter(b=>b.accounting_account_id);}
 function showInstalmentDate(c,due){
  const date=$('ctDate');
  $('ctInstalmentDue').parentElement.hidden=!due;
  $('ctInstalmentDue').value=due||'';
  date.parentElement.firstChild.textContent=due?'Actual date paid':c.kind==='transfer'?'Date sent':c.kind==='in'?'Date received':'Date paid';
 }
 function extra(c){
  const p=$('ctPurpose').value,capital=['share_buyback','return_share_capital'].includes(p),owner=['owner_funds_introduced','capital_contribution','repay_owner_loan','owner_drawings','share_buyback','return_share_capital'].includes(p),tax=['income_tax','income_tax_refund'].includes(p);
  let html='';
  if(['loan_received','loan_repayment'].includes(p)&&c.loans?.length)html+=field('loan','Loan',`<select id="ctLoan"><option value="">General bank loan (existing account)</option>${options(c.loans)}</select>`,true);
  if(owner||tax)html+=field('owner',capital?'Shareholder receiving this payment':'Owner/shareholder',`<select id="ctOwner" ${capital?'aria-describedby="ctShareholderHelp"':''}><option value="">${capital?'Select shareholder receiving payment':'Select owner/shareholder'}</option>${options((capital?c.data.capital?.shareholders:c.data.owners)||[])}</select>${capital?`<small class="hint" id="ctShareholderHelp">${p==='share_buyback'?'Select the shareholder whose shares the company is buying back—the person receiving the money. If they are leaving, select the outgoing shareholder, not the remaining shareholder.':'Select the shareholder receiving the capital repayment. If more than one shareholder is paid, record each payment separately against its recipient.'}</small>`:''}`);
  if(tax)html+=field('taxpayer','Whose income tax?',`<select id="ctTaxpayer"><option value="business">Business/company income tax</option><option value="owner">Owner’s personal income tax</option></select>`)+field('year','Tax year ending',`<input id="ctYear" type="number" min="2000" max="2200" value="${new Date().getFullYear()+(new Date().getMonth()>2?1:0)}">`)+ '<p class="hint wide">For provisional or terminal income tax only. Record GST and payroll tax on their existing pages. Personal income tax is an owner movement.</p>';
  if(p==='grant')html+=field('funder','Grant paid by','<input id="ctParty" required placeholder="Funder or organisation">')+field('gst','GST treatment','<select id="ctGst"><option value="">Choose the grant’s GST treatment</option><option value="GST">Includes GST</option><option value="ZERO">Zero-rated GST</option><option value="NO_GST">No GST / outside GST</option></select>')+'<p class="hint wide">Grant rules vary by funder and purpose. Confirm GST and income-tax treatment from the grant agreement. Explain any tax or deduction adjustments in the note for your accountant.</p>';
  if(p==='loan_repayment')html+=field('interest','Interest included — if any','<input id="ctInterest" type="number" min="0" step="0.01" inputmode="decimal" value="0.00">')+'<p class="hint wide">Enter the interest portion in the field above. Ordinary standalone interest costs belong in Expenses.</p>';
  if(p==='interest')html+=field('withheld','Tax withheld — if any','<input id="ctWithheld" type="number" min="0" step="0.01" inputmode="decimal" value="0.00">')+'<p class="hint wide">Enter the net amount received above. Frindly adds the tax withheld to gross interest.</p>';
  if(p.startsWith('other_'))html+=field('category','Category',`<select id="ctCategory"><option value="">Select a non-standard category</option>${options((c.data.categories||[]).filter(a=>!/(owner|shareholder|capital|loan|deposit|grant|interest)/.test(a.key||'')))}</select>`,true)+'<p class="hint wide">For balance movements and other receipts only. This form does not calculate GST. Use Invoices for taxable sales and Expenses for purchases. Ask your accountant if the category is unclear.</p><button type="button" class="secondary wide" id="ctOtherAdvanced">Need another category or split allocations?</button>';
  if(capital)html+=`${field('shareEvent','Link an additional payment to a completed share change — optional',`<select id="ctCapitalEvent"><option value="">No existing completed share change</option>${(c.data.capital?.share_changes||[]).filter(e=>e.type===(p==='share_buyback'?'cancellation':'capital_only')).map(e=>`<option value="${esc(e.id)}">${esc(e.reference)} · ${esc(e.effective_date)}</option>`).join('')}</select><small class="hint">Use only for the same approved acquisition / capital return. This links the payment without reducing shares again. If the full equity reduction was already posted as a payable, use accountant settlement instead.</small>`,true)}<p class="hint wide">For a legally authorised company payment to a shareholder, not a private purchase between shareholders. Use the approved equity allocation; a buyback is not automatically all share capital. No GST is calculated. After recording, open the payment to confirm a separate linked shareholding change. This does not update the Companies Register.</p><label class="wide">Approved equity allocation<div id="ctCapitalLines"></div><button type="button" class="secondary" id="ctCapitalAdd">+ Add equity allocation</button></label>${field('authority','Resolution / approval reference','<input id="ctCapitalAuthority" required minlength="3" maxlength="200">')}${field('approved','Authorisation date','<input id="ctCapitalAuthorityDate" type="date" required>')}${field('reviewer','Accountant / adviser who confirmed allocation','<input id="ctCapitalReviewer" required minlength="3" maxlength="200">')}${field('shares','Shares / class or capital reduction details','<input id="ctCapitalShares" required minlength="3" maxlength="500">',true)}${field('taxreview','Tax / withholding review','<select id="ctCapitalTax" required><option value="">Choose confirmed treatment</option><option value="no_additional_withholding">Reviewed — no additional withholding payable from this entry</option><option value="accountant">Withholding or a previously posted liability needs accountant settlement</option></select>',true)}<p class="hint wide">If tax must be withheld or the equity reduction was already posted as a payable, use the existing accountant workflow to settle it. Do not post the equity reduction twice.</p><label class="wide"><input type="checkbox" id="ctCapitalAuthorised" required> Required company approvals and supporting documents are in place.</label><label class="wide"><input type="checkbox" id="ctCapitalSolvent" required> Directors have confirmed the required solvency assessment and certificates.</label><label class="wide"><input type="checkbox" id="ctCapitalReviewed" required> The allocation and tax treatment have been reviewed and approved.</label><label class="wide"><input type="checkbox" id="ctCapitalNotPosted" required> This equity reduction and payment have not already been posted elsewhere.</label>`;
  $('ctExtra').innerHTML=html;
  $('ctRepaymentAmountHelp')?.remove();
  $('ctAmount').removeAttribute('aria-describedby');
  if(p==='loan_repayment'){
   $('ctAmount').setAttribute('aria-describedby','ctRepaymentAmountHelp');
   $('ctAmount').insertAdjacentHTML('afterend','<small id="ctRepaymentAmountHelp" class="hint">Enter the full payment, including principal and interest. Include any finance fees charged in the same payment when using a registered loan.</small>');
  }
  c.loanDue=null;
  showInstalmentDate(c,null);
  if(p==='loan_repayment'&&$('ctLoan')){
   $('ctInterest').parentElement.insertAdjacentHTML('afterend','<label id="ctLoanFeeLabel" hidden>Finance fee included (optional)<input id="ctLoanFee" type="number" min="0" step="0.01" inputmode="decimal"></label>');
  }
  if($('ctLoan'))$('ctLoan').onchange=()=>{
   const loan=c.loans.find(item=>item.id===$('ctLoan').value);
   c.loanDue=null;
   showInstalmentDate(c,null);
   if($('ctLoanFee')){$('ctLoanFee').value='';$('ctLoanFeeLabel').hidden=!loan;}
   if($('ctInterest')){$('ctInterest').parentElement.hidden=false;$('ctInterest').value='0.00';}
   if(!loan)return;
   if(!c.tx&&c.banks.some(account=>account.id===loan.bank_id))$('ctBank').value=loan.bank_id;
   if(p!=='loan_repayment')return;
   const next=window.LoansFinance.nextPayment(loan,c.data.transactions||[]);
   if(!next)return;
   const remaining=(next.total-next.paid)/100;
   if(!c.tx&&!$('ctAmount').value)$('ctAmount').value=remaining;
   $('ctInterest').value=Math.min(Number($('ctAmount').value),Math.max(0,next.interest-next.paidInterest)/100).toFixed(2);
   c.loanDue=next.due;
   showInstalmentDate(c,next.due);
   if(!c.tx&&!c.paymentDateEdited&&next.due<today())$('ctDate').value='';
  };
if($('ctOtherAdvanced'))$('ctOtherAdvanced').onclick=()=>route(c,'advanced');
  if($('ctNote'))$('ctNote').parentElement.firstChild.textContent=capital?'Accounting allocation note — required':'Note — optional (required for grants)';
  if(capital){
   if(!c.data.capital?.can_record){$('ctExtra').innerHTML='<p class="notice">Capital payments require an NZ company, the current backend update, and authorised accounting access.</p>';return;}
   $('ctCapitalEvent').onchange=()=>{const e=(c.data.capital?.share_changes||[]).find(x=>x.id===$('ctCapitalEvent').value);if(e)$('ctOwner').value=e.owner_id;$('ctOwner').disabled=!!e;};
   const addLine=()=>{const row=document.createElement('div');row.className='ct-capital-line';row.innerHTML=`<select class="ct-capital-account" aria-label="Equity account" required><option value="">Select approved equity account</option>${options(c.data.capital.accounts||[])}</select><input class="ct-capital-amount" aria-label="Equity allocation amount" type="number" min="0.01" step="0.01" inputmode="decimal" required><button type="button" class="secondary" aria-label="Remove allocation">Remove</button>`;row.querySelector('button').onclick=()=>row.remove();$('ctCapitalLines').append(row);};addLine();$('ctCapitalAdd').hidden=p==='return_share_capital';$('ctCapitalAdd').onclick=()=>{if($('ctCapitalLines').children.length<10)addLine();};
   $('ctNote').required=true;$('ctNote').minLength=5;
  }else if($('ctNote')){$('ctNote').required=false;$('ctNote').removeAttribute('minlength');}
  if(tax){const entity=c.data.entity_type||window.SAAS?.state?.business?.settings?.business_entity_type; if(['sole_trader','partnership'].includes(entity))$('ctTaxpayer').value='owner';}
  if(!$('ctDescription').dataset.edited)$('ctDescription').value=label(p);
 }
 function buybackBalanceMessage(c,onlyWarning=false){
  const preview=c.capitalPreview;
  if(!preview?.account_id)return '';
  const lines=[...$('ctCapitalLines').children];
  const allocated=lines.filter(row=>row.querySelector('select').value===preview.account_id)
   .reduce((total,row)=>total+cents(row.querySelector('input').value),0);
  if(!allocated)return '';
  const available=money(preview.balance);
  const summary=`${available} posted share capital on ${$('ctDate').value}. Proposed allocation: ${money(allocated/100)}.`;
  return allocated>cents(preview.balance)?summary+' Review the approved allocation before recording.':onlyWarning?'':summary;
 }
 async function previewBuybackBalance(c){
  c.capitalPreview=null;
  const date=$('ctDate').value;
  const notice=$('ctBuybackAllocationBalance');
  notice.textContent='Checking posted share capital…';
  $('ctBuybackBalance').textContent='';
  $('ctReviewOpeningCapital').hidden=true;
  try{
   const result=await rpc('frindly_buyback_share_capital_preview',{p_as_of:date});
   if(!active(c)||!c.buybackReview||$('ctDate').value!==date)return;
   c.capitalPreview=result;
   c.updateBuybackBalance();
  }catch(e){
   if(active(c)&&c.buybackReview&&$('ctDate').value===date)notice.textContent='The posted balance will be checked when you record this payment.';
  }
 }
 function capitalConfirmation(id){
  return ($('ctBuybackConfirm')||$(id))?.checked===true;
 }
 async function openShareCapitalReview(asOf=today(),returnToBuyback=null){
  if($('ctOpeningCapitalDialog'))return;
  const business=bid();
  const dialog=document.createElement('dialog');
  dialog.id='ctOpeningCapitalDialog';
  dialog.className='card';
  dialog.setAttribute('aria-labelledby','ctOpeningTitle');
  dialog.style.cssText='width:min(720px,calc(100% - 24px));max-height:90dvh;overflow:auto;margin:auto;color:inherit;';
  dialog.innerHTML=`<h2 id="ctOpeningTitle">Review opening share capital</h2>
   <p id="ctOpeningCurrent" role="status">Loading posted share capital…</p>
   <button type="button" class="secondary" id="ctOpeningLedger" hidden>View ledger entries</button>
   <div id="ctOpeningLedgerRows" hidden></div>
   <form id="ctOpeningForm" hidden>
    <p class="hint">Use the verified opening amount from the previous books. The guided correction moves an existing opening equity balance into share capital.</p>
    <div class="form-grid compact">
     <label>Opening date<input id="ctOpeningDate" type="date" max="${esc(asOf)}" required></label>
     <label>Verified opening amount<input id="ctOpeningAmount" type="number" min="0.01" step="0.01" required></label>
     <label class="wide">Source reference<input id="ctOpeningReference" required minlength="3" maxlength="200" placeholder="Opening trial balance or journal reference"></label>
    </div>
    <p id="ctOpeningPreview" role="status"></p>
    <label id="ctOpeningConfirmLabel" hidden><input type="checkbox" id="ctOpeningConfirm"> I verified this allocation against the opening records.</label>
    <div class="actions"><button class="secondary" type="submit" id="ctOpeningCheck">Preview correction</button>
    <button class="primary" type="button" id="ctOpeningPost" hidden>Post opening correction</button></div>
   </form>
   <p id="ctOpeningError" class="notice" role="alert" hidden></p>
   <div class="actions"><button type="button" class="secondary" id="ctOpeningManual" hidden>Open Manual Journals</button>
   <button type="button" class="secondary" id="ctOpeningClose">${returnToBuyback?'Back to buyback':'Close'}</button></div>`;
  document.body.append(dialog);
  dialog.showModal();
  let busy=false,preview=null,posted=false;
  const current=()=>dialog.open&&bid()===business;
  const closeReview=()=>{if(!busy)dialog.close();};
  dialog.addEventListener('cancel',event=>{event.preventDefault();event.stopPropagation();closeReview();});
  dialog.addEventListener('close',()=>{dialog.remove();if(bid()===business)returnToBuyback?.();});
  $('ctOpeningClose').onclick=closeReview;
  const report=e=>{if(current()){$('ctOpeningError').textContent=e.message||String(e);$('ctOpeningError').hidden=false;}};
  const setBusy=value=>{
   busy=value;
   for(const control of dialog.querySelectorAll('button,input'))control.disabled=value;
  };
  const resetPreview=()=>{
   preview=null;
   $('ctOpeningConfirm').checked=false;
   $('ctOpeningConfirmLabel').hidden=true;
   $('ctOpeningPost').hidden=true;
   $('ctOpeningPreview').textContent='';
   $('ctOpeningError').hidden=true;
  };
  $('ctOpeningForm').oninput=event=>{if(event.target.id!=='ctOpeningConfirm')resetPreview();};
  $('ctOpeningManual').onclick=async()=>{
   if(!current()||busy)return;
   closeReview();
   if(returnToBuyback)close();
   await window.switchView?.('financials');
   if(bid()===business)$('finManualJournalTab')?.click();
  };
  try{
   const account=await rpc('frindly_opening_share_capital_review',{p_as_of:asOf});
   if(!current())return;
   $('ctOpeningCurrent').textContent=`${account.code} · ${account.name} · ${money(account.balance)} on ${asOf}.${account.has_entries?'':' No entries recorded.'}`;
   $('ctOpeningLedger').hidden=false;
   $('ctOpeningManual').hidden=false;
   $('ctOpeningForm').hidden=false;
   $('ctOpeningLedger').onclick=async()=>{
    if(!current()||busy)return;
    const host=$('ctOpeningLedgerRows');
    if(!host.hidden){host.hidden=true;return;}
    host.hidden=false;
    host.textContent='Loading ledger entries…';
    try{
     const rows=await rpc('v6170c45_general_ledger',{p_from:'1900-01-01',p_to:asOf,p_account_code:account.code,p_source_type:null});
     if(!current())return;
     host.innerHTML=rows?.length?`<div class="table-scroll"><table><thead><tr><th>Date</th><th>Reference</th><th>Debit</th><th>Credit</th></tr></thead><tbody>${rows.slice(-100).reverse().map(row=>`<tr><td>${esc(row.journal_date)}</td><td>${esc(row.source_reference||row.journal_number||row.description)}</td><td>${esc(money(row.debit))}</td><td>${esc(money(row.credit))}</td></tr>`).join('')}</tbody></table></div>`:'<p>No posted entries for this account on this date.</p>';
    }catch(e){if(current()){host.hidden=true;report(e);}}
   };
   $('ctOpeningForm').onsubmit=async event=>{
    event.preventDefault();
    if(!current()||busy||posted)return;
    resetPreview();
    const args={p_as_of:$('ctOpeningDate').value,p_amount:Number($('ctOpeningAmount').value),p_reference:$('ctOpeningReference').value.trim()};
    setBusy(true);
    try{
     const result=await rpc('frindly_opening_share_capital_review',args);
     if(!current())return;
     if(result.reason){$('ctOpeningPreview').textContent=result.reason;return;}
     preview={...args,p_expected_offset:result.offset.id};
     $('ctOpeningPreview').textContent=`On ${args.p_as_of}, debit ${result.offset.name} and credit ${result.name} by ${money(args.p_amount)} each.`;
     $('ctOpeningConfirmLabel').hidden=false;
     $('ctOpeningPost').hidden=false;
    }catch(e){report(e);}finally{if(current())setBusy(false);else dialog.close();}
   };
   $('ctOpeningPost').onclick=async()=>{
    if(!current()||busy||posted||!preview)return;
    if(!$('ctOpeningConfirm').checked)return report(new Error('Confirm you verified the opening allocation.'));
    setBusy(true);
    try{
     await rpc('frindly_opening_share_capital_review',{...preview,p_confirm:true});
     if(!current())return;
     posted=true;
     toast('Opening share capital correction posted');
     window.dispatchEvent(new CustomEvent('frindly:cash-recorded'));
     void Promise.allSettled([window.Financials?.refresh?.(),window.Dashboard?.refresh?.()]);
    }catch(e){report(e);}finally{
     if(current())setBusy(false);
     if(posted||!current())dialog.close();
    }
   };
  }catch(e){report(e);}
 }
 function setupBuyback(c){
  const form=$('ctForm'),payment=form.firstElementChild,extra=$('ctExtra');
  form.classList.add('ct-buyback-form');
  const review=document.createElement('section');
  review.id='ctBuybackReview';
  review.innerHTML='<h3 tabindex="-1">Review and record</h3><p id="ctBuybackSummary"></p><p class="hint">Use the accounting instructions approved for this buyback.</p><button type="button" class="secondary" id="ctBuybackHelp">I need accounting instructions</button><p class="hint" id="ctBuybackHelpText" hidden>Ask your accountant which account or accounts to use and whether tax needs to be withheld. Return here with their instructions, or ask them to use the accountant workflow if a payable has already been recorded.</p>';
  form.insertBefore(review,extra);
  const owner=$('ctOwner'),event=$('ctCapitalEvent');
  owner.required=true;
  owner.parentElement.firstChild.textContent='Shareholder paid';
  $('ctShareholderHelp').textContent='Choose the shareholder the company paid for their shares.';
  payment.append(owner.parentElement,event.parentElement);
  event.parentElement.hidden=event.options.length===1;
  event.parentElement.firstChild.textContent='Payment towards an existing buyback?';
  event.parentElement.querySelector('small').textContent='Choose the original buyback if this payment is an instalment.';
  extra.querySelector('p').hidden=true;
  $('ctCapitalLines').parentElement.firstChild.textContent='Accounting instructions';
  $('ctCapitalAdd').textContent='Split across accounts';
  $('ctCapitalAdd').insertAdjacentHTML('beforebegin','<small id="ctBuybackAllocationBalance" class="hint" role="status"></small><button type="button" id="ctReviewOpeningCapital" class="secondary" hidden>Review opening share capital</button>');
  $('ctReviewOpeningCapital').onclick=()=>openShareCapitalReview($('ctDate').value,()=>{
   if(!active(c)||!c.buybackReview)return;
   if($('ctError').textContent===buybackBalanceMessage(c,true))$('ctError').hidden=true;
   void previewBuybackBalance(c);
  });
  $('ctDescription').parentElement.hidden=true;
  $('ctReference').parentElement.firstChild.textContent='Bank reference (optional)';
  const approval=document.createElement('div');
  approval.className='wide form-grid compact';
  approval.innerHTML='<h3 class="wide">Approval details</h3>';
  extra.insertBefore(approval,$('ctCapitalAuthority').parentElement);
  for(const id of ['ctCapitalAuthority','ctCapitalAuthorityDate','ctCapitalReviewer','ctCapitalShares','ctCapitalTax','ctNote']){
   approval.append($(id).parentElement);
  }
  $('ctNote').parentElement.firstChild.textContent='Accounting instructions or document reference';
  const confirmation=$('ctCapitalAuthorised').parentElement;
  confirmation.classList.add('ct-buyback-confirmation');
  confirmation.innerHTML='<input type="checkbox" id="ctBuybackConfirm" required><span>I confirm the company approvals and solvency checks are complete, the accountant approved the allocation and tax treatment, and this payment and equity reduction are being recorded for the first time.</span>';
  for(const id of ['ctCapitalSolvent','ctCapitalReviewed','ctCapitalNotPosted'])$(id).parentElement.remove();
  const actions=$('ctSave').parentElement;
  actions.before($('ctError'));
  $('ctError').classList.add('notice');
  $('ctError').tabIndex=-1;
  actions.insertAdjacentHTML('beforebegin','<p id="ctBuybackBalance" class="hint" role="status"></p>');
  actions.insertAdjacentHTML('afterbegin','<button type="button" class="secondary" id="ctBuybackBack">Back</button>');
  const updateBalance=()=>{
   if(!c.buybackReview||!c.capitalPreview)return;
   $('ctBuybackAllocationBalance').textContent=buybackBalanceMessage(c);
   const footer=$('ctBuybackBalance');
   const alert=$('ctError');
   const warning=buybackBalanceMessage(c,true);
   $('ctReviewOpeningCapital').hidden=!warning;
   if(!alert.hidden&&footer.textContent&&alert.textContent===footer.textContent&&warning!==footer.textContent)alert.hidden=true;
   footer.textContent=warning;
   footer.hidden=!warning||(!alert.hidden&&alert.textContent===warning);
  };
  c.updateBuybackBalance=updateBalance;
  extra.addEventListener('input',updateBalance);
  extra.addEventListener('change',updateBalance);
  $('ctCapitalLines').addEventListener('click',updateBalance);
  $('ctBuybackHelp').onclick=()=>{$('ctBuybackHelpText').hidden=!$('ctBuybackHelpText').hidden;};
  const setStep=isReview=>{
   c.buybackReview=isReview;
   payment.hidden=isReview;
   review.hidden=!isReview;
   extra.hidden=!isReview;
   $('ctReference').parentElement.hidden=!isReview;
   $('ctBuybackBack').hidden=!isReview;
   $('ctSave').textContent=isReview?(c.tx?'Record & match':'Record buyback payment'):'Review payment';
   form.noValidate=!isReview;
   $('ctError').hidden=true;
   $('ctBuybackBalance').hidden=!isReview;
   if(isReview)void previewBuybackBalance(c);
   if(isReview)review.querySelector('h3').focus();
   else $('ctPurpose').focus();
  };
  $('ctBuybackBack').onclick=()=>setStep(false);
  c.reviewBuyback=()=>{
   if(!c.data.capital?.can_record)return error(c,new Error('Capital payments require authorised accounting access.'));
   for(const control of payment.querySelectorAll('input,select'))if(!control.reportValidity())return;
   const linked=(c.data.capital?.share_changes||[]).find(row=>row.id===event.value);
   const authority=$('ctCapitalAuthority');
   if(!authority.value||authority.value===c.linkedAuthority){
    c.linkedAuthority=linked?.reference||'';
    authority.value=c.linkedAuthority;
   }
   const shareholder=owner.selectedOptions[0].textContent;
   $('ctDescription').value='Share buyback – '+shareholder;
   $('ctBuybackSummary').textContent=shareholder+' · '+money($('ctAmount').value)+' · '+$('ctDate').value+' · '+$('ctBank').selectedOptions[0].textContent;
   const lines=$('ctCapitalLines');
   if(lines.children.length===1)lines.querySelector('input').value=$('ctAmount').value;
   setStep(true);
  };
  setStep(false);
 }
 async function open(kind='out',preset={},tx=null,onDone=null){
  const token=++sequence,c={bid:bid(),kind,tx,onDone,preset,requestId:crypto.randomUUID(),busy:false};context=c;modal().classList.add('open');$('ctContent').innerHTML='<p>Loading bank transaction form…</p><p id="ctError" role="alert" hidden></p>';
  try{
   const [data,accounts]=await Promise.all([snapshot(),banks(c)]);if(!active(c)||token!==sequence)return;c.data=data;c.banks=accounts;
   if(!data.can_write)throw new Error('You do not have permission to record financial transactions.');
   if(['share_buyback','return_share_capital'].includes(preset.purpose)&&!data.capital?.can_record)throw new Error('Capital payments require an NZ company and authorised accounting access.');
   if(['loan_received','loan_repayment'].includes(preset.purpose)&&window.LoansFinance){
    try{c.loans=(await window.LoansFinance.list()).loans.filter(loan=>!loan.closed);}catch(e){if(preset.loan_id)throw e;}
    if(!active(c))return;
   }
   if(preset.loan_id&&!c.loans?.some(loan=>loan.id===preset.loan_id))throw new Error('The selected loan is unavailable');
   const transfer=kind==='transfer';
   $('ctContent').innerHTML=`<h2>${transfer?'Transfer between accounts':kind==='in'?'Record money in':'Record money out'}</h2><p class="hint">This records a transaction in Frindly. It does not send money through your bank.</p><p id="ctError" role="alert" hidden></p><form id="ctForm"><div class="form-grid compact">${field('purpose',kind==='in'?'Where did this money come from?':transfer?'Transfer type':'What was this payment for?',`<select id="ctPurpose">${purposes[kind].filter(([v])=>!['share_buyback','return_share_capital'].includes(v)||data.entity_type==='company').map(([v,l])=>`<option value="${v}">${esc(l)}</option>`).join('')}</select>`,true)}${field('instalmentDue','Instalment due','<input id="ctInstalmentDue" type="date" readonly>')}${field('date',transfer?'Date sent':kind==='in'?'Date received':'Date paid',`<input id="ctDate" type="date" required value="${esc(tx?.transaction_date||today())}" ${tx?'readonly':''}>`)}${field('amount',kind==='in'?'Amount received':'Amount paid',`<input id="ctAmount" type="number" min="0.01" step="0.01" inputmode="decimal" required value="${tx?Math.abs(tx.amount).toFixed(2):''}" ${tx?'readonly':''}>`)}${field('bank',transfer?'From account':kind==='in'?'Received into':'Paid from',`<select id="ctBank" required><option value="">Select bank account</option>${options(accounts.map(a=>({...a,name:a.name+(a.account_number?' · '+a.account_number:'')})))}</select>`)}${transfer?field('to','To account',`<select id="ctTo" required><option value="">Select destination bank</option>${options(accounts.map(a=>({...a,name:a.name+(a.account_number?' · '+a.account_number:'')})))}</select>`)+field('received','Date received',`<input id="ctReceived" type="date" required value="${esc(tx?.transaction_date||today())}">`):''}</div><div id="ctExtra" class="form-grid compact"></div><div class="form-grid compact">${field('description','Description','<input id="ctDescription" required maxlength="500">',true)}${field('reference','Reference — optional',`<input id="ctReference" value="${esc(tx?.reference||'')}">`,true)}${field('note','Note — optional (required for grants)','<textarea id="ctNote" rows="2"></textarea>',true)}</div><p class="hint">Use the actual date for historical transactions. Check existing records before saving.</p><div id="ctDuplicate" class="notice" hidden></div><div class="actions"><button type="button" class="secondary" id="ctCancel">Cancel</button><button type="submit" class="primary" id="ctSave">${tx?'Record & match':'Record transaction'}</button></div></form>`;
   $('ctBank').value=tx?.bank_account_id||accounts.find(x=>x.is_default)?.id||'';
   if(tx){if(transfer&&tx.amount>0){$('ctTo').value=tx.bank_account_id;$('ctTo').disabled=true;$('ctBank').value='';$('ctReceived').value=tx.transaction_date;$('ctReceived').readOnly=true;$('ctDate').readOnly=false;}else $('ctBank').disabled=true;}
   if(preset.purpose)$('ctPurpose').value=preset.purpose;

   for(const [id,value] of Object.entries(preset.paymentFields||{}))$(id).value=value;
   $('ctDate').oninput=()=>{c.paymentDateEdited=true;};
   $('ctDescription').oninput=()=>{$('ctDescription').dataset.edited='true';c.duplicateAcknowledged=false;};
   $('ctPurpose').onchange=()=>{if(preset.interest_only||preset.purpose==='share_buyback'||$('ctPurpose').value==='share_buyback'||(['loan_received','loan_repayment'].includes($('ctPurpose').value)&&window.LoansFinance&&!c.loans))return open(kind,{purpose:$('ctPurpose').value,paymentFields:Object.fromEntries(['ctDate','ctAmount','ctBank','ctReference'].map(id=>[id,$(id).value]))},tx,onDone);delete $('ctDescription').dataset.edited;extra(c);c.duplicateAcknowledged=false;};extra(c);
   if(preset.loan_id){
    if(!$('ctLoan')||!c.loans.some(loan=>loan.id===preset.loan_id))throw new Error('The selected loan is unavailable');
    $('ctLoan').value=preset.loan_id;
    if($('ctLoanFeeLabel'))$('ctLoanFeeLabel').hidden=!!preset.interest_only;
    if(!tx&&accounts.some(account=>account.id===preset.bank_id))$('ctBank').value=preset.bank_id;
    if(!tx&&preset.amount!=null)$('ctAmount').value=preset.amount;
    if(!tx&&preset.date!=null)$('ctDate').value=preset.date;
    if(preset.loan_due_date)showInstalmentDate(c,preset.loan_due_date);
    if($('ctInterest')&&preset.interest!=null)$('ctInterest').value=preset.interest;
    if($('ctInterest')&&preset.interest_only){
     $('ctInterest').parentElement.hidden=true;
     $('ctDescription').parentElement.insertAdjacentHTML('afterend','<p class="hint wide">The full payment will be recorded as loan interest.</p>');
    }
    if(preset.description)$('ctDescription').value=preset.description;
   }
   if(preset.owner_id&&$('ctOwner'))$('ctOwner').value=preset.owner_id;if(preset.tax_year&&$('ctYear'))$('ctYear').value=preset.tax_year;
   if($('ctPurpose').value==='share_buyback'&&c.data.capital?.can_record)setupBuyback(c);
   $('ctForm').addEventListener('input',()=>{c.duplicateAcknowledged=false;$('ctDuplicate').hidden=true;});$('ctCancel').onclick=close;$('ctForm').onsubmit=e=>{e.preventDefault();if(c.reviewBuyback&&!c.buybackReview)c.reviewBuyback();else save(c);};
   $('ctPurpose').focus();
  }catch(e){error(c,e);}
 }
 function payload(c){const p=$('ctPurpose').value;return {kind:c.kind,purpose:p,loan_id:$('ctLoan')?.value||undefined,loan_fee:$('ctLoan')?.value&&$('ctLoanFee')?.value?Number($('ctLoanFee').value):undefined,loan_due_date:$('ctLoan')?.value?(c.loanDue||($('ctLoan').value===c.preset.loan_id?c.preset.loan_due_date:undefined)):undefined,date:$('ctDate').value,received_date:$('ctReceived')?.value||undefined,bank_id:$('ctBank').value,to_bank_id:$('ctTo')?.value||undefined,amount:Number($('ctAmount').value),description:$('ctDescription').value.trim(),reference:$('ctReference').value.trim(),note:$('ctNote').value.trim(),party:$('ctParty')?.value.trim()||undefined,gst_treatment:$('ctGst')?.value||'NO_GST',owner_id:(!['income_tax','income_tax_refund'].includes(p)||$('ctTaxpayer')?.value==='owner')?$('ctOwner')?.value||undefined:undefined,taxpayer:$('ctTaxpayer')?.value||undefined,tax_year:$('ctYear')?Number($('ctYear').value):undefined,interest_amount:c.preset.interest_only&&p==='loan_repayment'&&$('ctLoan')?.value===c.preset.loan_id?Number($('ctAmount').value):Number($('ctInterest')?.value||0),withheld_amount:Number($('ctWithheld')?.value||0),account_id:$('ctCategory')?.value||undefined,...(['share_buyback','return_share_capital'].includes(p)?{capital_share_change_id:$('ctCapitalEvent')?.value||null,capital_allocations:[...document.querySelectorAll('#ctCapitalLines .ct-capital-line')].map(row=>({account_id:row.querySelector('select').value,amount:Number(row.querySelector('input').value)})),capital_authority_ref:$('ctCapitalAuthority')?.value.trim(),capital_authority_date:$('ctCapitalAuthorityDate')?.value,capital_reviewer:$('ctCapitalReviewer')?.value.trim(),capital_share_details:$('ctCapitalShares')?.value.trim(),capital_tax_status:$('ctCapitalTax')?.value,capital_authorised:capitalConfirmation('ctCapitalAuthorised'),capital_solvent:capitalConfirmation('ctCapitalSolvent'),capital_tax_reviewed:capitalConfirmation('ctCapitalReviewed'),capital_not_previously_posted:capitalConfirmation('ctCapitalNotPosted')}:{})};}
 async function saved(c,message){if(!active(c))return;c.busy=false;close();toast(message);c.onDone?.();window.dispatchEvent(new CustomEvent('frindly:cash-recorded'));await Promise.allSettled([window.Financials?.refresh?.(),window.Dashboard?.refresh?.()]);await taxHistory();}
 async function save(c){if(!active(c)||c.busy)return;const p=payload(c);if(!p.bank_id||c.kind==='transfer'&&(!p.to_bank_id||p.to_bank_id===p.bank_id))return error(c,new Error('Select the correct bank accounts.'));if($('ctGst')&&!$('ctGst').value)return error(c,new Error('Choose the grant’s GST treatment.'));if($('ctOwner')&&!['income_tax','income_tax_refund'].includes(p.purpose)&&!p.owner_id||p.taxpayer==='owner'&&!p.owner_id)return error(c,new Error('Select an owner/shareholder.'));
  if(['share_buyback','return_share_capital'].includes(p.purpose)){
   if(!c.data.capital?.can_record)return error(c,new Error('Capital payments require authorised accounting access.'));
   if(p.capital_tax_status!=='no_additional_withholding')return error(c,new Error('Use the accountant workflow for withholding or a previously recorded payable.'));
   if(!p.owner_id||!p.capital_authorised||!p.capital_solvent||!p.capital_tax_reviewed||!p.capital_not_previously_posted)return error(c,new Error('Select the shareholder and confirm all authorisations.'));
   if(!p.capital_allocations.length||p.capital_allocations.some(x=>!x.account_id||!Number.isFinite(x.amount)||x.amount<=0)||p.capital_allocations.reduce((n,x)=>n+cents(x.amount),0)!==cents(p.amount))return error(c,new Error('Approved equity allocations must equal the bank payment.'));
  }
  if(p.purpose==='share_buyback'){
   const warning=buybackBalanceMessage(c,true);
   if(warning){
    $('ctBuybackBalance').hidden=true;
    return error(c,new Error(warning));
   }
  }
  const duplicate=(c.data.transactions||[]).find(t=>t.status==='recorded'&&(t.purpose===p.purpose||['share_buyback','return_share_capital'].includes(t.purpose)&&['share_buyback','return_share_capital'].includes(p.purpose))&&cents(t.amount)===cents(p.amount)&&t.legs?.some(l=>l.bank_account_id===p.bank_id&&l.transaction_date===p.date));
  if(duplicate&&!c.duplicateAcknowledged){
   const previous=duplicate.request_payload;
   const otherInstalment=p.purpose==='loan_repayment'&&p.loan_id&&p.loan_id===previous?.loan_id&&p.loan_due_date&&previous.loan_due_date&&p.loan_due_date!==previous.loan_due_date;
   const warning=otherInstalment?`Another instalment (due ${esc(previous.loan_due_date)}) has a ${esc(money(p.amount))} payment recorded on ${esc(p.date)}. Continue only if your bank statement shows a separate debit for this instalment.`:`A ${esc(money(p.amount))} ${esc(label(p.purpose))} transaction is already recorded on ${esc(p.date)}.`;
   $('ctDuplicate').hidden=false;$('ctDuplicate').innerHTML=`${warning} <button type="button" class="secondary" id="ctViewDuplicate">View recorded transaction</button> <button type="button" class="secondary" id="ctSeparate">Record a separate transaction</button>`;$('ctViewDuplicate').onclick=()=>view(duplicate.id);$('ctSeparate').onclick=()=>{c.duplicateAcknowledged=true;save(c);};return;}
  c.busy=true;$('ctSave').disabled=true;$('ctCancel').disabled=true;$('ctClose').disabled=true;$('ctError').hidden=true;
  try{
   let recorded;if(c.tx)recorded=await rpc('frindly_match_cash_transaction',{p_bank_transaction_id:c.tx.id,p_request_id:c.requestId,p_transaction:p});
   else recorded=await rpc('frindly_record_cash_transaction',{p_request_id:c.requestId,p_transaction:p});
   await saved(c,c.tx?'Transaction recorded and matched':'Transaction recorded');
   if(['share_buyback','return_share_capital'].includes(p.purpose)&&bid()===c.bid){let id=recorded;if(c.tx){const latest=await snapshot();id=latest.transactions.find(t=>t.legs?.some(l=>l.id===recorded))?.id;}if(id)await view(id,p.purpose==='share_buyback');}
  }catch(e){error(c,e);}finally{c.busy=false;if($('ctSave'))$('ctSave').disabled=false;if($('ctCancel'))$('ctCancel').disabled=false;$('ctClose').disabled=false;}
 }
 // The hub routes to existing forms. It never substitutes a generic posting for a linked payment.
 const moneyRoutes={in:[
  ['invoice_payment','Customer invoice payment','Select an issued invoice and record its receipt.','invoice'],
  ['sale','Sale / payment without an invoice','Create the sales record first, then record its payment.','sale'],
  ['customer_deposit','Customer deposit or advance','Use a customer-linked advance invoice where it is a sale; refundable security deposits need accountant allocation.','deposit'],
  ['supplier_refund','Supplier refund','Select an existing supplier credit.','supplier_refund'],
  ['gst_refund','GST refund received','Select the GST return being refunded.','gst_refund'],
  ...purposes.in.map(([p,n])=>[p,p==='capital_contribution'?'Investment / share capital received':n,'Use the existing receipt form.',p]),
  ['asset_sale','Sale of equipment / business asset','Receipt, asset disposal and gain/loss require accountant allocation.','advanced'],
  ['advanced','Split receipt / another transaction','Use the existing accountant journal for multiple allocations or special accounting.','advanced']
 ],out:[
  ['expense_payment','Pay an existing expense / bill','Select an outstanding recorded bill.','expense'],
  ['purchase','Business purchase / expense','Use Expenses, including split lines and payment details.','purchase'],
  ['asset_purchase','Buy equipment / business asset','Use the existing purchase form and the appropriate asset classification.','purchase'],
  ['customer_refund','Refund a customer','Use the customer credit and refund workflow.','customer_refund'],
  ['gst_payment','Pay GST','Select the GST return being paid.','gst_payment'],
  ['wages','Pay employees','Record payment against finalised wages.','wages'],
  ['payroll_ird','Pay PAYE / payroll deductions','Allocate a payment to existing payroll IRD obligations.','ird'],
  ...purposes.out.map(([p,n])=>[p,n,'Use the existing payment form.',p]),
  ['distribution','Dividend / distribution','Use accountant journals to settle an approved distribution; do not treat it as an expense.','advanced'],
  ['advanced','Split payment / another transaction','Use the existing accountant journal for multiple allocations or special accounting.','advanced']
 ]};
 async function choose(kind='in'){
  if(kind==='transfer')return open('transfer');
  const token=++sequence,c={bid:bid(),kind,busy:false};context=c;modal().classList.add('open');$('ctClose').disabled=false;
  $('ctContent').innerHTML='<p role="status">Loading recording options…</p><p id="ctError" role="alert" hidden></p>';
  try{const data=await snapshot();if(!active(c)||token!==sequence)return;if(!data.can_write)throw new Error('You do not have permission to record financial transactions.');
   $('ctContent').innerHTML=`<h2>${kind==='in'?'Record money in':'Record money out'}</h2><p class="hint">Choose what happened. Frindly uses the existing transaction and payment workflow so it is recorded once.</p><p id="ctError" role="alert" hidden></p><label>Find a transaction type<input id="ctRouteSearch" type="search" placeholder="Invoice, GST, investment, refund…"></label><div id="ctRouteList" class="ct-route-list"></div><button class="secondary" id="ctCancel">Cancel</button>`;
   const draw=()=>{const term=$('ctRouteSearch').value.trim().toLowerCase(),rows=moneyRoutes[kind].filter(r=>!['share_buyback','return_share_capital'].includes(r[0])||data.entity_type==='company').filter(r=>r.join(' ').toLowerCase().includes(term));$('ctRouteList').innerHTML=rows.map(([id,title,help])=>`<button type="button" class="secondary ct-route" data-money-route="${esc(id)}"><strong>${esc(title)}</strong><small>${esc(help)}</small></button>`).join('')||'<p class="hint">No matching type. Clear the search and choose Other receipt/payment or Split / another transaction.</p>';$('ctRouteList').querySelectorAll('[data-money-route]').forEach(b=>b.onclick=()=>route(c,b.dataset.moneyRoute));};$('ctRouteSearch').oninput=draw;$('ctCancel').onclick=close;draw();$('ctRouteSearch').focus();
  }catch(e){error(c,e);}
 }
 async function pick(c,title,load,done,empty){
  const token=++sequence;$('ctContent').innerHTML=`<h2>${esc(title)}</h2><p role="status">Loading existing records…</p><p id="ctError" role="alert" hidden></p>`;
  try{const choices=await load();if(!active(c)||token!==sequence)return;
   $('ctContent').innerHTML=`<h2>${esc(title)}</h2><p class="hint">Select the original record. Payment is recorded through its existing form.</p><p id="ctError" role="alert" hidden></p>${choices.length?'<label>Search records<input id="ctPickSearch" type="search" placeholder="Name, reference or amount"></label><div id="ctPickList" class="ct-route-list"></div>':`<p class="notice">${esc(empty)}</p>`}<div class="actions"><button class="secondary" id="ctPickBack">Back</button><button class="secondary" id="ctCancel">Cancel</button></div>`;
   $('ctPickBack').onclick=()=>choose(c.kind);$('ctCancel').onclick=close;
   if(choices.length){const draw=()=>{const term=$('ctPickSearch').value.toLowerCase();$('ctPickList').innerHTML=choices.filter(r=>r.label.toLowerCase().includes(term)).map((r,i)=>`<button type="button" class="secondary ct-route" data-money-pick="${esc(r.id)}">${esc(r.label)}</button>`).join('')||'<p>No matching records.</p>';$('ctPickList').querySelectorAll('[data-money-pick]').forEach(b=>b.onclick=async()=>{if(!active(c)||c.busy)return;c.busy=true;b.disabled=true;try{c.busy=false;close();await done(b.dataset.moneyPick);}catch(e){c.busy=false;if(b.isConnected)b.disabled=false;if(active(c))error(c,e);else toast(e.message||String(e));}});};$('ctPickSearch').oninput=draw;draw();}
  }catch(e){error(c,e);}
 }
 async function route(c,id){
  if(!active(c)||c.busy)return;const row=moneyRoutes[c.kind].find(r=>r[0]===id);if(!row)return;const action=row[3];
  try{
   if(purposes[c.kind].some(p=>p[0]===action)){return open(c.kind,{purpose:action});}
   if(action==='invoice')return pick(c,'Receive an invoice payment',()=>window.FrindlyInvoices.moneyChoices(),async id=>{await window.FrindlyInvoices.openPayment(id);followLinkedDialog('invoiceModal',c.bid);},'No issued invoices have an outstanding balance. Create or issue the invoice in Invoices first.');
   if(action==='expense'||action==='supplier_refund'){const refund=action==='supplier_refund';return pick(c,refund?'Receive a supplier refund':'Pay an existing bill',()=>window.Expenses.moneyChoices(refund?'refund':'payment'),async id=>{if(refund)await window.Expenses.openMoneyRefund(id);else await window.Expenses.openMoneyPayment(id);followLinkedDialog(refund?'supplierRefundModal':'expensePaymentModal',c.bid);},refund?'No recorded supplier credit is available. Create the supplier credit against its original expense first.':'No recorded bills have an outstanding balance. Create the purchase in Expenses first.');}
   if(['gst_refund','gst_payment','wages','ird'].includes(action)){
    const kind=action.startsWith('gst')?'gst':action,direction=action==='gst_refund'?'refund':'payment';
    return pick(c,action==='gst_refund'?'Receive a GST refund':kind==='gst'?'Pay GST':kind==='wages'?'Pay employees':'Pay payroll IRD obligations',async()=>{const data=await rpc('frindly_settlement_snapshot',{p_kind:kind,p_source_id:null});const grouped=new Map();for(const o of data.obligations||[])if(o.direction===direction&&Number(o.outstanding)>0&&o.account_id&&!o.notice){const x=grouped.get(o.source_id)||{id:o.source_id,label:o.label,amount:0};x.amount+=Number(o.outstanding);grouped.set(o.source_id,x);}return [...grouped.values()].map(x=>({...x,label:x.label+' · '+money(x.amount)}));},id=>window.LiabilityPayments.open(kind,id),kind==='gst'?'No posted GST return has an outstanding amount in this direction. Review the GST return first.':'No posted unpaid obligation is available. Review the pay run first.');
   }
   if(action==='customer_refund'){close();return await window.FrindlyInvoices.openRefunds();}
   if(action==='sale'){close();if(await window.switchView?.('create')!==false)toast('Create the sales invoice, then record its payment.');return;}
   if(action==='purchase'){close();if(await window.switchView?.('expenses')!==false)window.Expenses.switchTab('add');return;}
   // Special entries stay under the established accounting permission checks.
   $('ctContent').innerHTML=`<h2>${esc(row[1])}</h2><p class="hint">${esc(row[2])}</p><p id="ctError" role="alert" hidden></p>${action==='deposit'||id==='asset_sale'?`<p>${id==='asset_sale'?'Record the asset sale and receipt through Invoices so sales tax follows the existing workflow. Your accountant records the disposal adjustment separately, without recording the bank receipt again.':'For an advance against a sale, use the existing staged/advance invoice workflow. A refundable customer security deposit is a liability and needs accountant allocation.'}</p><button class="primary" id="ctAdvanceInvoice">Open Invoices</button>`:''}<p>${id==='asset_sale'?'The separate disposal journal must remove the asset and accumulated depreciation and recognise the gain or loss; it must not duplicate the bank receipt.':'For special accounting, select the bank ledger and enter balanced allocation lines in Manual Journals. Deposits and distributions must use the appropriate liability or equity accounts.'} Link payments for existing invoices, bills, GST and payroll through their own forms instead.</p><p class="hint">Manual journals retain the existing owner/admin/accountant permissions. GST-sensitive or unusual transactions need accountant review. No money is recorded until the original form is completed.</p><div class="actions"><button class="primary" id="ctAdvanced">Open accountant journal</button><button class="secondary" id="ctPickBack">Back</button><button class="secondary" id="ctCancel">Cancel</button></div>`;
   $('ctPickBack').onclick=()=>choose(c.kind);$('ctCancel').onclick=close;
   if($('ctAdvanceInvoice'))$('ctAdvanceInvoice').onclick=async()=>{close();await window.switchView?.('invoices');};
   $('ctAdvanced').onclick=()=>{const button=$('finManualJournalTab');if(!button)return error(c,new Error('Manual Journals is not available. Ask your accountant to record this transaction.'));const period=$('financialReportPeriodCard'),panel=$('financial-panel-cashflow');if(period&&panel?.contains(period))panel.before(period);close();button.click();};
  }catch(e){error(c,e);}
 }
 async function reconcile(tx,onDone,preset={}){
  const c={bid:bid(),tx,onDone,busy:false};context=c;const token=++sequence;modal().classList.add('open');$('ctClose').disabled=false;$('ctContent').innerHTML='<p>Finding recorded transactions…</p><p id="ctError" role="alert" hidden></p>';
  try{const data=await snapshot();if(!active(c)||token!==sequence)return;const candidates=(data.transactions||[]).filter(t=>t.status==='recorded').flatMap(t=>(t.legs||[]).filter(l=>!l.matched&&l.bank_account_id===tx.bank_account_id&&cents(l.amount)===cents(tx.amount)).map(l=>({t,l}))).sort((a,b)=>Math.abs(Date.parse(a.l.transaction_date)-Date.parse(tx.transaction_date))-Math.abs(Date.parse(b.l.transaction_date)-Date.parse(tx.transaction_date)));
   $('ctContent').innerHTML=`<h2>${preset.ownerEquity?'Owner / Equity':'Other bank transaction'}</h2><p>${esc(tx.transaction_date)} · ${esc(money(tx.amount))}</p><p id="ctError" role="alert" hidden></p><h3>Match a recorded transaction</h3>${candidates.length?`<label>Recorded transaction<select id="ctExisting"><option value="">Select a transaction</option>${candidates.map(({t,l})=>`<option value="${esc(l.id)}">${esc(l.transaction_date)} · ${esc(t.description)} · ${esc(money(l.amount))}</option>`).join('')}</select></label><p class="hint" id="ctMatchDate">Matching uses the bank statement date, ${esc(tx.transaction_date)}. Any date correction is audited.</p><button class="primary" id="ctMatch">Match recorded transaction</button>`:'<p class="hint">No unmatched transaction has this bank, amount and direction.</p>'}<h3>Not recorded yet?</h3><p class="hint">For grants, interest, loans, owner funds and income tax. Check recorded transactions before creating another.</p><div class="actions">${preset.ownerEquity&&tx.amount<0&&data.capital?.can_record?'<button type="button" class="secondary" id="ctBankBuyback">Share buyback</button>':''}<button class="secondary" id="ctNew">Record ${tx.amount>0?'money in':'money out'} & match</button><button class="secondary" id="ctTransfer"><span aria-hidden="true">⇄</span> Transfer between accounts</button><button class="secondary" id="ctCancel">Cancel</button></div>`;
   $('ctCancel').onclick=close;
   if($('ctBankBuyback'))$('ctBankBuyback').onclick=()=>open('out',{purpose:'share_buyback'},tx,onDone);
   $('ctNew').onclick=()=>open(tx.amount>0?'in':'out',preset,tx,onDone);$('ctTransfer').onclick=()=>open('transfer',{},tx,onDone);
   if($('ctMatch'))$('ctMatch').onclick=async()=>{if(c.busy)return;const id=$('ctExisting').value;if(!id)return error(c,new Error('Select the recorded transaction.'));c.busy=true;$('ctMatch').disabled=true;try{await rpc('frindly_match_cash_transaction',{p_bank_transaction_id:tx.id,p_leg_id:id});await saved(c,'Transaction matched');}catch(e){error(c,e);}finally{c.busy=false;if($('ctMatch'))$('ctMatch').disabled=false;}};
  }catch(e){error(c,e);}
 }
 async function shareChange(t){
  const c={bid:bid(),kind:'out',busy:false,requestId:crypto.randomUUID()};context=c;modal().classList.add('open');$('ctContent').innerHTML='<p>Loading shareholding record…</p><p id="ctError" role="alert" hidden></p>';
  try{const data=await rpc('frindly_share_change_snapshot',{p_transaction_id:t.id});if(!active(c))return;
   const linked=data.events.find(e=>e.id===data.linked_event_id),owner=data.owners.find(o=>o.id===t.owner_id),events=data.events.filter(e=>!e.payment_review_required&&e.change_type===(t.purpose==='share_buyback'?'cancellation':'capital_only'));
   const eventRows=e=>`<h3>${e.change_type==='cancellation'?'Confirmed share cancellation':'Capital returned — shares unchanged'}</h3><p>${esc(e.effective_date)} · ${esc(e.authority_ref)} · ${esc(e.note)}</p>${e.payment_review_required?`<p class="notice">Payment reversed — accountant review required. The legal share change has not been undone.</p>${linked&&data.can_confirm?'<button type="button" class="secondary" id="ctShareReview">Confirm accountant review — keep share change</button>':''}`:''}<div class="table-scroll"><table><thead><tr><th>Shareholder</th><th>Shares before</th><th>Shares after</th><th>Ownership after</th></tr></thead><tbody>${e.after_data.map(o=>`<tr><td>${esc(o.display_name)}</td><td>${esc(e.before_data.find(x=>x.id===o.id)?.shares_held??'Not recorded')}</td><td>${esc(o.shares_held??'Not recorded')}</td><td>${esc(o.ownership_percent??'Not recorded')}${o.ownership_percent!=null?'%':''}</td></tr>`).join('')}</tbody></table></div><h3>Linked payments</h3>${e.payments.map(p=>`<p><button type="button" class="secondary mini-btn" data-share-payment="${esc(p.id)}">${esc(p.description)} · ${esc(money(p.amount))} · ${esc(p.status)}</button></p>`).join('')}`;
   $('ctContent').innerHTML=`<h2>Shareholding change</h2><p>${esc(t.description)} · ${esc(money(t.amount))}</p><p id="ctError" role="alert" hidden></p>${linked?eventRows(linked):data.can_confirm&&t.status==='recorded'?`<p class="hint">Confirm legal completion separately from payment. This updates the existing shareholder register and history without posting another journal. A payment does not prove that all shares were sold.</p><form id="ctShareForm"><div class="form-grid compact">${field('mode','Record or link',`<select id="ctShareMode"><option value="">Confirm a new ${t.purpose==='share_buyback'?'share cancellation':'capital-only return'}</option>${events.map(e=>`<option value="${esc(e.id)}">Link another payment to ${esc(e.authority_ref)} · ${esc(e.effective_date)}</option>`).join('')}</select>`,true)}<div id="ctShareNew" class="wide form-grid compact">${field('effective','Legal completion / effective date',`<input id="ctShareDate" type="date" required max="${esc(today())}">`)}${field('quantity','Shares acquired and cancelled',`<input id="ctShareQuantity" type="number" min="0.0001" step="0.0001" ${t.purpose==='share_buyback'?'required':'value="0" readonly'}>`)}${field('reference','Approval / resolution reference',`<input id="ctShareRef" required minlength="3" maxlength="200" value="${esc(t.request_payload?.capital_authority_ref||'')}">`,true)}${field('document','Supporting document reference and completion note','<textarea id="ctShareNote" required minlength="5" maxlength="1000" rows="2"></textarea>',true)}${t.purpose==='share_buyback'?'<label class="wide"><input id="ctShareComplete" type="checkbox" required> I have checked that Settings contains every issued share, with accurate quantities in one share class, and that these shares are cancelled rather than held as treasury shares.</label>':'<p class="hint wide">This capital repayment leaves share numbers and ownership percentages unchanged. If shares are also cancelled, use your accountant to record the appropriate legal event.</p>'}<p class="hint wide">Missing share quantities, multiple classes, treasury shares or changes before later recorded ownership events require accountant review. <button type="button" class="secondary mini-btn" id="ctShareSettings">Open shareholder settings</button> <button type="button" class="secondary mini-btn" id="ctShareAccountant">Open accountant tools</button></p></div><div id="ctSharePreview" class="wide"></div><label class="wide"><input id="ctShareAuthorised" type="checkbox" required> The approved acquisition / capital return has legally completed, supporting records are available, and I have reviewed this preview and any linked payments.</label></div><p class="hint">Maintain the statutory share register and make any required Companies Office filings separately. A shareholder leaving does not automatically resign as a director.</p><div class="actions"><button type="button" class="secondary" id="ctShareBack">Back to payment</button><button type="submit" class="primary" id="ctShareConfirm" style="min-width:190px;min-height:38px;color:#fff;background:#2563eb;border:1px solid #2563eb;font-weight:600">Confirm shareholding change</button><p id="ctShareFeedback" role="alert" aria-live="assertive" hidden style="margin:8px 0 0;max-width:100%;font-weight:600"></p></div></form>`:'<p class="notice">This payment has no linked shareholding change. Confirmation requires an NZ company and authorised company accounting access, and the payment must be recorded.</p>'}<div class="actions"><button type="button" class="secondary" id="ctShareClose">${linked?'Back to payment':'Close'}</button></div>`;
   $('ctShareClose').onclick=()=>linked?view(t.id):close();if($('ctShareReview'))$('ctShareReview').onclick=async()=>{const note=await window.FrindlyDialogs.prompt('Confirm your accountant has reviewed the reversed payment and that the legal share change remains valid. Describe the review and replacement payment arrangement (this does not undo ownership):','');if(!note?.trim()||!active(c))return;c.busy=true;try{await rpc('frindly_review_share_payment',{p_change_id:linked.id,p_note:note.trim()});if(active(c))await shareChange(t);}catch(e){c.busy=false;error(c,e);}};document.querySelectorAll('[data-share-payment]').forEach(b=>b.onclick=()=>view(b.dataset.sharePayment));if(linked||!$('ctShareForm'))return;
   const preview=()=>{const eid=$('ctShareMode').value,isNew=!eid;$('ctShareNew').hidden=!isNew;$('ctShareNew').querySelectorAll('input,textarea').forEach(x=>x.disabled=!isNew);$('ctShareAuthorised').checked=false;
    if(eid){$('ctSharePreview').innerHTML=eventRows(events.find(e=>e.id===eid));return;}
    const qty=Number($('ctShareQuantity').value),cancel=t.purpose==='share_buyback',total=data.owners.reduce((n,o)=>n+Number(o.shares_held||0),0),valid=owner&&(!cancel||qty>0&&qty<=Number(owner.shares_held)&&total>qty&&data.owners.every(o=>o.shares_held!=null&&o.share_class&&o.share_class===owner.share_class&&(!Number(o.shares_held)||o.is_shareholder&&o.status==='active')));
    c.validPreview=valid;$('ctSharePreview').innerHTML=valid?`<h3>Preview — ${esc(owner.display_name)}${cancel?' · '+esc(owner.share_class):''}</h3><div class="table-scroll"><table><thead><tr><th>Shareholder</th><th>Shares before</th><th>Shares after</th><th>Ownership after</th></tr></thead><tbody>${data.owners.map(o=>{const n=Number(o.shares_held||0)-(cancel&&o.id===t.owner_id?qty:0),pct=cancel?(n/(total-qty)*100).toFixed(2):o.ownership_percent;return `<tr><td>${esc(o.display_name)}</td><td>${esc(o.shares_held??'Not recorded')}</td><td>${esc(cancel?n:o.shares_held??'Not recorded')}</td><td>${esc(pct??'Not recorded')}${pct!=null?'%':''}</td></tr>`;}).join('')}</tbody></table></div>`:'<p class="notice">Enter the shares to cancel and complete the share quantities and class for every holder in Settings before confirming. No ownership changes have been made.</p>';
   };
   $('ctShareMode').onchange=preview;['ctShareQuantity','ctShareDate'].forEach(id=>$(id)?.addEventListener('input',preview));
   // Checking approval must not clear itself; only changes to the preview invalidate approval.
   $('ctShareAuthorised').oninput=e=>e.stopPropagation();$('ctShareComplete')?.addEventListener('input',e=>e.stopPropagation());
   $('ctShareSettings').onclick=()=>{close();window.location.hash='#settings/owners';};$('ctShareAccountant').onclick=()=>route(c,'advanced');$('ctShareBack').onclick=()=>view(t.id);preview();
   const shareFeedback=(message,failed=false)=>{const node=$('ctShareFeedback');if(!node)return;node.textContent=message;node.hidden=false;node.style.color=failed?'#b91c1c':'#166534';if(failed)node.scrollIntoView({block:'nearest',behavior:'smooth'});};
   $('ctShareForm').addEventListener('invalid',e=>{const label=e.target.closest('label');shareFeedback('Please complete the required field: '+(label?.textContent||e.target.id).trim().slice(0,100)+'.',true);},true);
   $('ctShareForm').onsubmit=async e=>{e.preventDefault();if(!active(c)||c.busy)return;const eid=$('ctShareMode').value;if(!eid&&!c.validPreview){shareFeedback('Complete and review the share register preview first.',true);return;}if(!$('ctShareAuthorised').checked||(!eid&&t.purpose==='share_buyback'&&!$('ctShareComplete').checked)){shareFeedback('Please tick both confirmation boxes before saving.',true);return;}const p={transaction_id:t.id,event_id:eid||null,authorised:$('ctShareAuthorised').checked,...(!eid?{change_type:t.purpose==='share_buyback'?'cancellation':'capital_only',effective_date:$('ctShareDate').value,shares_acquired:Number($('ctShareQuantity').value),authority_ref:$('ctShareRef').value.trim(),note:$('ctShareNote').value.trim(),register_complete:!!$('ctShareComplete')?.checked,expected_owners:data.owners}:{})};c.busy=true;$('ctShareConfirm').disabled=true;$('ctShareConfirm').textContent='Saving…';shareFeedback('Saving the confirmed shareholding change…');try{await rpc('frindly_confirm_share_change',{p_request_id:c.requestId,p_change:p});if(!active(c))return;await window.Financials?.refresh?.();toast('Shareholding change saved — no additional journal posted');await shareChange(t);}catch(err){shareFeedback(err.message||String(err),true);c.busy=false;if($('ctShareConfirm')){$('ctShareConfirm').disabled=false;$('ctShareConfirm').textContent='Confirm shareholding change';}}};
  }catch(e){error(c,e);}
 }
 function ownershipPeriods(owner,history,from,to){
  const changes=history.filter(h=>h.owner_id===owner.id).sort((a,b)=>a.effective_date.localeCompare(b.effective_date));if(!changes.length)return null;
  let current=changes[0].before_data||owner,start=from;const periods=[];
  const add=(end)=>{const effective=current.shareholding_effective_from,begin=effective&&effective>start?effective:start;if(begin<=end)periods.push({from:begin,to:end,owner:current});};
  for(const h of changes){if(h.effective_date<=from){current=h.after_data;continue;}if(h.effective_date>to)break;const date=new Date(h.effective_date+'T12:00:00Z');date.setUTCDate(date.getUTCDate()-1);add(date.toISOString().slice(0,10));start=h.effective_date;current=h.after_data;}
  add(to);return {periods,asOf:current};
 }
 async function ownerChanges(ownerId){const c={bid:bid()};context=c;modal().classList.add('open');$('ctContent').innerHTML='<p>Loading capital payments…</p><p id="ctError" role="alert" hidden></p>';try{const data=await snapshot();if(!active(c))return;if(data.entity_type!=='company')throw new Error('Shareholding changes are for companies only.');const payments=data.transactions.filter(t=>t.owner_id===ownerId&&['share_buyback','return_share_capital'].includes(t.purpose));$('ctContent').innerHTML=`<h2>Capital payments & share changes</h2><p>Open an existing payment to confirm or review its linked shareholding record.</p>${payments.map(t=>`<p><button type="button" class="secondary" data-owner-capital="${esc(t.id)}">${esc(t.description)} · ${esc(money(t.amount))} · ${esc(t.status)}</button></p>`).join('')||'<p>No capital payments recorded for this person.</p>'}<button type="button" class="secondary" id="ctOwnerClose">Close</button>`;document.querySelectorAll('[data-owner-capital]').forEach(b=>b.onclick=()=>view(b.dataset.ownerCapital));$('ctOwnerClose').onclick=close;}catch(e){error(c,e);}}

 async function view(id,buybackRecorded=false){const c={bid:bid(),busy:false};context=c;++sequence;modal().classList.add('open');$('ctClose').disabled=false;$('ctContent').innerHTML='<p>Loading transaction…</p><p id="ctError" role="alert" hidden></p>';try{const data=await snapshot();if(!active(c))return;const t=data.transactions.find(t=>t.id===id);if(!t)throw new Error('Transaction unavailable in this business.');$('ctContent').innerHTML=`<h2>${buybackRecorded?'Payment recorded':esc(t.description)}</h2><p>${esc(label(t.purpose))} · ${esc(money(t.amount))} · ${t.status==='void'?'Reversed':'Recorded'}</p><p id="ctError" role="alert" hidden></p><div class="table-scroll"><table><thead><tr><th>Bank</th><th>Date</th><th>Amount</th><th>Bank match</th></tr></thead><tbody>${(t.legs||[]).map(l=>`<tr><td>${esc(l.bank_name)}</td><td>${esc(l.transaction_date)}${l.original_date!==l.transaction_date?`<small>Originally ${esc(l.original_date)}</small>`:''}</td><td>${esc(money(l.amount))}</td><td>${l.matched?'Matched':'Not matched'}</td></tr>`).join('')}</tbody></table></div><p>${esc(t.reference||'')}</p><p>${esc(t.note||'')}</p>${['share_buyback','return_share_capital'].includes(t.purpose)?`<h3>Approved capital allocation</h3><p>${esc(t.request_payload?.capital_authority_ref)} · ${esc(t.request_payload?.capital_authority_date)} · Reviewed by ${esc(t.request_payload?.capital_reviewer)}</p><p>${esc(t.request_payload?.capital_share_details)}</p>${(t.request_payload?.capital_allocations||[]).map(a=>`<p>${esc((data.capital?.accounts||[]).find(x=>x.id===a.account_id)?.name||a.account_id)} · ${esc(money(a.amount))}</p>`).join('')}<p class="hint">Payment alone does not change ownership. Confirm or review the linked shareholding record, then maintain the statutory register and Companies Office filings.</p>${data.entity_type==='company'?`<button type="button" class="secondary" id="ctShareChange">${buybackRecorded?'Confirm shareholding change':'Confirm / review shareholding change'}</button>`:''}`:''}${t.tax_year?`<p>Tax year ending ${esc(t.tax_year)} · ${esc(t.taxpayer)}</p>`:''}<div class="actions"><button class="secondary" id="ctCancel">${buybackRecorded?'Do this later':'Close'}</button>${data.can_write&&t.status==='recorded'&&!t.legs.some(l=>l.matched)?`<button class="secondary danger" id="ctVoid">${t.kind==='transfer'?'Reverse transfer':'Reverse transaction'}</button>`:''}</div>`;$('ctCancel').onclick=close;if($('ctShareChange'))$('ctShareChange').onclick=()=>shareChange(t);if($('ctVoid'))$('ctVoid').onclick=async()=>{const reason=await window.FrindlyDialogs.prompt((['share_buyback','return_share_capital'].includes(t.purpose)?'Reversing payment does not undo the legal share change. Review its linked shareholding record with your accountant. Reason for reversal:':'Reason for reversing this transaction:'),'');if(!reason?.trim()||!active(c)||c.busy)return;c.busy=true;$('ctVoid').disabled=true;try{await rpc('frindly_void_cash_transaction',{p_transaction_id:id,p_reason:reason.trim()});await saved(c,'Transaction reversed');}catch(e){error(c,e);c.busy=false;$('ctVoid').disabled=false;}};
  }catch(e){error(c,e);}}
 // Shared posted-bank projection. No operational estimates are substituted on failure.
 async function ledger(to){const b=bid(),client=sb();let all=[];for(let start=0;;start+=1000){let query=client.rpc('frindly_cash_ledger',{p_to:to});const paged=typeof query.range==='function';const r=await(paged?query.range(start,start+999):query);if(r.error)throw new Error(r.error.message);all.push(...(r.data||[]));if(!paged||(r.data||[]).length<1000)break;}if(bid()!==b)throw new Error('Business changed while loading.');return all.map(r=>({...r,amount:Number(r.debit||0)-Number(r.credit||0)}));}

 function totals(rows,from,to){const period=rows.filter(r=>r.journal_date>=from&&r.journal_date<=to),group=new Map();for(const r of period.filter(r=>!(r.status==='reversed'&&['cash_transaction','cash_transfer'].includes(r.source_type))&&r.source_type!=='cash_correction')){const k=r.journal_id||r.journal_number;const x=group.get(k)||{amount:0,transfer:r.source_type==='cash_transfer'};x.amount+=r.amount;group.set(k,x);}const movements=[...group.values()];return {opening:rows.filter(r=>r.journal_date<from).reduce((s,r)=>s+r.amount,0),closing:rows.filter(r=>r.journal_date<=to).reduce((s,r)=>s+r.amount,0),moneyIn:movements.filter(r=>!r.transfer&&r.amount>0).reduce((s,r)=>s+r.amount,0),moneyOut:-movements.filter(r=>!r.transfer&&r.amount<0).reduce((s,r)=>s+r.amount,0),transit:movements.filter(r=>r.transfer).reduce((s,r)=>s+r.amount,0)};}
 async function render(from,to){
  const root=$('finCashFlowBody');if(!root)return;const b=bid(),token=++renderSequence;
  const previous=historyContext?.bid===b?historyContext:null;
  const period=$('financialReportPeriodCard');if(period&&root.contains(period))root.before(period);
  root.innerHTML='<p role="status">Loading recorded transactions…</p>';
  try{
   const [data,rows]=await Promise.all([snapshot(),ledger(to)]);if(b!==bid()||token!==renderSequence)return;
   historyContext={rows,bid:b,bank:previous?.bank||'',type:previous?.type||'all',search:previous?.search||''};
   const linked=new Map((data.transactions||[]).flatMap(t=>(t.legs||[]).map(l=>[l.accounting_journal_id,t]))),grouped=new Map();
   for(const r of rows){
    if(/opening/.test(r.source_type||'')||r.source_type==='cash_correction'||r.status==='reversed'&&['cash_transaction','cash_transfer'].includes(r.source_type))continue;
    const cash=linked.get(r.journal_id);if(cash&&cash.status!=='recorded')continue;
    const key=[r.journal_id,r.bank_name].join('|'),x=grouped.get(key)||{...r,amount:0,cash};x.amount+=Number(r.amount);grouped.set(key,x);
   }
   const entries=[...grouped.values()].filter(r=>Math.abs(r.amount)>.005).map(r=>({id:r.cash?.id||r.journal_id,journalId:r.journal_id,cash:!!r.cash,description:r.cash?.description||r.description||r.source_reference||'Bank movement',reference:r.cash?.reference||r.source_reference||'',purpose:r.cash?.purpose||({customer_payment:'Customer invoice payment',invoice_payment:'Customer invoice payment',supplier_payment:'Supplier payment',expense_payment:'Expense payment',customer_refund:'Customer refund',supplier_refund:'Supplier refund',liability_settlement:'GST / payroll settlement',manual_journal:'Accountant journal'}[r.source_type]||String(r.source_type||'Bank movement').replaceAll('_',' ')),kind:/transfer/.test(r.source_type||'')?'transfer':r.amount>0?'in':'out',legs:[{id:r.account_code,bank_account_id:r.bank_name,bank_name:r.bank_name,transaction_date:r.journal_date,amount:r.amount}]}));
   const bankMap=new Map(rows.map(r=>[r.bank_name,r.bank_name]));
   root.innerHTML=`<section class="card ct-entry-card" aria-labelledby="ctEntryHeading"><h3 id="ctEntryHeading">Record a transaction</h3><div class="cash-entry-actions"><div class="actions"><button class="primary" data-cash-open="in" ${data.can_write?'':'disabled'}><span aria-hidden="true">↓</span> Record money in</button><button class="primary" data-cash-open="out" ${data.can_write?'':'disabled'}><span aria-hidden="true">↑</span> Record money out</button><button class="primary" data-cash-open="transfer" ${data.can_write?'':'disabled'}>Transfer between accounts</button></div><p class="hint">Choose any receipt or payment. Frindly opens the right existing workflow.</p><details class="ct-entry-help"><summary>What can I record here?</summary><p class="hint">Customer and supplier payments, refunds, GST, payroll, investment, loans, grants, interest, deposits and transfers. Special or split allocations use the existing accountant workflow.</p></details></div></section><section class="card ct-history-card" aria-labelledby="ctHistoryHeading"><div class="ct-history-heading"><h3 id="ctHistoryHeading">All receipts &amp; payments</h3><div class="ct-report-links"><button class="ct-report-link" data-cash-report="cashbook">Open Cash Book ↗</button><button class="ct-report-link" data-cash-report="cashstatement">Cash Flow Report ↗</button></div></div><p class="hint">Recorded bank receipts and payments from linked workflows. Opening and running balances remain in Cash Book.</p><div class="ct-filter-top"><div id="ctPeriodSlot"></div><label>Bank account<select id="ctHistoryBank"><option value="">All bank accounts</option>${[...bankMap].map(([id,n])=>`<option value="${esc(id)}">${esc(n)}</option>`).join('')}</select></label></div><div class="ct-filter-bottom"><label>Transaction type<select id="ctHistoryType"><option value="all">All types</option><option value="in">Money in</option><option value="out">Money out</option><option value="transfer">Transfers</option></select></label><label>Search<input id="ctHistorySearch" type="search" placeholder="Description, reference or amount"></label></div><div class="table-scroll ct-history-table"><table><thead><tr><th>Date</th><th>Description</th><th>Transaction type</th><th>Bank account</th><th>Money in</th><th>Money out</th><th></th></tr></thead><tbody id="ctHistoryRows"></tbody></table></div><div class="ct-pagination"><span id="ctHistoryCount" role="status"></span><div class="actions"><button class="secondary" id="ctPrevious">Previous</button><button class="secondary" id="ctNext">Next</button></div></div></section>`;
   // Move the existing period controls rather than introduce a second date state.
   const period=$('financialReportPeriodCard');if(period)$('ctPeriodSlot').append(period);
   $('ctHistoryType').value=historyContext.type;$('ctHistoryBank').value=historyContext.bank;$('ctHistorySearch').value=historyContext.search;
   let page=0;
   const draw=()=>{
    const type=$('ctHistoryType').value,bank=$('ctHistoryBank').value,search=$('ctHistorySearch').value.trim().toLowerCase();Object.assign(historyContext,{type,bank,search});
    const history=entries.flatMap(t=>(t.legs||[]).map(l=>({t,l}))).filter(({t,l})=>l.transaction_date>=from&&l.transaction_date<=to&&(!bank||(l.bank_account_id||l.bank_name)===bank)&&(type==='all'||type==='transfer'&&t.kind==='transfer'||type==='in'&&t.kind!=='transfer'&&Number(l.amount)>0||type==='out'&&t.kind!=='transfer'&&Number(l.amount)<0)&&(!search||[t.description,t.reference,label(t.purpose),l.bank_name,Math.abs(Number(l.amount)).toFixed(2)].join(' ').toLowerCase().includes(search))).sort((a,b)=>String(b.l.transaction_date).localeCompare(String(a.l.transaction_date))||String(a.t.id).localeCompare(String(b.t.id))||String(a.l.id).localeCompare(String(b.l.id)));
    page=Math.min(page,Math.max(0,Math.ceil(history.length/20)-1));const start=page*20;
    $('ctHistoryRows').innerHTML=history.slice(start,start+20).map(({t,l})=>`<tr><td data-label="Date">${esc(l.transaction_date)}</td><td data-label="Description">${esc(t.description)}${t.reference?`<small>${esc(t.reference)}</small>`:''}</td><td data-label="Transaction type">${esc(label(t.purpose))}</td><td data-label="Bank account">${esc(l.bank_name)}</td><td data-label="Money in">${Number(l.amount)>0?money(l.amount):'—'}</td><td data-label="Money out">${Number(l.amount)<0?money(-l.amount):'—'}</td><td><button class="secondary compact-btn" ${t.cash?`data-cash-view="${esc(t.id)}"`:`data-cash-journal="${esc(t.journalId)}"`}>View details</button></td></tr>`).join('')||'<tr><td colspan="7"><strong>No transactions found for this period.</strong><small>Try another date range or record a receipt or payment above.</small></td></tr>';
    $('ctHistoryCount').textContent=history.length?`Showing ${start+1}–${Math.min(start+20,history.length)} of ${history.length} account movements`:'0 account movements';$('ctPrevious').disabled=page===0;$('ctNext').disabled=start+20>=history.length;
   };
   for(const id of ['ctHistoryType','ctHistoryBank'])$(id).onchange=()=>{page=0;draw();};$('ctHistorySearch').oninput=()=>{page=0;draw();};$('ctPrevious').onclick=()=>{page--;draw();};$('ctNext').onclick=()=>{page++;draw();};
   root.querySelectorAll('[data-cash-report]').forEach(button=>button.onclick=()=>{document.querySelector(`#finMoreReports [data-fin-tab="${button.dataset.cashReport}"]`)?.click();});draw();
  }catch(e){if(b===bid()&&token===renderSequence)root.innerHTML=`<p class="notice">Recorded transactions unavailable. ${esc(e.message)}</p>`;}
 }
 async function journal(id){const c={bid:bid(),busy:false};context=c;++sequence;modal().classList.add('open');$('ctClose').disabled=false;const rows=historyContext?.bid===c.bid?(historyContext.rows||[]).filter(r=>r.journal_id===id):[],r=rows[0];if(!r){$('ctContent').innerHTML='<p>Reload Money In &amp; Out to view this movement.</p><button class="secondary" id="ctCancel">Close</button>';$('ctCancel').onclick=close;return;}const source=r.source_type||'',target=/invoice|customer/.test(source)?'invoices':/expense|supplier/.test(source)?'expenses':/payroll/.test(source)?'payroll':'financials';$('ctContent').innerHTML=`<h2>Recorded bank movement</h2><p>${esc(r.journal_date)} · ${esc(r.description||r.source_reference||source)}</p><p>${esc(r.source_reference||'')}</p>${rows.map(l=>`<p>${esc(l.bank_name)} · ${l.amount<0?'Money out':'Money in'} ${esc(money(Math.abs(l.amount)))}</p>`).join('')}<p class="hint">This was recorded through its existing workflow. Manage the original payment there.</p><div id="ctSettlementActions"></div><div class="actions"><button class="secondary" id="ctSource">Open ${target==='financials'?'Financials':target==='payroll'?'Payroll':target==='expenses'?'Expenses':'Invoices'}</button><button class="secondary" id="ctCancel">Close</button></div>`;$('ctCancel').onclick=close;if(source==='liability_settlement')window.LiabilityPayments?.showGstActions(id,$('ctSettlementActions'),()=>active(c),e=>error(c,e),()=>saved(c,'GST settlement updated'));$('ctSource').onclick=async()=>{if(!active(c))return;try{const businessId=c.bid;if(['customer_payment','invoice_payment','supplier_payment','expense_payment'].includes(source)){const incoming=['customer_payment','invoice_payment'].includes(source),column=incoming?'invoice_id':'expense_id',table=incoming?'customer_payments':'expense_payments';const result=await sb().from(table).select(column).eq('business_id',businessId).eq('id',r.source_id).maybeSingle();if(!active(c))return;if(result.error)throw new Error(result.error.message);if(result.data?.[column]){close();return incoming?await window.FrindlyInvoices.openDetails(result.data[column]):await window.Expenses.openDetails(result.data[column]);}}if(source==='liability_settlement'){const results=await Promise.allSettled(['gst','wages','ird'].map(async kind=>({kind,data:await rpc('frindly_settlement_snapshot',{p_kind:kind,p_source_id:null})})));if(!active(c))return;for(const result of results){if(result.status!=='fulfilled')continue;const {kind,data}=result.value,payment=(data.payments||[]).find(p=>p.accounting_journal_id===id),allocations=(payment?.allocations||[]).filter(a=>a.kind===kind);if(allocations.length){const sourceId=allocations.length===1?allocations[0].gst_return_id||allocations[0].pay_run_id:null;close();return await window.LiabilityPayments.open(kind,sourceId);}}}if(source==='customer_refund'){close();return await window.FrindlyInvoices.openRefunds();}close();await window.switchView?.(target);if(source==='supplier_refund')window.Expenses?.switchTab('credits');}catch(e){if(active(c))error(c,e);else toast(e.message||String(e));}};}

 async function taxHistory(){const root=$('provisionalCashHistory');if(!root)return;const b=bid();try{const data=await snapshot();if(b!==bid())return;const tx=data.transactions.filter(t=>['income_tax','income_tax_refund'].includes(t.purpose)&&t.status==='recorded');root.innerHTML='<h3>Recorded income-tax payments and refunds</h3><p class="hint">These are the same transactions shown in Money In &amp; Out. Estimates do not mean tax has been paid.</p>'+(tx.map(t=>`<p>${esc(t.legs[0]?.transaction_date)} · ${esc(money(t.amount))} · Tax year ${esc(t.tax_year)} · ${esc(t.taxpayer)} <button class="secondary compact-btn" data-cash-view="${esc(t.id)}">View</button></p>`).join('')||'<p class="hint">No income-tax transactions recorded here yet.</p>');}catch(e){if(b===bid())root.textContent=e.message;}}
 window.CashTransactions={openShareCapitalReview,ownershipPeriods,ownerChanges,choose,open,reconcile,view,render,ledger,totals,taxHistory,snapshot};
 document.addEventListener('click',e=>{const a=e.target.closest('[data-cash-open]'),v=e.target.closest('[data-cash-view]'),j=e.target.closest('[data-cash-journal]');if(a){if(a.dataset.cashPurpose)open(a.dataset.cashOpen,{purpose:a.dataset.cashPurpose,tax_year:a.dataset.cashYear});else choose(a.dataset.cashOpen);}if(v)view(v.dataset.cashView);if(j)journal(j.dataset.cashJournal);});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&context)close();});
})();
