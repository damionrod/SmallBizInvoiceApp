const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const root = path.resolve(__dirname, '..');

test('voided bills remain visible as history without payable actions or totals', () => {
  const nodes = new Map();
  const node = id => {
    if (!nodes.has(id)) nodes.set(id, {
      value: '', textContent: '', innerHTML: '',
      querySelectorAll: () => []
    });
    return nodes.get(id);
  };
  const window = {
    FinloCore: {dom: {byId: node}, text: {escapeHtml: String}, value: {num: x => Number(x || 0)}},
    SAAS: {state: {business: {settings: {currency: 'NZD'}}}}
  };
  const document = {getElementById: node};
  let source = fs.readFileSync(path.join(root, 'public/expenses.js'), 'utf8');
  source = source.replace('  window.Expenses={init,',
    '  window.__test={state,statusOf,supplierCreditAdjustedOutstanding,renderBills,renderBillsSummary,isActiveExpense};\n  window.Expenses={init,');
  vm.runInNewContext(source, {window, document, Intl, Date, console});
  const active = {id: 'active', expense_number: 'EXP-A', invoice_date: '2026-09-24',
    payment_status: 'unpaid', lifecycle_state: 'recorded', total_amount: 40.25,
    gst_amount: 5.25, ex_gst: 35, expense_payments: []};
  const voided = {id: 'voided', expense_number: 'EXP-V', invoice_date: '2026-09-24',
    payment_status: 'unpaid', lifecycle_state: 'voided', total_amount: 115,
    gst_amount: 15, ex_gst: 100, expense_payments: []};
  window.__test.state.expenses = [active, voided];
  window.__test.renderBills();
  assert.equal(window.__test.statusOf(voided), 'voided');
  assert.equal(window.__test.supplierCreditAdjustedOutstanding(voided), 0);
  assert.equal(window.__test.isActiveExpense(voided), false);
  assert.match(node('expenseRows').innerHTML, /EXP-V[\s\S]*Voided/);
  assert.doesNotMatch(node('expenseRows').innerHTML.match(/EXP-V[\s\S]*?<\/tr>/)?.[0] || '', /data-exp-(pay|edit|archive|rec)=/);
  assert.match(node('expenseRows').innerHTML, /EXP-A/);
  assert.equal(node('expBillsTotal').textContent, 'NZD\u00a040.25');
  assert.equal(node('expBillsGst').textContent, 'NZD\u00a05.25');
  assert.equal(node('expBillsUnpaidCount').textContent, '1 bill');
});

test('bank matching does not offer voided supplier bills', () => {
  const source = fs.readFileSync(path.join(root, 'public/bank-reconciliation.js'), 'utf8');
  assert.match(source, /\.or\('lifecycle_state\.is\.null,lifecycle_state\.eq\.recorded'\)/);
});
