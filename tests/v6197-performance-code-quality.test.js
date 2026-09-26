const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

const root=path.resolve(__dirname,'..');

function makeElement(id,overrides={}){
  return {
    id,value:'',textContent:'',innerHTML:'',checked:false,disabled:false,dataset:{},
    classList:{add(){},remove(){},toggle(){}},
    setAttribute(){},removeAttribute(){},appendChild(){},replaceChildren(){},
    querySelector(){return null},querySelectorAll(){return []},
    ...overrides
  };
}

function payrollHarness({leaveInputs=[]}={}){
  let source=fs.readFileSync(path.join(root,'public/payroll.js'),'utf8');
  source=source
    .replace("await load();toast(id?'Employee updated':'Employee added')","window.__payrollLoaded=(window.__payrollLoaded||0)+1;toast(id?'Employee updated':'Employee added')")
    .replace("state.settingsDirty=false;$('payrollSettingsStatus').textContent='Saved';await load();toast('Payroll settings saved');","state.settingsDirty=false;$('payrollSettingsStatus').textContent='Saved';window.__payrollLoaded=(window.__payrollLoaded||0)+1;toast('Payroll settings saved');")
    .replace('window.Payroll={init,onShow','window.__payrollTest={state,savePayrollSettings,saveEmployee};window.Payroll={init,onShow');

  const calls=[];
  const elements=new Map();
  const byId=id=>{
    if(!elements.has(id))elements.set(id,makeElement(id));
    return elements.get(id);
  };
  const set=(id,props)=>Object.assign(byId(id),props);
  [
    ['payrollSettingCountry','NZ'],['payrollSettingFrequency','fortnightly'],['payrollSettingPayDay','5'],
    ['payrollSettingWeekStart','1'],['payrollSettingHours','40'],['payrollSettingDays','5'],
    ['payrollSettingPrefix','EMP'],['payrollSettingPayslipNote','Thanks'],
    ['peFirst','Ada'],['peLast','Lovelace'],['peEmploymentType','permanent'],['peStart','2026-09-01'],
    ['peEmploymentStatus','active'],['pePayType','hourly'],['peFrequency','weekly'],['peHolidayMethod','standard'],
    ['pePaygEligibility','not_eligible'],['peTaxCode','M'],['peKiwiStatus','not_enrolled']
  ].forEach(([id,value])=>set(id,{value}));
  ['peMiddle','pePreferred','peDob','peEmail','peMobile','pePhone','peAddress','peEmergencyName','peEmergencyPhone','peNotes','peEnd','peJobTitle','peDepartment','peManager','peHours','peDays','peHourlyRate','peSalary','peOvertime','peHolidayRate','peIrd','peKiwiEmployee','peKiwiEmployer','peBankName','peBankNumber','peBankReference'].forEach(id=>set(id,{value:''}));
  ['peStudentLoan'].forEach(id=>set(id,{checked:false}));
  set('peLeaveBalances',{querySelectorAll:selector=>selector==='[data-leave-id]'?leaveInputs:[]});
  set('payrollSaveEmployee',{textContent:'Save Employee',dataset:{}});
  set('payrollSaveSettings',{textContent:'Save Settings'});
  set('payrollEmployeeId',{value:''});
  set('payrollSettingsStatus',{textContent:''});

  const dataSelectors=new Map();
  const q=(selector)=>{
    if(!String(selector).startsWith('[data-'))return null;
    if(!dataSelectors.has(selector))dataSelectors.set(selector,makeElement(selector));
    return dataSelectors.get(selector);
  };
  const seedPayItem=id=>{
    q(`[data-pi-type="${id}"]`).value=id==='new-pay'?'reimbursement':'earning';
    q(`[data-pi-name="${id}"]`).value=id==='new-pay'?'Mileage':'Ordinary time';
    q(`[data-pi-calc="${id}"]`).value='fixed';
    q(`[data-pi-rate="${id}"]`).value=id==='new-pay'?'0.95':'25';
    q(`[data-pi-taxfree="${id}"]`).checked=false;
    q(`[data-pi-statutory="${id}"]`).value=id==='new-pay'?'reimbursement':'ordinary_earnings';
    q(`[data-pi-gross-mode="${id}"]`).value='include';
    q(`[data-pi-owp-mode="${id}"]`).value='include';
    q(`[data-pi-rdp-mode="${id}"]`).value='include';
    q(`[data-pi-adp-mode="${id}"]`).value='include';
  };
  const seedLeave=id=>{q(`[data-lt-name="${id}"]`).value=id==='new-leave'?'Alt holiday':'Annual holidays';q(`[data-lt-paid="${id}"]`).checked=id!=='new-leave'};
  const seedDoc=id=>{q(`[data-dt-name="${id}"]`).value=id==='new-doc'?'Licence':'Agreement';q(`[data-dt-required="${id}"]`).checked=id!=='new-doc'};
  ['pay-existing','new-pay'].forEach(seedPayItem);
  ['leave-existing','new-leave'].forEach(seedLeave);
  ['doc-existing','new-doc'].forEach(seedDoc);

  const makeBuilder=table=>({
    table,
    upsert(rows,options){calls.push({op:'upsert',table,rows,options});return Promise.resolve({error:null,data:rows})},
    insert(row){calls.push({op:'insert',table,row});this.row=row;return this},
    update(row){calls.push({op:'update',table,row});this.row=row;return this},
    select(){return this},
    single(){return Promise.resolve({error:null,data:{id:'emp-1',...(this.row||{})}})},
    eq(){return this}
  });
  const window={
    __payrollLoaded:0,
    SAAS:{state:{business:{id:'biz-1'},user:{id:'user-1'}},client:()=>({from:makeBuilder})},
    FinloCore:{format:{money:()=>'$0.00'},ui:{toast(){}}},
    toast(){},
    addEventListener(){}
  };
  const document={getElementById:byId,querySelector:q,querySelectorAll:()=>[],createElement:tag=>makeElement(tag)};
  vm.runInNewContext(source,{window,document,localStorage:{getItem:()=>null},console,Date,Intl,setTimeout,clearTimeout,confirm:()=>true,prompt:()=>'',alert(){}});
  const api=window.__payrollTest;
  api.state.businessId='biz-1';
  api.state.settings={country_code:'AU',currency:'NZD'};
  api.state.payItems=[{id:'pay-existing'},{id:'new-pay'}];
  api.state.leaveTypes=[{id:'leave-existing'},{id:'new-leave'}];
  api.state.docTypes=[{id:'doc-existing'},{id:'new-doc'}];
  return {api,calls,window};
}

