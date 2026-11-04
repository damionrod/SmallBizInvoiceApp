(() => {
  const byId = id => document.getElementById(id);
  const business = () => window.SAAS?.state?.business?.id;
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const money = value => new Intl.NumberFormat('en-NZ', {style:'currency',currency:'NZD'}).format(value);
  const today = () => new Intl.DateTimeFormat('en-CA',{timeZone:'Pacific/Auckland',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
  const cents = value => Math.round(Number(value)*100);
  const dateText = date => date.toISOString().slice(0,10);
  const types = ['business','vehicle','machinery','equipment','property','other'];
  let selected, renderVersion = 0;
  async function rpc(name,args={}) {
    const {data,error}=await window.SAAS.client().rpc(name,args);
    if(error)throw error;
    return data;
  }
  const list = asOf => rpc('frindly_loan_register',asOf?{p_as_of:asOf}:{});

  function importedSchedule(text, base) {
    if(!text.trim())return [];
    let remaining=cents(base), previous='';
    const lines=text.trim().split(/\r?\n/);
    if(lines.length>600)throw new Error('Enter up to 600 lender instalments.');
    return lines.map(line=>{
      const parts=line.split(',').map(part=>part.trim());
      const [due,principalText,interestText]=parts;
      const date=new Date(due+'T00:00:00Z');
      if(parts.length!==3||!/^\d{4}-\d{2}-\d{2}$/.test(due)||!Number.isFinite(date.getTime())||dateText(date)!==due||due<=previous
        ||![principalText,interestText].every(value=>/^\d+(\.\d{1,2})?$/.test(value))){
        throw new Error('Enter each lender instalment as YYYY-MM-DD, principal, interest, in date order.');
      }
      const principal=cents(principalText), interest=cents(interestText);
      if(principal>remaining||principal+interest<=0||!Number.isSafeInteger(principal+interest)){
        throw new Error('Check the lender schedule amounts against the amount owing.');
      }
      previous=due;
      remaining-=principal;
      return {due,principal,interest,remaining,total:principal+interest};
    });
  }

  function appliedPayments(row,payments){
    const applied=payments.filter(payment=>payment.request_payload?.loan_due_date===row.due&&payment.purpose==='loan_repayment')
      .reduce((sum,payment)=>({total:sum.total+cents(payment.amount),interest:sum.interest+cents(payment.interest_amount)}),{total:0,interest:0});
    return {...row,paid:applied.total,paidInterest:applied.interest};
  }

  function projectedSchedule(loan, payments) {
    const terms=loan.terms;
    if(terms.schedule?.length)return terms.schedule.map(row=>appliedPayments(row,payments));
    const count=Number(terms.count), rate=Number(terms.rate)/100;
    const regular=cents(terms.regular);
    if(!terms.first||!Number.isFinite(rate)||!regular||count<1||count>600)return [];
    const periods={weekly:52,fortnightly:26,monthly:12}[terms.frequency];
    if(!periods)return [];
    const first=new Date(terms.first+'T00:00:00Z');
    if(!Number.isFinite(first.getTime()))return [];
    let remaining=cents(terms.base ?? loan.original_amount);
    let previous=new Date((terms.accrualFrom||loan.start_date)+'T00:00:00Z');
    const rows=[];
    for(let index=0;index<count&&remaining>0;index++){
      const date=new Date(first);
      if(terms.frequency==='monthly'){
        date.setUTCDate(1);
        date.setUTCMonth(first.getUTCMonth()+index);
        const end=new Date(Date.UTC(date.getUTCFullYear(),date.getUTCMonth()+1,0)).getUTCDate();
        date.setUTCDate(Math.min(first.getUTCDate(),end));
      }else date.setUTCDate(first.getUTCDate()+index*(terms.frequency==='weekly'?7:14));
      const days=Math.max(0,(date-previous)/86400000);
      const interest=Math.round(remaining*rate*(terms.method==='daily365'?days/365:1/periods));
      previous=date;
      const principal=Math.min(remaining,Math.max(0,regular-interest));
      const due=dateText(date), total=interest+principal;
      remaining-=principal;
      rows.push(appliedPayments({due,total,interest,principal,remaining},payments));
    }
    return rows;
  }

  async function editor(root, loan=null) {
    const tenant=business();
    const {data:banks,error}=await window.SAAS.client().from('bank_accounts').select('id,name,is_default').eq('business_id',tenant).eq('archived',false).order('name');
    if(tenant!==business()||root.hidden)return;
    if(error)throw error;
    const terms=loan?.terms||{};
    root.innerHTML=`<h3>${loan?'Update loan terms':'Add a loan'}</h3><form id="finLoanForm">
      <div class="form-grid compact">
      ${loan?'':`<label>Loan name<input name="name" required maxlength="100" placeholder="ANZ vehicle loan"></label>
      <label>Lender<input name="lender" required maxlength="100"></label>
      <label>Loan type<select name="loan_type">${types.map(type=>`<option value="${type}">${type[0].toUpperCase()+type.slice(1)}</option>`).join('')}</select></label>
      <label>Original loan amount<input name="original_amount" type="number" min="0.01" step="0.01" required></label>
      <label>Loan start date<input name="start_date" type="date" required value="${today()}"></label>
      <label>Usual bank account<select name="bank_id" required>${(banks||[]).map(bank=>`<option value="${esc(bank.id)}" ${bank.is_default?'selected':''}>${esc(bank.name)}</option>`).join('')}</select></label>`}
      <label>Annual interest rate (%)<input name="rate" type="number" min="0" max="100" step="0.001" required value="${esc(terms.rate??0)}"></label>
      <label>How often do you pay?<select name="frequency">${['weekly','fortnightly','monthly'].map(value=>`<option ${value===(terms.frequency||'monthly')?'selected':''}>${value}</option>`).join('')}</select></label>
      <label>${loan?'Next repayment date':'First repayment date'}<input name="first" type="date" required value="${esc(terms.first||'')}"></label>
      <label>Number of repayments<input name="count" type="number" min="1" max="600" step="1" required value="${esc(terms.count||'')}"></label>
      <label>Regular repayment<input name="regular" type="number" min="0.01" step="0.01" placeholder="Use your lender’s amount" value="${esc(terms.regular||'')}"></label>
      </div>
      ${loan?'':`<details><summary>Already paying this loan?</summary><p class="hint">Use an opening balance only if this debt is missing from your books. Ask your accountant if it is already recorded.</p><div class="form-grid compact"><label>Opening amount owing<input name="opening_amount" type="number" min="0" step="0.01"></label><label>Opening balance date<input name="opening_date" type="date"></label></div></details>`}
      <details><summary>Interest calculation and lender schedule</summary><label>Estimate method<select name="method"><option value="periodic">Rate divided by payment frequency</option><option value="daily365" ${terms.method==='daily365'?'selected':''}>Daily interest (365-day basis)</option></select></label><p class="hint">Paste one instalment per line with its due date, principal and interest. Example: 2026-12-01, 800.00, 200.00. This schedule takes precedence over estimates.</p><label>Lender instalments<textarea name="schedule" rows="4">${esc((terms.schedule||[]).map(row=>[row.due,row.principal/100,row.interest/100].join(', ')).join('\n'))}</textarea></label></details>
      <details><summary>Balance Sheet classification</summary><label>Repayment rights<select name="classification">
      <option value="">Needs review</option>
      <option value="demand" ${terms.classification==='demand'?'selected':''}>Payable on demand or within 12 months</option>
      <option value="scheduled" ${terms.classification==='scheduled'?'selected':''}>Use lender schedule. The agreement allows deferral of later amounts</option>
      </select></label><p class="hint">Use the lender’s schedule and confirm that the business can defer the later payments under its agreement and applicable covenants.</p></details>
      <p class="hint">The schedule estimates reducing-balance interest. Leave the repayment amount blank to calculate an estimate, or enter the amount on your lender’s statement.</p>
      <p id="finLoanError" role="alert"></p><div class="actions"><button type="button" class="secondary" id="finLoanCancel">Cancel</button><button class="primary">Save loan</button></div></form>`;
    byId('finLoanCancel').onclick=render;
    const form=byId('finLoanForm'),id=loan?.id||crypto.randomUUID();
    form.onsubmit=async event=>{
      event.preventDefault();
      if(tenant!==business())return;
      const values=Object.fromEntries(new FormData(form));
      const base=Number(loan?.owing ?? (Number(values.opening_amount)||values.original_amount));
      const rate=Number(values.rate)/100/{weekly:52,fortnightly:26,monthly:12}[values.frequency];
      const calculated=rate?base*rate/(1-(1+rate)**-Number(values.count)):base/Number(values.count);
      const regular=Number(values.regular||calculated.toFixed(2));
      const button=form.querySelector('[type=submit],button.primary');
      button.disabled=true;
      try{
        const accrualFrom=loan?today():(values.opening_date||values.start_date);
        const schedule=importedSchedule(values.schedule,base);
        if(!schedule.length&&values.first<accrualFrom)throw new Error('Choose a repayment date on or after the balance date.');
        if(!schedule.length&&values.method==='daily365'&&!values.regular)throw new Error('Enter your lender’s regular repayment for a daily interest estimate.');
        if(!Number.isFinite(regular)||regular<=0)throw new Error('Enter the regular repayment amount from your lender.');
        await rpc('frindly_save_loan',{p_id:id,p_details:{
          action:loan?'terms':'create',name:values.name,lender:values.lender,loan_type:values.loan_type,
          bank_id:values.bank_id,original_amount:values.original_amount,start_date:values.start_date,
          opening_amount:values.opening_amount||null,opening_date:values.opening_date||null,
          terms:{rate:values.rate,frequency:values.frequency,first:values.first,count:values.count,regular,base,method:values.method,accrualFrom,schedule,classification:values.classification,classificationFrom:today()}
        }});
        if(tenant===business()){selected=id;await render();}
      }catch(e){if(tenant===business()&&form.isConnected)byId('finLoanError').textContent=e.message;}
      finally{button.disabled=false;}
    };
  }

  async function directFinance(root,loan){
    const tenant=business(), version=++renderVersion;
    const bills=await rpc('frindly_financeable_asset_bills');
    if(tenant!==business()||root.hidden||version!==renderVersion)return;
    root.innerHTML=`<h3>Lender paid the supplier</h3><p class="hint">Select an unpaid bill already posted as a fixed asset. This records a supplier payment against ${esc(loan.name)}.</p>
      <form id="finDirectFinance"><div class="form-grid compact">
      <label>Asset bill<select name="bill" required><option value="">Choose a bill</option>${bills.map(bill=>`<option value="${esc(bill.id)}">${esc(bill.expense_number)} · ${esc(bill.supplier_name)} · ${money(bill.outstanding)} owing</option>`).join('')}</select></label>
      <label>Amount lender paid<input name="amount" type="number" min="0.01" step="0.01" required></label>
      <label>Date lender paid<input name="date" type="date" required max="${today()}" value="${today()}"></label>
      <label>Lender reference<input name="reference" maxlength="200"></label>
      </div><p id="finLoanError" role="alert"></p><div class="actions"><button type="button" class="secondary" id="finFinanceBack">Back</button><button type="submit" class="primary" ${bills.length?'':'disabled'}>Record supplier payment</button></div></form>`;
    byId('finFinanceBack').onclick=render;
    const form=byId('finDirectFinance'), request=crypto.randomUUID(), submit=form.querySelector('[type=submit]');
    form.elements.bill.onchange=()=>{
      const bill=bills.find(item=>item.id===form.elements.bill.value);
      form.elements.amount.value=bill?.outstanding??'';
      form.elements.amount.max=bill?.outstanding??'';
    };
    form.onsubmit=async event=>{
      event.preventDefault();
      if(tenant!==business()||submit.disabled)return;
      submit.disabled=true;
      const values=Object.fromEntries(new FormData(form));
      try{
        await rpc('frindly_record_direct_asset_finance',{p_request:request,p_loan:loan.id,p_expense:values.bill,p_date:values.date,p_amount:Number(values.amount),p_reference:values.reference});
        if(tenant===business()&&form.isConnected)await render();
      }catch(error){if(tenant===business()&&form.isConnected)byId('finLoanError').textContent=error.message;}
      finally{submit.disabled=false;}
    };
  }

  async function render(){
    const root=byId('financial-panel-loans');
    if(!root||root.hidden)return;
    const tenant=business(), version=++renderVersion;
    root.textContent='Loading loans…';
    try{
      const [{loans,can_write:canWrite},cash]=await Promise.all([list(),window.CashTransactions.snapshot()]);
      if(version!==renderVersion||tenant!==business()||root.hidden)return;
      const loan=loans.find(item=>item.id===selected)||loans[0];
      const payments=loan?cash.transactions.filter(item=>item.request_payload?.loan_id===loan.id&&item.status==='recorded'):[];
      const schedule=loan?projectedSchedule(loan,payments):[];
      const next=schedule.find(row=>row.paid<row.total);
      const noPostedBalance=loan&&!loan.closed&&Number(loan.owing)===0;
      const metric=(label,value)=>`<div><dt class="hint">${esc(label)}</dt><dd style="margin:0"><strong>${esc(value)}</strong></dd></div>`;
      const metricGrid='display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,10rem),1fr));gap:1rem';
      root.innerHTML=`<div class="page-head compact-head"><div><h2>Loans &amp; Finance</h2><p>See what you owe and record payments using Money In &amp; Out.</p></div>${canWrite?'<button class="primary" id="finLoanAdd">Add loan</button>':''}</div>
      <p class="hint">Use Owner Current Accounts for shareholder or director lending.</p>
      <div class="ct-workspace">${loans.map(item=>`<button type="button" class="secondary" data-fin-loan="${esc(item.id)}" aria-pressed="${item.id===loan?.id}">${esc(item.name)}${item.closed?' · Closed':''}</button>`).join(' ')||'<p>No loans added yet.</p>'}</div>
      ${loan?`<section class="card" style="margin-block:1rem">
      <h3>${esc(loan.name)}</h3><p class="hint">${esc(loan.lender)} · ${loan.closed?'Closed':'Open'}</p>
      <dl style="${metricGrid}">
        ${metric('Original loan amount',money(loan.original_amount))}
        ${metric('Recorded balance owing',money(loan.owing))}
        ${metric('Annual interest rate',loan.terms.rate+'%')}
        ${metric('Regular repayment',money(loan.terms.regular)+' '+loan.terms.frequency)}
      </dl>
      ${noPostedBalance?'<p class="hint">The recorded balance is $0.00. If this is a new loan, record how the loan was funded using Record loan funds received or Lender paid supplier.</p>':''}
      </section>
      ${next&&!loan.closed?`<section class="card" style="margin-block:1rem">
        <h3>${noPostedBalance?'Planned repayment':'First unpaid scheduled repayment'}</h3>
        <p class="hint">${esc(next.due)} · ${loan.terms.schedule?.length?'Lender schedule':'Estimate from loan terms'}</p>
        <dl style="${metricGrid}">
          ${metric('Total scheduled payment',money(next.total/100))}
          ${metric('Principal (capital)',money(next.principal/100))}
          ${metric('Interest',money(next.interest/100))}
          ${next.paid?metric('Still to record',money((next.total-next.paid)/100)):''}
        </dl>
      </section>`:''}
      ${canWrite&&!loan.closed?`<div class="actions"><button class="primary" data-loan-action="repayment">Record repayment</button><button class="secondary" data-loan-action="funds">Record loan funds received</button><button class="secondary" data-loan-action="topup">Loan top-up</button><button class="secondary" data-loan-action="extra">Extra principal payment</button><button class="secondary" data-loan-action="interest">Interest-only payment</button><button class="secondary" id="finDirectFinanceOpen">Lender paid supplier</button><button class="secondary" id="finLoanTerms">Update loan terms</button><button class="secondary" id="finLoanClose">Close loan</button></div>`:canWrite&&loan.closed?'<button class="secondary" id="finLoanReopen">Reopen loan</button>':''}
      <details class="card" style="margin-block:1rem" open><summary><strong>Repayment schedule</strong></summary><p class="hint">${loan.terms.schedule?.length?'From your lender’s schedule.':'Estimates from your loan terms.'} Principal reduces the amount you owe. Interest is the cost of borrowing. Use your lender’s figures when recording a payment.</p>${schedule.length?'':'<p class="hint">No instalments to display. Check the repayment dates and amounts in Update loan terms.</p>'}<div class="table-scroll" tabindex="0" role="region" aria-label="Repayment schedule table" style="max-height:min(26rem,55vh);overflow:auto"><table><thead style="position:sticky;top:0;z-index:1"><tr><th>Due date</th><th>Total payment</th><th>Principal (capital)</th><th>Interest</th><th>Projected balance</th><th>Status</th><th></th></tr></thead><tbody>${schedule.map((row,index)=>`<tr><td>${row.due}</td><td>${money(row.total/100)}</td><td>${money(row.principal/100)}</td><td>${money(row.interest/100)}</td><td>${money(row.remaining/100)}</td><td>${row.paid>=row.total?'Paid':row.paid?'Partially paid':noPostedBalance?'Planned':row.due<today()?'Overdue':'Upcoming'}</td><td>${canWrite&&!loan.closed&&row.paid<row.total?`<button class="secondary" data-loan-instalment="${index}">Record payment</button>`:''}</td></tr>`).join('')}</tbody></table></div></details>
      <details><summary>Payment history</summary>${payments.map(payment=>`<p>${esc(payment.description)} · ${money(payment.amount)} <button class="secondary" data-cash-view="${esc(payment.id)}">View</button></p>`).join('')||'<p>No payments recorded.</p>'}</details>
      <details><summary>Check a lender statement</summary><form id="finLoanStatement"><div class="form-grid compact"><label>Statement date<input name="date" type="date" required value="${today()}"></label><label>Amount owing on statement<input name="amount" type="number" min="0" step="0.01" required></label></div><button class="secondary">Compare balances</button><p id="finLoanComparison" role="status"></p></form></details>
      `:''}<p id="finLoanError" role="alert"></p>`;
      const report=e=>{if(tenant===business()&&byId('finLoanError'))byId('finLoanError').textContent=e.message;};
      if(byId('finLoanAdd'))byId('finLoanAdd').onclick=()=>editor(root).catch(report);
      for(const button of root.querySelectorAll('[data-fin-loan]'))button.onclick=()=>{selected=button.dataset.finLoan;render();};
      if(!loan)return;
      if(byId('finDirectFinanceOpen'))byId('finDirectFinanceOpen').onclick=()=>directFinance(root,loan).catch(report);
      if(byId('finLoanTerms'))byId('finLoanTerms').onclick=()=>editor(root,loan).catch(report);
      if(byId('finLoanClose'))byId('finLoanClose').onclick=async()=>{
        if(tenant!==business())return;
        try{await rpc('frindly_save_loan',{p_id:loan.id,p_details:{action:'close'}});await render();}catch(e){report(e);}
      };
      if(byId('finLoanReopen'))byId('finLoanReopen').onclick=async()=>{
        if(tenant!==business())return;
        try{await rpc('frindly_save_loan',{p_id:loan.id,p_details:{action:'reopen'}});await render();}catch(e){report(e);}
      };
      const openPayment=(action,row)=>{
        if(tenant!==business())return;
        const incoming=['funds','topup'].includes(action);
        const labels={funds:'Loan funds received',topup:'Loan top-up',repayment:'Loan repayment',extra:'Extra principal payment',interest:'Interest-only payment'};
        const firstReceipt=action==='funds'&&Number(loan.owing)===0&&payments.length===0;
        const amount=row?(row.total-row.paid)/100:firstReceipt?Number(loan.original_amount):undefined;
        window.CashTransactions.open(incoming?'in':'out',{
          purpose:incoming?'loan_received':'loan_repayment',loan_id:loan.id,bank_id:loan.bank_id,
          amount,date:row&&row.due<today()?'':today(),loan_due_date:row?.due,
          interest:row?Math.min(amount,Math.max(0,row.interest-row.paidInterest)/100):0,
          interest_only:action==='interest',description:labels[action]+' · '+loan.name
        },null,render);
      };
      for(const button of root.querySelectorAll('[data-loan-action]'))button.onclick=()=>openPayment(button.dataset.loanAction,button.dataset.loanAction==='repayment'?next:undefined);
      for(const button of root.querySelectorAll('[data-loan-instalment]'))button.onclick=()=>openPayment('repayment',schedule[Number(button.dataset.loanInstalment)]);
      byId('finLoanStatement').onsubmit=async event=>{
        event.preventDefault();
        const form=event.currentTarget, values=new FormData(form);
        try{
          const report=await list(values.get('date'));
          if(!form.isConnected||tenant!==business())return;
          const owing=report.loans.find(item=>item.id===loan.id).owing;
          const difference=cents(values.get('amount'))-cents(owing);
          byId('finLoanComparison').textContent=difference?`Frindly shows ${money(owing)}. Your lender balance differs by ${money(difference/100)}. Check dates, payments and principal splits.`:`Balances match at ${money(owing)}.`;
        }catch(e){report(e);}
      };
    }catch(e){if(version===renderVersion&&tenant===business())root.textContent=e.message;}
  }
  async function upcoming(){
    const tenant=business();
    const [{loans},cash]=await Promise.all([list(),window.CashTransactions.snapshot()]);
    if(tenant!==business())return [];
    const end=new Date(today()+'T00:00:00Z');
    end.setUTCDate(end.getUTCDate()+30);
    return loans.filter(loan=>!loan.closed&&Number(loan.owing)>0).flatMap(loan=>{
      const payments=cash.transactions.filter(payment=>payment.status==='recorded'&&payment.request_payload?.loan_id===loan.id);
      const amount=projectedSchedule(loan,payments)
        .filter(row=>row.due<=dateText(end))
        .reduce((total,row)=>total+Math.max(0,row.total-row.paid),0);
      return amount?[{label:loan.name,amount:amount/100}]:[];
    });
  }
  function nextPayment(loan, transactions){
    const payments=transactions.filter(payment=>payment.status==='recorded'&&payment.request_payload?.loan_id===loan.id);
    return projectedSchedule(loan,payments).find(row=>row.paid<row.total);
  }
  function splitLiability(loan, transactions, asOf){
    const balance=cents(loan.owing);
    const terms=loan.terms;
    if(balance<=0||!terms.classificationFrom||terms.classificationFrom>asOf)return null;
    if(terms.classification==='demand')return {current:balance/100,longTerm:0};
    if(terms.classification!=='scheduled'||!Array.isArray(terms.schedule)||!terms.schedule.length)return null;
    const cutoff=new Date(asOf+'T00:00:00Z');
    const day=cutoff.getUTCDate();
    cutoff.setUTCDate(1);
    cutoff.setUTCFullYear(cutoff.getUTCFullYear()+1);
    const last=new Date(Date.UTC(cutoff.getUTCFullYear(),cutoff.getUTCMonth()+1,0)).getUTCDate();
    cutoff.setUTCDate(Math.min(day,last));
    const dueThrough=dateText(cutoff);
    const principalByDue=new Map();
    for(const payment of transactions){
      const payload=payment.request_payload;
      if(payload?.loan_id!==loan.id||payment.status!=='recorded'||payment.purpose!=='loan_repayment')continue;
      const paidOn=payment.legs?.[0]?.transaction_date||payload.date;
      if(!paidOn||paidOn>asOf||!payload.loan_due_date)continue;
      const principal=cents(payment.amount)-cents(payment.interest_amount||0)-cents(payload.loan_fee||0);
      principalByDue.set(payload.loan_due_date,(principalByDue.get(payload.loan_due_date)||0)+principal);
    }
    let total=0,current=0;
    const seen=new Set();
    for(const row of terms.schedule){
      if(!/^\d{4}-\d{2}-\d{2}$/.test(row.due)||seen.has(row.due)||!Number.isSafeInteger(row.principal)||row.principal<0)return null;
      seen.add(row.due);
      const unpaid=row.principal-(principalByDue.get(row.due)||0);
      if(unpaid<0)return null;
      total+=unpaid;
      if(row.due<=dueThrough)current+=unpaid;
    }
    // A changed principal balance or incomplete schedule requires a refreshed lender schedule.
    if(total!==balance)return null;
    return {current:current/100,longTerm:(balance-current)/100};
  }

  async function classifications(asOf){
    const tenant=business();
    const [{loans},cash]=await Promise.all([list(asOf),window.CashTransactions.snapshot()]);
    if(tenant!==business())return new Map();
    return new Map(loans.filter(loan=>Number(loan.owing)>0).map(loan=>[loan.account_id,splitLiability(loan,cash.transactions,asOf)]));
  }

  window.LoansFinance={list,render,upcoming,nextPayment,classifications};
})();
