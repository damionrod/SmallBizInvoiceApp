// Runs the actual Edge Function with in-memory Supabase/Stripe substitutes.
// No credentials, real accounts, payments, or network requests are used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createHash, webcrypto } = require('node:crypto');
const { stripTypeScriptTypes } = require('node:module');
const { test } = require('node:test');

const root = path.join(__dirname, '..');
const accountId = 'acct_mock_existing';
const businessId = 'business_mock';
const token = 'mock-invoice-token-not-a-real-payment-link';
const requestUrl = 'https://example.test/functions/v1/invoice-payments';

function harness({ existing = true } = {}) {
  const state = { signedIn: true, role: 'owner', enabled: true, cardStatus: 'active', stripeError: null };
  const calls = [];
  const writes = [];
  const rows = {
    payment_provider_settings: [{ provider: 'stripe', enabled: true, mode: 'test', public_config: {} }],
    businesses: [{ id: businessId, name: 'Mock business', settings: {} }],
    invoice_payment_settings: existing ? [{
      business_id: businessId, stripe_account_id: accountId, connect_status: 'active',
      fee_mode: 'split', fee_percent: 2.65, fee_fixed_amount: 0.30,
      allow_partial_payments: true, currency: 'nzd',
    }] : [],
    invoice_payment_links: [{
      id: 'link_mock', business_id: businessId, invoice_id: 'invoice_mock', active: true,
      expires_at: null, token_hash: createHash('sha256').update(token).digest('hex'),
    }],
    invoices: [{
      id: 'invoice_mock', business_id: businessId, invoice_number: 'TEST-01',
      total: 100, amount_paid: 20, balance_due: 80, lifecycle_state: 'issued',
      customer_name: 'Test customer', customer_email: 'customer@example.test', company_snapshot: {},
    }],
    invoice_payment_transactions: [],
  };

  function query(table) {
    assert.ok(Object.hasOwn(rows, table), `Unexpected table: ${table}`);
    let operation = 'select';
    let patch;
    const filters = [];
    const matches = (row) => filters.every(([key, value]) => row[key] === value);
    const execute = () => {
      if (operation === 'select') return { data: structuredClone(rows[table].find(matches) || null), error: null };
      writes.push({ table, operation, patch: structuredClone(patch) });
      if (operation === 'upsert') {
        const previous = rows[table].find((row) => row.business_id === patch.business_id);
        if (previous) Object.assign(previous, patch);
        else rows[table].push(structuredClone(patch));
        return { data: structuredClone(previous || patch), error: null };
      }
      if (operation === 'insert') {
        const row = { id: `transaction_mock_${rows[table].length + 1}`, ...structuredClone(patch) };
        rows[table].push(row);
        return { data: structuredClone(row), error: null };
      }
      rows[table].filter(matches).forEach((row) => Object.assign(row, patch));
      return { data: null, error: null };
    };
    const builder = {
      select() { return builder; },
      eq(key, value) { filters.push([key, value]); return builder; },
      maybeSingle() { return Promise.resolve(execute()); },
      single() { return Promise.resolve(execute()); },
      upsert(value) { operation = 'upsert'; patch = value; return builder; },
      insert(value) { operation = 'insert'; patch = value; return builder; },
      update(value) { operation = 'update'; patch = value; return builder; },
      then(resolve, reject) { return Promise.resolve().then(execute).then(resolve, reject); },
    };
    return builder;
  }

  const admin = {
    from: query,
    async rpc(name, args) {
      if (name === 'v6181_invoice_payments_enabled') {
        assert.equal(args.p_business_id, businessId);
        return { data: state.enabled, error: null };
      }
      if (name === 'v34_get_payment_provider_secret') {
        return { data: JSON.stringify({ secret_key: 'sk_test_mock_only' }), error: null };
      }
      throw new Error(`Unexpected admin RPC: ${name}`);
    },
  };
  const client = {
    auth: { async getUser() { return { data: { user: state.signedIn ? { id: 'user_mock', email: 'owner@example.test' } : null } }; } },
    async rpc(name) {
      if (name === 'current_business_id') return { data: businessId, error: null };
      if (name === 'v6147_current_business_role') return { data: state.role, error: null };
      throw new Error(`Unexpected client RPC: ${name}`);
    },
  };
  const account = () => ({
    id: accountId,
    configuration: { merchant: { capabilities: { card_payments: { status: state.cardStatus } } } },
    identity: { status: 'verified' }, requirements: {},
  });
  const json = (data, status = 200) => new Response(JSON.stringify(data), { status });
  let handler;
  const context = vm.createContext({
    URL, URLSearchParams, Request, Response, TextEncoder, btoa, crypto: webcrypto,
    createClient: (_url, key) => key === 'service_mock' ? admin : client,
    Deno: {
      env: { get: (name) => ({ SUPABASE_URL: 'https://example.test', SUPABASE_ANON_KEY: 'anon_mock', SUPABASE_SERVICE_ROLE_KEY: 'service_mock', PUBLIC_APP_URL: 'https://app.example.test' })[name] },
      serve: (callback) => { handler = callback; },
    },
    async fetch(input, init = {}) {
      const url = new URL(input);
      const method = init.method || 'GET';
      calls.push({ url, method, headers: init.headers, body: init.body });
      assert.equal(url.origin, 'https://api.stripe.com');
      if (url.pathname.startsWith('/v2/')) {
        if (init.headers['Content-Type'] !== 'application/json') {
          return json({ error: { message: 'For v2 API endpoints, only JSON is supported.' } }, 400);
        }
        assert.equal(init.headers['Stripe-Version'], '2026-08-26.preview');
      }
      if (url.pathname === `/v2/core/accounts/${accountId}` && method === 'GET') {
        if (state.stripeError) return json({ error: { message: state.stripeError } }, 400);
        if (url.searchParams.has('include[]')) return json({ error: { message: 'v2 include query parameters require indices.' } }, 400);
        assert.deepEqual([...url.searchParams], [
          ['include[0]', 'configuration.merchant'], ['include[1]', 'identity'], ['include[2]', 'requirements'],
        ]);
        assert.equal(init.body, undefined, 'A v2 GET keeps includes in the query, not a request body');
        return json(account());
      }
      if (url.pathname === '/v2/core/accounts' && method === 'POST') {
        assert.equal(JSON.parse(init.body).configuration.merchant.capabilities.card_payments.requested, true);
        return json(account());
      }
      if (url.pathname === '/v2/core/account_links' && method === 'POST') {
        const body = JSON.parse(init.body);
        assert.equal(body.account, accountId);
        assert.equal(body.use_case.type, 'account_onboarding');
        assert.equal(body.use_case.account_onboarding.return_url, 'https://app.example.test/?connect=return#settings/payments');
        return json({ url: `https://connect.stripe.com/mock-onboarding/${calls.length}` });
      }
      if (url.pathname === '/v1/checkout/sessions' && method === 'POST') {
        assert.equal(init.headers['Content-Type'], 'application/x-www-form-urlencoded');
        assert.equal(init.headers['Stripe-Account'], accountId);
        assert.equal(init.body.get('mode'), 'payment');
        return json({ id: 'cs_test_mock', url: 'https://checkout.stripe.com/mock-invoice-payment' });
      }
      throw new Error(`Unexpected Stripe request: ${method} ${url.pathname}`);
    },
  });

  for (const file of ['_shared/payment-config.ts', '_shared/invoice-payments.ts', 'invoice-payments/index.ts']) {
    const source = fs.readFileSync(path.join(root, 'supabase/functions', file), 'utf8')
      .replace(/^import\s+[\s\S]*?\s+from\s+['"][^'"]+['"];?\s*/gm, '')
      .replace(/^export\s+/gm, '');
    vm.runInContext(stripTypeScriptTypes(source), context, { filename: file });
  }
  return {
    state, rows, calls, writes,
    async request(action, payload = {}, method = 'POST') {
      const req = new Request(requestUrl, {
        method,
        headers: { 'Content-Type': 'application/json', Authorization: 'Bearer mock-session', Origin: 'https://app.example.test' },
        ...(method === 'OPTIONS' ? {} : { body: JSON.stringify({ action, ...payload }) }),
      });
      const response = await handler(req);
      return { status: response.status, headers: response.headers, body: method === 'OPTIONS' ? await response.text() : await response.json() };
    },
  };
}

