const fs=require('fs'),path=require('path'),assert=require('assert');
const f=path.join(__dirname,'..','supabase','migrations','20260920162000_v6179a_schedule_dashboard_foundation_correction.sql');
const s=fs.readFileSync(f,'utf8');
const hardeningFile=path.join(__dirname,'..','supabase','migrations','20260920170000_v6179d_phase_a_advisor_hardening.sql');
const h=fs.readFileSync(hardeningFile,'utf8');
const executable=s.split('\n').filter(line=>!line.trim().startsWith('--')).join('\n');
const hardeningExecutable=h.split('\n').filter(line=>!line.trim().startsWith('--')).join('\n');
const complete=s+'\n'+h;
let n=0; const ok=(x,m)=>{assert.ok(x,m);n++};

ok(/^begin;/mi.test(s)&&/^commit;/mi.test(s),'transaction bounded');
ok(!/drop\s+.+cascade/i.test(executable),'no destructive cascade');
ok(!/frindly_updated_at/i.test(s)&&/provider_updated_at/i.test(s),'provider field corrected');
for(const ref of ['job_costings','customers','quotes','invoices','job_recurrence_series']){
  ok(new RegExp(`references public\\.${ref}\\(id\\) on delete set null`,'i').test(s),`optional ${ref} uses SET NULL`);
}
ok(/schedule_id uuid not null references public\.job_schedules\(id\) on delete cascade/i.test(s),'assignments cascade with schedule');
ok(/google_calendar_event_links[\s\S]*schedule_id uuid not null references public\.job_schedules\(id\) on delete cascade/i.test(s),'event link cascades with schedule');
ok(/job_schedules_time_pair_check[\s\S]*start_at is null and end_at is null[\s\S]*start_at is not null and end_at is not null and end_at > start_at/i.test(s),'paired schedule times');
ok(/job_schedules_status_time_check[\s\S]*status='unscheduled' or \(start_at is not null and end_at is not null\)/i.test(s),'non-unscheduled requires times');
ok(/job_schedules_actual_time_pair_check[\s\S]*actual_start_at is null and actual_end_at is null[\s\S]*actual_end_at > actual_start_at/i.test(s),'paired actual times');
ok(/create policy v6179_google_connections_own_read on public\.google_calendar_connections for select to authenticated/i.test(s),'Google connection client read-only policy');
ok(/grant select on public\.google_calendar_connections to authenticated/i.test(s),'Google connection select grant');
ok(/revoke insert,update,delete on public\.google_calendar_connections from authenticated/i.test(s),'Google connection browser DML revoked');
ok(!/grant select,insert,update,delete on public\.google_calendar_connections/i.test(s),'no broad Google metadata grant');
ok(/google_calendar_event_links[\s\S]*employee_id uuid null references public\.payroll_employees\(id\) on delete cascade/i.test(s),'employee-owned Google link cascades on employee deletion');
ok(/google_calendar_event_links_actor_check check \(\(employee_id is not null\)::integer \+ \(user_id is not null\)::integer = 1\)/i.test(s),'exactly one actor');
ok(/pg_catalog\.pg_timezone_names/i.test(s)&&/v6179_is_iana_timezone/i.test(s),'IANA catalogue validation');
ok(/0=Sunday, 1=Monday, \.\.\. 6=Saturday/i.test(s),'weekday convention documented');
ok(/frequency='weekly'[\s\S]*v6179_smallint_array_is_unique\(days_of_week\)/i.test(s),'weekly unique weekdays');
ok(/frequency in \('daily','monthly'\) and days_of_week is null/i.test(s),'non-weekly weekdays rejected');
ok(/job_recurrence_series_start_time_check check \(default_start_time is not null\)/i.test(s),'recurrence start time required');
ok(/information_schema\.columns/i.test(s)&&/expected %s, found %s/i.test(s),'preflight verifies columns/types');
ok(/V61\.79A preflight failed\. Missing:/i.test(s),'preflight consolidated error');
ok(/where not exists \(select 1 from public\.modules where slug='schedule'\)/i.test(s),'module idempotent');
ok(!/included_modules\s*=.*schedule/i.test(s),'does not add schedule to plans');
for(const t of ['job_recurrence_series','job_schedules','job_schedule_assignments','google_calendar_connections','google_calendar_event_links','google_calendar_sync_log']){
  ok(new RegExp(`create table if not exists public\\.${t}`,'i').test(s),`creates ${t}`);
  ok(new RegExp(`alter table public\\.${t} enable row level security`,'i').test(s),`RLS ${t}`);
  ok(new RegExp(`revoke all on public\\.${t} from anon`,'i').test(s),`anon revoked ${t}`);
}
ok(!/\b(refresh_token|access_token|client_secret)\b\s+(text|varchar|bytea)/i.test(s),'no token/secret columns');
ok(/current_business_id\(\)/i.test(s),'active business helper reused');
ok(/v6147_current_business_role/i.test(s),'role helper reused');
for(const fn of ['v6179_schedule_entitled','v6179_schedule_role_allowed']){
  ok(new RegExp(`create or replace function public\\.${fn}[\\s\\S]*?security definer[\\s\\S]*?set search_path = 'public'`,'i').test(s),`hardened ${fn}`);
  ok(new RegExp(`revoke all on function public\\.${fn}`,'i').test(s),`public revoke ${fn}`);
  ok(new RegExp(`revoke execute on function public\\.${fn}.*from anon`,'i').test(s),`anon revoke ${fn}`);
}
ok(/unique\(schedule_id,employee_id\)/i.test(s),'assignment uniqueness');
ok(/job_schedules_recurrence_occurrence_uidx/i.test(s),'recurrence occurrence uniqueness');
ok(/google_calendar_event_links_employee_uidx/i.test(s)&&/google_calendar_event_links_user_uidx/i.test(s),'Google nullable-actor unique indexes');
ok(/v6179_dashboard_summary/i.test(s)&&/'bank_position',null/i.test(s)&&/unsupported_until_opening_or_current_balance_source_is_verified/i.test(s),'dashboard remains fail-closed');
ok(/v6179_today_schedule/i.test(s),'today schedule RPC');
ok(!/profiles\.business_id/i.test(s),'no legacy profile fallback');
const dollars=(s.match(/\$[a-z0-9_]+\$/gi)||[]), counts={}; for(const d of dollars)counts[d]=(counts[d]||0)+1;
ok(Object.values(counts).every(v=>v%2===0),'balanced tagged dollar quoting');


