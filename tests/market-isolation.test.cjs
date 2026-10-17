'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const configSource = fs.readFileSync(path.join(root, 'public/app-config.js'), 'utf8');
const guardSource = fs.readFileSync(path.join(root, 'public/market-environment.js'), 'utf8');
const project = 'smvvevrtjqkflyqkyape';
const site = '2b57d35f-1627-4e0a-82f0-d1817966b606';
function runtime(changed) {
  const calls = [];
  const window = { supabase: { createClient: (...args) => { calls.push(args); return { args }; } } };
  const context = vm.createContext({ window, document: { addEventListener() {} } });
  vm.runInContext(configSource, context);
  if (changed) window.APP_CONFIG = { ...window.APP_CONFIG, ...changed };
  return { context, window, calls };
}
function fixture(t, mutate) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'frindly-market-build-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  fs.mkdirSync(path.join(temp, 'public'));
  fs.mkdirSync(path.join(temp, 'scripts'));
  fs.copyFileSync(path.join(root, 'scripts/build-market.cjs'), path.join(temp, 'scripts/build-market.cjs'));
  fs.writeFileSync(path.join(temp, 'public/app-config.js'), configSource);
  fs.writeFileSync(path.join(temp, 'public/frontend-quality.css'), '');
  fs.writeFileSync(path.join(temp, 'public/index.html'), '<!doctype html><title>Test</title>');
  if (mutate) mutate(temp);
  return temp;
}
function build(temp, env = {}) {
  return spawnSync(process.execPath, [path.join(temp, 'scripts/build-market.cjs')], {
    encoding: 'utf8', env: { ...process.env, SITE_ID: site, ...env }
  });
}
test('both runtime configurations select the isolated project and disable outbound services', () => {
  assert.equal(fs.readFileSync(path.join(root, 'app-config.js'), 'utf8'), configSource);
  const r = runtime();
  assert.equal(r.window.APP_CONFIG.projectRef, project);
  assert.equal(r.window.APP_CONFIG.stripeEnabled, false);
  assert.equal(r.window.APP_CONFIG.outboundServicesEnabled, false);
  assert.equal(Object.isFrozen(r.window.APP_CONFIG), true);
});
test('legacy settings cannot create a client against production', () => {
  const r = runtime();
  vm.runInContext(guardSource, r.context);
  assert.throws(() => r.window.supabase.createClient('https://oxsbzytwbphagcbilxud.supabase.co', 'old-key'), /cannot connect/);
  assert.equal(r.calls.length, 0);
});
test('a different key is rejected before client creation', () => {
  const r = runtime();
  vm.runInContext(guardSource, r.context);
  assert.throws(() => r.window.supabase.createClient(r.window.APP_CONFIG.supabaseUrl, 'different-key'), /cannot connect/);
  assert.equal(r.calls.length, 0);
});
test('allowed clients use a separate auth storage key and preserve explicit options', () => {
  const r = runtime();
  vm.runInContext(guardSource, r.context);
  r.window.supabase.createClient(r.window.APP_CONFIG.supabaseUrl, r.window.APP_CONFIG.supabaseKey,
    { auth: { persistSession: false }, global: { headers: { test: 'yes' } } });
  assert.equal(r.calls.length, 1);
  assert.equal(r.calls[0][2].auth.storageKey, 'frindly-market-' + project + '-auth-token');
  assert.equal(r.calls[0][2].auth.persistSession, false);
  assert.equal(r.calls[0][2].global.headers.test, 'yes');
});
test('the runtime refuses a configuration with outbound services enabled', () => {
  const r = runtime({ outboundServicesEnabled: true });
  assert.throws(() => vm.runInContext(guardSource, r.context), /isolated test database/);
});
test('the Market branch refuses a build on the live Netlify project', (t) => {
  const temp = fixture(t);
  const result = build(temp, { SITE_ID: '83bd9223-ec6b-4320-8ae0-cf635ab3c7be' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /only build on the Frindly Market/);
  assert.equal(fs.existsSync(path.join(temp, 'dist-market')), false);
});
test('Market hosting excludes legacy scheduled Netlify handlers', () => {
  const config = fs.readFileSync(path.join(root, 'netlify.toml'), 'utf8');
  const section = config.match(/\[functions\]\s*\n([\s\S]*?)(?=\n\[|$)/);
  assert.ok(section, 'Netlify Functions directory must be explicit');
  const directory = section[1].match(/directory\s*=\s*"([^"]+)"/);
  assert.ok(directory, 'Netlify Functions directory must be configured');
  const configured = path.resolve(root, directory[1]);
  assert.notEqual(configured, path.join(root, 'netlify/functions'));
  assert.equal(fs.existsSync(configured), true);
  function executableFiles(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
      const file = path.join(dir, entry.name);
      return entry.isDirectory() ? executableFiles(file) : /\.(?:[cm]?[jt]s|go|zip)$/.test(file) ? [file] : [];
    });
  }
  assert.deepEqual(executableFiles(configured), []);
});
test('a production reference in any published script blocks the build', (t) => {
  const temp = fixture(t, p => fs.writeFileSync(path.join(p, 'public/accidental.js'), 'const project = "oxsbzytwbphagcbilxud";'));
  const result = build(temp);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /production reference/);
});
test('a privileged key in a published file blocks the build', (t) => {
  const temp = fixture(t, p => fs.writeFileSync(path.join(p, 'public/accidental.js'), 'const key = "sb_secret_' + 'a'.repeat(30) + '";'));
  assert.notEqual(build(temp).status, 0);
});
test('a service-role JWT in a published file blocks the build', (t) => {
  const payload = Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64url');
  const temp = fixture(t, p => fs.writeFileSync(path.join(p, 'public/accidental.js'), 'const key = "eyJhbGciOiJIUzI1NiJ9.' + payload + '.signature";'));
  assert.notEqual(build(temp).status, 0);
});
test('valid builds allow internal test services and exclude outbound and signup email routes', (t) => {
  const temp = fixture(t);
  const result = build(temp);
  assert.equal(result.status, 0, result.stderr);
  const headers = fs.readFileSync(path.join(temp, 'dist-market/_headers'), 'utf8');
  const connect = headers.split('\n').find(x => x.includes('Content-Security-Policy:')).split('connect-src ')[1].split(';')[0];
  assert.match(connect, /\/rest\/v1\//);
  assert.match(connect, /\/auth\/v1\/token/);
  assert.match(connect, /\/storage\/v1\//);
  assert.match(connect, /\/functions\/v1\/import-migration-analyse/);
  assert.doesNotMatch(connect, /\/functions\/v1(?:\s|\/\s)|send-invoice|invoice-payments|stripe-webhook|scan-expense-document|\/signup|\/recover|\/otp|supabase\.co(?:\s|$)/);
  assert.match(headers, /X-Robots-Tag: noindex/);
  const manifest = JSON.parse(fs.readFileSync(path.join(temp, 'dist-market/market-build.json'), 'utf8'));
  assert.equal(manifest.projectRef, project);
  assert.equal(manifest.outboundServicesEnabled, false);
});
test('unsafe Market configuration blocks the build', (t) => {
  const temp = fixture(t, p => fs.writeFileSync(path.join(p, 'public/app-config.js'), configSource.replace('stripeEnabled: false', 'stripeEnabled: true')));
  assert.notEqual(build(temp).status, 0);
});
test('payment links show a test notice without issuing a request', () => {
  let fetches = 0;
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, { hidden: false, addEventListener() {}, innerHTML: '', className: '' });
    return elements.get(id);
  }
  const context = {
    window: { APP_CONFIG: { environment: 'market', outboundServicesEnabled: false } },
    document: { getElementById: element }, URLSearchParams,
    location: { search: '?token=test' },
    fetch() { fetches++; throw new Error('Unexpected payment request'); }
  };
  vm.runInNewContext(fs.readFileSync(path.join(root, 'public/pay.js'), 'utf8'), context);
  assert.equal(fetches, 0);
  assert.match(element('paymentMessage').innerHTML, /Payments are disabled/);
});

