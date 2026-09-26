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
  assert.match(source,/income','revenue','other_income/);
  assert.match(source,/asset','current_asset/);
  assert.match(source,/PGRST205/);
  assert.match(source,/Migration required/);
  assert.match(source,/Apply the accounting foundation migration in Supabase first/);
});

test('v6191 accounting foundation is non-posting and uses business settings access',()=>{
  const sql=fs.readFileSync('supabase/migrations/20260926163000_v6191_accounting_foundation_xero_ready.sql','utf8');
  assert.match(sql,/create table if not exists public\.accounting_accounts/);
  assert.match(sql,/create or replace function public\.v6191_seed_default_chart/);
  assert.match(sql,/'asset','liability','revenue','other_income','other_expense'/);
  assert.match(sql,/accounting_accounts_account_type_check/);
  assert.match(sql,/where not exists \(/);
  assert.match(sql,/v6147_can_write_area\(business_id,'business_settings'\)/);
  assert.match(sql,/with \(security_invoker = true\)/);
  assert.match(sql,/a\.business_id = public\.current_business_id\(\)/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_lines/i);
  assert.doesNotMatch(sql,/update public\.(expenses|invoices|gst_returns|se_items|se_assets)\b/i);
});

test('v6191b metadata migration enriches existing chart without changing ledger type',()=>{
  const sql=fs.readFileSync('supabase/migrations/20260926164000_v6191b_enrich_existing_chart_metadata.sql','utf8');
  assert.match(sql,/metadata-only/i);
  assert.match(sql,/report_section = d\.report_section/);
  assert.match(sql,/xero_account_type = coalesce/);
  assert.doesNotMatch(sql,/\n\s*account_type\s*=/i);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_lines/i);
});

test('v6192 posting engine is explicit, balanced and idempotent',()=>{
  const sql=fs.readFileSync('supabase/migrations/20260926175500_v6192_posting_engine.sql','utf8');
  assert.match(sql,/create or replace function public\.v6192_post_operational_ledger/);
  assert.match(sql,/v6192_create_posted_journal/);
  assert.match(sql,/v6169a_accountant_centre_access\(v_business_id, true\)/);
  assert.match(sql,/not exists \(\s*select 1 from public\.accounting_journals j[\s\S]+j\.source_type = 'invoice'/);
  assert.match(sql,/j\.source_type = 'customer_payment'/);
  assert.match(sql,/j\.source_type = 'expense'/);
  assert.match(sql,/j\.source_type = 'supplier_payment'/);
  assert.match(sql,/j\.source_type = 'depreciation'/);
  assert.match(sql,/Posted journal must have at least two balanced lines/);
  assert.match(sql,/status = 'posted'/);
  assert.doesNotMatch(sql,/update public\.(invoices|expenses|customer_payments|expense_payments)\b/i);
  assert.doesNotMatch(sql,/delete from public\.accounting_journal/i);
});

test('accountant centre exposes manual ledger posting with confirmation',()=>{
  const html=fs.readFileSync('public/index.html','utf8');
  const js=fs.readFileSync('public/accountant-centre.js','utf8');
  assert.match(html,/postAccountingLedger/);
  assert.match(html,/Post Accounting Ledger/);
  assert.match(js,/rpc\('v6192_post_operational_ledger'/);
  assert.match(js,/confirm\(`Post accounting journals/);
  assert.match(js,/Already posted source records are skipped|Posted \$\{num\(x\.posted\)\} journals/);
});
