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
    body.innerHTML=rows.length?rows.map(p=>`<tr><td>${esc(p.po_number)}</td><td>${esc(p.supplier_name||'')}</td><td>${esc(p.order_date||'')}</td><td><span class="badge">${esc(p.status||'draft')}</span></td><td>${money(p.total_amount)}</td><td><button class="secondary" data-po-open="${esc(p.id)}" type="button">Open</button> <button class="secondary" data-po-pdf="${esc(p.id)}" type="button">PDF</button></td></tr>`).join(''):'<tr><td colspan="6">No purchase orders yet.</td></tr>';
    body.querySelectorAll('[data-po-open]').forEach(b=>b.onclick=()=>openPoEditor(b.dataset.poOpen));
    body.querySelectorAll('[data-po-pdf]').forEach(b=>b.onclick=()=>downloadPoPdf(b.dataset.poPdf,b));
  }
  // Supplier-facing PDF: only saved purchase-order fields; never include private estimates.
  async function downloadPoPdf(id,button){
    if(!id)return toast('Save the purchase order before downloading its PDF.');
    if(!window.jspdf?.jsPDF)return toast('PDF library is unavailable. Please reload and try again.');
    if(button){button.disabled=true;button.textContent='Preparing…';}
    try{
      const bid=businessId(),c=client();
      const [poResult,linesResult,bizResult]=await Promise.all([
        c.from('purchase_orders').select('id,po_number,supplier_name,order_date,expected_date,notes,currency,status').eq('business_id',bid).eq('id',id).single(),
        c.from('purchase_order_lines').select('description,qty,unit_price').eq('business_id',bid).eq('purchase_order_id',id).order('line_order'),
        c.from('businesses').select('name').eq('id',bid).maybeSingle()
      ]);
      if(poResult.error||!poResult.data)throw new Error('Purchase order could not be loaded.');
      if(linesResult.error||!linesResult.data?.length)throw new Error('Purchase order lines could not be loaded.');
      const po=poResult.data,items=linesResult.data;
      const doc=new window.jspdf.jsPDF({unit:'mm',format:'a4'});
      const plain=v=>String(v??'').replace(/[\r\n\t]+/g,' ').trim();
      doc.setFontSize(18);doc.text('PURCHASE ORDER',14,20);
      doc.setFontSize(10);
      const meta=[['PO number',po.po_number],['From',bizResult.data?.name||'Business'],['Supplier',po.supplier_name],['Order date',po.order_date],['Expected delivery',po.expected_date||'—'],['Status',po.status||'draft']];
      let y=30;
      for(const [label,value] of meta){doc.setFont(undefined,'bold');doc.text(`${label}:`,14,y);doc.setFont(undefined,'normal');const wrapped=doc.splitTextToSize(plain(value),135);doc.text(wrapped,55,y);y+=Math.max(1,wrapped.length)*5+2;}
      const fmt=n=>Number(n||0).toLocaleString('en-NZ',{minimumFractionDigits:2,maximumFractionDigits:2});
      const total=items.reduce((sum,item)=>sum+Number(item.qty||0)*Number(item.unit_price||0),0);
      if(typeof doc.autoTable==='function'){
        doc.autoTable({startY:y+5,head:[['Description','Quantity','Unit price','Amount']],body:items.map(item=>[plain(item.description),fmt(item.qty),fmt(item.unit_price),fmt(Number(item.qty||0)*Number(item.unit_price||0))]),theme:'grid',styles:{fontSize:9,overflow:'linebreak'},columnStyles:{1:{halign:'right'},2:{halign:'right'},3:{halign:'right'}}});
        y=doc.lastAutoTable.finalY+10;
      }else{
        for(const item of items){if(y>270){doc.addPage();y=20;}const lines=doc.splitTextToSize(`${plain(item.description)}  |  ${fmt(item.qty)} x ${fmt(item.unit_price)} = ${fmt(Number(item.qty||0)*Number(item.unit_price||0))}`,175);doc.text(lines,14,y);y+=lines.length*5+3;}
      }
      if(y>267){doc.addPage();y=20;}
      doc.setFont(undefined,'bold');doc.text(`Total (${plain(po.currency||'NZD')}): ${fmt(total)}`,14,y);y+=10;
      if(po.notes){doc.setFont(undefined,'normal');const noteLines=doc.splitTextToSize(`Notes: ${plain(po.notes)}`,180);for(const line of noteLines){if(y>280){doc.addPage();y=20;}doc.text(line,14,y);y+=5;}}
      const filename=`purchase-order-${plain(po.po_number||id).replace(/[^a-zA-Z0-9_-]/g,'_')}.pdf`;
      doc.save(filename);
    }catch(error){console.error('Purchase order PDF:',error);toast(error?.message||'Could not download purchase order PDF.');}
    finally{if(button){button.disabled=false;button.textContent=button.id==='poPdf'?'Download PDF':'PDF';}}
  }
  // Purchase order helpers are deliberately isolated from expense and accounting posting.
  let poSuppliers=[], poHistory=[], poPreviousUnitCosts=[];
  let poHistoryError='', poHistoryRequest=0;
  async function poLoadHistory(supplierId){
    const request=++poHistoryRequest;
    poHistory=[];poPreviousUnitCosts=[];poHistoryError='';
    if(!supplierId)return;
    const supplier=poSuppliers.find(s=>s.id===supplierId);
    const normalized=s=>String(s||'').trim().toLocaleLowerCase();
    const names=[supplier?.supplier_name,supplier?.trading_name].filter(Boolean);
    // A legacy name is safe only if it uniquely identifies this supplier in the current business.
    const uniqueNames=names.filter(n=>poSuppliers.filter(x=>[x.supplier_name,x.trading_name].some(v=>normalized(v)===normalized(n))).length===1);
    try{
      const c=client(),bid=businessId();
      // Include older expenses whose supplier name was saved before supplier IDs were linked.
      const [linked,named]=await Promise.all([
        c.from('expenses').select('id,invoice_date,supplier_id,supplier_name,description').eq('business_id',bid).eq('supplier_id',supplierId).order('invoice_date',{ascending:false}).limit(500),
        c.from('expenses').select('id,invoice_date,supplier_id,supplier_name,description').eq('business_id',bid).is('supplier_id',null).order('invoice_date',{ascending:false}).limit(1000)
      ]);
      if(linked.error)throw linked.error;if(named.error)throw named.error;
      const matches=[...(linked.data||[]),...(named.data||[]).filter(e=>uniqueNames.some(n=>normalized(n)===normalized(e.supplier_name)))];
      const expenses=[...new Map(matches.map(e=>[e.id,e])).values()].sort((a,b)=>String(b.invoice_date||'').localeCompare(String(a.invoice_date||'')));
      const details=expenses.filter(e=>String(e.description||'').trim()).map(e=>({expense_id:e.id,description:e.description,ex_gst:null,invoice_date:e.invoice_date}));
      for(let i=0;i<expenses.length;i+=100){
        const ids=expenses.slice(i,i+100).map(e=>e.id);
        const {data,error}=await c.from('expense_lines').select('expense_id,description,total_amount,ex_gst').eq('business_id',bid).in('expense_id',ids).limit(1000);
        if(error)throw error;details.push(...(data||[]));
      }
      // Historical PO lines have real quantities and unit prices, unlike expense lines.
      // Load them only for this supplier and this business; never infer unit cost from an expense total.
      const {data:pastOrders,error:pastOrdersError}=await c.from('purchase_orders').select('id,order_date').eq('business_id',bid).eq('supplier_id',supplierId).order('order_date',{ascending:false}).limit(500);
      if(pastOrdersError)throw pastOrdersError;
      const costHistory=[];
      for(let i=0;i<(pastOrders||[]).length;i+=100){
        const batch=pastOrders.slice(i,i+100),orderDates=new Map(batch.map(o=>[o.id,o.order_date]));
        const {data:pastLines,error:pastLinesError}=await c.from('purchase_order_lines').select('purchase_order_id,description,qty,unit_price').eq('business_id',bid).in('purchase_order_id',batch.map(o=>o.id)).limit(1000);
        if(pastLinesError)throw pastLinesError;
        costHistory.push(...(pastLines||[]).filter(l=>Number(l.qty)>0&&Number.isFinite(Number(l.unit_price))&&Number(l.unit_price)>=0).map(l=>({...l,order_date:orderDates.get(l.purchase_order_id)||''})));
      }
      if(request!==poHistoryRequest)return;
      poPreviousUnitCosts=costHistory.sort((a,b)=>String(b.order_date).localeCompare(String(a.order_date)));
      const byId=new Map(expenses.map(e=>[e.id,e]));
      poHistory=details.map(d=>({...d,invoice_date:byId.get(d.expense_id)?.invoice_date||''})).filter(d=>String(d.description||'').trim()).sort((a,b)=>String(b.invoice_date).localeCompare(String(a.invoice_date)));
    }catch(e){if(request!==poHistoryRequest)return;poHistoryError='Previously purchased items could not be loaded. Please try again.';console.warn('Purchase order item history:',e);}
  }
  function poSuggestion(desc){
    const value=String(desc||'').trim().toLowerCase();
    return poHistory.find(h=>h.description.trim().toLowerCase()===value)||null;
  }
  function poRow(l={}){
    return `<tr><td><input data-po-desc autocomplete="off" value="${esc(l.description||'')}" aria-label="Item description" aria-autocomplete="list" aria-expanded="false"><div class="po-item-menu" role="listbox" hidden></div></td><td><input data-po-qty type="number" min="0.01" step="0.01" value="${l.qty??1}" aria-label="Quantity"></td><td><input data-po-gst-rate type="hidden" value="${num(l.gst_rate)}"><input data-po-price type="number" min="0" step="0.01" value="${num(l.unit_price)}" aria-label="Purchase order unit price"></td><td><span data-po-last>—</span><div><input data-po-private-cost type="number" min="0" step="0.01" placeholder="Optional private unit cost" aria-label="Private estimated unit cost" style="width:145px;max-width:100%;margin-top:5px"></div></td><td><span data-po-estimate>—</span></td><td><button class="secondary" data-po-remove type="button">Remove</button></td></tr>`;
  }
  function poRefreshEstimates(){
    let sum=0, known=0, totalRows=0;
    document.querySelectorAll('#poLineRows tr').forEach(r=>{
      totalRows++;
      const description=String(r.querySelector('[data-po-desc]')?.value||'').trim().toLocaleLowerCase();
      const previous=poPreviousUnitCosts.find(h=>String(h.description||'').trim().toLocaleLowerCase()===description);
      const expense=poSuggestion(description),qty=Number(r.querySelector('[data-po-qty]')?.value);
      const last=r.querySelector('[data-po-last]'),estimate=r.querySelector('[data-po-estimate]');
      const privateInput=r.querySelector('[data-po-private-cost]');
      // Never infer a unit cost from an expense line without a recorded quantity.
      // A manually entered private unit estimate takes priority over previous PO history.
      const manual=privateInput&&privateInput.value.trim()!==''?Number(privateInput.value):null;
      const historical=previous?Number(previous.unit_price):null;
      const manualValid=manual!==null&&Number.isFinite(manual)&&manual>=0;
      const historicalValid=historical!==null&&Number.isFinite(historical)&&historical>=0;
      const unit=manualValid?manual:historicalValid?historical:null;
      if(last){
        last.textContent=historicalValid?`${money(historical)} (previous PO unit price)`:
          expense&&expense.ex_gst!=null?`${money(expense.ex_gst)} (expense line total; quantity unknown)`:
          'No historical unit cost';
      }
      if(unit!==null&&Number.isFinite(qty)&&qty>0){
        const extended=unit*qty;
        if(estimate)estimate.textContent=`${money(extended)}${manualValid?' (manual estimate)':' (historical estimate)'}`;
        sum+=extended;known++;
      }else if(estimate){estimate.textContent='Enter a private unit cost to estimate';}
      if(privateInput){privateInput.setAttribute('aria-label',`Private estimated unit cost for ${description||'new item'}`);}
    });
    const total=$('poPrivateEstimate');
    if(total)total.textContent=known===totalRows&&known>0?money(sum):known?`${money(sum)} estimated; ${totalRows-known} line(s) without an estimate`:'Unavailable: enter a private unit cost or select an item with historical PO pricing.';
  }
  function poRefreshSuggestions(){
    const message=$('poHistoryMessage');
    if(message){message.textContent=poHistoryError||(!poHistory.length&&$('poSupplierSelect')?.value?'No previous items recorded for this supplier. You can type a new description.':'');if(poHistoryError){const retry=document.createElement('button');retry.type='button';retry.className='secondary';retry.textContent='Retry';retry.onclick=async()=>{await poLoadHistory($('poSupplierSelect')?.value);poRefreshSuggestions()};message.append(' ',retry)}}
    document.querySelectorAll('#poLineRows tr').forEach(r=>{const menu=r.querySelector('.po-item-menu');if(menu&&!menu.hidden)poShowItems(r)});
    poRefreshEstimates();
  }
  function poShowItems(row){
    const input=row.querySelector('[data-po-desc]'),menu=row.querySelector('.po-item-menu');if(!input||!menu)return;
    const term=input.value.trim().toLocaleLowerCase(),seen=new Set();
    const items=poHistory.filter(h=>{const label=String(h.description||'').trim(),key=label.toLocaleLowerCase();if(!label||seen.has(key)||!key.includes(term))return false;seen.add(key);return true}).slice(0,60);
    const supplierChosen=!!$('poSupplierSelect')?.value;
    menu.innerHTML=items.map(h=>`<button type="button" class="po-item-option" role="option" data-po-choice="${esc(h.description)}">${esc(h.description)}</button>`).join('')||`<div class="po-item-empty">${poHistoryError?esc(poHistoryError):supplierChosen?'No matching previous items. Type a new description.':'Select a supplier to see previous items.'}</div>`;
    menu.hidden=false;input.setAttribute('aria-expanded','true');
    menu.querySelectorAll('[data-po-choice]').forEach(button=>button.addEventListener('mousedown',e=>e.preventDefault()));
    menu.querySelectorAll('[data-po-choice]').forEach(button=>button.addEventListener('click',()=>{input.value=button.dataset.poChoice;poHideItems(row);poRefreshEstimates();input.focus()}));
  }
  function poHideItems(row){const menu=row.querySelector('.po-item-menu'),input=row.querySelector('[data-po-desc]');if(menu)menu.hidden=true;if(input)input.setAttribute('aria-expanded','false')}
  function wirePoRows(){
    document.querySelectorAll('#poLineRows tr').forEach(r=>{
      if(r.dataset.poWired)return;r.dataset.poWired='true';
      const input=r.querySelector('[data-po-desc]');
      input?.addEventListener('focus',()=>poShowItems(r));
      input?.addEventListener('click',()=>poShowItems(r));
      input?.addEventListener('input',()=>{poShowItems(r);poRefreshEstimates()});
      input?.addEventListener('keydown',e=>{if(e.key==='Escape')poHideItems(r);if(e.key==='ArrowDown'){const first=r.querySelector('.po-item-option');if(first){e.preventDefault();first.focus()}}});
      r.querySelector('.po-item-menu')?.addEventListener('keydown',e=>{if(e.key==='Escape'){poHideItems(r);input?.focus()}});
      input?.addEventListener('blur',()=>setTimeout(()=>{if(!r.contains(document.activeElement))poHideItems(r)},120));
      r.querySelector('[data-po-qty]')?.addEventListener('input',poRefreshEstimates);
      r.querySelector('[data-po-private-cost]')?.addEventListener('input',poRefreshEstimates);
      r.querySelector('[data-po-remove]')?.addEventListener('click',()=>{r.remove();poRefreshEstimates()});
    });
    poRefreshEstimates();
  }
  async function openPoEditor(id){
    const editor=$('poEditor');if(!editor)return;editor.hidden=false;
    let po=null,lines=[];
    if(id){const found=await safeSelect('purchase_orders',q=>q.select('*').eq('business_id',businessId()).eq('id',id).maybeSingle());po=Array.isArray(found)?found[0]:found;lines=await safeSelect('purchase_order_lines',q=>q.select('*').eq('business_id',businessId()).eq('purchase_order_id',id).order('line_order'))}
    if(!lines.length)lines=[{description:'',qty:1,unit_price:0}];
    poSuppliers=await safeSelect('suppliers',q=>q.select('id,supplier_name,trading_name,email').eq('business_id',businessId()).eq('archived',false).order('supplier_name').limit(500));
    editor.innerHTML=`<div class="card-title"><h3>${po?'Edit':'New'} Purchase Order</h3><button class="secondary" id="poClose" type="button">Close</button></div>
      <div class="form-grid compact"><label>PO number<input id="poNumber" value="${esc(po?.po_number||'PO-'+Date.now().toString().slice(-6))}"></label>
      <label>Supplier<select id="poSupplierSelect"><option value="">Select supplier</option>${poSuppliers.map(x=>`<option value="${esc(x.id)}">${esc(x.supplier_name||x.trading_name||'Supplier')}</option>`).join('')}</select></label>
      <label>Supplier name (for existing unlinked orders)<input id="poSupplier" value="${esc(po?.supplier_name||'')}"></label>
      <label>Order date<input id="poDate" type="date" value="${esc(po?.order_date||today())}"></label>
      <label>Expected delivery date<input id="poExpectedDate" type="date" value="${esc(po?.expected_date||'')}"></label>
      <label>Status<select id="poStatus"><option value="draft">Draft</option><option value="approved">Approved</option><option value="sent">Sent</option><option value="partially_received">Partially received</option><option value="billed">Billed</option><option value="closed">Closed</option><option value="cancelled">Cancelled</option></select></label>
      <label class="wide">Notes<input id="poNotes" value="${esc(po?.notes||'')}"></label></div>
      <p class="hint" id="poHistoryMessage" role="status"></p>
      <style>#poLineRows td:first-child{position:relative;min-width:210px;overflow:visible}.po-item-menu{position:absolute;z-index:1100;top:calc(100% - 2px);left:0;min-width:250px;width:max-content;max-width:min(450px,85vw);max-height:230px;overflow:auto;background:var(--card-bg,#fff);color:var(--text,#17233b);border:1px solid #b9bdc9;border-radius:9px;box-shadow:0 8px 20px #17233b33;padding:4px}.po-item-menu[hidden]{display:none!important}.po-item-option{display:block;width:100%;text-align:left;padding:9px 11px;border:0;border-radius:5px;background:transparent;color:inherit;cursor:pointer;white-space:normal}.po-item-option:hover,.po-item-option:focus{background:#ece8fb}.po-item-empty{padding:10px;font-size:12px;color:#626878}#poLineRows{overflow:visible}</style>
      <div class="table-scroll"><table><thead><tr><th>Description</th><th>Qty</th><th>PO unit price</th><th>Previous cost (private)</th><th>Estimated line cost (private)</th><th></th></tr></thead><tbody id="poLineRows">${lines.map(poRow).join('')}</tbody></table></div>
      <p class="hint">Internal estimates use prior Purchase Order unit prices when available. Enter a private unit cost to override or estimate new items. Private estimates are session-only, not saved to Purchase Orders, and never sent to suppliers. Expense totals are never treated as unit prices.</p>
      <p class="hint"><strong>Internal estimated total:</strong> <span id="poPrivateEstimate">—</span></p>
      <div class="actions"><button class="secondary" id="poAddLine" type="button">+ Add line</button><button class="primary" id="poSave" type="button">Save Purchase Order</button>${po?'<button class="secondary" id="poPdf" type="button">Download PDF</button><button class="secondary" id="poEmail" type="button">Email Purchase Order</button>':''}</div>
      <p class="hint">Saving a PO does not create a bill, payment or journal. Emailing sends only the supplier-facing PO fields.</p>`;
    editor.dataset.poUpdatedAt=po?.updated_at||'';
    $('poStatus').value=po?.status||'draft';
    $('poStatus').disabled=true;$('poStatus').title='Status changes are managed by the purchase order workflow, not by editing order details.';
    $('poSupplierSelect').value=po?.supplier_id||'';
    $('poSupplierSelect').onchange=async()=>{const supplier=poSuppliers.find(x=>x.id===$('poSupplierSelect').value);if(supplier)$('poSupplier').value=supplier.supplier_name||supplier.trading_name||'';await poLoadHistory(supplier?.id);poRefreshSuggestions()};
    $('poClose').onclick=()=>editor.hidden=true;
    $('poAddLine').onclick=()=>{$('poLineRows').insertAdjacentHTML('beforeend',poRow());wirePoRows()};
    $('poSave').onclick=()=>savePo(po?.id);
    const originalPoSnapshot=()=>JSON.stringify([...editor.querySelectorAll('input,select')].filter(x=>x.id!=='poHistoryMessage').map(x=>[x.id||x.dataset.poDesc||x.dataset.poQty||x.dataset.poPrice,x.value]));
    let savedSnapshot=originalPoSnapshot();
    editor.dataset.poDirty='false';editor.addEventListener('input',()=>{editor.dataset.poDirty=String(originalPoSnapshot()!==savedSnapshot)});editor.addEventListener('change',()=>{editor.dataset.poDirty=String(originalPoSnapshot()!==savedSnapshot)});
    if(po){$('poEmail').onclick=()=>emailPo(po.id);$('poPdf').onclick=()=>{if(editor.dataset.poDirty==='true')return toast('Save your purchase order changes before downloading its PDF.');downloadPoPdf(po.id,$('poPdf'));};}
    await poLoadHistory($('poSupplierSelect').value);poRefreshSuggestions();wirePoRows();
  }
  async function savePo(id){
    const lines=[...document.querySelectorAll('#poLineRows tr')].map((r,i)=>({line_order:i+1,description:(r.querySelector('[data-po-desc]')?.value||'').trim(),qty:Number(r.querySelector('[data-po-qty]')?.value),unit_price:Number(r.querySelector('[data-po-price]')?.value),gst_rate:Number(r.querySelector('[data-po-gst-rate]')?.value||0)}));
    if(!lines.length||lines.some(l=>!l.description))return toast('Add at least one item and give every line a description.');
    if(lines.some(l=>!Number.isFinite(l.qty)||l.qty<=0||!Number.isFinite(l.unit_price)||l.unit_price<0))return toast('Quantities must be greater than zero and prices cannot be negative.');
    const total=lines.reduce((a,l)=>a+l.qty*l.unit_price,0),row={business_id:businessId(),po_number:$('poNumber').value.trim(),supplier_id:$('poSupplierSelect').value||null,supplier_name:$('poSupplier').value.trim(),order_date:$('poDate').value,expected_date:$('poExpectedDate').value||null,status:$('poStatus').value,notes:$('poNotes').value,total_amount:total,currency:currency(),updated_by:userId(),updated_at:new Date().toISOString()};
    if(!row.supplier_name||!row.supplier_id)return toast('Choose a supplier from the list before saving.');
    const c=client(),saved=await c.rpc('v61142b_save_purchase_order',{p_order:{...row,id:id||null},p_lines:lines,p_expected_updated_at:id?$('poEditor')?.dataset.poUpdatedAt||null:null});
    if(saved.error)return toast(saved.error.message);
    toast('Purchase order saved.');$('poEditor').hidden=true;renderPurchaseOrders();
  }
  async function emailPo(id){
    const supplier=poSuppliers.find(s=>s.id===$('poSupplierSelect')?.value);
    if($('poEditor')?.dataset.poDirty==='true')return toast('Save your purchase order changes before emailing.');
    if(!supplier?.email)return toast('Select a supplier with an email address saved in Suppliers.');
    if(!await (window.FrindlyDialogs?.confirm?.(`Send the saved purchase order to ${supplier.email}? Save any changes before sending.`)??Promise.resolve(window.confirm(`Send purchase order to ${supplier.email}?`))))return;
    const button=$('poEmail');if(button){button.disabled=true;button.textContent='Sending…'}
    try{const {data,error}=await client().functions.invoke('send-purchase-order',{body:{purchaseOrderId:id}});if(error||!data?.success)throw Error(data?.error||error?.message||'Could not send purchase order');toast(`Purchase order emailed to ${supplier.email}.`);renderPurchaseOrders()}
    catch(e){toast(`Purchase order email failed: ${e.message||e}`)}finally{if(button){button.disabled=false;button.textContent='Email Purchase Order'}}
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
