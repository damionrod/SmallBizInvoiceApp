/* Robert-only synthetic NZ Holidays Act calculation harness.
   No writes. Never use this result for statutory confirmation or posting. */
(function(root){
  'use strict';
  const ROBERT='a9511a03-136d-4eb7-8345-d32f64639307';
  const RULES={owp_formula_divisor_weeks:4,awe_standard_divisor_weeks:52,awe_lookback_months:12,annual_holiday_payment_selection:'greater_of_owp_awe'};
  async function run(client,holidayStart='2026-10-07'){
    if(!client||typeof client.rpc!=='function')throw new Error('Authenticated Supabase client required');
    if(!root.FinloNZHolidays?.calculate)throw new Error('NZ Holidays calculation engine unavailable');
    const {data,error}=await client.rpc('frindly_robert_synthetic_holidays_engine_input',{p_holiday_start:holidayStart});
    if(error)throw error;
    if(!data||data.synthetic_test_only!==true||data.posting_enabled!==false||data.confirmation_permitted!==false||data.employee_id!==ROBERT)throw new Error('Unsafe or unexpected fixture response');
    const entries=(data.aweEarnings||[]).map(e=>({...e,earning_date:e.earning_date}));
    if(entries.length!==26)throw new Error('Incomplete Robert-only synthetic fixture');
    const input={...data,rules:RULES,owpFormulaEarnings:entries,aweEarnings:entries};
    const result=root.FinloNZHolidays.calculate(input);
    const expected=Math.max(Number(result.owp_amount),Number(result.awe_amount));
    if(result.status!=='calculated'||!Number.isFinite(expected)||Math.abs(expected-Number(result.selected_amount))>0.011)throw new Error('OWP/AWE calculation validation failed: '+JSON.stringify(result.reasons||[]));
    return Object.freeze({employee_id:ROBERT,holidayStart,synthetic_test_only:true,posting_enabled:false,confirmation_permitted:false,owp:result.owp_amount,awe:result.awe_amount,selected_method:result.selected_method,selected_amount:result.selected_amount,awe_gross_earnings:result.awe_gross_earnings,awe_divisor:result.awe_divisor,status:'test_calculated_only'});
  }
  root.FrindlyRobertHolidaysTest=Object.freeze({run});
})(typeof window!=='undefined'?window:globalThis);
