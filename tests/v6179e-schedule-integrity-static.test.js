const fs=require('fs'),path=require('path'),root=path.resolve(__dirname,'..');
let n=0;function ok(value,message){if(!value)throw new Error('FAIL: '+message);n++}
const file='supabase/migrations/20260920220000_v6179e_schedule_integrity_correction.sql';
const sql=fs.readFileSync(path.join(root,file),'utf8');
ok(/^begin;/mi.test(sql)&&/^commit;/mi.test(sql),'migration is transaction bounded');
ok(/create or replace function public\.v6179_save_schedule_with_assignments/.test(sql),'atomic save is replaced additively');
ok(/security invoker/i.test(sql)&&!/security definer/i.test(sql),'functions remain security invoker');
ok(/set search_path = pg_catalog, public, auth/i.test(sql),'atomic save has explicit search path');
ok(/and not \(a\.employee_id=any\(coalesce\(p_employee_ids,'\{\}'::uuid\[\]\)\)\)/.test(sql),'only removed employees are deleted');
ok(/select distinct employee_id[\s\S]*on conflict \(schedule_id,employee_id\) do nothing/.test(sql),'new employees are deduplicated and retained rows are untouched');
for(const field of ['assignment_status','planned_hours','actual_hours'])ok(sql.includes(field),`${field} preservation is documented`);
ok(/create or replace function public\.v6179_today_schedule/.test(sql),'Today Schedule RPC is replaced additively');
ok(/coalesce\(nullif\(btrim\(e\.preferred_name\),''\),e\.first_name\)/.test(sql),'preferred name falls back to first name');
ok(/revoke all on function public\.v6179_save_schedule_with_assignments[\s\S]*from public/.test(sql),'PUBLIC execute is revoked');
ok(/revoke execute on function public\.v6179_save_schedule_with_assignments[\s\S]*from anon/.test(sql),'anon execute is revoked');
ok(/grant execute on function public\.v6179_save_schedule_with_assignments[\s\S]*to authenticated/.test(sql),'authenticated execute is restored');
ok(!/drop\s+[^;]*cascade/i.test(sql),'no DROP CASCADE');
console.log(`${n}/${n} V61.79E Schedule integrity static checks PASS`);