test('the server outbound guard rejects requests before reading secrets or making a provider call', async () => {
  const { stripTypeScriptTypes } = require('node:module');
  let handler, calls = 0;
  const source = fs.readFileSync(path.join(root, 'ops/market/functions/outbound-disabled/index.ts'), 'utf8');
  vm.runInNewContext(stripTypeScriptTypes(source), {
    Deno: { serve(fn) { handler = fn; }, env: { get() { throw new Error('Unexpected secret read'); } } },
    Response, fetch() { calls++; throw new Error('Unexpected provider call'); }
  });
  const response = await handler(new Request('https://test.invalid', { method: 'POST', body: '{}' }));
  assert.equal(response.status, 503);
  assert.equal((await response.json()).code, 'MARKET_OUTBOUND_DISABLED');
  assert.equal(calls, 0);
});
test('the outbound guard provides CORS preflight without performing an action', () => {
  const { stripTypeScriptTypes } = require('node:module');
  let handler;
  vm.runInNewContext(stripTypeScriptTypes(fs.readFileSync(path.join(root, 'ops/market/functions/outbound-disabled/index.ts'), 'utf8')), {
    Deno: { serve(fn) { handler = fn; } }, Response
  });
  const response = handler(new Request('https://test.invalid', { method: 'OPTIONS' }));
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), 'https://frindly-market.netlify.app');
});
test('migration AI stays disabled even if its optional enabled argument is true', async () => {
  const { stripTypeScriptTypes } = require('node:module');
  const source = fs.readFileSync(path.join(root, 'ops/market/functions/import-migration-analyse/index.ts'), 'utf8');
  const js = stripTypeScriptTypes(source).replace(/^import .*?;\s*$/gm, '');
  let requests = 0, secretReads = 0;
  const context = vm.createContext({
    Deno: { serve() {}, env: { get(name) { if (name.startsWith('OPENAI')) secretReads++; return undefined; } } },
    fetch() { requests++; throw new Error('Unexpected AI request'); },
    TextEncoder, TextDecoder, URL, URLSearchParams, Response, Request
  });
  vm.runInContext(js, context);
  const result = await vm.runInContext('optionalAiCandidates("invoices", [], true)', context);
  assert.equal(result.length, 0);
  assert.equal(requests, 0);
  assert.equal(secretReads, 0);
});