test('payroll settings save batches pay items, leave types and document types with mixed IDs',async()=>{
  const {api,calls}=payrollHarness();
  await api.savePayrollSettings();
  const upserts=calls.filter(c=>c.op==='upsert');
  assert.deepEqual(upserts.map(c=>c.table),['payroll_settings','payroll_pay_items','payroll_leave_types','payroll_document_types']);
  const payRows=upserts.find(c=>c.table==='payroll_pay_items').rows;
  assert.equal(payRows.length,2);
  assert.deepEqual(payRows.map(r=>r.id),['pay-existing','new-pay']);
  assert.equal(payRows[1].name,'Mileage');
  assert.equal(payRows[1].taxable,false);
  const leaveRows=upserts.find(c=>c.table==='payroll_leave_types').rows;
  assert.deepEqual(leaveRows.map(r=>[r.id,r.name,r.paid]),[['leave-existing','Annual holidays',true],['new-leave','Alt holiday',false]]);
  const docRows=upserts.find(c=>c.table==='payroll_document_types').rows;
  assert.deepEqual(docRows.map(r=>[r.id,r.name,r.required]),[['doc-existing','Agreement',true],['new-doc','Licence',false]]);
  assert.equal(upserts.find(c=>c.table==='payroll_pay_items').options.onConflict,'id');
});

test('employee save batches leave balances and skips empty leave-balance arrays',async()=>{
  const leaveInputs=[
    {dataset:{leaveId:'annual'},value:'12.5'},
    {dataset:{leaveId:'sick'},value:'4'}
  ];
  const withLeave=payrollHarness({leaveInputs});
  await withLeave.api.saveEmployee();
  const leaveUpserts=withLeave.calls.filter(c=>c.op==='upsert'&&c.table==='payroll_employee_leave');
  assert.equal(leaveUpserts.length,1);
  assert.equal(leaveUpserts[0].options.onConflict,'employee_id,leave_type_id');
  assert.equal(JSON.stringify(leaveUpserts[0].rows.map(r=>[r.employee_id,r.leave_type_id,r.balance_hours])),JSON.stringify([['emp-1','annual',12.5],['emp-1','sick',4]]));

  const noLeave=payrollHarness({leaveInputs:[]});
  await noLeave.api.saveEmployee();
  assert.equal(noLeave.calls.filter(c=>c.op==='upsert'&&c.table==='payroll_employee_leave').length,0);
});

