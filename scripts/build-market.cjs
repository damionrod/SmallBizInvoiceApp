'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createHash } = require('node:crypto');
const root = path.resolve(__dirname, '..');
const project = 'smvvevrtjqkflyqkyape';
const site = '2b57d35f-1627-4e0a-82f0-d1817966b606';
function fail(message) { throw new Error(message); }
if (process.env.SITE_ID && process.env.SITE_ID !== site) fail('This branch can only build on the Frindly Market Netlify project.');
const context = { window: {} };
vm.runInNewContext(fs.readFileSync(path.join(root, 'public/app-config.js'), 'utf8'), context);
const c = context.window.APP_CONFIG;
if (!c || c.environment !== 'market' || c.projectRef !== project ||
    c.supabaseUrl !== 'https://' + project + '.supabase.co' ||
    !String(c.supabaseKey || '').startsWith('sb_publishable_') ||
    c.outboundServicesEnabled !== false || c.stripeEnabled !== false) {
  fail('Refusing to build: isolated Market configuration is required.');
}
const publicDir = path.join(root, 'public');
for (const name of fs.readdirSync(publicDir)) {
  if (!/\.(js|html|css)$/.test(name)) continue;
  const content = fs.readFileSync(path.join(publicDir, name), 'utf8');
  const hasSecret = /(?:sb_secret_[A-Za-z0-9_-]{16,}|sk_live_[A-Za-z0-9]{16,})/.test(content);
  const hasServiceJwt = [...content.matchAll(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g)].some(([token]) => {
    try { return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).role === 'service_role'; }
    catch { return false; }
  });
  if (content.includes('oxsbzytwbphagcbilxud') || hasSecret || hasServiceJwt) {
    fail('Refusing to publish a production reference or privileged key in ' + name);
  }
}
const output = path.join(root, 'dist-market');
fs.rmSync(output, { recursive: true, force: true });
fs.cpSync(publicDir, output, { recursive: true });
const api = 'https://' + project + '.supabase.co';
const csp = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' https://fonts.gstatic.com data:",
  "img-src 'self' data: blob: " + api,
  "connect-src 'self' " + api + "/rest/v1/ " + api + "/auth/v1/token " + api + "/auth/v1/user " + api + "/auth/v1/logout " + api + "/storage/v1/ " + api + "/functions/v1/import-migration-analyse " + api + "/functions/v1/frindly-expense-assessment-preview " + api + "/functions/v1/frindly-expense-assessment-readonly " + api + "/functions/v1/frindly-expense-correction-gateway wss://" + project + ".supabase.co/realtime/",
  "frame-src 'none'",
  "form-action 'self'",
  "base-uri 'self'",
  "object-src 'none'"
].join('; ');
const headers = [
  '/*',
  '  Content-Security-Policy: ' + csp,
  '  X-Robots-Tag: noindex, nofollow, noarchive',
  '  Referrer-Policy: no-referrer',
  '  X-Content-Type-Options: nosniff',
  '  X-Frame-Options: DENY',
  '  Permissions-Policy: payment=(), geolocation=(), microphone=()',
  ''
].join('\n');
fs.writeFileSync(path.join(output, '_headers'), headers);
fs.writeFileSync(path.join(output, 'robots.txt'), 'User-agent: *\nDisallow: /\n');
fs.appendFileSync(path.join(output, 'frontend-quality.css'), '\n.market-environment-banner{padding:7px 16px;text-align:center;background:#38236b;color:#fff;font:600 12px/1.4 Lato,sans-serif;position:relative;z-index:10010}\n');
// Hash final published bytes, including generated CSS, rather than hand-written release tags.
const hash = bytes => createHash('sha256').update(bytes).digest('hex').slice(0, 16);
const assets = Object.fromEntries(fs.readdirSync(output).sort()
  .filter(name => /\.(?:js|css)$/.test(name))
  .map(name => [name, hash(fs.readFileSync(path.join(output, name)))]));
const assetManifest = 'window.FRINDLY_BUILD_ASSETS=Object.freeze(' + JSON.stringify(assets) + ');\n';
fs.writeFileSync(path.join(output, 'runtime-assets.js'), assetManifest);
for (const name of fs.readdirSync(output).filter(name => /\.html$/.test(name))) {
  const file = path.join(output, name);
  let html = fs.readFileSync(file, 'utf8');
  if (!/<head(?:\s[^>]*)?>/i.test(html)) fail('Missing document head in ' + name);
  html = html.replace(/((?:src|href)=["'])([^"']+)(["'])/g, (match, before, url, after) => {
    const [pathname, fragment] = url.split('#', 2);
    const key = pathname.split('?')[0].replace(/^\.\//, '').replace(/^\//, '');
    if (!assets[key]) return match;
    const [base, query = ''] = pathname.split('?', 2);
    const params = new URLSearchParams(query);
    params.set('v', assets[key]);
    return before + base + '?' + params.toString() + (fragment === undefined ? '' : '#' + fragment) + after;
  });
  html = html.replace(/<head(?:\s[^>]*)?>/i, head => head + '\n<script src="runtime-assets.js?v=' + hash(assetManifest) + '"></script>');
  fs.writeFileSync(file, html);
}
fs.writeFileSync(path.join(output, 'market-build.json'), JSON.stringify({
  environment: 'market', projectRef: project, siteId: site,
  version: c.version, outboundServicesEnabled: false,
  sourceCommit: process.env.COMMIT_REF || null
}, null, 2) + '\n');
console.log('Frindly Market build ready. Database: isolated test project. Outbound services: blocked.');
