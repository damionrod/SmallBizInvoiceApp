const fs=require('fs'),assert=require('assert');
const migration=fs.readFileSync('supabase/migrations/20260922120000_v6179k_admin_delete_business_dependents.sql','utf8');
const admin=fs.readFileSync('public/saas.js','utf8');
const checks=[
  ['existing delete RPC preserved',()=>assert(migration.includes('create or replace function public.v36_admin_delete_business'))],
  ['business name confirmation preserved',()=>assert(migration.includes("Business name confirmation does not match"))],
  ['current business deletion guard preserved',()=>assert(migration.includes('You cannot delete the business account you are currently logged into'))],
  ['accounting chart rows removed before business',()=>assert(migration.includes('delete from public.accounting_accounts where business_id = p_business_id'))],
  ['accounting periods removed before business',()=>assert(migration.includes('delete from public.accounting_periods where business_id = p_business_id'))],
  ['calendar rows removed before schedules',()=>assert(migration.includes('delete from public.google_calendar_sync_log where business_id = p_business_id'))],
  ['schedule rows removed before business',()=>assert(migration.includes('delete from public.job_schedules where business_id = p_business_id'))],
  ['posted journals remain protected',()=>assert(migration.includes('cannot be deleted. Suspend or close it instead.'))],
  ['frontend still calls existing RPC',()=>assert(admin.includes("rpc('v36_admin_delete_business'"))],
  ['no cascade DDL introduced',()=>assert(!/alter\s+table[\s\S]*on\s+delete\s+cascade/i.test(migration))],
];
let n=0;for(const [name,fn] of checks){try{fn();n++;console.log('PASS',name)}catch(e){console.error('FAIL',name,e.message);process.exitCode=1}}
console.log(`${n}/${checks.length} PASS`);
