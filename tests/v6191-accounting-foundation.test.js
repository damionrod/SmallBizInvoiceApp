const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('accountant pack includes Xero-ready chart and mapping evidence',()=>{
  const source=fs.readFileSync('public/accountant-centre.js','utf8');
  assert.match(source,/00_Chart_of_Accounts\.csv/);
  assert.match(source,/02_Xero_Mapping_Readiness\.csv/);
  assert.match(source,/MappedXeroAccountCode/);
  assert.match(source,/accounting_accounts'\)\.select\('\*'\)/);
  assert.match(source,/accounting_source_mappings'\)\.select\('\*'\)/);
  assert.match(source,/v6191_seed_default_chart/);
  assert.match(source,/renderSourceMappings/);
  assert.match(source,/PGRST205/);
  assert.match(source,/Migration required/);
  assert.match(source,/Apply the accounting foundation migration in Supabase first/);
});

test('v6191 accounting foundation is non-posting and uses business settings access',()=>{
  const sql=fs.readFileSync('supabase/migrations/20260926163000_v6191_accounting_foundation_xero_ready.sql','utf8');
  assert.match(sql,/create table if not exists public\.accounting_accounts/);
  assert.match(sql,/create or replace function public\.v6191_seed_default_chart/);
  assert.match(sql,/v6147_can_write_area\(business_id,'business_settings'\)/);
  assert.match(sql,/with \(security_invoker = true\)/);
  assert.match(sql,/a\.business_id = public\.current_business_id\(\)/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_lines/i);
  assert.doesNotMatch(sql,/update public\.(expenses|invoices|gst_returns|se_items|se_assets)\b/i);
});
