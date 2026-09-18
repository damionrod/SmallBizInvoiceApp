(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.FinloNZStatutoryLeave=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const round2=n=>Math.round((Number(n)+Number.EPSILON)*100)/100;
  const finite=n=>Number.isFinite(Number(n));
  const iso=v=>{if(!v)return null;const d=new Date(String(v)+'T00:00:00Z');return Number.isNaN(d.getTime())?null:d.toISOString().slice(0,10)};
  const addDays=(v,n)=>{const d=new Date(String(v)+'T00:00:00Z');if(Number.isNaN(d.getTime()))return null;d.setUTCDate(d.getUTCDate()+n);return d.toISOString().slice(0,10)};
  const addMonths=(v,n)=>{const d=new Date(String(v)+'T00:00:00Z');if(Number.isNaN(d.getTime()))return null;const day=d.getUTCDate();d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+n);const last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(day,last));return d.toISOString().slice(0,10)};
  const daysBetween=(a,b)=>Math.floor((new Date(String(b)+'T00:00:00Z')-new Date(String(a)+'T00:00:00Z'))/86400000);
  const need=(r,code,message)=>r.push({code,message});
  const getRule=(rules,key)=>rules&&Object.prototype.hasOwnProperty.call(rules,key)?rules[key]:null;
  const modeOk=m=>['include','exclude','conditional','needs_confirmation'].includes(m);

  function selectEffectiveRules(rows,date){
    const d=iso(date),out={}; if(!d)return out;
    for(const r of rows||[]){if(!r||r.active===false||String(r.country_code||'').toUpperCase()!=='NZ'||r.effective_from>d||(r.effective_to&&r.effective_to<d))continue;const old=out['__'+r.rule_key];if(!old||old.effective_from<r.effective_from){out['__'+r.rule_key]=r;out[r.rule_key]=r.numeric_value!=null?Number(r.numeric_value):r.text_value!=null?r.text_value:r.json_value}}
    return out;
  }

  function validateWorkPattern(pattern){
    const errors=[]; if(!pattern)return {valid:false,errors:['missing_work_pattern']};
    const type=pattern.pattern_type||pattern.type, j=pattern.pattern_json||pattern;
    if(!['fixed_weekly','rotating','roster','variable','other'].includes(type))errors.push('invalid_pattern_type');
    if(type==='fixed_weekly'&&!Array.isArray(j.weekdays))errors.push('fixed_weekly_requires_weekdays');
    if(type==='rotating'&&(!iso(j.cycle_start)||!Number.isInteger(Number(j.cycle_days))||Number(j.cycle_days)<1||!Array.isArray(j.working_cycle_days)))errors.push('rotating_requires_cycle');
    if(type==='roster'&&!Array.isArray(j.shifts))errors.push('roster_requires_shifts');
    return {valid:!errors.length,errors};
  }

  function resolveOWD(input){
    const reasons=[],date=iso(input?.date); if(!date)need(reasons,'invalid_leave_date','A valid leave date is required.');
    if(input?.employmentStart&&date&&input.employmentStart>date)need(reasons,'leave_before_employment','Leave date is before employment started.');
    if(input?.employmentEnd&&date&&input.employmentEnd<date)return {status:'determined',determination:'no',method:'system_supported',reasons,evidence_snapshot:{date,reason:'employment_ended'}};
    if(input?.employerConfirmation&&['yes','no'].includes(input.employerConfirmation.determination))return {status:'determined',determination:input.employerConfirmation.determination,method:'employer_determined',reasons,evidence_snapshot:{date,employer_confirmation:input.employerConfirmation,evidence:input.evidence||{}}};
    const p=input?.workPattern,check=validateWorkPattern(p); if(!check.valid){need(reasons,'owd_evidence_required','Effective work-pattern evidence is insufficient to determine OWD.');return {status:'needs_confirmation',determination:'needs_confirmation',method:'system_supported',reasons,evidence_snapshot:{date,pattern_errors:check.errors,evidence:input?.evidence||{}}}}
    const type=p.pattern_type||p.type,j=p.pattern_json||p;
    if(p.effective_from&&date<p.effective_from||p.effective_to&&date>p.effective_to){need(reasons,'work_pattern_not_effective','The work pattern does not cover the leave date.');return {status:'needs_confirmation',determination:'needs_confirmation',method:'system_supported',reasons,evidence_snapshot:{date,pattern_id:p.id||null}}}
    let determination='needs_confirmation',basis='';
    if(type==='fixed_weekly'){const wd=new Date(date+'T00:00:00Z').getUTCDay();determination=j.weekdays.map(Number).includes(wd)?'yes':'no';basis='effective_fixed_weekly_pattern'}
    else if(type==='rotating'){const idx=((daysBetween(j.cycle_start,date)%Number(j.cycle_days))+Number(j.cycle_days))%Number(j.cycle_days);determination=j.working_cycle_days.map(Number).includes(idx)?'yes':'no';basis='effective_rotating_pattern'}
    else if(type==='roster'){const shifts=j.shifts.filter(s=>iso(s.date)===date);if(shifts.some(s=>s.confirmed!==false)){determination='yes';basis='confirmed_roster_shift'}else{need(reasons,'roster_absence_not_conclusive','No confirmed roster shift does not by itself prove the day was not an OWD.')}}
    else {need(reasons,'variable_pattern_requires_confirmation','Variable/other work patterns require date-specific evidence or employer confirmation.')}
    return {status:determination==='needs_confirmation'?'needs_confirmation':'determined',determination,method:'system_supported',reasons,evidence_snapshot:{date,pattern_id:p.id||null,pattern_type:type,basis,evidence:input?.evidence||{}}};
  }

  function calculateRDP(input){
    const reasons=[],components=[],date=iso(input?.date); if(input?.owd?.determination!=='yes')need(reasons,'owd_yes_required','RDP requires a confirmed Otherwise Working Day.');
    if(!Array.isArray(input?.expectedEarnings)||!input.expectedEarnings.length)need(reasons,'rdp_earnings_required','Day-specific expected earnings are required for RDP.');
    let total=0;
    for(const e of input?.expectedEarnings||[]){const amount=Number(e.amount),mode=e.rdp_inclusion_mode;if(!finite(amount)||amount<0){need(reasons,'invalid_rdp_amount','RDP contains an invalid expected earning amount.');continue}if(!modeOk(mode)){need(reasons,'rdp_classification_required',`${e.description||'An earning'} needs RDP classification.`);continue}if(mode==='conditional'||mode==='needs_confirmation'){need(reasons,'rdp_component_confirmation',`${e.description||'An earning'} needs day-specific RDP confirmation.`);components.push({...e,included:null});continue}if(mode==='exclude'&&e.statutory_earning_code==='reimbursement'&&e.qualifying_reimbursement!==true){need(reasons,'reimbursement_confirmation','Reimbursement exclusion requires genuine qualifying reimbursement evidence.');components.push({...e,included:null});continue}const included=mode==='include';if(included)total+=amount;components.push({...e,included})}
    if(input?.specialAgreementRate!=null){if(!finite(input.specialAgreementRate)||Number(input.specialAgreementRate)<0)need(reasons,'invalid_special_rdp_rate','Special agreement RDP rate is invalid.');else total=Math.max(total,Number(input.specialAgreementRate))}
    return {status:reasons.length?'needs_confirmation':'calculated',amount:reasons.length?null:round2(total),reasons,input_snapshot:{date,components,special_agreement_rate:input?.specialAgreementRate??null}};
  }

  function calculateADP(input){
    const reasons=[],date=iso(input?.date),trigger=input?.trigger;
    const permitted=Array.isArray(input?.permittedTriggers)?input.permittedTriggers:[];if(!permitted.length)need(reasons,'adp_trigger_rules_required','Effective permitted ADP trigger rules are required.');else if(!permitted.includes(trigger))need(reasons,'adp_trigger_required','ADP requires a permitted statutory trigger for the applicable effective-dated rule version.');
    const end=iso(input?.lastPayPeriodEnd||input?.lookbackEnd);let start=null;const weeks=Number(input?.lookbackWeeks||52);if(end&&finite(weeks)&&weeks>0){start=addDays(end,-(weeks*7-1));const emp=iso(input?.employmentStart);if(emp&&emp>start)start=emp}if(!start||!end||start>end)need(reasons,'adp_period_required','The immediately preceding pay-period end and statutory ADP lookback are required.');
    if(!Array.isArray(input?.earnings)||!input.earnings.length)need(reasons,'adp_earnings_required','ADP gross-earnings history is required.');
    let gross=0;const included=[],excluded=[];
    for(const e of input?.earnings||[]){const d=iso(e.date||e.earning_date),amount=Number(e.amount),mode=e.holidays_gross_earnings_mode;if(!d||!finite(amount)||amount<0&&!e.valid_correction){need(reasons,'invalid_adp_earning','ADP history contains an invalid earning.');continue}if(d<start||d>end){excluded.push({...e,reason:'outside_adp_period'});continue}if(!modeOk(mode)){need(reasons,'adp_classification_required',`${e.description||'An earning'} needs Holidays Act gross-earnings classification.`);continue}if(mode==='conditional'||mode==='needs_confirmation'){need(reasons,'adp_classification_confirmation',`${e.description||'An earning'} needs gross-earnings confirmation.`);continue}if(mode==='include'){gross+=amount;included.push(e)}else excluded.push({...e,reason:'classified_exclude'})}
    if(!Array.isArray(input?.qualifyingDays)||!input.qualifyingDays.length)need(reasons,'adp_day_history_required','Whole/part-day work and paid-leave history is required for ADP.');
    const dayMap=new Map();for(const d0 of input?.qualifyingDays||[]){const d=iso(d0.date);if(!d||d<start||d>end)continue;if(d0.qualifies!==true)continue;dayMap.set(d,{date:d,basis:d0.basis||'worked_or_paid_leave'})}
    const divisor=dayMap.size;if(divisor<=0)need(reasons,'adp_divisor_required','No qualifying whole/part days can be established for ADP.');
    return {status:reasons.length?'needs_confirmation':'calculated',amount:reasons.length?null:round2(gross/divisor),gross_earnings:round2(gross),divisor,reasons,input_snapshot:{trigger,period_start:start,period_end:end,included_earnings:included,excluded_earnings:excluded,qualifying_days:[...dayMap.values()]}};
  }

  function eligibility(input,rules){
    const reasons=[],date=iso(input?.date),start=iso(input?.employmentStart),eligibilityKey=input?.leaveCode==='family_violence_leave'?'family_violence_eligibility_months':'statutory_leave_eligibility_months',eligibilityRule=getRule(rules,eligibilityKey),months=Number(eligibilityRule);
    if(!date||!start||eligibilityRule==null||!finite(months))need(reasons,'eligibility_evidence_required','Employment start date and effective eligibility rule are required.');
    if(!reasons.length&&addMonths(start,months)<=date)return {status:'eligible',basis:'continuous_employment',reasons};
    const h=input?.workTestHistory;if(!h){need(reasons,'work_test_history_required','Six-month work-test history is required where continuous-employment eligibility is not established.');return {status:'needs_confirmation',reasons}}
    const avg=Number(h.average_hours_per_week),weekly=Number(h.minimum_hours_each_week),monthly=Number(h.minimum_hours_each_month),avgRule=Number(getRule(rules,'statutory_leave_work_test_average_hours_per_week')),weekRule=Number(getRule(rules,'statutory_leave_work_test_min_hours_each_week')),monthRule=Number(getRule(rules,'statutory_leave_work_test_min_hours_each_month'));
    if(![avg,weekly,monthly,avgRule,weekRule,monthRule].every(finite)){need(reasons,'work_test_history_required','Complete work-test evidence is required.');return {status:'needs_confirmation',reasons}}
    const ok=avg>=avgRule&&(weekly>=weekRule||monthly>=monthRule);return ok?{status:'eligible',basis:'work_test',reasons}:{status:'not_eligible',basis:'work_test',reasons};
  }

  function entitlement(input,rules){
    const code=input.leaveCode,date=iso(input.date),reasons=[];
    if(code==='sick_leave'){const grant=Number(getRule(rules,'sick_leave_grant_days')),cap=Number(getRule(rules,'sick_leave_current_entitlement_cap_days')),carryRule=getRule(rules,'sick_leave_carry_forward_enabled');if(!finite(grant)||!finite(cap)||![0,1,false,true,'0','1'].includes(carryRule))need(reasons,'sick_rules_required','Effective sick-leave grant/cap/carry-forward rules are required.');const carry=carryRule===true||carryRule===1||carryRule==='1',current=Math.max(0,Number(input.currentStatutoryDays||0)),grantDue=input.grantDue===true?grant:0,base=carry?current:0;return {status:reasons.length?'needs_confirmation':'calculated',available_days:reasons.length?null:Math.min(cap,base+grantDue),grant_days:grantDue,carry_forward:carry,reasons}}
    if(code==='bereavement_leave'){const cat=input.bereavementCategory;if(cat==='three_day'){const d=Number(getRule(rules,'bereavement_immediate_days'));return finite(d)?{status:'calculated',available_days:d,event_based:true,reasons}:{status:'needs_confirmation',reasons:[{code:'bereavement_rule_required',message:'Effective bereavement rule is required.'}]}}if(cat==='one_day'){if(input.employerAccepted!==true)return {status:'needs_confirmation',reasons:[{code:'bereavement_employer_determination_required',message:'Employer determination is required for this bereavement category.'}]};const d=Number(getRule(rules,'bereavement_other_days'));return finite(d)?{status:'calculated',available_days:d,event_based:true,reasons}:{status:'needs_confirmation',reasons:[{code:'bereavement_rule_required',message:'Effective bereavement rule is required.'}]}}return {status:'needs_confirmation',reasons:[{code:'bereavement_category_required',message:'Bereavement statutory category is required.'}]}}
    if(code==='family_violence_leave'){const d=Number(getRule(rules,'family_violence_grant_days')),carryRule=getRule(rules,'family_violence_carry_forward_enabled');if(!finite(d)||![0,1,false,true,'0','1'].includes(carryRule))return {status:'needs_confirmation',reasons:[{code:'family_violence_rule_required',message:'Effective family-violence entitlement and carry-forward rules are required.'}]};const carry=carryRule===true||carryRule===1||carryRule==='1',prior=carry?Math.max(0,Number(input.carryForwardDays||0)):0;return {status:'calculated',available_days:Math.max(0,d+prior-Number(input.usedInPeriod||0)),grant_days:d,carry_forward:carry,privacy_safe:true,reasons}}
    return {status:'needs_confirmation',reasons:[{code:'statutory_leave_code_required',message:'A supported statutory leave code is required.'}]};
  }

  function calculateStatutoryLeave(input){
    const reasons=[],rules=input?.rules||{},elig=eligibility(input,rules);if(elig.status==='needs_confirmation')reasons.push(...elig.reasons);if(elig.status==='not_eligible')return {status:'not_eligible',confirmation_state:'not_required',reasons:elig.reasons,eligibility:elig};
    const ent=entitlement(input,rules);if(ent.status==='needs_confirmation')reasons.push(...ent.reasons);
    const qty=Number(input?.statutoryDays);if(!finite(qty)||qty<=0)need(reasons,'statutory_days_required','Statutory leave quantity in days is required.');if(qty>0&&qty<1&&input?.fractionalDayEvidence?.agreed!==true)need(reasons,'fractional_day_agreement_required','Fractional statutory-day treatment requires explicit agreement/policy evidence.');if(ent.available_days!=null&&qty>ent.available_days)need(reasons,'insufficient_statutory_entitlement','Requested statutory days exceed available entitlement.');if(input?.accWeeklyCompensationOverlap===true&&!input?.accOverlapResolution)need(reasons,'acc_overlap_confirmation','ACC weekly-compensation overlap requires a confirmed treatment decision.');
    const owd=resolveOWD(input?.owdInput||{date:input.date,employmentStart:input.employmentStart,employmentEnd:input.employmentEnd});if(owd.status==='needs_confirmation')reasons.push(...owd.reasons);if(owd.determination==='no')return {status:reasons.length?'needs_confirmation':'not_payable_day',confirmation_state:reasons.length?'needs_confirmation':'not_required',reasons,eligibility:elig,entitlement:ent,owd,statutory_quantity:qty,statutory_unit:'days'};
    let rdp=null,adp=null,selected=null;if(owd.determination==='yes'){rdp=calculateRDP({...input.rdpInput,date:input.date,owd});if(rdp.status==='calculated'){selected={method:'rdp',amount:rdp.amount}}else if(input.adpInput){adp=calculateADP({...input.adpInput,date:input.date,employmentStart:input.employmentStart,lookbackWeeks:Number(getRule(rules,'adp_lookback_weeks')),permittedTriggers:getRule(rules,'adp_permitted_triggers')});if(adp.status==='calculated')selected={method:'adp',amount:adp.amount};else reasons.push(...rdp.reasons,...adp.reasons)}else reasons.push(...rdp.reasons)}
    return {status:reasons.length?'needs_confirmation':'calculated',confirmation_state:reasons.length?'needs_confirmation':'confirmed',reasons,eligibility:elig,entitlement:ent,owd,rdp,adp,selected_method:selected?.method||null,selected_amount:selected?.amount??null,statutory_quantity:qty,statutory_unit:'days',privacy_safe:input.leaveCode==='family_violence_leave'};
  }

  function buildStoragePayload(result,input,ctx){
    return {business_id:ctx.businessId,employee_id:ctx.employeeId,leave_type_id:ctx.leaveTypeId||null,leave_transaction_id:ctx.leaveTransactionId||null,pay_run_id:ctx.payRunId||null,owd_determination_id:ctx.owdDeterminationId||null,statutory_leave_code:input.leaveCode,calculation_type:input.leaveCode,relevant_from:iso(input.date),relevant_to:iso(input.date),rule_version:'V61.73-P4B.1',rules_snapshot:ctx.rulesSnapshot||{},input_snapshot:{leave_code:input.leaveCode,statutory_quantity:result.statutory_quantity,statutory_unit:'days',eligibility:result.eligibility,entitlement:result.entitlement,rdp:result.rdp?.input_snapshot||null,adp:result.adp?.input_snapshot||null,fractional_day_evidence:input.fractionalDayEvidence||null,acc_overlap:{overlap:!!input.accWeeklyCompensationOverlap,resolution:input.accOverlapResolution||null}},owd_evidence_snapshot:result.owd?.evidence_snapshot||{},rdp_amount:result.rdp?.amount??null,adp_amount:result.adp?.amount??null,selected_method:result.selected_method,selected_amount:result.selected_amount,confirmation_state:result.confirmation_state,explanation_snapshot:{status:result.status,reasons:result.reasons,privacy_safe:result.privacy_safe===true,selected_method:result.selected_method,selected_amount:result.selected_amount}};
  }

  function draftPayrollLine(result,input){if(result.status!=='calculated'||!result.selected_amount)return null;return {line_type:'earning',description:input.leaveCode==='family_violence_leave'?'Paid leave':input.leaveCode==='sick_leave'?'Sick Leave':'Bereavement Leave',quantity:Number(result.statutory_quantity),rate:Number(result.selected_amount),amount:round2(Number(result.selected_amount)*Number(result.statutory_quantity)),taxable:true,statutory_leave_code:input.leaveCode,statutory_calculation_id:input.statutoryCalculationId||null}}

  return {selectEffectiveRules,validateWorkPattern,resolveOWD,calculateRDP,calculateADP,eligibility,entitlement,calculateStatutoryLeave,buildStoragePayload,draftPayrollLine,addDays,addMonths};
});
