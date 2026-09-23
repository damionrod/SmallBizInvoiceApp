// Execute the actual webhook with isolated Stripe/database fixtures.
// No real webhooks, payments, emails, credentials, or network calls are used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const { test } = require('node:test');

const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'supabase/functions/stripe-webhook/index.ts'), 'utf8');
const start = 1790130136;
const end = 1792722136;
const periodStart = new Date(start * 1000).toISOString();
const periodEnd = new Date(end * 1000).toISOString();
const businessId = 'business_fixture';
const subscriptionId = 'sub_fixture';
const customerId = 'cus_fixture';
const planId = 'pro_fixture';

function subscription(overrides = {}) {
  return {
    id: subscriptionId, customer: customerId, status: 'active', cancel_at_period_end: false,
    metadata: { business_id: businessId, plan_id: planId, billing_interval: 'monthly' },
    items: { data: [{ current_period_start: start, current_period_end: end, price: { id: 'price_fixture' } }] },
    ...overrides,
  };
}

function checkout(overrides = {}) {
  return {
    id: 'cs_test_fixture', mode: 'subscription', payment_status: 'paid',
    subscription: subscriptionId, customer: customerId,
    metadata: { business_id: businessId, plan_id: planId, billing_interval: 'monthly' },
    ...overrides,
  };
}

function harness(stripeSubscription = subscription()) {
  let handler;
  let event;
  const writes = [], rpcCalls = [], retrievals = [], network = [];
  const state = { databaseError: false };
  const rows = {
    subscriptions: [{
      business_id: businessId, plan_id: 'trial_fixture', status: 'trialing',
      stripe_customer_id: null, stripe_subscription_id: null, trial_ends_at: '2026-10-07T00:00:00.000Z',
      invoice_limit_override: 77,
    }, { business_id: 'other_business', plan_id: 'other_plan', status: 'active' }],
    invoice_payment_transactions: [{ id: 'transaction_fixture', status: 'pending' }],
  };
  const db = {
    from(table) {
      assert.ok(rows[table], `Unexpected table: ${table}`);
      let patch = null;
      const filters = [];
      const builder = {
        update(value) { patch = value; return builder; },
        select() { return builder; },
        eq(key, value) { filters.push(row => row[key] === value); return builder; },
        neq(key, value) { filters.push(row => row[key] !== value); return builder; },
        maybeSingle() { return Promise.resolve({ data: rows[table].find(row => filters.every(f => f(row))) || null, error: null }); },
        then(resolve, reject) {
          return Promise.resolve().then(() => {
            if (state.databaseError) return { error: new Error('Fixture database update failed') };
            if (patch) {
              assert.ok(filters.length, 'Every update must be scoped');
              writes.push({ table, patch: structuredClone(patch) });
              rows[table].filter(row => filters.every(f => f(row))).forEach(row => Object.assign(row, structuredClone(patch)));
            }
            return { error: null };
          }).then(resolve, reject);
        },
      };
      return builder;
    },
    async rpc(name, args) {
      rpcCalls.push({ name, args: structuredClone(args) });
      assert.ok(['v6151_process_referral_event', 'v6181_record_online_invoice_payment'].includes(name));
      return { error: null };
    },
  };
  class StripeMock {
    constructor() {
      this.webhooks = { constructEventAsync: async (_body, signature) => {
        if (signature !== 'fixture-valid') throw new Error('Invalid fixture signature');
        return event;
      } };
      this.subscriptions = { retrieve: async id => {
        assert.equal(id, stripeSubscription.id);
        retrievals.push(id);
        return stripeSubscription;
      } };
    }
  }
  const context = vm.createContext({
    Request, Response, URL, URLSearchParams, console,
    Stripe: StripeMock, createClient: () => db, STRIPE_API_VERSION: '2026-07-29.dahlia',
    getStripeConfig: async () => ({ secretKey: 'sk_test_fixture_only', webhookSecret: 'whsec_fixture_only' }),
    stripeHeaders: () => ({ Authorization: 'Bearer fixture-only' }),
    Deno: {
      env: { get: key => ({ SUPABASE_URL: 'https://example.test', SUPABASE_SERVICE_ROLE_KEY: 'fixture-only' })[key] },
      serve: callback => { handler = callback; },
    },
    async fetch(input, init) {
      network.push({ input, init });
      assert.equal(new URL(input).pathname, '/v1/payment_intents/pi_fixture');
      assert.equal(init.headers['Stripe-Account'], 'acct_fixture');
      return new Response(JSON.stringify({
        id: 'pi_fixture', amount_received: 2549,
        latest_charge: { id: 'ch_fixture', balance_transaction: { fee: 98, net: 2451 } },
      }));
    },
  });
  vm.runInContext(stripTypeScriptTypes(source.replace(/^import[^\n]*\n/gm, '')), context);
  return {
    rows, writes, rpcCalls, retrievals, network, state,
    async send(type, object, { signature = 'fixture-valid', account } = {}) {
      event = { id: 'evt_fixture', type, data: { object }, created: start, account };
      const headers = signature === null ? {} : { 'stripe-signature': signature };
      const response = await handler(new Request('https://example.test/webhook', { method: 'POST', headers, body: '{}' }));
      return { status: response.status, body: await response.text() };
    },
  };
}

