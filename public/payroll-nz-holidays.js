(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.FinloNZHolidays=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const MODES=new Set(['include','exclude','conditional','needs_confirmation']);
  const round2=n=>Math.round((Number(n)+Number.EPSILON)*100)/100;
  const finite=n=>Number.isFinite(Number(n));
  const iso=d=>{if(!d)return null;const x=d instanceof Date?new Date(d):new Date(String(d)+'T00:00:00Z');return Number.isNaN(x.getTime())?null:x.toISOString().slice(0,10)};
  const addMonths=(date,months)=>{const d=new Date(String(date)+'T00:00:00Z');if(Number.isNaN(d.getTime()))return null;const day=d.getUTCDate();d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+months);const last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(day,last));return d.toISOString().slice(0,10)};
  const addDays=(date,days)=>{const d=new Date(String(date)+'T00:00:00Z');if(Number.isNaN(d.getTime()))return null;d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10)};
  const daysInclusive=(a,b)=>{const x=new Date(String(a)+'T00:00:00Z'),y=new Date(String(b)+'T00:00:00Z');return Math.floor((y-x)/86400000)+1};
  const wholeOrPartWeeks=(a,b)=>Math.max(1,Math.ceil(daysInclusive(a,b)/7));
  function need(reasons,code,message){reasons.push({code,message})}
  function validateEntries(entries,modeField,reasons,label,{requireHistory=false}={}){
    if(requireHistory&&(!Array.isArray(entries)||!entries.length)){need(reasons,'missing_earnings_history',`${label} earnings history is required.`);return 0}
    let total=0;
    for(const e of entries||[]){
      const amount=Number(e.amount),earningDate=iso(e.earning_date||e.date);
      if(!Number.isFinite(amount)){need(reasons,'invalid_amount',`${label} contains an invalid earning amount.`);continue}
      if(amount<0&&e.valid_correction!==true){need(reasons,'negative_earning_requires_confirmation',`${label} contains a negative earning that is not explicitly identified as a valid correction.`);continue}
      if(!earningDate){need(reasons,'invalid_earning_date',`${label} contains an earning with a missing or invalid earnings date.`);continue}
      const mode=e[modeField];
      if(!MODES.has(mode)){need(reasons,'missing_classification',`${e.description||e.statutory_earning_code||'An earning'} needs ${label} classification.`);continue}
      if(mode==='conditional'||mode==='needs_confirmation'){need(reasons,'classification_confirmation',`${e.description||e.statutory_earning_code||'An earning'} needs employer confirmation for ${label}.`);continue}
      if(mode==='include')total+=amount;
    }
    return total;
  }
  function validateReimbursementSemantics(e,reasons){
    if(e?.holidays_gross_earnings_mode==='exclude'||e?.owp_inclusion_mode==='exclude'){
      if(e?.statutory_earning_code==='reimbursement'&&e?.qualifying_reimbursement!==true){
        need(reasons,'reimbursement_semantics_confirmation','A reimbursement may be excluded only after confirming it genuinely reimburses qualifying employment-related costs.');
      }
    }
  }
  function selectEffectiveRules(rows,date){
    const d=iso(date); if(!d)return {};
    const effective=(rows||[]).filter(r=>r&&r.active!==false&&String(r.country_code||'').toUpperCase()==='NZ'&&r.rule_type==='holidays'&&r.effective_from<=d&&(!r.effective_to||r.effective_to>=d));
    const latest={};
    for(const r of effective.sort((a,b)=>String(a.effective_from).localeCompare(String(b.effective_from))))latest[r.rule_key]=r.numeric_value!=null?Number(r.numeric_value):(r.text_value!=null?r.text_value:r.json_value);
    return latest;
  }
  function classifyEarnings(rows,payItems){
    const map=new Map((payItems||[]).map(i=>[i.id,i]));
    return (rows||[]).map(row=>{const item=map.get(row.pay_item_id)||{};return {...row,statutory_earning_code:row.statutory_earning_code??item.statutory_earning_code??null,holidays_gross_earnings_mode:row.holidays_gross_earnings_mode??item.holidays_gross_earnings_mode??'needs_confirmation',owp_inclusion_mode:row.owp_inclusion_mode??item.owp_inclusion_mode??'needs_confirmation',classification_notes:row.classification_notes??item.classification_notes??null}});
  }
  function buildCalculationInput({rules,holidayStart,lastPayPeriodEnd,employmentStart,owpMethod,ordinaryWeeklyPayAmount,ordinaryWeeklyPayEvidence,employmentAgreementWeeklyRate,actualOwpComparator,normalPayPeriodDays=null,normalPayPeriodBasis=null,earnings=[],owpFormulaEarnings=null,aweEarnings=null,payItems=[],unpaidLeaveAdjustmentRequired=false,aweExcludedUnpaidWeeks=null}){
    const classifiedAll=classifyEarnings(earnings,payItems);
    const classifiedOwp=classifyEarnings(owpFormulaEarnings==null?earnings:owpFormulaEarnings,payItems);
    const classifiedAwe=classifyEarnings(aweEarnings==null?earnings:aweEarnings,payItems);
    return {rules,holidayStart,lastPayPeriodEnd,employmentStart,owpMethod,ordinaryWeeklyPayAmount,ordinaryWeeklyPayEvidence,employmentAgreementWeeklyRate,actualOwpComparator,normalPayPeriodDays,normalPayPeriodBasis,owpFormulaEarnings:classifiedOwp,aweEarnings:classifiedAwe,classifiedEarnings:classifiedAll,unpaidLeaveAdjustmentRequired,aweExcludedUnpaidWeeks};
  }
  function buildStoragePayload(result,input,context={}){
    return {business_id:context.businessId,employee_id:context.employeeId,leave_type_id:context.leaveTypeId||null,leave_transaction_id:context.leaveTransactionId||null,pay_run_id:context.payRunId||null,statutory_leave_code:'annual_holiday',calculation_type:'annual_holiday',relevant_from:input.holidayStart,relevant_to:input.holidayEnd||input.holidayStart,rule_version:'V61.73-P3.2',rules_snapshot:context.rulesSnapshot||null,input_snapshot:{...(input.inputSnapshot||{}),engine_input:{holidayStart:input.holidayStart,lastPayPeriodEnd:input.lastPayPeriodEnd,employmentStart:input.employmentStart,owpMethod:input.owpMethod,ordinaryWeeklyPayEvidence:input.ordinaryWeeklyPayEvidence||null,unpaidLeaveAdjustmentRequired:!!input.unpaidLeaveAdjustmentRequired,aweExcludedUnpaidWeeks:input.aweExcludedUnpaidWeeks??null,normalPayPeriodDays:input.normalPayPeriodDays??null,normalPayPeriodBasis:input.normalPayPeriodBasis??null},calculation:result.input_snapshot||{}},owp_amount:result.owp_amount,awe_amount:result.awe_amount,owp_method:result.owp_method,awe_period_start:result.awe_period_start,awe_period_end:result.awe_period_end,awe_gross_earnings:result.awe_gross_earnings,awe_divisor:result.awe_divisor,selected_method:result.selected_method,selected_amount:result.selected_amount,confirmation_state:result.confirmation_state,explanation_snapshot:result.status==='needs_confirmation'?{title:'Annual holiday pay',status:'Needs confirmation',reasons:result.reasons}:result.explanation_snapshot};
  }
  function calculate(input){
    const reasons=[];
    const rules=input?.rules||{};
    const divisor=Number(rules.owp_formula_divisor_weeks),aweStandard=Number(rules.awe_standard_divisor_weeks),lookbackMonths=Number(rules.awe_lookback_months);
    if(!(divisor>0))need(reasons,'missing_rule','OWP formula divisor rule is unavailable.');
    if(!(aweStandard>0))need(reasons,'missing_rule','AWE standard divisor rule is unavailable.');
    if(!(lookbackMonths>0))need(reasons,'missing_rule','AWE lookback rule is unavailable.');
    if(rules.annual_holiday_payment_selection!=='greater_of_owp_awe')need(reasons,'missing_rule','Annual-holiday OWP/AWE selection rule is unavailable.');
    const lastPayPeriodEnd=iso(input?.lastPayPeriodEnd),holidayStart=iso(input?.holidayStart),employmentStart=iso(input?.employmentStart);
    if(!lastPayPeriodEnd)need(reasons,'missing_last_pay_period','Last pay-period end date is required.');
    if(!holidayStart)need(reasons,'missing_holiday_start','Annual-holiday start date is required.');
    if(!employmentStart)need(reasons,'missing_employment_start','Employee start date is required.');
    if(employmentStart&&holidayStart&&employmentStart>holidayStart)need(reasons,'employment_after_holiday_start','Employment start cannot be after annual-holiday commencement.');
    if(employmentStart&&lastPayPeriodEnd&&employmentStart>lastPayPeriodEnd)need(reasons,'employment_after_last_pay_period','Employment start cannot be after the end of the last pay period used for AWE.');
    if(lastPayPeriodEnd&&holidayStart&&lastPayPeriodEnd>=holidayStart)need(reasons,'invalid_last_pay_period_relationship','The last pay period used for annual-holiday pay must end before the annual holiday begins.');

    for(const e of [...(input?.owpFormulaEarnings||[]),...(input?.aweEarnings||[])])validateReimbursementSemantics(e,reasons);

    let owp=null,owpMethod=input?.owpMethod||null,owpInputs={};
    if(owpMethod==='ordinary_week'){
      const evidence=input?.ordinaryWeeklyPayEvidence;
      if(!finite(input.ordinaryWeeklyPayAmount)||Number(input.ordinaryWeeklyPayAmount)<0)need(reasons,'missing_ordinary_week_pay','Confirmed statutory ordinary weekly pay is required.');
      if(!evidence||evidence.confirmedByEmployer!==true||!String(evidence.basis||'').trim())need(reasons,'ordinary_week_provenance_required','Ordinary-week OWP requires employer confirmation/evidence that the amount is statutory OWP and includes applicable regular earnings.');
      if(Array.isArray(evidence?.components)){
        for(const c of evidence.components){if(!MODES.has(c.owp_inclusion_mode)||['conditional','needs_confirmation'].includes(c.owp_inclusion_mode))need(reasons,'ordinary_week_component_confirmation',`${c.description||c.statutory_earning_code||'An ordinary-week component'} needs explicit OWP treatment confirmation.`)}
      }
      if(finite(input.ordinaryWeeklyPayAmount)&&Number(input.ordinaryWeeklyPayAmount)>=0&&evidence?.confirmedByEmployer===true&&String(evidence.basis||'').trim()){owp=Number(input.ordinaryWeeklyPayAmount);owpInputs={ordinary_week_amount:owp,provenance:evidence}}
    }else if(owpMethod==='statutory_formula'){
      const formulaReasons=[];
      const normalPayPeriodDays=Number(input?.normalPayPeriodDays);
      const normalPayPeriodBasis=String(input?.normalPayPeriodBasis||'').trim();
      let formulaPeriodStart=null,formulaPeriodEnd=lastPayPeriodEnd;
      if(!Number.isInteger(normalPayPeriodDays)||normalPayPeriodDays<=0||!normalPayPeriodBasis){
        need(formulaReasons,'missing_normal_pay_period','Confirm the employee normal pay-period length and basis so the statutory OWP formula period can be established.');
      }else if(lastPayPeriodEnd){
        formulaPeriodStart=normalPayPeriodDays>28?addDays(lastPayPeriodEnd,-normalPayPeriodDays+1):addDays(lastPayPeriodEnd,-27);
      }
      const allFormula=input?.owpFormulaEarnings||[];
      if(!allFormula.length)need(formulaReasons,'missing_earnings_history','OWP earnings history is required.');
      const considered=[],outside=[];
      for(const e of allFormula){
        const d=iso(e.earning_date||e.date);
        if(!d){need(formulaReasons,'invalid_earning_date','OWP contains an earning with a missing or invalid earnings date.');continue}
        if(formulaPeriodStart&&formulaPeriodEnd&&d>=formulaPeriodStart&&d<=formulaPeriodEnd)considered.push(e);else outside.push(e);
      }
      if(allFormula.length&&formulaPeriodStart&&formulaPeriodEnd&&!considered.length)need(formulaReasons,'missing_applicable_earnings_history','No OWP earnings history falls within the statutory formula period.');
      const included=validateEntries(considered,'owp_inclusion_mode',formulaReasons,'OWP',{requireHistory:false});
      const includedEntries=considered.filter(e=>e.owp_inclusion_mode==='include');
      const excludedEntries=considered.filter(e=>e.owp_inclusion_mode==='exclude');
      reasons.push(...formulaReasons);
      owpInputs={formula_period_start:formulaPeriodStart,formula_period_end:formulaPeriodEnd,normal_pay_period_days:Number.isInteger(normalPayPeriodDays)&&normalPayPeriodDays>0?normalPayPeriodDays:null,normal_pay_period_basis:normalPayPeriodBasis||null,earnings_considered:considered.map(e=>({date:iso(e.earning_date||e.date),amount:Number(e.amount),statutory_earning_code:e.statutory_earning_code||null,owp_inclusion_mode:e.owp_inclusion_mode})),included_earnings:includedEntries.map(e=>({date:iso(e.earning_date||e.date),amount:Number(e.amount),statutory_earning_code:e.statutory_earning_code||null})),excluded_earnings:[...excludedEntries.map(e=>({date:iso(e.earning_date||e.date),amount:Number(e.amount),statutory_earning_code:e.statutory_earning_code||null,reason:'classified_exclude'})),...outside.map(e=>({date:iso(e.earning_date||e.date),amount:Number(e.amount),statutory_earning_code:e.statutory_earning_code||null,reason:'outside_formula_period'}))],included_earnings_total:round2(included),divisor,earnings_count:considered.length};
      if(divisor>0&&!formulaReasons.length)owp=included/divisor;
    }else if(owpMethod==='employment_agreement_rate'){
      if(!finite(input.employmentAgreementWeeklyRate)||Number(input.employmentAgreementWeeklyRate)<0)need(reasons,'missing_agreement_rate','Employment-agreement OWP rate is required.');
      if(!finite(input.actualOwpComparator)||Number(input.actualOwpComparator)<0)need(reasons,'missing_actual_owp','Actual statutory OWP comparator is required before an employment-agreement rate can be used.');
      if(finite(input.employmentAgreementWeeklyRate)&&finite(input.actualOwpComparator)&&Number(input.employmentAgreementWeeklyRate)>=0&&Number(input.actualOwpComparator)>=0){owp=Math.max(Number(input.employmentAgreementWeeklyRate),Number(input.actualOwpComparator));owpInputs={agreement_rate:Number(input.employmentAgreementWeeklyRate),actual_owp:Number(input.actualOwpComparator)}}
    }else need(reasons,'missing_owp_method','Confirm whether OWP is determinable as an ordinary working week or requires the statutory formula.');

    const agreementRate=Number(input?.employmentAgreementWeeklyRate);
    if(owp!=null&&owpMethod!=='employment_agreement_rate'&&Number.isFinite(agreementRate)&&agreementRate>owp){owp=agreementRate;owpInputs.employment_agreement_floor=agreementRate}

    let awe=null,aweGross=null,aweDivisor=null,awePeriodStart=null,awePeriodEnd=lastPayPeriodEnd;
    if(lastPayPeriodEnd&&employmentStart&&aweStandard>0&&lookbackMonths>0&&!(employmentStart>lastPayPeriodEnd)&&!(lastPayPeriodEnd>=holidayStart)){
      const standardStart=addDays(addMonths(lastPayPeriodEnd,-lookbackMonths),1);
      awePeriodStart=employmentStart>standardStart?employmentStart:standardStart;
      const earningsReasons=[];
      const allAwe=input?.aweEarnings||[];
      if(!allAwe.length)need(earningsReasons,'missing_earnings_history','AWE earnings history is required.');
      const periodEntries=[];
      for(const e of allAwe){
        const d=iso(e.earning_date||e.date);
        if(!d){need(earningsReasons,'invalid_earning_date','AWE contains an earning with a missing or invalid earnings date.');continue}
        if(d<awePeriodStart||d>awePeriodEnd)continue;
        periodEntries.push(e);
      }
      if(allAwe.length&&!periodEntries.length)need(earningsReasons,'missing_applicable_earnings_history','No earnings history falls within the applicable AWE period.');
      aweGross=validateEntries(periodEntries,'holidays_gross_earnings_mode',earningsReasons,'Holidays Act gross earnings');
      reasons.push(...earningsReasons);
      const underFullPeriod=employmentStart>standardStart;
      aweDivisor=underFullPeriod?wholeOrPartWeeks(employmentStart,awePeriodEnd):aweStandard;
      if(input?.unpaidLeaveAdjustmentRequired===true&&!finite(input?.aweExcludedUnpaidWeeks))need(reasons,'missing_unpaid_leave_adjustment','Confirm the number of whole or part weeks that must be excluded from the AWE divisor for qualifying unpaid leave.');
      if(finite(input?.aweExcludedUnpaidWeeks)){
        const excluded=Number(input.aweExcludedUnpaidWeeks);
        if(excluded<0)need(reasons,'negative_unpaid_leave_weeks','Excluded unpaid-leave weeks cannot be negative.');
        else if(excluded>=aweDivisor)need(reasons,'excluded_unpaid_weeks_exceed_divisor','Excluded unpaid-leave weeks must be less than the applicable AWE divisor.');
        else aweDivisor-=excluded;
      }
      if(aweDivisor>0&&!earningsReasons.length&&!reasons.some(r=>['negative_unpaid_leave_weeks','excluded_unpaid_weeks_exceed_divisor'].includes(r.code)))awe=aweGross/aweDivisor;
    }

    const snapshot={owp:owpInputs,awe:{period_start:awePeriodStart,period_end:awePeriodEnd,gross_earnings:aweGross==null?null:round2(aweGross),divisor:aweDivisor,earnings_count:(input?.aweEarnings||[]).length},validation:{holiday_start:holidayStart,last_pay_period_end:lastPayPeriodEnd,employment_start:employmentStart}};
    if(reasons.length)return {status:'needs_confirmation',confirmation_state:'needs_confirmation',reasons,owp_amount:owp==null?null:round2(owp),awe_amount:awe==null?null:round2(awe),owp_method:owpMethod,awe_period_start:awePeriodStart,awe_period_end:awePeriodEnd,awe_gross_earnings:aweGross==null?null:round2(aweGross),awe_divisor:aweDivisor,selected_method:null,selected_amount:null,input_snapshot:snapshot};
    const selectedMethod=owp>=awe?'owp':'awe',selectedAmount=Math.max(owp,awe);
    return {status:'calculated',confirmation_state:'confirmed',reasons:[],owp_amount:round2(owp),awe_amount:round2(awe),owp_method:owpMethod,awe_period_start:awePeriodStart,awe_period_end:awePeriodEnd,awe_gross_earnings:round2(aweGross),awe_divisor:aweDivisor,selected_method:selectedMethod,selected_amount:round2(selectedAmount),input_snapshot:snapshot,explanation_snapshot:{title:'Annual holiday pay',owp:round2(owp),awe:round2(awe),applied:selectedMethod,holiday_payment:round2(selectedAmount)}};
  }
  return {calculate,wholeOrPartWeeks,selectEffectiveRules,classifyEarnings,buildCalculationInput,buildStoragePayload};
});
