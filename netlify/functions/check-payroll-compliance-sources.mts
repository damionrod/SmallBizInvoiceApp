export default async () => {
  const base=Netlify.env.get('SUPABASE_URL');
  const secret=Netlify.env.get('PAYROLL_COMPLIANCE_MONITOR_SECRET');
  if(!base||!secret){console.error('Payroll compliance schedule skipped: required server environment variables are missing.');return;}
  const r=await fetch(`${base}/functions/v1/check-payroll-compliance-sources`,{method:'POST',headers:{'content-type':'application/json','x-finlo-monitor-secret':secret},body:'{}'});
  if(!r.ok)console.error('Payroll compliance check failed',r.status,await r.text());
};
export const config={schedule:'0 18 * * *'};
