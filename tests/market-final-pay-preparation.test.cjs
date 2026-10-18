const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const payroll=fs.readFileSync('public/payroll.js','utf8');
const html=fs.readFileSync('public/index.html','utf8');
const sql=fs.readFileSync('supabase/migrations/20261018090000_v6236_market_termination_preparation.sql','utf8');

test('employee termination is routed through the final-pay preparation RPC',()=>{
  assert.match(payroll,/rpc\('v6236_prepare_employee_termination'/);
  assert.doesNotMatch(payroll,/from\('payroll_employees'\)\.update\(\{employment_status:'terminated'/);
  assert.match(payroll,/Use the final-pay workflow to terminate an employee/);
});

test('termination UI states that no statutory amount is guessed',()=>{
  assert.match(html,/No holiday amount will be guessed or paid automatically/);
  assert.match(html,/End employment &amp; prepare final pay/);
  assert.match(payroll,/Final pay: \$\{esc\(human\(p\.status\)\)\}/);
});

test('server command is tenant-scoped, permissioned, versioned and idempotent',()=>{
  assert.match(sql,/v6147_can_write_area\(v_business_id,'payroll'\)/);
  assert.match(sql,/business_id=v_business_id and request_id=p_request_id/);
  assert.match(sql,/updated_at is distinct from p_expected_updated_at/);
  assert.match(sql,/unique \(business_id, request_id\)/);
  assert.match(sql,/payroll_termination_one_open_idx/);
});

test('direct transition to terminated is blocked and review table is browser read-only',()=>{
  assert.match(sql,/Use Prepare final pay to terminate an employee/);
  assert.match(sql,/revoke insert,update,delete on table public\.payroll_termination_preparations from authenticated/);
  assert.match(sql,/grant select on table public\.payroll_termination_preparations to authenticated/);
  assert.doesNotMatch(sql,/grant select,insert,update,delete on table public\.payroll_termination_preparations to authenticated/);
});

test('tenant cleanup clears all final-pay workflow arrays',()=>{
  for(const name of ['paygDeterminations','annualHolidayEntitlementPeriods','finalPayCalculations','finalPayComponents','terminationPreparations']){
    assert.match(payroll,new RegExp(`state\\.${name}=\\[\\]`));
  }
});
