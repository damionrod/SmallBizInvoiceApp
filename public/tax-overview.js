(function(root,factory){
  'use strict';
  if(typeof module==='object'&&module.exports)module.exports=factory(require('./data-access.js'));
  else root.FrindlyTaxOverview=factory(root.FrindlyData);
})(typeof window==='object'?window:globalThis,function(data){
  'use strict';
  const sources=Object.freeze({
    gst:{table:'gst_returns',columns:'id,period_start,period_end,status,gst_net,statutory_due_date'},
    filings:{table:'ird_filing_batches',columns:'id,filing_type,period_start,period_end,due_date,status,ird_reference,created_at'},
    payroll:{table:'payroll_pay_runs',columns:'id,pay_run_number,pay_date,status,country_code'},
    payrollFilings:{table:'payroll_ird_filings',columns:'id,pay_run_id,pay_date,status,ird_reference,created_at'},
    plans:{table:'provisional_tax_plans',columns:'id,tax_year_end,method,status,estimated_income_tax'},
    instalments:{table:'provisional_tax_instalments',columns:'id,plan_id,due_date,suggested_amount,paid_amount,status'}
  });
  function value(v){return v===null||v===undefined||v===''?null:Number.isFinite(Number(v))?Number(v):null}
  function payrollRows(runs,events){
    const latest=new Map();
    for(const e of events){const old=latest.get(e.pay_run_id);if(!old||String(e.created_at||'')>String(old.created_at||'')||(e.created_at===old.created_at&&String(e.id)>String(old.id)))latest.set(e.pay_run_id,e)}
    return runs.filter(r=>r.status==='finalised'&&r.country_code==='NZ').map(r=>({...r,filing:latest.get(r.id)||null})).sort((a,b)=>String(b.pay_date).localeCompare(String(a.pay_date)));
  }
  async function load(client,businessId,guard=()=>{}){
    if(!businessId)throw new Error('Choose a business first.');
    const results=await Promise.all(Object.entries(sources).map(async([key,source])=>{
      try{return[key,{available:true,rows:await data.readAll(()=>client.from(source.table).select(source.columns).eq('business_id',businessId),{guard})}]}
      catch(error){guard();return[key,{available:false,rows:[],message:'These records could not be verified with your access. Refresh or contact your administrator.'}]}
    }));
    guard();return Object.fromEntries(results);
  }
  return Object.freeze({load,payrollRows,value});
});
