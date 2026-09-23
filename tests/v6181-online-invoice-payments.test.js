const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const checks = [];
const assert = (name, condition) => { checks.push([name, !!condition]); if (!condition) throw new Error(name); };

const migration = read('supabase/migrations/20260922200000_v6181_online_invoice_payments_foundation.sql');
const shared = read('supabase/functions/_shared/invoice-payments.ts');
const config = read('supabase/functions/_shared/payment-config.ts');
const payments = read('supabase/functions/invoice-payments/index.ts');
const email = read('supabase/functions/send-invoice/index.ts');
const webhook = read('supabase/functions/stripe-webhook/index.ts');
const saas = read('public/saas.js');
const html = read('public/index.html');
const payHtml = read('public/pay.html');
const payJs = read('public/pay.js');
const supabaseConfig = read('supabase/config.toml');

assert('module is seeded disabled by default', migration.includes("'invoice_payments'") && migration.includes("false\nwhere not exists"));
assert('settings store fee mode and partial-payment choice', migration.includes("fee_mode in ('bear','split','pass')") && migration.includes('allow_partial_payments'));
assert('online transactions stay separate from invoice ledger', migration.includes('create table if not exists public.invoice_payment_transactions') && migration.includes('invoice_payment_transaction_id'));
assert('transaction settlement locks invoice and blocks overpayment', migration.includes('for update') && migration.includes('exceeds the remaining invoice balance'));
assert('server entitlement requires global module plus plan or business override', migration.includes('v6181_invoice_payments_enabled') && migration.includes("m.is_active = true") && migration.includes('business_modules') && migration.includes('included_modules'));
assert('public payment links store only a token hash', shared.includes('hashOpaqueToken') && payments.includes('token_hash') && email.includes('tokenHash'));
assert('Connect uses Accounts v2 and full dashboard onboarding', config.includes('STRIPE_CONNECT_API_VERSION') && payments.includes('/v2/core/accounts') && payments.includes('dashboard: \'full\'') && payments.includes('/v2/core/account_links'));
assert('direct charge is scoped to the connected account', payments.includes("'Stripe-Account': String(record.settings.stripe_account_id)") && payments.includes("form.set('mode', 'payment')"));
assert('webhook settles through the atomic database function', webhook.includes('v6181_record_online_invoice_payment') && webhook.includes('checkout.session.async_payment_succeeded'));
assert('invoice email adds Pay Now only when setup is active', email.includes('Pay Now') && email.includes('connect_status === \'active\'') && email.includes('invoice_payment_links'));
assert('settings exposes fee and partial-payment controls', html.includes('id="onlinePaymentsSettingsNav"') && saas.includes('id="invoicePaymentFeeMode"') && saas.includes('id="invoicePaymentPartial"'));
assert('Superadmin gets a separate monitoring page', html.includes('data-admin-view="invoice-payments"') && html.includes('id="adminInvoicePaymentRows"') && saas.includes('renderAdminInvoicePayments'));
assert('frontend entitlement fails closed when module is globally inactive', saas.includes('modules!inner(slug,is_active)') && saas.includes('module?.is_active!==true') && saas.includes("'invoice_payments'"));
assert('customer page supports partial amounts and hosted checkout', payHtml.includes('id="paymentAmount"') && payJs.includes("call('checkout'") && payJs.includes('allow_partial_payments'));
assert('public checkout and Stripe webhook bypass the Supabase JWT gate', supabaseConfig.includes('[functions.invoice-payments]') && supabaseConfig.includes('[functions.stripe-webhook]') && supabaseConfig.includes('verify_jwt = false'));

for (const [name] of checks) console.log('PASS', name);
console.log(`${checks.length}/${checks.length} V61.81 Online Invoice Payments static checks PASS`);
