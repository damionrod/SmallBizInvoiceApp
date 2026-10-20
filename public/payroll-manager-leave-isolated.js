/* Frindly Payroll Leave Drafts — isolated manager UI, v6236.
 * Opt-in only. No route registration or existing payroll file changes.
 * Mount with: FrindlyManagerLeaveDrafts.mount(element, {client: supabaseClient})
 * Hard-restricted to isolated Supabase project.
 */
(function(root){
'use strict';
const EXPECTED_PROJECT='smvvevrtjqkflyqkyape';
const css=`
.fr-leave{font:inherit;max-width:860px;color:inherit}
.fr-leave *{box-sizing:border-box}
.fr-leave h2{margin:0 0 12px;font-size:1.2rem}
.fr-leave form{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
.fr-leave label{display:flex;flex-direction:column;gap:5px;font-size:.9rem}
.fr-leave input,.fr-leave select{width:100%;min-height:42px;padding:8px 10px;border:1px solid #b7beca;border-radius:8px;background:#fff;color:#182335;font:inherit}
.fr-leave button{min-height:42px;border:0;border-radius:8px;padding:9px 18px;background:#6035a5;color:white;font:inherit;cursor:pointer}
.fr-leave button:disabled{opacity:.55;cursor:wait}
.fr-leave .wide{grid-column:1/-1}
.fr-leave .notice{margin:10px 0;font-size:.9rem;white-space:pre-wrap}
 .fr-leave .draft-item{border:1px solid #d9dce4;border-radius:9px;padding:12px;margin:10px 0} .fr-leave .draft-item p{margin:6px 0 10px} 
 .fr-leave .history-entry{border-bottom:1px solid #e2e4ea;padding:7px 0;margin:0;font-size:.9rem}
@media(max-width:600px){.fr-leave form{grid-template-columns:minmax(0,1fr)}}
`;
function node(tag,attrs={},text){
 const el=document.createElement(tag);
 for(const [k,v] of Object.entries(attrs)){if(k==='class')el.className=v;else el.setAttribute(k,v);}
 if(text!==undefined)el.textContent=String(text);
 return el;
}
function validDate(s){return /^\d{4}-\d{2}-\d{2}$/.test(s)&&!Number.isNaN(Date.parse(s+'T12:00:00Z'))}
function mount(target,{client}={}){
 if(!target||typeof target.appendChild!=='function')throw Error('Mount target required');
 if(!client||typeof client.rpc!=='function')throw Error('Supabase client required');
 const host=new URL(client.supabaseUrl||'https://invalid.example').hostname;
 if(host!==EXPECTED_PROJECT+'.supabase.co')throw Error('This screen is restricted to the isolated payroll environment');
 target.replaceChildren();
 const wrap=node('section',{class:'fr-leave'});
 const style=node('style');style.textContent=css;wrap.append(style,node('h2',{},'Create leave draft'));
 const notice=node('p',{class:'notice',role:'status','aria-live':'polite'},'Loading payroll employees and leave types…');
 const form=node('form');form.hidden=true;
 function field(title,type,required=true){
   const label=node('label');label.append(node('span',{},title));
   const input=node(type==='select'?'select':'input',type==='select'?{}:{type});
   if(required)input.required=true;
   label.append(input);form.append(label);return input;
 }
 const employee=field('Employee','select'),leave=field('Leave type','select'),
 from=field('Start date','date'),to=field('End date','date'),
 qty=field('Quantity','number'),unit=field('Unit','select');
 qty.min='0.01';qty.max='10000';qty.step='0.01';
 for(const [v,label] of [['hours','Hours'],['days','Days'],['weeks','Weeks']]){
   const opt=node('option',{value:v},label);unit.append(opt);
 }
 const action=node('div',{class:'wide'}),save=node('button',{type:'submit'},'Save draft');
 const cancel=node('button',{type:'button'},'Cancel edit');cancel.hidden=true;cancel.style.marginLeft='8px';
 action.append(save,cancel);form.append(action);wrap.append(notice,form);
 const heading=node('h2',{},'Saved drafts'),draftList=node('div',{class:'draft-list'});
 const approvalHeading=node('h2',{},'Leave approvals'),approvalList=node('div',{class:'approval-list'});
 const previewHeading=node('h2',{},'Payroll impact preview (read-only)'),previewList=node('div',{class:'preview-list'});
 const validationHeading=node('h2',{},'Pre-payroll validation (read-only)'),validationList=node('div',{class:'validation-list'});
 const reconciliationHeading=node('h2',{},'Payroll reconciliation (read-only)'),reconciliationList=node('div',{class:'reconciliation-list'});
 const fixtureHeading=node('h2',{},'Hypothetical payroll test data (isolated)'),fixtureList=node('div',{class:'fixture-list'});
 const calculationHeading=node('h2',{},'Simulated statutory calculation tests'),calculationList=node('div',{class:'calculation-list'});
 const checksHeading=node('h2',{},'Automated scenario checks (isolated)'),checksList=node('div',{class:'checks-list'});
 const transactionHeading=node('h2',{},'Transaction safeguards (temporary simulation)'),transactionList=node('div',{class:'transaction-list'});
 const readinessHeading=node('h2',{},'Payroll integration readiness (read-only)'),readinessList=node('div',{class:'readiness-list'});
 const frameworkHeading=node('h2',{},'Synthetic earnings and statutory framework (Phases 16–17)'),frameworkList=node('div',{class:'framework-list'});
 const stageHeading=node('h2',{},'Phase 18 — blocked payroll integration staging'),stageList=node('div',{class:'stage-list'});
 const gateHeading=node('h2',{},'Phase 19 — integration safety audit (read-only)'),gateList=node('div',{class:'gate-list'});
 const historyHeading=node('h2',{},'Draft activity'),historyList=node('div',{class:'draft-history'});
 wrap.append(heading,draftList,approvalHeading,approvalList,previewHeading,previewList,validationHeading,validationList,reconciliationHeading,reconciliationList,fixtureHeading,fixtureList,calculationHeading,calculationList,checksHeading,checksList,transactionHeading,transactionList,readinessHeading,readinessList,frameworkHeading,frameworkList,stageHeading,stageList,gateHeading,gateList,historyHeading,historyList);target.append(wrap);
 let editing=null;
 cancel.addEventListener('click',()=>{editing=null;form.reset();save.textContent='Save draft';cancel.hidden=true;});
 async function approvalAction(draftId,action){
   const {error}=await client.rpc('v6239_manager_leave_approval_command',{p_draft_id:draftId,p_action:action});
   if(error)throw error;
   notice.textContent='Request '+(action==='submit'?'submitted':action==='approve'?'approved':'declined')+' successfully. Payroll unchanged.';
   await loadDrafts();await loadApprovals();await loadPreview();await loadValidation();await loadReconciliation();await loadFixtures();await loadCalculationTests();await loadAutomatedChecks();await loadTransactionTests();await loadIntegrationReadiness();await loadStatutoryFramework();await loadIntegrationStage();await loadIntegrationGateAudit();
   window.alert('Leave request '+(action==='submit'?'submitted for approval':action==='approve'?'approved':'declined')+' successfully.');
 }
 async function loadApprovals(){
   const {data,error}=await client.rpc('v6239_manager_leave_approvals_read');
   if(destroyed)return;
   approvalList.replaceChildren();
   if(error){approvalList.append(node('p',{},'Unable to load approvals: '+error.message));return;}
   const rows=Array.isArray(data)?data:[];
   if(!rows.length){approvalList.append(node('p',{},'No submitted requests yet.'));return;}
   for(const a of rows){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},a.employee+' — '+a.leave_type+' · '+a.status));
     item.append(node('p',{},a.date_from+' to '+a.date_to+' · '+a.quantity+' '+a.unit));
     if(a.status==='pending'){
       for(const [action,label] of [['approve','Approve'],['decline','Decline']]){
         const btn=node('button',{type:'button'},label);btn.style.marginRight='8px';
         btn.addEventListener('click',async()=>{
           if(save.disabled||btn.disabled)return;
           if(!window.confirm(label+' this leave request?'))return;
           save.disabled=true;btn.disabled=true;
           try{await approvalAction(a.draft_id,action);}
           catch(err){notice.textContent=label+' failed: '+(err.message||'Unknown error');btn.disabled=false;}
           finally{save.disabled=false;}
         });
         item.append(btn);
       }
     }
     approvalList.append(item);
   }
 }
 async function loadPreview(){
   const {data,error}=await client.rpc('v6240_manager_leave_payroll_preview');
   if(destroyed)return;
   previewList.replaceChildren();
   if(error){previewList.append(node('p',{},'Unable to load preview: '+error.message));return;}
   const rows=Array.isArray(data)?data:[];
   previewList.append(node('p',{},'Estimates only. No leave balances, payroll calculations, payslips or transactions are changed.'));
   if(!rows.length){previewList.append(node('p',{},'No approved leave to preview.'));return;}
   for(const p of rows){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},p.employee+' — '+p.leave_type));
     item.append(node('p',{},p.from+' to '+p.to+' · '+p.quantity+' '+p.unit));
     item.append(node('p',{},p.estimated_hours==null?'Hours: cannot estimate':'Estimated hours: '+p.estimated_hours));
     item.append(node('p',{},p.review_note));
     previewList.append(item);
   }
 }
 async function loadValidation(){
   const {data,error}=await client.rpc('v6241_manager_leave_payroll_validation');
   if(destroyed)return;
   validationList.replaceChildren();
   if(error){validationList.append(node('p',{},'Validation unavailable: '+error.message));return;}
   const rows=Array.isArray(data)?data:[];
   validationList.append(node('p',{},'All requests remain blocked from automatic payroll posting pending statutory and reconciliation testing.'));
   if(!rows.length){validationList.append(node('p',{},'No approved requests to validate.'));return;}
   for(const v of rows){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},v.employee+' — '+v.leave_type));
     item.append(node('p',{},v.date_from+' to '+v.date_to));
     item.append(node('p',{},v.overlap_count>0?'Warning: overlaps '+v.overlap_count+' other approved request(s).':'No overlap with other approved requests.'));
     item.append(node('p',{},v.schedule_missing?'Working schedule incomplete.':'Working schedule present.'));
     const kind=String(v.leave_type||'').toLowerCase();
     const guidance=kind.includes('annual')?'Annual leave: compare ordinary weekly pay and average weekly earnings; use the higher amount.'
       :kind.includes('sick')||kind.includes('alternative')?'Verify otherwise-working days and relevant daily pay, or average daily pay where permitted.'
       :'Review applicable leave rules and employment agreement.';
     item.append(node('p',{},'NZ statutory review: '+guidance));
     item.append(node('p',{},'Entitlements, earnings history, pay-period matching and duplicate posting: not verified.'));
     item.append(node('p',{},'Payroll posting: BLOCKED — statutory and duplicate-posting checks still required.'));
     validationList.append(item);
   }
 }
 async function loadReconciliation(){
   const {data,error}=await client.rpc('v6243_manager_leave_reconciliation_preview');
   if(destroyed)return;
   reconciliationList.replaceChildren();
   if(error){reconciliationList.append(node('p',{},'Reconciliation unavailable: '+error.message));return;}
   const rows=Array.isArray(data)?data:[];
   reconciliationList.append(node('p',{},'Diagnostic only. Matching records do not establish correct statutory pay or authorise payroll posting.'));
   if(!rows.length){reconciliationList.append(node('p',{},'No approved leave to reconcile.'));return;}
   for(const x of rows){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},x.employee+' — '+x.leave_type));
     item.append(node('p',{},x.date_from+' to '+x.date_to));
     item.append(node('p',{},'Recorded leave balance (hours): '+(x.balance_hours==null?'not available':x.balance_hours)));
     item.append(node('p',{},'Statutory entitlement records: '+x.statutory_entitlement_records));
     item.append(node('p',{},'Overlapping payroll periods: '+x.payroll_period_matches));
     item.append(node('p',{},'Historical employee payroll records: '+x.payroll_employee_history_records));
     item.append(node('p',{},'Existing leave transactions in date range: '+x.existing_leave_transactions));
     item.append(node('p',{},'Payroll posting: BLOCKED — requires calculation and duplicate-posting verification.'));
     reconciliationList.append(item);
   }
 }
 async function loadFixtures(){
   const {data,error}=await client.rpc('v6244_manager_leave_fixture_preview');
   if(destroyed)return;
   fixtureList.replaceChildren();
   if(error){fixtureList.append(node('p',{},'Test data unavailable: '+error.message));return;}
   fixtureList.append(node('p',{},'HYPOTHETICAL TEST DATA ONLY — not actual employee earnings or balances. No payroll posting.'));
   for(const x of (Array.isArray(data)?data:[])){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},x.employee+' — '+x.leave_type+' (test scenario)'));
     item.append(node('p',{},'Hypothetical available leave: '+x.available_days+' days; test period: '+x.pay_period_from+' to '+x.pay_period_to));
     if(x.owp_weekly!=null)item.append(node('p',{},'Hypothetical weekly OWP: $'+x.owp_weekly+'; AWE: $'+x.awe_weekly));
     if(x.rdp_daily!=null)item.append(node('p',{},'Hypothetical daily RDP: $'+x.rdp_daily+'; ADP: $'+x.adp_daily));
     item.append(node('p',{},'Payroll posting: DISABLED.'));
     fixtureList.append(item);
   }
 }
 async function loadCalculationTests(){
   const {data,error}=await client.rpc('v6245_manager_leave_calculation_test_preview');
   if(destroyed)return;
   calculationList.replaceChildren();
   if(error){calculationList.append(node('p',{},'Calculation test unavailable: '+error.message));return;}
   calculationList.append(node('p',{},'HYPOTHETICAL RATES ONLY. No certified statutory payment, leave deduction or payroll posting.'));
   for(const x of (Array.isArray(data)?data:[])){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},x.employee+' — '+x.leave_type));
     item.append(node('p',{},'Simulated method: '+x.selected_method));
     item.append(node('p',{},'Hypothetical '+(x.selected_method.endsWith('WEEKLY')?'weekly':'daily')+' rate: $'+x.hypothetical_rate));
     item.append(node('p',{},x.note));
     item.append(node('p',{},'Calculation test records for this request: '+x.duplicate_test_records+' (unique approval ID).'));
     item.append(node('p',{},'Payroll posting: DISABLED.'));
     calculationList.append(item);
   }
 }
 async function loadAutomatedChecks(){
   const {data,error}=await client.rpc('v6246_manager_leave_automated_checks');
   if(destroyed)return;
   checksList.replaceChildren();
   if(error){checksList.append(node('p',{},'Scenario checks unavailable: '+error.message));return;}
   const checks=Array.isArray(data)?data:[];
   checksList.append(node('p',{},'SIMULATED CHECKS ONLY. These do not certify statutory pay or authorise payroll posting.'));
   checksList.append(node('p',{},checks.filter(x=>x.passed).length+' of '+checks.length+' scenario checks passed.'));
   for(const x of checks){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},(x.passed?'PASS — ':'FAIL — ')+x.name));
     item.append(node('p',{},x.note));
     if(!x.passed)item.append(node('p',{},'Expected: '+x.expected+'; actual: '+x.actual));
     checksList.append(item);
   }
 }
 async function loadTransactionTests(){
   const {data,error}=await client.rpc('v6247_manager_leave_transaction_safety_tests');
   if(destroyed)return;
   transactionList.replaceChildren();
   if(error){transactionList.append(node('p',{},'Temporary transaction tests unavailable: '+error.message));return;}
   transactionList.append(node('p',{},'ISOLATED SIMULATION ONLY. Uses a temporary ledger; no payroll transactions, payslips or real leave balances are changed.'));
   if(!data?.available){transactionList.append(node('p',{},data?.message||'No approved leave available.'));return;}
   const checks=Array.isArray(data.tests)?data.tests:[];
   transactionList.append(node('p',{},checks.filter(x=>x.passed).length+' of '+checks.length+' temporary transaction checks passed.'));
   for(const x of checks){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},(x.passed?'PASS — ':'FAIL — ')+x.name));
     item.append(node('p',{},x.note));
     transactionList.append(item);
   }
 }
 async function loadIntegrationReadiness(){
   const {data,error}=await client.rpc('v6249_manager_leave_integration_readiness');
   if(destroyed)return;
   readinessList.replaceChildren();
   if(error){readinessList.append(node('p',{},'Integration readiness unavailable: '+error.message));return;}
   readinessList.append(node('p',{},'READ-ONLY MAPPING. This does not change pay runs, payslips, balances, leave transactions or accounting.'));
   const rows=Array.isArray(data)?data:[];
   if(!rows.length){readinessList.append(node('p',{},'No approved leave requests to review.'));return;}
   for(const x of rows){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},x.employee+' — '+x.leave_type));
     item.append(node('p',{},x.from+' to '+x.to+' · '+x.quantity+' '+x.unit));
     item.append(node('p',{},'Matching pay runs: '+x.pay_run_matches+'; employee payroll records: '+x.employee_pay_records+'; pay lines: '+x.pay_lines));
     item.append(node('p',{},'Existing leave transactions in range: '+x.leave_transactions+'; balance record: '+(x.leave_balance_present?'present':'missing')));
     item.append(node('p',{},'Pending: statutory pay rate, entitlement, payslip, accounting and idempotent posting verification.'));
     item.append(node('p',{},'Payroll integration: BLOCKED — read-only.'));
     readinessList.append(item);
   }
 }
 async function loadStatutoryFramework(){
  const {data,error}=await client.rpc('v6250_manager_leave_statutory_framework_preview');
  if(destroyed)return;
  frameworkList.replaceChildren();
  if(error){frameworkList.append(node('p',{},'Framework unavailable: '+error.message));return;}
  frameworkList.append(node('p',{},'SYNTHETIC EARNINGS ONLY. No actual earnings, statutory payment or payroll posting.'));
  for(const x of (Array.isArray(data)?data:[])){
   const item=node('div',{class:'draft-item'});
   item.append(node('strong',{},x.employee+' — '+x.leave_type));
   item.append(node('p',{},'Sample weeks: '+x.weeks_of_sample_earnings+'; invented gross earnings NZD '+x.sample_total_gross));
   item.append(node('p',{},'Illustrative AWE NZD '+x.sample_awe_weekly+' per week.'));
   if(x.illustrative_higher_weekly_rate!=null)item.append(node('p',{},'Illustrative OWP NZD '+x.illustrative_owp_weekly+'; higher weekly comparison NZD '+x.illustrative_higher_weekly_rate));
   else item.append(node('p',{},'Illustrative RDP NZD '+x.illustrative_rdp_daily+' per day; ADP NZD '+x.illustrative_adp_daily+' per day.'));
   item.append(node('p',{},'Sample entitlement '+x.sample_entitlement_days+' days; sufficiency: '+(x.sample_balance_sufficient?'yes':'not established')));
   item.append(node('p',{},x.caveat));
   item.append(node('p',{},'Statutory verification PENDING. Payroll posting BLOCKED.'));
   frameworkList.append(item);
  }
 }
 async function loadIntegrationStage(){
  const {data,error}=await client.rpc('v6251_manager_leave_integration_stage_preview');
  if(destroyed)return;
  stageList.replaceChildren();
  if(error){stageList.append(node('p',{},'Integration stage unavailable: '+error.message));return;}
  stageList.append(node('p',{},'ISOLATED STAGING ONLY. No payroll, balance, payslip or accounting records are posted.'));
  for(const x of (Array.isArray(data)?data:[])){
   const item=node('div',{class:'draft-item'});
   item.append(node('strong',{},x.employee+' — '+x.leave_type));
   item.append(node('p',{},x.leave_from+' to '+x.leave_to+' · '+x.quantity+' '+x.unit));
   item.append(node('p',{},'Payroll line: '+x.payroll.status+'; statutory calculation missing.'));
   item.append(node('p',{},'Leave balance: '+x.balance.status+'; hours conversion unverified.'));
   item.append(node('p',{},'Payslip: '+x.payslip.status+'; PAYE and net pay not calculated.'));
   item.append(node('p',{},'Accounting: '+x.accounting.status+'; accounts and amounts not mapped.'));
   item.append(node('p',{},'Posting: DISABLED. No financial or leave records changed.'));
   stageList.append(item);
  }
 }
 async function loadIntegrationGateAudit(){
  const {data,error}=await client.rpc('v6252_manager_leave_end_to_end_gate_audit');
  if(destroyed)return;
  gateList.replaceChildren();
  if(error){gateList.append(node('p',{},'Integration audit unavailable: '+error.message));return;}
  gateList.append(node('p',{},'READ-ONLY GATE AUDIT. Passing these checks is NOT an end-to-end payroll test. Posting remains disabled.'));
  for(const x of (Array.isArray(data)?data:[])){
   const item=node('div',{class:'draft-item'});
   item.append(node('strong',{},x.employee+' — '+x.leave_type));
   const checks=Array.isArray(x.checks)?x.checks:[];
   item.append(node('p',{},checks.filter(v=>v.passed).length+' of '+checks.length+' staging safety checks passed.'));
   for(const v of checks)item.append(node('p',{},(v.passed?'PASS: ':'FAIL: ')+v.name));
   item.append(node('strong',{},'Outstanding integration blockers:'));
   for(const blocker of (Array.isArray(x.blockers)?x.blockers:[]))item.append(node('p',{},'Pending: '+blocker));
   item.append(node('p',{},'Real payroll posting: BLOCKED.'));
   gateList.append(item);
  }
 }
 async function loadHistory(){
   const {data,error}=await client.rpc('v6238_manager_leave_draft_history');
   if(destroyed)return;
   historyList.replaceChildren();
   if(error){historyList.append(node('p',{},'Unable to load activity: '+error.message));return;}
   const rows=Array.isArray(data)?data:[];
   if(!rows.length){historyList.append(node('p',{},'No draft activity yet.'));return;}
   for(const a of rows){
     const entry=node('p',{class:'history-entry'},(a.action==='create'?'Created':a.action==='update'?'Edited':'Deleted')+' draft · '+new Date(a.created_at).toLocaleString());
     historyList.append(entry);
   }
 }
 async function loadDrafts(){
   const {data,error}=await client.rpc('v6237_manager_leave_drafts_read');
   if(destroyed)return;
   draftList.replaceChildren();
   if(error){draftList.append(node('p',{},'Unable to load drafts: '+error.message));return;}
   const drafts=Array.isArray(data)?data:[];
   heading.textContent='Saved drafts ('+drafts.length+')';
   if(!drafts.length){draftList.append(node('p',{},'No saved drafts yet.'));return;}
   for(const d of drafts){
     const item=node('div',{class:'draft-item'});
     item.append(node('strong',{},d.employee_name+' — '+d.leave_type));
     item.append(node('p',{},d.date_from+' to '+d.date_to+' · '+d.quantity+' '+d.unit));
     const edit=node('button',{type:'button'},'Edit');
     edit.addEventListener('click',()=>{
       editing=d.id;employee.value=d.employee_id;leave.value=d.leave_type_id;
       from.value=d.date_from;to.value=d.date_to;qty.value=d.quantity;unit.value=d.unit;
       save.textContent='Update draft';cancel.hidden=false;
       form.scrollIntoView({behavior:'smooth',block:'start'});
     });
     const del=node('button',{type:'button'},'Delete');
     del.style.marginLeft='8px';
     del.addEventListener('click',async()=>{
       if(del.disabled||save.disabled)return;
       if(!window.confirm('Permanently delete this draft? This cannot be undone.'))return;
       edit.disabled=true;del.disabled=true;save.disabled=true;
       const {error}=await client.rpc('v6237_manager_leave_draft_delete',{p_id:d.id});
       if(error){notice.textContent='Delete failed: '+error.message;edit.disabled=false;del.disabled=false;save.disabled=false;return;}
       if(editing===d.id)cancel.click();
       notice.textContent='Draft deleted; audit entry retained.';
       try{await loadDrafts();await loadApprovals();await loadPreview();await loadValidation();await loadReconciliation();await loadFixtures();await loadCalculationTests();await loadAutomatedChecks();await loadTransactionTests();await loadIntegrationReadiness();await loadStatutoryFramework();await loadIntegrationStage();await loadIntegrationGateAudit();await loadHistory();}finally{save.disabled=false;}
     });
     const submit=node('button',{type:'button'},'Submit for approval');submit.style.marginLeft='8px';
     submit.addEventListener('click',async()=>{
       if(save.disabled||submit.disabled)return;
       if(!window.confirm('Submit this draft? It will be locked against edits and deletion.'))return;
       save.disabled=true;submit.disabled=true;
       try{await approvalAction(d.id,'submit');if(editing===d.id)cancel.click();}
       catch(err){notice.textContent='Submission failed: '+(err.message||'Unknown error');submit.disabled=false;}
       finally{save.disabled=false;}
     });
     item.append(edit,del,submit);draftList.append(item);
   }
 }

 let destroyed=false;
 async function init(){
   try{
     const [employeesRes,leaveRes]=await Promise.all([
       client.from('payroll_employees').select('id,first_name,last_name').eq('archived',false).in('employment_status',['active','on_leave']).order('first_name').limit(500),
       client.from('payroll_leave_types').select('id,name').eq('archived',false).order('name').limit(200)
     ]);
     if(employeesRes.error)throw employeesRes.error;
     if(leaveRes.error)throw leaveRes.error;
     if(destroyed)return;
     const employees=employeesRes.data||[],types=leaveRes.data||[];
     for(const e of employees)employee.append(node('option',{value:e.id},[e.first_name,e.last_name].filter(Boolean).join(' ')));
     for(const t of types)leave.append(node('option',{value:t.id},t.name));
     if(!employees.length||!types.length){notice.textContent='No eligible employees or leave types are available.';return;}
     form.hidden=false;notice.textContent='Draft only — this does not approve leave or change payroll balances.';
     await loadDrafts();await loadApprovals();await loadPreview();await loadValidation();await loadReconciliation();await loadFixtures();await loadCalculationTests();await loadAutomatedChecks();await loadTransactionTests();await loadIntegrationReadiness();await loadStatutoryFramework();await loadIntegrationStage();await loadIntegrationGateAudit();await loadHistory();
   }catch(err){if(!destroyed)notice.textContent='Unable to load leave form: '+(err.message||'Access denied');}
 }
 form.addEventListener('submit',async event=>{
   event.preventDefault();
   if(save.disabled)return;
   const q=Number(qty.value);
   if(!validDate(from.value)||!validDate(to.value)||to.value<from.value||!Number.isFinite(q)||q<=0||q>10000||!/^\d+(?:\.\d{1,2})?$/.test(qty.value)){
     notice.textContent='Enter valid dates and a positive quantity (up to two decimals).';return;
   }
   save.disabled=true;notice.textContent='Saving draft…';
   try{
     const {error}=await client.rpc(editing?'v6237_manager_leave_draft_update':'v6236_manager_leave_draft_create',{
       ...(editing?{p_id:editing}:{}),p_employee:employee.value,p_leave_type:leave.value,p_from:from.value,
       p_to:to.value,p_quantity:q,p_unit:unit.value
     });
     if(error)throw error;
     notice.textContent='Leave draft saved in isolated testing. No payroll balances were changed.';
     cancel.click();await loadDrafts();await loadApprovals();await loadHistory();
   }catch(err){notice.textContent='Draft not saved: '+(err.message||'Access denied');}
   finally{if(!destroyed)save.disabled=false;}
 });
 init();
 return {destroy(){destroyed=true;target.replaceChildren();}};
}
root.FrindlyManagerLeaveDrafts=Object.freeze({mount});
})(typeof window!=='undefined'?window:globalThis);
