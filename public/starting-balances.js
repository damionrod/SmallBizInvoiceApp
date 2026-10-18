(function(root,factory){
 'use strict';const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.FrindlyStartingBalances=api;
})(typeof window==='object'?window:globalThis,function(){
 'use strict';
 const norm=v=>String(v??'').normalize('NFKC').trim().toLowerCase().replace(/[^a-z0-9]/g,'');
 function cents(value){
  if(value===null||value===undefined||String(value).trim()==='')return 0;
  const text=String(value).trim().replace(/^\((.*)\)$/,'-$1');
  if(!/^-?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{1,2})?$/.test(text))throw new Error('Use amounts with no more than two decimal places.');
  const clean=text.replaceAll(',',''),negative=clean.startsWith('-'),parts=clean.replace(/^-/, '').split('.'),integer=BigInt(parts[0])*100n+BigInt((parts[1]||'').padEnd(2,'0'));if(integer>BigInt(Number.MAX_SAFE_INTEGER))throw new Error('Amount is too large.');return Number(integer)*(negative?-1:1);
 }
 function mapping(headers){const pick=names=>headers.findIndex(h=>names.includes(norm(h)));return {code:pick(['accountcode','code','accountnumber','accountno','account']),debit:pick(['debit','debits','debitbalance']),credit:pick(['credit','credits','creditbalance'])}}
 function review(rows,columns,accounts,ledger,overrides={}){
  if(!Number.isInteger(columns.code)||columns.code<0||!Number.isInteger(columns.debit)||columns.debit<0||!Number.isInteger(columns.credit)||columns.credit<0||new Set(Object.values(columns)).size!==3)throw new Error('Choose three different columns for account code, debit and credit.');
  const byId=new Map(accounts.map(a=>[a.id,a])),byCode=new Map();for(const account of accounts){const code=String(account.account_code).trim();if(byCode.has(code))throw new Error('Frindly has ambiguous account codes. Ask your accountant to review them.');byCode.set(code,account);}
  const existing=new Map(ledger.map(r=>[String(r.account_code).trim(),cents(r.debits)-cents(r.credits)]));
  const seen=new Set(),errors=[],lines=[];let debits=0,credits=0;
  rows.forEach((row,i)=>{
   if(row.every(v=>String(v??'').trim()===''))return;
   const sourceCode=String(row[columns.code]??'').trim(),account=Object.prototype.hasOwnProperty.call(overrides,i)?byId.get(overrides[i]):byCode.get(sourceCode),line={row:i+2,sourceCode,account:account||null,targetDebit:0,targetCredit:0,existing:0,difference:0,error:null};
   try{
    if(!account||account.archived)throw new Error('Choose an active Frindly account.');
    if(seen.has(account.id))throw new Error('This account appears more than once. Review the source file.');seen.add(account.id);
    line.targetDebit=cents(row[columns.debit]);line.targetCredit=cents(row[columns.credit]);
    if(line.targetDebit<0||line.targetCredit<0||(line.targetDebit>0&&line.targetCredit>0))throw new Error('Use one non-negative debit or credit per account.');
    line.existing=existing.get(String(account.account_code).trim())||0;line.difference=line.targetDebit-line.targetCredit-line.existing;
    if(!Number.isSafeInteger(debits+line.targetDebit)||!Number.isSafeInteger(credits+line.targetCredit)||!Number.isSafeInteger(line.difference))throw new Error('The combined balances are too large.');debits+=line.targetDebit;credits+=line.targetCredit;
   }catch(e){line.error=e.message;errors.push(`Row ${line.row}: ${e.message}`)}lines.push(line);
  });
  if(!lines.length)errors.push('The file has no balance rows.');
  if(debits!==credits)errors.push('Source debit and credit totals do not balance.');
  for(const [code,amount] of existing)if(amount!==0&&!lines.some(l=>l.account&&String(l.account.account_code).trim()===code))errors.push(`Existing ledger account ${code} is missing from the file.`);
  return {lines,debits,credits,errors,balanced:debits===credits,reviewRequired:lines.filter(l=>l.account?.is_control||l.account?.allow_manual_posting===false).map(l=>l.account.account_code),canPost:false};
 }
 function assessEvidence(evidence,model){
  if(!evidence||evidence.posts_balances!==false||!Array.isArray(evidence.documents)||!Array.isArray(evidence.completed_imports)||!Array.isArray(evidence.accounts)||!Array.isArray(evidence.ledger)||!evidence.snapshot_hash)throw new Error('Conversion evidence is incomplete. Refresh the review.');
  if(evidence.documents.length!==evidence.counts?.documents||evidence.completed_imports.length!==evidence.counts?.completed_import_records)throw new Error('The conversion evidence is incomplete; no partial result can be accepted.');
  const issues=[],totals={invoice:0,expense:0},complete={invoice:true,expense:true},documents=new Map(),add=(a,b)=>{const n=a+b;if(!Number.isSafeInteger(n))throw new Error('The combined conversion balances are too large.');return n;};
  const currency=String(evidence.currency||'').trim().toUpperCase();if(!/^[A-Z]{3}$/.test(currency))throw new Error('Configure the business currency before reviewing conversion balances.');
  if(evidence.accounts.length!==evidence.ledger.length)throw new Error('The account and ledger evidence is incomplete. Refresh the review.');
  let ledgerDebits=0,ledgerCredits=0;for(const row of evidence.ledger){if(row.debits===null||row.debits===undefined||row.credits===null||row.credits===undefined)throw new Error('A ledger balance is unavailable.');ledgerDebits=add(ledgerDebits,cents(row.debits));ledgerCredits=add(ledgerCredits,cents(row.credits));}
  if(ledgerDebits!==ledgerCredits)issues.push({kind:'ledger',reference:'Trial balance',message:'The posted ledger debits and credits do not balance.'});
  for(const d of evidence.documents){
   if(!['invoice','expense'].includes(d.kind)||!d.id||documents.has(d.kind+':'+d.id))throw new Error('The document evidence has duplicate or invalid identifiers.');documents.set(d.kind+':'+d.id,d);
   const report=message=>issues.push({kind:d.kind,id:d.id,reference:d.reference||d.id,message});
   try{
    const required=['gross','paid_before','paid_all','credits_before','stored_paid','stored_balance'];for(const key of required)if(d[key]===null||d[key]===undefined)throw new Error('A required document balance is unavailable.');
    const gross=cents(d.gross),paid=cents(d.paid_before),paidAll=cents(d.paid_all),credits=cents(d.credits_before);
    if(gross<0||paid<0||paidAll<paid||credits<0)throw new Error('Amounts or dated payment evidence are inconsistent.');
    if(d.date===null){complete[d.kind]=false;report('The document date is missing.');}
    if(!d.currency||String(d.currency).trim().toUpperCase()!==currency){complete[d.kind]=false;report('The document currency is missing or differs from the business currency.');}
    if(d.estimated_payments){complete[d.kind]=false;report('A payment is marked as a legacy estimate. Confirm its amount and date from source evidence.');}
    if(d.undated_payments){complete[d.kind]=false;report('A payment has no date, so its starting-date treatment needs review.');}
    if(cents(d.stored_paid)!==paidAll)report('The saved paid amount differs from Frindly payment history. An opening-paid balance may be missing.');
    if(cents(d.stored_balance)!==Math.max(gross-paidAll,0))report('The saved cash balance differs from Frindly payment history. Credits are checked separately.');
    if(d.lifecycle_state==='voided'){
     if(!d.voided_at||d.voided_after_cutover!==false){complete[d.kind]=false;report('This document was voided later or has no void date. Historical treatment needs review.');}continue;
    }
    if(d.lifecycle_state==='draft')continue;
    if(d.lifecycle_state!==null&&!['issued','recorded'].includes(d.lifecycle_state)){complete[d.kind]=false;report('The document lifecycle needs review before it can be counted.');continue;}
    if(d.date<=evidence.ledger_as_of&&!d.source_journals)report('This document has no source journal dated on or before the starting date.');
    totals[d.kind]=add(totals[d.kind],(d.date&&d.date<=evidence.ledger_as_of?gross:0)-paid);
   }catch(error){complete[d.kind]=false;report(error.message);}
  }
  for(const kind of ['invoice','expense'])if(evidence.history_gaps?.[kind]){complete[kind]=false;issues.push({kind,reference:'Historical credits',message:'A credit was voided after the starting date or has no void date. Reconstruct its earlier treatment.'});}
  const settlements=evidence.settlements||{};
  for(const [kind,credit,refund] of [['invoice','customer_credits_before','customer_refunds_before'],['expense','supplier_credits_before','supplier_refunds_before']]){
   if(settlements[credit]===null||settlements[credit]===undefined||settlements[refund]===null||settlements[refund]===undefined){complete[kind]=false;issues.push({kind,reference:'Credits and refunds',message:'Dated credit/refund totals are unavailable.'});continue;}
   totals[kind]=add(add(totals[kind],-cents(settlements[credit])),cents(settlements[refund]));
  }
  for(const r of evidence.completed_imports){
   if(r.duplicate_action==='skip')continue;
   const kind=r.kind==='invoices'?'invoice':r.kind==='expenses'?'expense':null;if(!kind)throw new Error('Invalid completed import evidence.');
   const report=message=>issues.push({kind:'import',id:r.id,reference:r.reference||r.id,message});
   try{
    for(const key of ['source_total','source_paid','source_outstanding'])if(r[key]===null||r[key]===undefined)throw new Error('Source settlement amounts are missing. Review the original export.');
    const total=cents(r.source_total),paid=cents(r.source_paid),outstanding=cents(r.source_outstanding);
    if(total<0||paid<0||outstanding<0||add(paid,outstanding)!==total)report('Source paid and outstanding amounts do not equal the original total. Closed/void history needs separate review.');
    if(r.currency!==currency)report('Source currency differs from the review currency.');
    if(paid>0&&outstanding>0)report(r.commit_mode==='historical_reference'?'Part-paid source is historical reference only; its opening-paid amount is not an operational payment.':'A part-paid opening record needs the shared opening-paid accounting path before it is safe to use.');
    if(r.commit_mode==='native_opening'){
     const d=documents.get(kind+':'+r.imported_record_id);
     if(!d){if(!r.source_date||r.source_date<=evidence.ledger_as_of)report('The completed import target is missing from this starting-date review.');}
     else if(cents(d.gross)!==total)report('The linked Frindly document total differs from the source total.');
     if(paid>0)report('The source opening-paid amount must be preserved separately from Frindly bank payments.');
    }
   }catch(error){report(error.message);}
  }
  const controls=[];
  for(const [kind,key,label,sign] of [['invoice','accounts_receivable','Money customers owe',1],['expense','accounts_payable','Bills to pay',-1]]){
   const accounts=evidence.accounts.filter(a=>!a.archived&&(a.system_account_key===key||a.system_key===key));
   const control={kind,label,account:null,detail:complete[kind]?totals[kind]:null,ledger:null,target:null,difference:null,status:'needs_review'};
   if(accounts.length!==1){issues.push({kind:'control',reference:label,message:'The control-account mapping is missing or ambiguous.'});controls.push(control);continue;}
   const account=accounts[0];control.account=account.account_code;
   const rows=evidence.ledger.filter(l=>String(l.account_code)===String(account.account_code));if(rows.length!==1)throw new Error('The control-account ledger evidence is incomplete or ambiguous.');
   control.ledger=sign*add(cents(rows[0].debits),-cents(rows[0].credits));
   const targets=model.lines.filter(l=>!l.error&&l.account?.id===account.id);if(targets.length===1)control.target=sign*(targets[0].targetDebit-targets[0].targetCredit);
   if(control.detail!==null&&control.target!==null){control.difference=add(control.target,-control.detail);control.status=control.difference===0&&control.detail===control.ledger?'amounts_agree':'difference';}
   if(control.detail!==null&&control.detail!==control.ledger)issues.push({kind:'control',reference:label,message:'The dated document detail differs from the posted control-account balance.'});controls.push(control);
  }
  if(evidence.incomplete_batches)issues.push({kind:'migration',reference:'Migration history',message:`${evidence.incomplete_batches} migration batch(es) are unfinished. They are excluded from completed-source evidence.`});
  if(evidence.tax_error||!evidence.tax_status)issues.push({kind:'tax',reference:'GST history',message:evidence.tax_error||'Tax settings at the starting date are unavailable.'});
  else if(evidence.tax_status.settings_source==='financial_settings_fallback')issues.push({kind:'tax',reference:'GST history',message:'Only current fallback tax settings are available. Confirm the historical registration and accounting basis.'});
  return {controls,issues,currency,snapshot_hash:evidence.snapshot_hash,posts_balances:false,ready_to_post:false,manual_checks:['Confirm the bank statement closing balances; imported bank movements do not establish them.','Confirm GST already returned in the previous system and the accounting basis at cutover.','Review historical edits, voids and unallocated credits/refunds before approving the conversion.','Reconcile stock, equipment, depreciation, payroll, loans and owner balances once.']};
 }
 async function open(){
  const win=window,doc=document,$=id=>doc.getElementById(id),saas=win.SAAS,bid=saas?.state?.business?.id;
  if(!bid||!saas.canWriteArea?.('financials'))return win.FinloCore.ui.toast('Your accountant or business administrator can review starting balances.');
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const root=$('importMigrationContent'),modal=$('importMigrationModal');if(!root||!modal)return;
  let viewButton;const on=win.FrindlyPlanning.today(new Date(),String(saas.state.business.settings?.country||'NZ').toUpperCase()==='AU'?'Australia/Sydney':'Pacific/Auckland'),contextGuard=win.FinloCore.context.createGuard(()=>({businessId:saas.state.business?.id,userId:saas.state.user?.id,saas:win.SAAS})),guard=()=>{contextGuard();if(viewButton&&($('sbReview')!==viewButton||!modal.classList.contains('open')))throw new Error('This review was closed.');};
  root.innerHTML=`<div class="import-flow"><div class="page-head compact-head"><div><h2>Starting balances review</h2><p>Compare the amounts from before you began using Frindly.</p></div></div><p class="notice">This review does not import or post balances. It helps your accountant avoid counting imported invoices, bills, stock, equipment or payroll twice.</p><div class="form-grid compact"><label>Start using Frindly from<input id="sbCutover" type="date" value="${on}"></label><label>Trial-balance CSV<input id="sbFile" type="file" accept=".csv,text/csv"></label></div><p class="hint">The CSV amounts must use your business currency. This review does not convert currencies.</p><div id="sbMapping"></div><div class="actions"><button class="primary" id="sbReview" type="button">Compare starting balances</button><button class="secondary" id="sbBack" type="button">Back to migration</button></div><div id="sbResult" aria-live="polite"></div></div>`;modal.classList.add('open');
  viewButton=$('sbReview');let parsed=null,filename='',run=0,fileSequence=0;
  const invalidate=()=>{run++;$('sbResult').innerHTML='';};
  $('sbBack').onclick=()=>win.ImportMigration.open();$('sbCutover').oninput=invalidate;
  $('sbFile').onchange=async()=>{const fileToken=++fileSequence;invalidate();parsed=null;$('sbMapping').innerHTML='';const file=$('sbFile').files?.[0];if(!file)return;try{if(file.size>2097152)throw new Error('Choose a CSV smaller than 2 MB.');const text=await file.text();guard();if(fileToken!==fileSequence)return;const all=win.FinloCore.csv.parseCsv(text.replace(/^\uFEFF/,''));if(all.length<2||all.length>2001)throw new Error('Choose a CSV with headings and no more than 2,000 rows.');if(all.some(row=>row.some(v=>String(v).trim())&&row.length!==all[0].length))throw new Error('The CSV has inconsistent columns. Check the file before mapping.');parsed={headers:all[0],rows:all.slice(1)};filename=file.name;const suggested=mapping(parsed.headers);$('sbMapping').innerHTML='<div class="form-grid compact">'+[['code','Account code'],['debit','Debit amount'],['credit','Credit amount']].map(([key,title])=>`<label>${title}<select id="sbMap${key}"><option value="-1">Choose column</option>${parsed.headers.map((h,i)=>`<option value="${i}" ${i===suggested[key]?'selected':''}>${esc(h)}</option>`).join('')}</select></label>`).join('')+'</div><p class="hint">Check the column choices. Account codes match exactly; unfamiliar codes can be mapped in the review.</p>';for(const key of ['code','debit','credit'])$('sbMap'+key).onchange=invalidate}catch(e){if($('sbReview')===viewButton&&fileToken===fileSequence)$('sbResult').textContent=e.message}};
  $('sbReview').onclick=async()=>{
   const token=++run,button=$('sbReview');if(!parsed)return $('sbResult').textContent='Choose a trial-balance CSV first.';
   button.disabled=true;$('sbResult').textContent='Checking existing accounts and ledger…';
   try{
    guard();const cutover=$('sbCutover').value;win.FrindlyPlanning.taxYear({},cutover);const day=new Date(cutover+'T00:00:00Z');day.setUTCDate(day.getUTCDate()-1);const asOf=day.toISOString().slice(0,10);
    const response=await saas.client().rpc('v6228_starting_balance_evidence',{p_cutover:cutover});guard();if(response.error)throw response.error;const evidence=response.data;if(evidence?.business_id!==bid||evidence.cutover_date!==cutover||evidence.ledger_as_of!==asOf)throw new Error('The conversion evidence belongs to another business or starting date.');const accounts=evidence.accounts,result={data:evidence.ledger};if(token!==run)return;
    const columns=Object.fromEntries(['code','debit','credit'].map(k=>[k,Number($('sbMap'+k).value)])),overrides={};
    const draw=()=>{guard();const model=review(parsed.rows,columns,accounts,result.data,overrides),checks=assessEvidence(evidence,model),amount=c=>(c/100).toFixed(2),opts=(id)=>'<option value="">Choose account</option>'+accounts.filter(a=>!a.archived).map(a=>`<option value="${esc(a.id)}" ${a.id===id?'selected':''}>${esc(a.account_code+' — '+a.account_name)}</option>`).join('');
     $('sbResult').innerHTML=`<h3>Review as at ${esc(asOf)}</h3><p>Source debits ${esc(amount(model.debits))} · Source credits ${esc(amount(model.credits))} (${esc(saas.state.business.settings?.currency||'NZD')})</p>${model.errors.length?'<div class="notice warning">'+model.errors.map(e=>`<p>${esc(e)}</p>`).join('')+'</div>':'<p class="hint">Source totals balance. This does not yet confirm that the migration is correct.</p>'}<div class="table-scroll"><table><thead><tr><th>Source code</th><th>Frindly account</th><th>Source balance</th><th>Existing ledger</th><th>Difference to review</th></tr></thead><tbody>${model.lines.map(l=>`<tr><td>${esc(l.sourceCode)}</td><td><select data-sb-row="${l.row-2}">${opts(l.account?.id)}</select>${l.error?`<small>${esc(l.error)}</small>`:''}</td><td>${esc(amount(l.targetDebit-l.targetCredit))}</td><td>${esc(amount(l.existing))}</td><td>${esc(amount(l.difference))}</td></tr>`).join('')}</tbody></table></div><p class="hint">Positive balances are debits; negative balances are credits. A difference is a review figure, not an instruction to post a journal. Ledger values are a read-only snapshot; refresh if records change.</p><h3>Starting-date cross-check</h3><p class="hint">Documents, dated payments, credits, refunds, completed imports and the ledger come from one database snapshot. Amount agreement alone does not approve a conversion.</p><div class="table-scroll"><table><thead><tr><th>Check</th><th>Source balance</th><th>Document detail</th><th>Posted ledger</th><th>Result</th></tr></thead><tbody>${checks.controls.map(c=>`<tr><td>${esc(c.label)}${c.account?` (${esc(c.account)})`:''}</td><td>${c.target===null?'Not mapped':esc(amount(c.target))}</td><td>${c.detail===null?'Needs review':esc(amount(c.detail))}</td><td>${c.ledger===null?'Unavailable':esc(amount(c.ledger))}</td><td>${c.status==='amounts_agree'?'Amounts agree':c.status==='difference'?'Difference':'Needs review'}</td></tr>`).join('')}</tbody></table></div><details ${checks.issues.length?'open':''}><summary>${checks.issues.length} item(s) to review</summary>${checks.issues.slice(0,50).map(x=>`<p><strong>${esc(x.reference)}</strong> — ${esc(x.message)}</p>`).join('')||'<p>No automatic discrepancies were found in the supported checks. Manual checks below are still required.</p>'}${checks.issues.length>50?'<p>Showing the first 50 items. The download contains every item and all supporting evidence.</p>':''}</details><p class="hint">Current document values and lifecycle states are used. A later edit or void can require historical reconstruction. Snapshot ${esc(evidence.snapshot_hash.slice(0,12))}.</p><h3>Before any balances are posted</h3><ul><li>Match money customers owe to the individual unpaid invoices.</li><li>Match bills you need to pay to the individual supplier bills.</li><li>Match bank balances to statements at this starting date.</li><li>Review stock, equipment, depreciation, tax, loans and owner balances once.</li><li>Have your accountant explain any suspense or balancing amount and approve the conversion.</li></ul><p class="hint">Control accounts needing detail review: ${esc(model.reviewRequired.join(', ')||'Review the account mapping; no control accounts were identified automatically.')}.</p><button class="secondary" id="sbDownload" type="button">Download review for accountant</button>`;
     root.querySelectorAll('[data-sb-row]').forEach(el=>el.onchange=()=>{overrides[el.dataset.sbRow]=el.value;draw()});
     $('sbDownload').onclick=()=>{guard();const payload={type:'frindly_starting_balances_review',business_id:bid,business_name:saas.state.business.name,source_filename:filename,cutover_date:cutover,ledger_as_of:asOf,reviewed_at:new Date().toISOString(),posts_balances:false,...model,conversion_checks:checks,evidence};win.FinloCore.csv.downloadBlob('frindly-starting-balances-review.json',new Blob([JSON.stringify(payload,null,2)],{type:'application/json'}));};
    };draw();
   }catch(e){if(saas.state.business?.id===bid&&token===run&&$('sbReview')===button)$('sbResult').textContent=e.message||'Starting balances could not be verified.'}finally{if($('sbReview')===button)button.disabled=false}
  };
 }
 return Object.freeze({mapping,review,cents,assessEvidence,open});
});
