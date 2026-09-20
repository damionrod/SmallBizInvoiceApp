const fs=require('fs'),path=require('path'),crypto=require('crypto');
const root=path.resolve(__dirname,'..');
let n=0;function ok(value,message){if(!value)throw new Error('FAIL: '+message);n++}
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
const rollback=read('docs/V61.79E-ROLLBACK.sql');
const checklist=read('docs/V61.79E-PRODUCTION-RELEASE-CHECKLIST.md');
const originalAtomic=read('supabase/migrations/20260920175500_v6179_phase_b_atomic_schedule_save.sql');
const originalFoundation=read('supabase/migrations/20260920162000_v6179a_schedule_dashboard_foundation_correction.sql');

ok(/^begin;/mi.test(rollback)&&/^commit;/mi.test(rollback),'rollback is transaction bounded');
ok((rollback.match(/create or replace function public\.v6179_/g)||[]).length===2,'rollback restores exactly two functions');
ok(/security invoker/i.test(rollback)&&!/security definer/i.test(rollback),'rollback preserves SECURITY INVOKER');
ok((rollback.match(/revoke execute on function public\.v6179_[^;]+ from anon;/gi)||[]).length===2,'rollback denies anon execution');
ok((rollback.match(/grant execute on function public\.v6179_[^;]+ to authenticated;/gi)||[]).length===2,'rollback restores authenticated grants');
ok(!/drop\s+[^;]*cascade/i.test(rollback),'rollback has no DROP CASCADE');
ok(rollback.includes("concat_ws(' ',e.preferred_name,e.first_name,e.last_name)"),'rollback restores original Today Schedule name expression');
ok(rollback.includes("foreach v_employee in array coalesce(p_employee_ids,'{}'::uuid[]) loop"),'rollback restores original assignment replacement');
ok(originalAtomic.includes("foreach v_employee in array coalesce(p_employee_ids,'{}'::uuid[]) loop"),'atomic rollback source matches protected migration behavior');
ok(originalFoundation.includes("concat_ws(' ',e.preferred_name,e.first_name,e.last_name)"),'Today Schedule rollback source matches protected migration behavior');

const protectedHashes={
  'supabase/migrations/20260920162000_v6179a_schedule_dashboard_foundation_correction.sql':'1ca71e662297b66b7d847aec146cfc729bae8b1d4976128100387257b3683d18',
  'supabase/migrations/20260920170000_v6179d_phase_a_advisor_hardening.sql':'7123e7190182e84c58e36b132e7ac9692cacd7fd9f86b8fe6e81cd000ea29d6f',
  'supabase/migrations/20260920175500_v6179_phase_b_atomic_schedule_save.sql':'2dcf64ff82ad2322d7440eb56a6d87c34463e1cee9ed837cb18c2cbf6f60def9'
};
for(const [file,expected] of Object.entries(protectedHashes))ok(hash(file)===expected,`${file} remains byte-for-byte protected`);
for(const phrase of ['release candidate','authenticated-http.test.js','V6179_REQUIRE_AUTH_HTTP=1','9:07 PM','Deployment order','Stop conditions','V61.79E-ROLLBACK.sql'])ok(checklist.includes(phrase),`checklist includes ${phrase}`);
ok(checklist.includes('20260920220000_v6179e_schedule_integrity_correction.sql')&&checklist.includes('20260920233000_v6179f_optional_employee_assignments.sql'),'checklist fixes ordered database-before-frontend deployment');
ok(/has\s+not been modified/.test(checklist),'checklist records no production modification');
console.log(`${n}/${n} V61.79E production-readiness checks PASS`);