test('first setup and a second visit use one account and JSON onboarding', async () => {
  const app = harness({ existing: false });
  const initial = await app.request('status');
  assert.equal(initial.status, 200);
  assert.equal(initial.body.settings.connect_status, 'not_started');
  assert.equal(app.calls.length, 0);
  assert.equal((await app.request('create-account')).status, 200);
  const firstLink = await app.request('create-account-link');
  assert.equal(firstLink.status, 200);
  for (let visit = 0; visit < 2; visit++) {
    const result = await app.request('status');
    assert.equal(result.status, 200, JSON.stringify(result.body));
    assert.equal(result.body.settings.stripe_account_id, accountId);
  }
  const resumed = await app.request('create-account');
  assert.equal(resumed.status, 200, JSON.stringify(resumed.body));
  assert.equal(resumed.body.account_id, accountId);
  const secondLink = await app.request('create-account-link');
  assert.equal(secondLink.status, 200);
  assert.notEqual(secondLink.body.url, firstLink.body.url);
  assert.equal(app.calls.filter((call) => call.method === 'POST' && call.url.pathname === '/v2/core/accounts').length, 1);
});

test('repeat status checks preserve fee/partial settings and report account restrictions', async () => {
  const app = harness();
  app.state.cardStatus = 'restricted';
  const result = await app.request('status');
  assert.equal(result.status, 200, JSON.stringify(result.body));
  assert.equal(result.body.settings.connect_status, 'restricted');
  assert.equal(result.body.settings.fee_mode, 'split');
  assert.equal(result.body.settings.allow_partial_payments, true);
  assert.ok(app.writes.every((write) => write.table === 'invoice_payment_settings'));
  assert.ok(app.writes.every((write) => !Object.hasOwn(write.patch, 'fee_mode') && !Object.hasOwn(write.patch, 'allow_partial_payments')));
});

