/*
Authenticated disposable-project PostgREST/RLS integration test.

Required environment variables:
  V6179_SUPABASE_URL
  V6179_PUBLISHABLE_KEY
  V6179_OWNER_ACCESS_TOKEN
  V6179_BUSINESS_ID
  V6179_EMPLOYEE_ID

Set V6179_REQUIRE_AUTH_HTTP=1 in release validation so missing credentials fail
instead of producing an explicit skip.
*/
const required=['V6179_SUPABASE_URL','V6179_PUBLISHABLE_KEY','V6179_OWNER_ACCESS_TOKEN','V6179_BUSINESS_ID','V6179_EMPLOYEE_ID'];
const missing=required.filter(k=>!process.env[k]);
if(missing.length){
  const message=`SKIP authenticated HTTP test: missing ${missing.join(', ')}`;
  if(process.env.V6179_REQUIRE_AUTH_HTTP==='1')throw new Error(message);
  console.log(message);process.exit(0);
}
const base=process.env.V6179_SUPABASE_URL.replace(/\/$/,''),key=process.env.V6179_PUBLISHABLE_KEY,token=process.env.V6179_OWNER_ACCESS_TOKEN,businessId=process.env.V6179_BUSINESS_ID,employeeId=process.env.V6179_EMPLOYEE_ID;
const headers={apikey:key,authorization:`Bearer ${token}`,'content-type':'application/json'};
let scheduleId=null,n=0;
function ok(value,message){if(!value)throw new Error(`FAIL: ${message}`);n++}
async function request(path,options={}){const response=await fetch(`${base}${path}`,{...options,headers:{...headers,...options.headers}}),text=await response.text();let body=null;try{body=text?JSON.parse(text):null}catch{body=text}if(!response.ok)throw new Error(`${options.method||'GET'} ${path} -> ${response.status}: ${text}`);return body}
(async()=>{
  const title=`V6179E HTTP ${Date.now()}`;
  const created=await request('/rest/v1/rpc/v6179_save_schedule_with_assignments',{method:'POST',body:JSON.stringify({p_schedule_id:null,p_schedule:{business_id:businessId,title,timezone:'Pacific/Auckland',status:'unscheduled'},p_employee_ids:[]})});
  scheduleId=created?.id;ok(scheduleId,'owner can create a schedule through authenticated RPC');
  let unassigned=await request(`/rest/v1/job_schedule_assignments?select=id&schedule_id=eq.${encodeURIComponent(scheduleId)}`);
  ok(unassigned.length===0,'owner can save a job with no employee and assign one later');
  await request('/rest/v1/rpc/v6179_save_schedule_with_assignments',{method:'POST',body:JSON.stringify({p_schedule_id:scheduleId,p_schedule:{business_id:businessId,title,timezone:'Pacific/Auckland',status:'unscheduled'},p_employee_ids:[employeeId]})});
  let assignments=await request(`/rest/v1/job_schedule_assignments?select=id,assignment_status,planned_hours,actual_hours&schedule_id=eq.${encodeURIComponent(scheduleId)}&employee_id=eq.${encodeURIComponent(employeeId)}`);
  ok(assignments.length===1,'owner can read the assignment through RLS');
  await request(`/rest/v1/job_schedule_assignments?id=eq.${encodeURIComponent(assignments[0].id)}`,{method:'PATCH',headers:{prefer:'return=minimal'},body:JSON.stringify({assignment_status:'confirmed',planned_hours:3.5,actual_hours:2.25})});
  await request('/rest/v1/rpc/v6179_save_schedule_with_assignments',{method:'POST',body:JSON.stringify({p_schedule_id:scheduleId,p_schedule:{business_id:businessId,title:`${title} edited`,timezone:'Pacific/Auckland',status:'unscheduled'},p_employee_ids:[employeeId]})});
  assignments=await request(`/rest/v1/job_schedule_assignments?select=assignment_status,planned_hours,actual_hours&schedule_id=eq.${encodeURIComponent(scheduleId)}&employee_id=eq.${encodeURIComponent(employeeId)}`);
  ok(assignments.length===1&&assignments[0].assignment_status==='confirmed'&&Number(assignments[0].planned_hours)===3.5&&Number(assignments[0].actual_hours)===2.25,'authenticated RPC edit preserves assignment progress');
  if(process.env.V6179_EMPLOYEE_ID_2){
    const second=process.env.V6179_EMPLOYEE_ID_2;
    await request('/rest/v1/rpc/v6179_save_schedule_with_assignments',{method:'POST',body:JSON.stringify({p_schedule_id:scheduleId,p_schedule:{business_id:businessId,title:`${title} team`,timezone:'Pacific/Auckland',status:'unscheduled'},p_employee_ids:[employeeId,second]})});
    const team=await request(`/rest/v1/job_schedule_assignments?select=employee_id&schedule_id=eq.${encodeURIComponent(scheduleId)}`);
    ok(team.length===2,'owner can assign multiple employees to one job');
  }
  console.log(`${n}/${n} V61.79E authenticated HTTP/RLS checks PASS`);
})().finally(async()=>{if(scheduleId)try{await request(`/rest/v1/job_schedules?id=eq.${encodeURIComponent(scheduleId)}`,{method:'DELETE',headers:{prefer:'return=minimal'}})}catch(error){console.error('Cleanup warning:',error.message)}}).catch(error=>{console.error(error);process.exitCode=1});
