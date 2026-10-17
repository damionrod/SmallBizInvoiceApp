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
 async function open(){
  const win=window,doc=document,$=id=>doc.getElementById(id),saas=win.SAAS,bid=saas?.state?.business?.id;
  if(!bid||!saas.canWriteArea?.('financials'))return win.FinloCore.ui.toast('Your accountant or business administrator can review starting balances.');
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const root=$('importMigrationContent'),modal=$('importMigrationModal');if(!root||!modal)return;
  let viewButton;const on=win.FrindlyPlanning.today(new Date(),String(saas.state.business.settings?.country||'NZ').toUpperCase()==='AU'?'Australia/Sydney':'Pacific/Auckland'),guard=()=>{if(saas.state.business?.id!==bid)throw new Error('Business changed. Reopen this review.');if(viewButton&&$('sbReview')!==viewButton)throw new Error('This review was closed.');};
  root.innerHTML=`<div class="import-flow"><div class="page-head compact-head"><div><h2>Starting balances review</h2><p>Compare the amounts from before you began using Frindly.</p></div></div><p class="notice">This review does not import or post balances. It helps your accountant avoid counting imported invoices, bills, stock, equipment or payroll twice.</p><div class="form-grid compact"><label>Start using Frindly from<input id="sbCutover" type="date" value="${on}"></label><label>Trial-balance CSV<input id="sbFile" type="file" accept=".csv,text/csv"></label></div><div id="sbMapping"></div><div class="actions"><button class="primary" id="sbReview" type="button">Compare starting balances</button><button class="secondary" id="sbBack" type="button">Back to migration</button></div><div id="sbResult" aria-live="polite"></div></div>`;modal.classList.add('open');
  viewButton=$('sbReview');let parsed=null,filename='',run=0,fileSequence=0;
  const invalidate=()=>{run++;$('sbResult').innerHTML='';};
  $('sbBack').onclick=()=>win.ImportMigration.open();$('sbCutover').oninput=invalidate;
  $('sbFile').onchange=async()=>{const fileToken=++fileSequence;invalidate();parsed=null;$('sbMapping').innerHTML='';const file=$('sbFile').files?.[0];if(!file)return;try{if(file.size>2097152)throw new Error('Choose a CSV smaller than 2 MB.');const text=await file.text();guard();if(fileToken!==fileSequence)return;const all=win.FinloCore.csv.parseCsv(text.replace(/^\uFEFF/,''));if(all.length<2||all.length>2001)throw new Error('Choose a CSV with headings and no more than 2,000 rows.');if(all.some(row=>row.some(v=>String(v).trim())&&row.length!==all[0].length))throw new Error('The CSV has inconsistent columns. Check the file before mapping.');parsed={headers:all[0],rows:all.slice(1)};filename=file.name;const suggested=mapping(parsed.headers);$('sbMapping').innerHTML='<div class="form-grid compact">'+[['code','Account code'],['debit','Debit amount'],['credit','Credit amount']].map(([key,title])=>`<label>${title}<select id="sbMap${key}"><option value="-1">Choose column</option>${parsed.headers.map((h,i)=>`<option value="${i}" ${i===suggested[key]?'selected':''}>${esc(h)}</option>`).join('')}</select></label>`).join('')+'</div><p class="hint">Check the column choices. Account codes match exactly; unfamiliar codes can be mapped in the review.</p>';for(const key of ['code','debit','credit'])$('sbMap'+key).onchange=invalidate}catch(e){if($('sbReview')===viewButton&&fileToken===fileSequence)$('sbResult').textContent=e.message}};
  $('sbReview').onclick=async()=>{
   const token=++run,button=$('sbReview');if(!parsed)return $('sbResult').textContent='Choose a trial-balance CSV first.';
   button.disabled=true;$('sbResult').textContent='Checking existing accounts and ledger…';
   try{
    guard();const cutover=$('sbCutover').value;win.FrindlyPlanning.taxYear({},cutover);const day=new Date(cutover+'T00:00:00Z');day.setUTCDate(day.getUTCDate()-1);const asOf=day.toISOString().slice(0,10);
    const accounts=await win.FrindlyData.readAll(()=>saas.client().from('accounting_accounts').select('id,account_code,account_name,archived,is_control,allow_manual_posting').eq('business_id',bid),{guard});
    const result=await saas.client().rpc('v6170b_trial_balance',{p_from:'0001-01-01',p_to:asOf});guard();if(result.error)throw result.error;if(!Array.isArray(result.data))throw new Error('The ledger could not be verified.');if(token!==run)return;
    const columns=Object.fromEntries(['code','debit','credit'].map(k=>[k,Number($('sbMap'+k).value)])),overrides={};
    const draw=()=>{guard();const model=review(parsed.rows,columns,accounts,result.data,overrides),amount=c=>(c/100).toFixed(2),opts=(id)=>'<option value="">Choose account</option>'+accounts.filter(a=>!a.archived).map(a=>`<option value="${esc(a.id)}" ${a.id===id?'selected':''}>${esc(a.account_code+' — '+a.account_name)}</option>`).join('');
     $('sbResult').innerHTML=`<h3>Review as at ${esc(asOf)}</h3><p>Source debits ${esc(amount(model.debits))} · Source credits ${esc(amount(model.credits))} (${esc(saas.state.business.settings?.currency||'NZD')})</p>${model.errors.length?'<div class="notice warning">'+model.errors.map(e=>`<p>${esc(e)}</p>`).join('')+'</div>':'<p class="hint">Source totals balance. This does not yet confirm that the migration is correct.</p>'}<div class="table-scroll"><table><thead><tr><th>Source code</th><th>Frindly account</th><th>Source balance</th><th>Existing ledger</th><th>Difference to review</th></tr></thead><tbody>${model.lines.map(l=>`<tr><td>${esc(l.sourceCode)}</td><td><select data-sb-row="${l.row-2}">${opts(l.account?.id)}</select>${l.error?`<small>${esc(l.error)}</small>`:''}</td><td>${esc(amount(l.targetDebit-l.targetCredit))}</td><td>${esc(amount(l.existing))}</td><td>${esc(amount(l.difference))}</td></tr>`).join('')}</tbody></table></div><p class="hint">Positive balances are debits; negative balances are credits. A difference is a review figure, not an instruction to post a journal. Ledger values are a read-only snapshot; refresh if records change.</p><h3>Before any balances are posted</h3><ul><li>Match money customers owe to the individual unpaid invoices.</li><li>Match bills you need to pay to the individual supplier bills.</li><li>Match bank balances to statements at this starting date.</li><li>Review stock, equipment, depreciation, tax, loans and owner balances once.</li><li>Have your accountant explain any suspense or balancing amount and approve the conversion.</li></ul><p class="hint">Control accounts needing detail review: ${esc(model.reviewRequired.join(', ')||'Review the account mapping; no control accounts were identified automatically.')}.</p><button class="secondary" id="sbDownload" type="button">Download review for accountant</button>`;
     root.querySelectorAll('[data-sb-row]').forEach(el=>el.onchange=()=>{overrides[el.dataset.sbRow]=el.value;draw()});
     $('sbDownload').onclick=()=>{guard();const payload={type:'frindly_starting_balances_review',business_id:bid,business_name:saas.state.business.name,source_filename:filename,cutover_date:cutover,ledger_as_of:asOf,reviewed_at:new Date().toISOString(),posts_balances:false,...model};win.FinloCore.csv.downloadBlob('frindly-starting-balances-review.json',new Blob([JSON.stringify(payload,null,2)],{type:'application/json'}));};
    };draw();
   }catch(e){if(saas.state.business?.id===bid&&token===run&&$('sbReview')===button)$('sbResult').textContent=e.message||'Starting balances could not be verified.'}finally{if($('sbReview')===button)button.disabled=false}
  };
 }
 return Object.freeze({mapping,review,cents,open});
});
