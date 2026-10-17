(function(root,factory){
  'use strict';
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.FrindlyPlanning=api;
})(typeof window==='object'?window:globalThis,function(){
  'use strict';
  const dayMs=86400000;
  function number(value){return value===null||value===undefined||value===''?null:Number.isFinite(Number(value))?Number(value):null}
  function date(value){
    if(!/^\d{4}-\d{2}-\d{2}$/.test(String(value)))throw new Error('A valid date is required.');
    const parsed=new Date(value+'T00:00:00Z');
    if(!Number.isFinite(parsed.getTime())||parsed.toISOString().slice(0,10)!==value)throw new Error('A valid date is required.');
    return parsed;
  }
  function stamp(value){return value.toISOString().slice(0,10)}
  function today(now=new Date(),timeZone='Pacific/Auckland'){
    const parts=new Intl.DateTimeFormat('en-NZ',{timeZone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(now);
    const part=name=>parts.find(x=>x.type===name).value;
    return part('year')+'-'+part('month')+'-'+part('day');
  }
  function yearEnd(year,month,day){
    const max=new Date(Date.UTC(2000,month,0)).getUTCDate();
    if(!Number.isInteger(month)||month<1||month>12||!Number.isInteger(day)||day<1||day>max)throw new Error('Review the business balance date in Tax settings.');
    return new Date(Date.UTC(year,month-1,Math.min(day,new Date(Date.UTC(year,month,0)).getUTCDate())));
  }
  function taxYear(config={},asOf=today()){
    const current=date(asOf),year=current.getUTCFullYear();
    let month=number(config.balance_date_month),day=number(config.balance_date_day),start,end;
    if(month===null&&day===null&&number(config.financial_year_start_month)!==null){
      const sm=number(config.financial_year_start_month),sd=number(config.financial_year_start_day)??1;
      start=yearEnd(year,sm,sd);if(start>current)start=yearEnd(year-1,sm,sd);
      end=yearEnd(start.getUTCFullYear()+1,sm,sd);end.setUTCDate(end.getUTCDate()-1);
    }else{
      month=month??3;day=day??31;
      end=yearEnd(year,month,day);if(current>end)end=yearEnd(year+1,month,day);
      start=new Date(yearEnd(end.getUTCFullYear()-1,month,day).getTime()+dayMs);
    }
    return {from:stamp(start),to:asOf,end:stamp(end),elapsedDays:Math.round((current-start)/dayMs)+1,yearDays:Math.round((end-start)/dayMs)+1};
  }
  function estimate(config,profit,asOf){
    const period=taxYear(config,asOf),value=number(profit),rate=number(config.estimated_tax_rate);
    if(value===null)throw new Error('Posted profit is unavailable.');
    const annualised=Math.max(0,value)*period.yearDays/period.elapsedDays;
    return {period,profit:value,annualised,rate:rate!==null&&rate>=0&&rate<=100?rate:null,tax:rate!==null&&rate>=0&&rate<=100?annualised*rate/100:null};
  }
  function usualStandardDates(config,asOf){
    const period=taxYear(config,asOf);
    if(String(config.country||'NZ').toUpperCase()!=='NZ'||period.end.slice(5)!=='03-31'||config.gst_filing_frequency==='six_monthly')return [];
    const y=Number(period.end.slice(0,4));
    return [(y-1)+'-08-28',y+'-01-15',y+'-05-07'];
  }
  return Object.freeze({today,taxYear,estimate,usualStandardDates});
});