test('completed Pro checkout replaces Trial using current Stripe item dates', async () => {
  const app = harness();
  const result = await app.send('checkout.session.completed', checkout());
  assert.equal(result.status, 200, result.body);
  const row = app.rows.subscriptions[0];
  assert.equal(row.plan_id, planId);
  assert.equal(row.status, 'active');
  assert.equal(row.stripe_customer_id, customerId);
  assert.equal(row.stripe_subscription_id, subscriptionId);
  assert.equal(row.current_period_start, periodStart);
  assert.equal(row.current_period_end, periodEnd);
  assert.equal(row.trial_ends_at, null);
  assert.equal(row.billing_interval, 'monthly');
  assert.equal(row.invoice_limit_override, 77);
  assert.deepEqual(app.rows.subscriptions[1], { business_id: 'other_business', plan_id: 'other_plan', status: 'active' });
  assert.ok(app.writes.every(write => write.table === 'subscriptions'));
  assert.equal(app.network.length, 0);
});

test('current subscription creation, renewal, cancellation and payment statuses retain their behavior', async () => {
  for (const [type, status, expected] of [
    ['customer.subscription.created', 'active', 'active'],
    ['customer.subscription.updated', 'active', 'active'],
    ['customer.subscription.updated', 'past_due', 'past_due'],
    ['customer.subscription.updated', 'trialing', 'trialing'],
    ['customer.subscription.deleted', 'canceled', 'canceled'],
  ]) {
    const sub = subscription({ status, cancel_at_period_end: true });
    const app = harness(sub);
    const result = await app.send(type, sub);
    assert.equal(result.status, 200, `${type}: ${result.body}`);
    assert.equal(app.rows.subscriptions[0].status, expected);
    assert.equal(app.rows.subscriptions[0].current_period_start, periodStart);
    assert.equal(app.rows.subscriptions[0].current_period_end, periodEnd);
    assert.equal(app.rows.subscriptions[0].cancel_at_period_end, true);
    assert.equal(app.rows.subscriptions[0].stripe_subscription_id, subscriptionId);
  }
});

test('older Stripe snapshots with subscription-level dates still work', async () => {
  const sub = subscription({ items: { data: [] }, current_period_start: start, current_period_end: end });
  const app = harness(sub);
  for (const [type, object] of [['checkout.session.completed', checkout()], ['customer.subscription.updated', sub]]) {
    const result = await app.send(type, object);
    assert.equal(result.status, 200, result.body);
    assert.equal(app.rows.subscriptions[0].current_period_start, periodStart);
    assert.equal(app.rows.subscriptions[0].current_period_end, periodEnd);
  }
});

test('missing or invalid dates never overwrite the business subscription', async () => {
  for (const item of [{}, { current_period_start: start, current_period_end: start - 1 }, { current_period_start: NaN, current_period_end: end }]) {
    const sub = subscription({ items: { data: [item] } });
    const app = harness(sub);
    const result = await app.send('customer.subscription.updated', sub);
    assert.equal(result.status, 500);
    assert.equal(app.writes.length, 0);
    assert.equal(app.rows.subscriptions[0].status, 'trialing');
  }
});

test('database failures are returned for Stripe retry instead of acknowledging an unsaved subscription', async () => {
  const sub = subscription();
  for (const [type, object] of [['checkout.session.completed', checkout()], ['customer.subscription.updated', sub]]) {
    const app = harness(sub);
    app.state.databaseError = true;
    const result = await app.send(type, object);
    assert.equal(result.status, 500);
    assert.equal(app.rows.subscriptions[0].status, 'trialing');
    assert.equal(app.rpcCalls.length, 0);
  }
});

test('repeated checkout events update the same subscription without duplicate records', async () => {
  const app = harness();
  for (let attempt = 0; attempt < 2; attempt++) assert.equal((await app.send('checkout.session.completed', checkout())).status, 200);
  assert.equal(app.rows.subscriptions.length, 2);
  assert.equal(app.rows.subscriptions.filter(row => row.business_id === businessId).length, 1);
  assert.equal(app.rows.subscriptions[0].stripe_subscription_id, subscriptionId);
});

test('connected invoice payments still use the existing settlement function and do not change subscriptions', async () => {
  const app = harness();
  const before = structuredClone(app.rows.subscriptions);
  const result = await app.send('checkout.session.completed', checkout({
    mode: 'payment', subscription: null, amount_total: 2549, payment_intent: 'pi_fixture',
    metadata: { business_id: businessId, payment_transaction_id: 'transaction_fixture' },
  }), { account: 'acct_fixture' });
  assert.equal(result.status, 200, result.body);
  assert.deepEqual(app.rows.subscriptions, before);
  assert.equal(app.retrievals.length, 0);
  assert.equal(app.rows.invoice_payment_transactions[0].gross_amount, 25.49);
  assert.equal(app.rows.invoice_payment_transactions[0].stripe_fee_amount, 0.98);
  assert.equal(app.rows.invoice_payment_transactions[0].net_amount, 24.51);
  assert.equal(app.rpcCalls.length, 1);
  assert.equal(app.rpcCalls[0].name, 'v6181_record_online_invoice_payment');
  assert.equal(app.rpcCalls[0].args.p_transaction_id, 'transaction_fixture');
});

test('missing and invalid signatures still reject events before subscription updates', async () => {
  const app = harness();
  for (const signature of [null, 'invalid-fixture']) {
    assert.equal((await app.send('checkout.session.completed', checkout(), { signature })).status, 400);
  }
  assert.equal(app.writes.length, 0);
  assert.equal(app.retrievals.length, 0);
  assert.equal(app.rpcCalls.length, 0);
});