// V61.79D advisor-hardening static coverage.
ok(/^begin;/mi.test(h)&&/^commit;/mi.test(h),'V61.79D transaction bounded');
ok(!/drop\s+.+cascade/i.test(hardeningExecutable),'V61.79D contains no DROP CASCADE');
for(const [policy,table] of [
  ['v6179_schedule_series_write','job_recurrence_series'],
  ['v6179_schedules_write','job_schedules'],
  ['v6179_schedule_assignments_write','job_schedule_assignments']
]) ok(new RegExp(`drop policy if exists ${policy} on public\\.${table}`,'i').test(h),`drops broad ${policy}`);

const policyFamilies=[
  ['v6179_schedule_series','job_recurrence_series'],
  ['v6179_schedules','job_schedules'],
  ['v6179_schedule_assignments','job_schedule_assignments']
];
for(const [prefix,table] of policyFamilies){
  ok(new RegExp(`create policy ${prefix}_insert[\\s\\S]*?on public\\.${table}[\\s\\S]*?for insert to authenticated[\\s\\S]*?with check \\(public\\.v6179_schedule_role_allowed\\(business_id, true\\)\\)`,'i').test(h),`${prefix} INSERT uses WITH CHECK`);
  ok(new RegExp(`create policy ${prefix}_update[\\s\\S]*?on public\\.${table}[\\s\\S]*?for update to authenticated[\\s\\S]*?using \\(public\\.v6179_schedule_role_allowed\\(business_id, true\\)\\)[\\s\\S]*?with check \\(public\\.v6179_schedule_role_allowed\\(business_id, true\\)\\)`,'i').test(h),`${prefix} UPDATE uses USING and WITH CHECK`);
  ok(new RegExp(`create policy ${prefix}_delete[\\s\\S]*?on public\\.${table}[\\s\\S]*?for delete to authenticated[\\s\\S]*?using \\(public\\.v6179_schedule_role_allowed\\(business_id, true\\)\\)`,'i').test(h),`${prefix} DELETE uses USING`);
}
ok((h.match(/create policy v6179_(?:schedule_series|schedules|schedule_assignments)_(?:insert|update|delete)/gi)||[]).length===9,'creates exactly nine operation-specific Schedule write policies');
for(const readPolicy of ['v6179_schedule_series_read','v6179_schedules_read','v6179_schedule_assignments_read'])
  ok(new RegExp(`create policy ${readPolicy}\\b`,'i').test(complete),`complete sequence retains ${readPolicy}`);
