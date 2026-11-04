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
          terms:{rate:values.rate,frequency:values.frequency,first:values.first,count:values.count,regular,base,method:values.method,accrualFrom,schedule}
        }});
        if(tenant===business()){selected=id;await render();}
      }catch(e){if(tenant===business()&&form.isConnected)byId('finLoanError').textContent=e.message;}
      finally{button.disabled=false;}
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
      const loan=loans.find(item=>item.id===selected);
      const payments=loan?cash.transactions.filter(item=>item.request_payload?.loan_id===loan.id&&item.status==='recorded'):[];
      const schedule=loan?projectedSchedule(loan,payments):[];
      const next=schedule.find(row=>row.paid<row.total);
      root.innerHTML=`<div class="page-head compact-head"><div><h2>Loans &amp; Finance</h2><p>See what you owe and record payments using Money In &amp; Out.</p></div>${canWrite?'<button class="primary" id="finLoanAdd">Add loan</button>':''}</div>
      <p class="hint">Use Owner Current Accounts for shareholder or director lending.</p>
      <div class="ct-workspace">${loans.map(item=>`<button type="button" class="secondary" data-fin-loan="${esc(item.id)}">${esc(item.name)} · ${money(item.owing)}${item.closed?' · Closed':''}</button>`).join(' ')||'<p>No loans added yet.</p>'}</div>
      ${loan?`<h3>${esc(loan.name)}</h3><p>${esc(loan.lender)} · ${loan.closed?'Closed':'Open'}</p><p>Original loan ${money(loan.original_amount)} · Amount owing ${money(loan.owing)}</p><p>${esc(loan.terms.rate)}% annual interest · ${money(loan.terms.regular)} ${esc(loan.terms.frequency)}${next?' · Next unpaid instalment '+esc(next.due):''}</p>
      ${canWrite&&!loan.closed?`<div class="actions"><button class="primary" data-loan-action="repayment">Record repayment</button><button class="secondary" data-loan-action="funds">Record loan funds received</button><button class="secondary" data-loan-action="topup">Loan top-up</button><button class="secondary" data-loan-action="extra">Extra principal payment</button><button class="secondary" data-loan-action="interest">Interest-only payment</button><button class="secondary" id="finLoanTerms">Update loan terms</button><button class="secondary" id="finLoanClose">Close loan</button></div>`:canWrite&&loan.closed?'<button class="secondary" id="finLoanReopen">Reopen loan</button>':''}
      <details><summary>Repayment schedule</summary><p class="hint">Estimated instalments. Use your lender’s figures when recording a payment. Update the terms after a top-up, extra payment or rate change.</p><div class="table-scroll"><table><thead><tr><th>Due</th><th>Payment</th><th>Principal</th><th>Interest</th><th>Estimated owing</th><th>Status</th><th></th></tr></thead><tbody>${schedule.map((row,index)=>`<tr><td>${row.due}</td><td>${money(row.total/100)}</td><td>${money(row.principal/100)}</td><td>${money(row.interest/100)}</td><td>${money(row.remaining/100)}</td><td>${row.paid>=row.total?'Paid':row.paid?'Partially paid':row.due<today()?'Overdue':'Upcoming'}</td><td>${canWrite&&!loan.closed&&row.paid<row.total?`<button class="secondary" data-loan-instalment="${index}">Record payment</button>`:''}</td></tr>`).join('')}</tbody></table></div></details>
      <details><summary>Payment history</summary>${payments.map(payment=>`<p>${esc(payment.description)} · ${money(payment.amount)} <button class="secondary" data-cash-view="${esc(payment.id)}">View</button></p>`).join('')||'<p>No payments recorded.</p>'}</details>
      <details><summary>Check a lender statement</summary><form id="finLoanStatement"><div class="form-grid compact"><label>Statement date<input name="date" type="date" required value="${today()}"></label><label>Amount owing on statement<input name="amount" type="number" min="0" step="0.01" required></label></div><button class="secondary">Compare balances</button><p id="finLoanComparison" role="status"></p></form></details>
      `:''}<p id="finLoanError" role="alert"></p>`;
      const report=e=>{if(tenant===business()&&byId('finLoanError'))byId('finLoanError').textContent=e.message;};
      if(byId('finLoanAdd'))byId('finLoanAdd').onclick=()=>editor(root).catch(report);
      for(const button of root.querySelectorAll('[data-fin-loan]'))button.onclick=()=>{selected=button.dataset.finLoan;render();};
      if(!loan)return;
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
        const amount=row?(row.total-row.paid)/100:undefined;
        window.CashTransactions.open(incoming?'in':'out',{
          purpose:incoming?'loan_received':'loan_repayment',loan_id:loan.id,bank_id:loan.bank_id,
          amount,date:today(),loan_due_date:row?.due,
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
  window.LoansFinance={list,render,upcoming,nextPayment};
})();
