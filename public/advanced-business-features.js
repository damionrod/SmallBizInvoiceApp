(function(){
  'use strict';
  const $=id=>document.getElementById(id);
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>Number(v||0)||0;
  const iso=d=>new Date(d).toISOString().slice(0,10);
  const today=()=>iso(new Date());
  const addDays=(s,n)=>{const d=new Date(`${s||today()}T00:00:00`);d.setDate(d.getDate()+Number(n||0));return iso(d)};
  const client=()=>window.SAAS?.client?.();
  const business=()=>window.SAAS?.state?.business||null;
  const businessId=()=>business()?.id||null;
  const userId=()=>window.SAAS?.state?.user?.id||null;
  const role=()=>window.SAAS?.state?.profile?.is_super_admin?'owner':(window.SAAS?.state?.accessRole||'viewer');
  const canBusinessWrite=()=>['owner','admin'].includes(role());
  const canAccountingWrite=()=>['owner','admin','accountant'].includes(role());
  const currency=()=>String(business()?.settings?.currency||'NZD').toUpperCase();
  const money=v=>{try{return new Intl.NumberFormat('en-NZ',{style:'currency',currency:currency(),currencyDisplay:'code'}).format(num(v))}catch{return `${currency()} ${num(v).toFixed(2)}`}};
  const toast=msg=>(window.toast?window.toast(msg):console.log(msg));
  const state={installed:false};

  async function safeSelect(table,query){
    const c=client(); if(!c||!businessId())return [];
    try{const r=await query(c.from(table)); if(r.error)throw r.error; return r.data||[]}catch(e){console.warn(`Frindly feature read skipped: ${table}`,e?.message||e); return []}
  }

  function customerStatementSettings(){
    const s=business()?.settings?.latePaymentFees||{};
    return {
      enabled:!!s.enabled,
      daysAfterDue:Math.max(0,num(s.daysAfterDue??7)),
      feeType:s.feeType==='percent'?'percent':'fixed',
      feeAmount:num(s.feeAmount??0),
      label:String(s.label||'Late payment fee').trim()||'Late payment fee'
    };
  }

  function injectCustomerStatements(){
    const view=$('view-customers'); if(!view||$('customerStatementCard'))return;
    const card=document.createElement('div');
    card.className='card customer-statement-card';
    card.id='customerStatementCard';
    card.innerHTML=`<div class="card-title"><div><h2>Customer Statement</h2><p class="hint">A read-only account statement from invoices, payments, credit notes and refunds.</p></div><button class="secondary" id="customerStatementRefresh" type="button">Refresh</button></div>
      <div class="form-grid compact statement-controls"><label>Customer<select id="statementCustomer"><option value="">Choose customer</option></select></label><label>From<input id="statementFrom" type="date"></label><label>To<input id="statementTo" type="date"></label></div>
      <div class="statement-summary" id="statementSummary"></div>
      <div class="table-scroll"><table><thead><tr><th>Date</th><th>Reference</th><th>Description</th><th>Debit</th><th>Credit</th><th>Balance</th></tr></thead><tbody id="statementRows"><tr><td colspan="6">Choose a customer to view a statement.</td></tr></tbody></table></div>
      <div class="actions"><button class="secondary" id="statementCsv" type="button">Download CSV</button><button class="primary" id="statementLateFeeDraft" type="button">Create late-fee draft</button></div>`;
    view.querySelector('.customer-list-card')?.before(card);
    const now=new Date(),start=new Date(now.getFullYear(),now.getMonth()-2,1);
    $('statementFrom').value=iso(start); $('statementTo').value=today();
    ['statementCustomer','statementFrom','statementTo'].forEach(id=>$(id)?.addEventListener('change',renderStatement));
    $('customerStatementRefresh').onclick=loadStatementCustomers;
    $('statementCsv').onclick=downloadStatementCsv;
    $('statementLateFeeDraft').onclick=createLateFeeDraftInvoice;
    loadStatementCustomers();
  }

  async function loadStatementCustomers(){
    const customers=await safeSelect('customers',q=>q.select('id,customer_number,name,email').eq('business_id',businessId()).order('name'));
    const sel=$('statementCustomer'); if(!sel)return;
    const previous=sel.value;
    sel.innerHTML='<option value="">Choose customer</option>'+customers.map(c=>`<option value="${esc(c.id)}">${esc(c.name||'Customer')} ${c.customer_number?`(${esc(c.customer_number)})`:''}</option>`).join('');
    if(previous)sel.value=previous;
    renderStatement();
  }

  async function statementData(){
    const cid=$('statementCustomer')?.value,from=$('statementFrom')?.value||'1900-01-01',to=$('statementTo')?.value||today();
    if(!cid)return {rows:[],customer:null,balance:0,overdue:0};
    const customers=await safeSelect('customers',q=>q.select('*').eq('business_id',businessId()).eq('id',cid));
    const invoices=await safeSelect('invoices',q=>q.select('id,invoice_number,invoice_date,due_date,customer_id,customer_name,total,balance_due,lifecycle_state').eq('business_id',businessId()).eq('customer_id',cid).lte('invoice_date',to).neq('lifecycle_state','voided'));
    const payments=await safeSelect('customer_payments',q=>q.select('id,invoice_id,payment_date,amount,reference,notes').eq('business_id',businessId()).lte('payment_date',to));
    const credits=await safeSelect('customer_credit_notes',q=>q.select('id,credit_note_number,customer_id,credit_date,total,status').eq('business_id',businessId()).eq('customer_id',cid).lte('credit_date',to));
    const refunds=await safeSelect('customer_refunds',q=>q.select('id,customer_id,refund_date,amount,reference,status').eq('business_id',businessId()).eq('customer_id',cid).lte('refund_date',to));
    const invoiceIds=new Set(invoices.map(i=>String(i.id)));
    const rows=[];
    invoices.forEach(i=>rows.push({date:i.invoice_date,ref:i.invoice_number,desc:`Invoice ${i.invoice_number||''}`,debit:num(i.total),credit:0,due:i.due_date,invoice:i}));
    payments.filter(p=>invoiceIds.has(String(p.invoice_id))).forEach(p=>rows.push({date:p.payment_date,ref:p.reference||'Payment',desc:p.notes||'Customer payment',debit:0,credit:num(p.amount)}));
    credits.filter(c=>String(c.status||'')!=='voided').forEach(c=>rows.push({date:c.credit_date,ref:c.credit_note_number||'Credit note',desc:'Customer credit note',debit:0,credit:num(c.total)}));
    refunds.filter(r=>String(r.status||'')!=='voided').forEach(r=>rows.push({date:r.refund_date,ref:r.reference||'Refund',desc:'Customer refund',debit:num(r.amount),credit:0}));
    rows.sort((a,b)=>String(a.date).localeCompare(String(b.date))||String(a.ref).localeCompare(String(b.ref)));
    let balance=0,opening=0,visible=[];
    rows.forEach(r=>{balance+=r.debit-r.credit;if(r.date<from)opening=balance;else visible.push({...r,balance})});
    const overdue=invoices.filter(i=>String(i.lifecycle_state||'issued')!=='draft'&&i.due_date&&i.due_date<today()).reduce((a,i)=>a+num(i.balance_due),0);
    return {rows:visible,customer:customers[0]||null,balance,opening,overdue};
  }

  async function renderStatement(){
    const body=$('statementRows'),summary=$('statementSummary'); if(!body||!summary)return;
    const data=await statementData();
    if(!data.customer){summary.innerHTML='';body.innerHTML='<tr><td colspan="6">Choose a customer to view a statement.</td></tr>';return}
    summary.innerHTML=`<div class="metric"><span>Customer</span><strong>${esc(data.customer.name||'Customer')}</strong></div><div class="metric"><span>Opening balance</span><strong>${money(data.opening)}</strong></div><div class="metric"><span>Closing balance</span><strong>${money(data.balance)}</strong></div><div class="metric"><span>Overdue</span><strong>${money(data.overdue)}</strong></div>`;
    body.innerHTML=data.rows.length?data.rows.map(r=>`<tr><td>${esc(r.date||'')}</td><td>${esc(r.ref||'')}</td><td>${esc(r.desc||'')}</td><td>${r.debit?money(r.debit):''}</td><td>${r.credit?money(r.credit):''}</td><td>${money(r.balance)}</td></tr>`).join(''):'<tr><td colspan="6">No statement activity in this date range.</td></tr>';
  }

  async function downloadStatementCsv(){
    const data=await statementData(); if(!data.customer)return toast('Choose a customer first.');
    const rows=[['Customer Statement',data.customer.name||''],['From',$('statementFrom').value],['To',$('statementTo').value],['Opening balance',data.opening],[],['Date','Reference','Description','Debit','Credit','Balance'],...data.rows.map(r=>[r.date,r.ref,r.desc,r.debit,r.credit,r.balance]),[],['Closing balance',data.balance]];
    const csv=rows.map(r=>r.map(v=>`"${String(v??'').replace(/"/g,'""')}"`).join(',')).join('\n');
    const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([csv],{type:'text/csv'}));a.download=`customer-statement-${(data.customer.name||'customer').replace(/[^a-z0-9]+/gi,'_')}-${today()}.csv`;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),500);
  }

  async function createLateFeeDraftInvoice(){
    const data=await statementData(), cfg=customerStatementSettings();
    if(!data.customer)return toast('Choose a customer first.');
    if(!cfg.enabled)return toast('Late-payment fees are disabled in Settings.');
    if(data.overdue<=0)return toast('This customer has no overdue balance.');
    const amount=cfg.feeType==='percent'?Math.round(data.overdue*cfg.feeAmount)/100:cfg.feeAmount;
    if(!(amount>0))return toast('Set a late-payment fee amount first.');
    window.switchView?.('create');
    setTimeout(()=>{
      if($('customerName'))$('customerName').value=data.customer.name||'';
      if($('customerEmail'))$('customerEmail').value=data.customer.email||'';
      if($('reference'))$('reference').value=`Late fee for overdue balance ${money(data.overdue)}`;
      const msg=`Add one invoice line: ${cfg.label} - ${money(amount)}. Review before saving so nothing is posted automatically.`;
      toast(msg);
    },100);
  }

  function injectLateFeeSettings(){
    const dest=$('centralPaymentsSettings')||document.querySelector('[data-settings-panel="invoicing"]'); if(!dest||$('lateFeeSettingsCard'))return;
    const cfg=customerStatementSettings();
    const card=document.createElement('div');
    card.className='card settings-merged-section';
    card.id='lateFeeSettingsCard';
    card.innerHTML=`<div class="card-title"><div><h3>Late-payment fees</h3><p class="hint">Optional. Frindly never applies these automatically; it prepares a draft for review.</p></div></div>
      <div class="form-grid compact"><label class="tick-option"><input id="lateFeeEnabled" type="checkbox" ${cfg.enabled?'checked':''}><span>Enable late-fee helper</span></label><label>Grace days after due date<input id="lateFeeDays" type="number" min="0" step="1" value="${cfg.daysAfterDue}"></label><label>Fee type<select id="lateFeeType"><option value="fixed">Fixed amount</option><option value="percent">Percent of overdue balance</option></select></label><label>Fee amount<input id="lateFeeAmount" type="number" min="0" step="0.01" value="${cfg.feeAmount}"></label><label class="wide">Fee label<input id="lateFeeLabel" value="${esc(cfg.label)}"></label></div>
      <div class="actions"><button class="primary" id="lateFeeSave" type="button">Save late-fee settings</button></div>`;
    dest.appendChild(card); $('lateFeeType').value=cfg.feeType; $('lateFeeSave').onclick=saveLateFeeSettings;
  }

  async function saveLateFeeSettings(){
    if(!canBusinessWrite())return toast('Only owners and admins can change late-fee settings.');
    const next={...(business()?.settings||{}),latePaymentFees:{enabled:!!$('lateFeeEnabled').checked,daysAfterDue:num($('lateFeeDays').value),feeType:$('lateFeeType').value,feeAmount:num($('lateFeeAmount').value),label:$('lateFeeLabel').value.trim()||'Late payment fee'}};
    const {error}=await client().from('businesses').update({settings:next,updated_at:new Date().toISOString()}).eq('id',businessId());
    if(error)return toast(error.message);
    window.SAAS.state.business.settings=next; window.invoiceAppHelpers?.updateSettings?.(next); toast('Late-fee settings saved.');
  }

  function injectFinancialPanels(){
    const more=$('finMoreReports')?.querySelector('.financial-more-menu'); if(more&&!$('finManualJournalTab')){
      more.insertAdjacentHTML('beforeend','<button type="button" id="finManualJournalTab" data-fin-tab="manualjournal">Manual Journals</button><button type="button" id="finProvisionalTaxTab" data-fin-tab="provisionaltax">Provisional Tax Plan</button>');
      $('finManualJournalTab').onclick=()=>showFinancialFeature('manualjournal');
      $('finProvisionalTaxTab').onclick=()=>showFinancialFeature('provisionaltax');
    }
    const root=$('view-financials'); if(root&&!$('financial-panel-manualjournal')){
      root.insertAdjacentHTML('beforeend',`<div class="financial-panel advanced-feature-panel" id="financial-panel-manualjournal" hidden>
        <div class="page-head compact-head"><div><h2>Manual Journals</h2><p>Accountant/admin-only corrections. Posted journals must balance and can only be reversed.</p></div><button class="secondary" id="manualJournalReload" type="button">Refresh</button></div>
        <div class="card" id="manualJournalAccess"></div><div class="card" id="manualJournalEditor"></div><div class="card table-card"><div class="table-scroll"><table><thead><tr><th>Date</th><th>Journal</th><th>Description</th><th>Status</th><th>Source</th></tr></thead><tbody id="manualJournalRows"></tbody></table></div></div>
      </div>
      <div class="financial-panel advanced-feature-panel" id="financial-panel-provisionaltax" hidden>
        <div class="page-head compact-head"><div><h2>Provisional Tax Plan</h2><p>Planning worksheet only. It does not file with IRD or post journals.</p></div><button class="secondary" id="provisionalTaxReload" type="button">Refresh</button></div>
        <div class="card" id="provisionalTaxBody"></div>
      </div>`);
      $('manualJournalReload').onclick=renderManualJournals;
      $('provisionalTaxReload').onclick=renderProvisionalTax;
    }
  }

  function showFinancialFeature(tab){
    document.querySelectorAll('[data-fin-tab]').forEach(b=>b.classList.toggle('active',b.dataset.finTab===tab));
    document.querySelectorAll('.financial-panel').forEach(p=>p.hidden=p.id!==`financial-panel-${tab}`);
    $('financialReportPeriodCard')?.removeAttribute('hidden');
    if(tab==='manualjournal')renderManualJournals();
    if(tab==='provisionaltax')renderProvisionalTax();
  }

  async function renderManualJournals(){
    const access=$('manualJournalAccess'),editor=$('manualJournalEditor'),rows=$('manualJournalRows'); if(!access||!editor||!rows)return;
    if(!canAccountingWrite()){
      access.innerHTML='<div class="notice">Manual journals are restricted to owner, admin and accountant roles.</div>';
      editor.innerHTML=''; rows.innerHTML='<tr><td colspan="5">No access.</td></tr>'; return;
    }
    access.innerHTML='<p class="hint">Use this only for accountant-approved adjustments, accruals, opening corrections and reclasses. Use reversal, not delete, after posting.</p>';
    const accounts=await safeSelect('accounting_accounts',q=>q.select('id,account_code,account_name,account_type,archived').eq('business_id',businessId()).eq('archived',false).order('account_code'));
    const opts=accounts.map(a=>`<option value="${esc(a.id)}">${esc(a.account_code)} - ${esc(a.account_name)}</option>`).join('');
    editor.innerHTML=`<div class="form-grid compact"><label>Date<input id="mjDate" type="date" value="${today()}"></label><label class="wide">Description<input id="mjDescription" placeholder="Reason for journal"></label></div>
      <div class="table-scroll"><table class="manual-journal-lines"><thead><tr><th>Account</th><th>Description</th><th>Debit</th><th>Credit</th><th></th></tr></thead><tbody id="mjLines"></tbody></table></div>
      <div class="statement-summary"><div class="metric"><span>Debits</span><strong id="mjDebitTotal">${money(0)}</strong></div><div class="metric"><span>Credits</span><strong id="mjCreditTotal">${money(0)}</strong></div><div class="metric"><span>Status</span><strong id="mjBalanceStatus">Not balanced</strong></div></div>
      <div class="actions"><button class="secondary" id="mjAddLine" type="button">+ Add line</button><button class="primary" id="mjPost" type="button">Post manual journal</button></div>`;
    const addLine=(d=0,c=0)=>{$('mjLines').insertAdjacentHTML('beforeend',`<tr><td><select data-mj-account>${opts}</select></td><td><input data-mj-desc placeholder="Line description"></td><td><input data-mj-debit type="number" min="0" step="0.01" value="${d||''}"></td><td><input data-mj-credit type="number" min="0" step="0.01" value="${c||''}"></td><td><button class="secondary" data-mj-remove type="button">Remove</button></td></tr>`);wireManualLines()};
    window.__frindlyAddManualLine=addLine; addLine(); addLine();
    $('mjAddLine').onclick=()=>addLine(); $('mjPost').onclick=postManualJournal;
    const journals=await safeSelect('accounting_journals',q=>q.select('id,journal_date,journal_number,description,status,source_type,source_reference').eq('business_id',businessId()).eq('source_type','manual_journal').order('journal_date',{ascending:false}).limit(30));
    rows.innerHTML=journals.length?journals.map(j=>`<tr><td>${esc(j.journal_date)}</td><td>${esc(j.journal_number||j.id)}</td><td>${esc(j.description||'')}</td><td>${esc(j.status||'')}</td><td>${esc(j.source_reference||'Manual journal')}</td></tr>`).join(''):'<tr><td colspan="5">No manual journals yet.</td></tr>';
  }

  function wireManualLines(){
    document.querySelectorAll('#mjLines input').forEach(i=>i.oninput=manualTotals);
    document.querySelectorAll('[data-mj-remove]').forEach(b=>b.onclick=()=>{b.closest('tr')?.remove();manualTotals()});
    manualTotals();
  }
  function manualTotals(){
    let d=0,c=0;document.querySelectorAll('#mjLines tr').forEach(r=>{d+=num(r.querySelector('[data-mj-debit]')?.value);c+=num(r.querySelector('[data-mj-credit]')?.value)});
    if($('mjDebitTotal'))$('mjDebitTotal').textContent=money(d); if($('mjCreditTotal'))$('mjCreditTotal').textContent=money(c); if($('mjBalanceStatus'))$('mjBalanceStatus').textContent=Math.abs(d-c)<=0.005&&d>0?'Balanced':'Not balanced';
  }
  async function postManualJournal(){
    if(!canAccountingWrite())return toast('Manual journals are restricted.');
    const lines=[...document.querySelectorAll('#mjLines tr')].map(r=>({account_id:r.querySelector('[data-mj-account]')?.value,description:r.querySelector('[data-mj-desc]')?.value||$('mjDescription').value,debit:num(r.querySelector('[data-mj-debit]')?.value),credit:num(r.querySelector('[data-mj-credit]')?.value),tax_code:'NO_GST',tax_rate:0,tax_amount:0})).filter(l=>l.account_id&&(l.debit||l.credit));
    const d=lines.reduce((a,l)=>a+l.debit,0),c=lines.reduce((a,l)=>a+l.credit,0);
    if(!lines.length||Math.abs(d-c)>0.005||d<=0)return toast('Manual journal must balance before posting.');
    const {data,error}=await client().rpc('v61117_post_manual_journal',{p_journal_date:$('mjDate').value,p_description:$('mjDescription').value,p_lines:lines});
    if(error)return toast(error.message);
    toast(`Manual journal posted: ${data}`); renderManualJournals();
  }

  async function renderProvisionalTax(){
    const root=$('provisionalTaxBody'); if(!root)return;
    const fyEnd=(()=>{const now=new Date();return `${now.getFullYear()+1}-03-31`})();
    const settings=await safeSelect('financial_settings',q=>q.select('*').eq('business_id',businessId()).maybeSingle());
    const taxRate=num((Array.isArray(settings)?settings[0]:settings)?.estimated_tax_rate||28);
    let profit=0; try{const r=await client().rpc('v6170b_profit_loss',{p_from:`${new Date().getFullYear()}-04-01`,p_to:today()});profit=num((r.data||[])[0]?.net_profit)}catch(e){console.warn(e)}
    const annualised=profit>0?profit*12/Math.max(1,new Date().getMonth()+1):0, tax=annualised*taxRate/100, instalment=tax/3;
    const dates=[`${new Date().getFullYear()}-08-28`,`${new Date().getFullYear()+1}-01-15`,`${new Date().getFullYear()+1}-05-07`];
    root.innerHTML=`<div class="summary-grid"><div class="metric"><span>YTD posted profit</span><strong>${money(profit)}</strong></div><div class="metric"><span>Annualised estimate</span><strong>${money(annualised)}</strong></div><div class="metric"><span>Estimated tax rate</span><strong>${taxRate.toFixed(2)}%</strong></div><div class="metric"><span>Estimated provisional tax</span><strong>${money(tax)}</strong></div></div>
      <p class="hint">Planning worksheet only. Confirm method, residual income tax and due dates with your accountant or IRD before paying.</p>
      <div class="table-scroll"><table><thead><tr><th>Instalment</th><th>Due date</th><th>Suggested reserve</th><th>Status</th></tr></thead><tbody>${dates.map((d,i)=>`<tr><td>P${i+1}</td><td>${d}</td><td>${money(instalment)}</td><td>${d<today()?'Review/paid?':'Upcoming'}</td></tr>`).join('')}</tbody></table></div>
      <div class="actions"><button class="secondary" id="provisionalTaxCsv" type="button">Download CSV</button></div>`;
    $('provisionalTaxCsv').onclick=()=>{const csv=[['Provisional Tax Plan'],['FY end',fyEnd],['YTD posted profit',profit],['Annualised estimate',annualised],['Estimated tax',tax],[],['Instalment','Due date','Suggested reserve'],...dates.map((d,i)=>[`P${i+1}`,d,instalment])].map(r=>r.join(',')).join('\n');const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([csv],{type:'text/csv'}));a.download=`provisional-tax-plan-${today()}.csv`;a.click();};
  }

  function injectPurchaseOrders(){
    const tabs=$('expenseTabs'),view=$('view-expenses'); if(!tabs||!view||$('purchaseOrdersTab'))return;
    tabs.insertAdjacentHTML('beforeend','<button class="module-tab" id="purchaseOrdersTab" data-exp-tab="purchaseorders">Purchase Orders</button>');
    view.insertAdjacentHTML('beforeend',`<div class="expense-panel advanced-feature-panel" id="expense-panel-purchaseorders"><div class="page-head compact-head"><div><h2>Purchase Orders</h2><p>Approve supplier orders before they become bills. Purchase orders do not post accounting.</p></div><button class="primary" id="poNew" type="button">+ New Purchase Order</button></div><div class="card" id="poEditor" hidden></div><div class="card table-card"><div class="table-scroll"><table><thead><tr><th>PO</th><th>Supplier</th><th>Date</th><th>Status</th><th>Total</th><th>Action</th></tr></thead><tbody id="poRows"></tbody></table></div></div></div>`);
    $('purchaseOrdersTab').onclick=()=>{window.Expenses?.switchTab?.('purchaseorders');renderPurchaseOrders()};
    $('poNew').onclick=()=>openPoEditor();
  }
  async function renderPurchaseOrders(){
    const body=$('poRows'); if(!body)return;
    const rows=await safeSelect('purchase_orders',q=>q.select('*').eq('business_id',businessId()).order('order_date',{ascending:false}).limit(100));
    body.innerHTML=rows.length?rows.map(p=>`<tr><td>${esc(p.po_number)}</td><td>${esc(p.supplier_name||'')}</td><td>${esc(p.order_date||'')}</td><td><span class="badge">${esc(p.status||'draft')}</span></td><td>${money(p.total_amount)}</td><td><button class="secondary" data-po-open="${esc(p.id)}" type="button">Open</button></td></tr>`).join(''):'<tr><td colspan="6">No purchase orders yet.</td></tr>';
    body.querySelectorAll('[data-po-open]').forEach(b=>b.onclick=()=>openPoEditor(b.dataset.poOpen));
  }
  async function openPoEditor(id){
    const editor=$('poEditor'); if(!editor)return; editor.hidden=false;
    let po=null,lines=[]; if(id){const found=await safeSelect('purchase_orders',q=>q.select('*').eq('business_id',businessId()).eq('id',id).maybeSingle());po=Array.isArray(found)?found[0]:found;lines=await safeSelect('purchase_order_lines',q=>q.select('*').eq('business_id',businessId()).eq('purchase_order_id',id).order('line_order'))}
    if(!lines.length)lines=[{description:'',qty:1,unit_price:0}];
    editor.innerHTML=`<div class="card-title"><h3>${po?'Edit':'New'} Purchase Order</h3><button class="secondary" id="poClose" type="button">Close</button></div><div class="form-grid compact"><label>PO number<input id="poNumber" value="${esc(po?.po_number||'PO-'+Date.now().toString().slice(-6))}"></label><label>Supplier<input id="poSupplier" value="${esc(po?.supplier_name||'')}"></label><label>Order date<input id="poDate" type="date" value="${esc(po?.order_date||today())}"></label><label>Status<select id="poStatus"><option value="draft">Draft</option><option value="approved">Approved</option><option value="sent">Sent</option><option value="partially_received">Partially received</option><option value="billed">Billed</option><option value="closed">Closed</option><option value="cancelled">Cancelled</option></select></label><label class="wide">Notes<input id="poNotes" value="${esc(po?.notes||'')}"></label></div><div class="table-scroll"><table><thead><tr><th>Description</th><th>Qty</th><th>Unit</th><th></th></tr></thead><tbody id="poLineRows">${lines.map(l=>`<tr><td><input data-po-desc value="${esc(l.description||'')}"></td><td><input data-po-qty type="number" min="0" step="0.01" value="${num(l.qty)||1}"></td><td><input data-po-price type="number" min="0" step="0.01" value="${num(l.unit_price)}"></td><td><button class="secondary" data-po-remove type="button">Remove</button></td></tr>`).join('')}</tbody></table></div><div class="actions"><button class="secondary" id="poAddLine" type="button">+ Add line</button><button class="primary" id="poSave" type="button">Save Purchase Order</button></div><p class="hint">Saving a PO does not create a bill, payment or journal.</p>`;
    $('poStatus').value=po?.status||'draft'; $('poClose').onclick=()=>editor.hidden=true; $('poAddLine').onclick=()=>{$('poLineRows').insertAdjacentHTML('beforeend','<tr><td><input data-po-desc></td><td><input data-po-qty type="number" min="0" step="0.01" value="1"></td><td><input data-po-price type="number" min="0" step="0.01" value="0"></td><td><button class="secondary" data-po-remove type="button">Remove</button></td></tr>');wirePoRemove()}; wirePoRemove(); $('poSave').onclick=()=>savePo(po?.id);
  }
  function wirePoRemove(){document.querySelectorAll('[data-po-remove]').forEach(b=>b.onclick=()=>b.closest('tr')?.remove())}
  async function savePo(id){
    const lines=[...document.querySelectorAll('#poLineRows tr')].map((r,i)=>({line_order:i+1,description:r.querySelector('[data-po-desc]')?.value||'',qty:num(r.querySelector('[data-po-qty]')?.value)||1,unit_price:num(r.querySelector('[data-po-price]')?.value)})).filter(l=>l.description);
    const total=lines.reduce((a,l)=>a+l.qty*l.unit_price,0), row={business_id:businessId(),po_number:$('poNumber').value.trim(),supplier_name:$('poSupplier').value.trim(),order_date:$('poDate').value,status:$('poStatus').value,notes:$('poNotes').value,total_amount:total,currency:currency(),updated_by:userId(),updated_at:new Date().toISOString()};
    const c=client(); const saved=id?await c.from('purchase_orders').update(row).eq('id',id).select('id').single():await c.from('purchase_orders').insert({...row,created_by:userId()}).select('id').single();
    if(saved.error)return toast(saved.error.message);
    await c.from('purchase_order_lines').delete().eq('business_id',businessId()).eq('purchase_order_id',saved.data.id);
    if(lines.length){const ins=await c.from('purchase_order_lines').insert(lines.map(l=>({...l,business_id:businessId(),purchase_order_id:saved.data.id,line_total:l.qty*l.unit_price})));if(ins.error)return toast(ins.error.message)}
    toast('Purchase order saved.'); $('poEditor').hidden=true; renderPurchaseOrders();
  }

  function install(){
    injectCustomerStatements(); injectLateFeeSettings(); injectFinancialPanels(); injectPurchaseOrders();
  }
  function boot(){
    if(state.installed)return; state.installed=true;
    const tick=setInterval(()=>{if(window.SAAS?.state?.business?.id&&client()){install();clearInterval(tick)}},500);
    document.addEventListener('click',e=>{if(e.target?.dataset?.finTab==='manualjournal')setTimeout(renderManualJournals,0);if(e.target?.dataset?.finTab==='provisionaltax')setTimeout(renderProvisionalTax,0);if(e.target?.dataset?.expTab==='purchaseorders')setTimeout(renderPurchaseOrders,0)});
    const mo=new MutationObserver(()=>install()); mo.observe(document.body,{childList:true,subtree:true});
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
  window.FrindlyAdvancedFeatures={install,renderStatement,renderManualJournals,renderProvisionalTax,renderPurchaseOrders};
})();