ok(/user_id\s*=\s*\(select auth\.uid\(\)\)/i.test(h),'Google ownership uses auth.uid init-plan form');

const expectedIndexes=[
'job_recurrence_series_job_costing_id_idx','job_recurrence_series_customer_id_idx','job_recurrence_series_created_by_idx','job_recurrence_series_updated_by_idx',
'job_schedules_job_costing_id_idx','job_schedules_quote_id_idx','job_schedules_customer_id_idx','job_schedules_invoice_id_idx','job_schedules_recurrence_series_id_idx','job_schedules_created_by_idx','job_schedules_updated_by_idx',
'job_schedule_assignments_business_id_idx','job_schedule_assignments_created_by_idx','job_schedule_assignments_updated_by_idx',
'google_calendar_connections_user_id_idx','google_calendar_event_links_employee_id_idx','google_calendar_event_links_user_id_idx','google_calendar_sync_log_connection_id_idx','google_calendar_sync_log_schedule_id_idx'];
const createdIndexes=[...h.matchAll(/create index if not exists\s+([a-z0-9_]+)\s+on\s+public\./gi)].map(m=>m[1]);
ok(createdIndexes.length===19,'V61.79D creates exactly 19 indexes');
ok(expectedIndexes.every(x=>createdIndexes.includes(x))&&createdIndexes.every(x=>expectedIndexes.includes(x)),'V61.79D index list exactly matches documented 19');
ok(!/\bto\s+anon\b/i.test(h),'V61.79D grants no policy access to anon');
ok(!/\bstaff\b/i.test(hardeningExecutable),'V61.79D grants no Schedule access to staff');

const stagingSql=fs.readFileSync(path.join(__dirname,'v6179a-staging-database-tests.sql'),'utf8');
const dollarBlocks=[...stagingSql.matchAll(/\$\$[\s\S]*?\$\$/g)].map(m=>m[0]);
ok(dollarBlocks.every(block=>!/:\'[A-Za-z_][A-Za-z0-9_]*\'/.test(block)),'no psql variable references inside dollar-quoted staging test blocks');
ok(/set_config\('v6179a\.business_a',\s*:'business_a',\s*true\)/.test(stagingSql),'staging fixtures copied to transaction-local settings');
ok(/set_config\('v6179a\.schedule_id'/.test(stagingSql),'generated schedule id copied to transaction-local setting');
ok(/complete expected V61\.79D RLS policy list present/.test(stagingSql),'staging test checks complete expected V61.79D RLS policy list');

ok(/create temporary table v6179a_results[\s\S]*?grant select, insert on v6179a_results to authenticated;/i.test(stagingSql),'authenticated has minimum SELECT/INSERT on temporary results table');
ok(!/grant\s+(?:all|update|delete|truncate|references|trigger)[^;]*v6179a_results\s+to\s+authenticated/i.test(stagingSql),'temporary results table has no broader authenticated grant');
console.log(`${n}/${n} V61.79E static migration checks PASS`);