test('Stripe errors still reach the caller without replacing the existing account', async () => {
  const app = harness();
  app.state.stripeError = 'Mock Stripe account unavailable';
  const result = await app.request('status');
  assert.equal(result.status, 400);
  assert.equal(result.body.error, app.state.stripeError);
  assert.equal(app.rows.invoice_payment_settings[0].stripe_account_id, accountId);
  assert.equal(app.writes.length, 0);
});

test('partial invoice checkout remains form-encoded and scoped to the connected account', async () => {
  const app = harness();
  const result = await app.request('checkout', { token, amount: 25 });
  assert.equal(result.status, 200, JSON.stringify(result.body));
  const call = app.calls.find((item) => item.url.pathname === '/v1/checkout/sessions');
  assert.equal(call.body.get('line_items[0][price_data][unit_amount]'), '2500');
  assert.equal(call.body.get('line_items[1][price_data][unit_amount]'), '49');
  assert.equal(call.body.get('client_reference_id'), 'invoice_mock');
  assert.equal(app.rows.invoice_payment_transactions[0].amount, 25);
  assert.equal(app.rows.invoice_payment_transactions[0].customer_fee_amount, 0.49);
  assert.equal(app.rows.invoice_payment_transactions[0].status, 'processing');
  assert.equal(app.rows.invoices[0].amount_paid, 20, 'Checkout creation must not mark an invoice paid');
  assert.equal(app.rows.invoices[0].balance_due, 80);
});

test('CORS, authentication, owner permissions, and module gating are unchanged', async () => {
  const app = harness();
  const cors = await app.request('', {}, 'OPTIONS');
  assert.equal(cors.status, 200);
  assert.equal(cors.headers.get('Access-Control-Allow-Origin'), '*');
  app.state.signedIn = false;
  assert.equal((await app.request('status')).status, 401);
  app.state.signedIn = true;
  app.state.role = 'member';
  assert.equal((await app.request('create-account')).status, 403);
  app.state.role = 'owner';
  app.state.enabled = false;
  assert.match((await app.request('status')).body.error, /not been enabled/);
  assert.equal(app.calls.length, 0);
  assert.equal(app.writes.length, 0);
});