function bankHarness(allocations){
  let source=fs.readFileSync(path.join(root,'public/bank-reconciliation.js'),'utf8');
  source=source
    .replace("toast('Reconciliation undone');loadHistory()","toast('Reconciliation undone');window.__loadHistoryCalled=(window.__loadHistoryCalled||0)+1")
    .replace('window.BankReconciliation={init,onShow,refresh:loadQueue,openImport};','window.__bankTest={state,undoReconciliation};window.BankReconciliation={init,onShow,refresh:loadQueue,openImport};');
  const calls=[];
  const makeBuilder=table=>({
    table,
    select(){return this},
    eq(column,value){calls.push({op:'eq',table,column,value});if(table==='bank_reconciliation_allocations'&&column==='bank_transaction_id')this.result={data:allocations,error:null};return this},
    delete(){calls.push({op:'delete',table});this.deleted=true;return this},
    in(column,values){calls.push({op:'in',table,column,values});return Promise.resolve({error:null})},
    update(row){calls.push({op:'update',table,row});return this},
    insert(row){calls.push({op:'insert',table,row});return Promise.resolve({error:null})},
    then(resolve){resolve(this.result||{error:null,data:[]})}
  });
  const window={
    __loadHistoryCalled:0,
    SAAS:{state:{business:{id:'biz-1',settings:{}},user:{id:'user-1'}},client:()=>({from:makeBuilder})},
    FinloCore:{format:{money:()=>'$0.00'},ui:{toast(){}}},
    refreshInvoiceList(){},Expenses:{refresh(){}}
  };
  const document={getElementById:()=>makeElement('x'),querySelectorAll:()=>[],createElement:tag=>makeElement(tag),body:makeElement('body')};
  vm.runInNewContext(source,{window,document,console,Date,Intl,setTimeout,clearTimeout,confirm:()=>true,prompt:()=>'',alert(){}});
  return {api:window.__bankTest,calls,window};
}

test('bank undo batches payment deletes and handles single and zero IDs',async()=>{
  const many=bankHarness([
    {customer_payment_id:'cp-1'},
    {customer_payment_id:'cp-2'},
    {expense_payment_id:'ep-1'},
    {created_expense:true,expense_id:'ex-1'}
  ]);
  await many.api.undoReconciliation('tx-1');
  assert.deepEqual(many.calls.filter(c=>c.op==='in').map(c=>[c.table,c.column,c.values]),[
    ['customer_payments','id',['cp-1','cp-2']],
    ['expense_payments','id',['ep-1']],
    ['expenses','id',['ex-1']]
  ]);

  const single=bankHarness([{customer_payment_id:'cp-only'}]);
  await single.api.undoReconciliation('tx-2');
  assert.deepEqual(single.calls.filter(c=>c.op==='in').map(c=>[c.table,c.values]),[['customer_payments',['cp-only']]]);

  const none=bankHarness([]);
  await none.api.undoReconciliation('tx-3');
  assert.equal(none.calls.filter(c=>c.op==='in'&&['customer_payments','expense_payments','expenses'].includes(c.table)).length,0);
});

test('FinloCore loader appends scripts in parallel, waits for all loads and rejects failures',async()=>{
  const source=fs.readFileSync(path.join(root,'public/finlo-core.js'),'utf8');
  const appended=[];
  const document={
    getElementById:()=>null,
    createElement:tag=>({tag}),
    body:{appendChild(node){appended.push(node)}}
  };
  const window={};
  vm.runInNewContext(source,{window,document,Intl,URL:{createObjectURL(){return'blob:test'},revokeObjectURL(){}},Blob:function(){},setTimeout,alert(){}});

  let resolved=false;
  const promise=window.FinloCore.loader.loadScriptsSequentially(['a.js','b.js','c.js']).then(()=>{resolved=true});
  assert.deepEqual(appended.map(s=>s.src),['a.js','b.js','c.js']);
  assert.equal(appended.length,3,'all scripts are appended before any load completes');
  appended[1].onload();
  await Promise.resolve();
  assert.equal(resolved,false);
  appended[0].onload();
  await Promise.resolve();
  assert.equal(resolved,false);
  appended[2].onload();
  await promise;
  assert.equal(resolved,true);

  const failed=window.FinloCore.loader.loadScriptsSequentially(['bad.js']);
  appended.at(-1).onerror();
  await assert.rejects(failed,/Unable to load bad\.js/);
});
