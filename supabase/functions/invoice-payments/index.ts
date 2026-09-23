import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  getStripeConfig,
  randomIntegrationSuffix,
  stripeConnectHeaders,
} from '../_shared/payment-config.ts';
import {
  INVOICE_PAYMENTS_MODULE,
  appOrigin,
  calculateCustomerFee,
  cents,
  createOpaqueToken,
  hashOpaqueToken,
  normaliseCurrency,
  paymentJson,
  roundCents,
} from '../_shared/invoice-payments.ts';

type Context = {
  client: any;
  admin: any;
  user: any;
  businessId: string;
  role: string;
};

function bad(message: string, status = 400) {
  return paymentJson({ error: message }, status);
}

async function contextFor(req: Request, ownerOnly = false): Promise<Context | Response> {
  const url = Deno.env.get('SUPABASE_URL');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !service) return bad('Supabase configuration is missing.', 500);

  const auth = req.headers.get('Authorization') || '';
  const client = createClient(url, anon, { global: { headers: { Authorization: auth } } });
  const admin = createClient(url, service);
  const { data: { user } } = await client.auth.getUser();
  if (!user) return bad('Not authenticated.', 401);

  const { data: businessId, error: businessError } = await client.rpc('current_business_id');
  if (businessError || !businessId) return bad('No active business context found.', 403);
  const { data: role, error: roleError } = await client.rpc('v6147_current_business_role', { p_business_id: businessId });
  if (roleError || !role) return bad('Business access could not be verified.', 403);
  if (ownerOnly && role !== 'owner') return bad('Only the Business Owner can manage Stripe payout settings.', 403);

  return { client, admin, user, businessId: String(businessId), role: String(role) };
}

async function requireEnabled(admin: any, businessId: string) {
  const { data, error } = await admin.rpc('v6181_invoice_payments_enabled', { p_business_id: businessId });
  if (error) throw new Error(`Online Invoice Payments is not available: ${error.message}`);
  if (data !== true) throw new Error('Online Invoice Payments has not been enabled for this business by the platform administrator.');
}

async function stripeAccount(secret: string, accountId: string) {
  const params = new URLSearchParams();
  params.append('include[]', 'configuration.merchant');
  params.append('include[]', 'identity');
  params.append('include[]', 'requirements');
  const response = await fetch(`https://api.stripe.com/v2/core/accounts/${encodeURIComponent(accountId)}?${params.toString()}`, {
    headers: stripeConnectHeaders(secret),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || 'Unable to retrieve the connected Stripe account.');
  return data;
}

function cardStatus(account: any): string {
  return String(account?.configuration?.merchant?.capabilities?.card_payments?.status || 'not_requested');
}

function connectStatus(account: any): string {
  const status = cardStatus(account);
  if (status === 'active') return 'active';
  if (['restricted', 'inactive'].includes(status)) return 'restricted';
  return 'pending';
}

async function saveAccountStatus(admin: any, businessId: string, account: any) {
  const requirements = account?.requirements || {};
  const patch = {
    stripe_account_id: String(account?.id || ''),
    connect_status: connectStatus(account),
    card_payments_status: cardStatus(account),
    details_submitted: account?.details_submitted === true || account?.identity?.status === 'verified',
    requirements,
    updated_at: new Date().toISOString(),
  };
  const { error } = await admin.from('invoice_payment_settings').upsert({
    business_id: businessId,
    ...patch,
  }, { onConflict: 'business_id' });
  if (error) throw error;
  return patch;
}

async function getSettings(admin: any, businessId: string) {
  const { data, error } = await admin.from('invoice_payment_settings').select('*').eq('business_id', businessId).maybeSingle();
  if (error) throw error;
  return data || {
    business_id: businessId,
    stripe_account_id: null,
    connect_status: 'not_started',
    card_payments_status: 'not_requested',
    details_submitted: false,
    requirements: {},
    fee_mode: 'bear',
    fee_percent: 2.65,
    fee_fixed_amount: 0.30,
    allow_partial_payments: true,
    currency: 'nzd',
  };
}

async function loadPublicPayment(admin: any, token: string) {
  const tokenHash = await hashOpaqueToken(token);
  const { data: link, error: linkError } = await admin
    .from('invoice_payment_links')
    .select('id,business_id,invoice_id,active,expires_at')
    .eq('token_hash', tokenHash)
    .eq('active', true)
    .maybeSingle();
  if (linkError || !link) throw new Error('This payment link is invalid or has been disabled.');
  if (link.expires_at && new Date(link.expires_at) < new Date()) throw new Error('This payment link has expired.');

  const { data: invoice, error: invoiceError } = await admin
    .from('invoices')
    .select('id,business_id,invoice_number,customer_name,customer_email,total,amount_paid,balance_due,due_date,lifecycle_state,company_snapshot')
    .eq('id', link.invoice_id)
    .eq('business_id', link.business_id)
    .single();
  if (invoiceError || !invoice) throw new Error('Invoice not found.');
  if (invoice.lifecycle_state === 'voided') throw new Error('This invoice has been voided.');

  const settings = await getSettings(admin, String(link.business_id));
  const snapshot = invoice.company_snapshot || {};
  const balance = roundCents(Math.max(0, Number(invoice.balance_due ?? (Number(invoice.total || 0) - Number(invoice.amount_paid || 0)))));
  return {
    link,
    invoice,
    settings,
    balance,
    currency: normaliseCurrency(settings.currency || snapshot.currency || 'nzd'),
    businessName: String(snapshot.trading || snapshot.company || 'Your Business'),
  };
}

async function createConnectAccount(ctx: Context, req: Request) {
  await requireEnabled(ctx.admin, ctx.businessId);
  const cfg = await getStripeConfig(ctx.admin, true);
  const { data: business, error: businessError } = await ctx.admin.from('businesses').select('id,name,settings').eq('id', ctx.businessId).single();
  if (businessError || !business) throw new Error('Business details could not be loaded.');
  const existing = await getSettings(ctx.admin, ctx.businessId);
  if (existing.stripe_account_id) {
    const account = await stripeAccount(cfg.secretKey, existing.stripe_account_id);
    const status = await saveAccountStatus(ctx.admin, ctx.businessId, account);
    return paymentJson({ success: true, account_id: existing.stripe_account_id, settings: { ...existing, ...status }, account });
  }

  const settings = business.settings || {};
  const body = {
    contact_email: String(ctx.user.email || '').trim() || undefined,
    display_name: String(business.name || settings.company || settings.trading || 'Frindly business').trim(),
    dashboard: 'full',
    identity: { country: 'nz' },
    configuration: { merchant: { capabilities: { card_payments: { requested: true } } } },
    defaults: { responsibilities: { fees_collector: 'stripe', losses_collector: 'stripe' } },
    include: ['configuration.merchant', 'identity', 'requirements'],
  };
  const response = await fetch('https://api.stripe.com/v2/core/accounts', {
    method: 'POST',
    headers: stripeConnectHeaders(cfg.secretKey, true),
    body: JSON.stringify(body),
  });
  const account = await response.json();
  if (!response.ok) throw new Error(account?.error?.message || 'Stripe could not create the connected account.');
  const status = await saveAccountStatus(ctx.admin, ctx.businessId, account);
  return paymentJson({ success: true, account_id: account.id, settings: status, account });
}

async function createAccountLink(ctx: Context, req: Request) {
  await requireEnabled(ctx.admin, ctx.businessId);
  const cfg = await getStripeConfig(ctx.admin, true);
  const settings = await getSettings(ctx.admin, ctx.businessId);
  if (!settings.stripe_account_id) throw new Error('Start Stripe setup before opening onboarding.');
  const origin = appOrigin(req);
  const returnUrl = `${origin}/?connect=return#settings/payments`;
  const refreshUrl = `${origin}/?connect=refresh#settings/payments`;
  const response = await fetch('https://api.stripe.com/v2/core/account_links', {
    method: 'POST',
    headers: stripeConnectHeaders(cfg.secretKey, true),
    body: JSON.stringify({
      account: settings.stripe_account_id,
      use_case: {
        type: 'account_onboarding',
        account_onboarding: { configurations: ['merchant'], return_url: returnUrl, refresh_url: refreshUrl },
      },
    }),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || 'Stripe could not open onboarding.');
  return paymentJson({ url: data.url });
}

async function refreshStatus(ctx: Context) {
  await requireEnabled(ctx.admin, ctx.businessId);
  const cfg = await getStripeConfig(ctx.admin, true);
  const settings = await getSettings(ctx.admin, ctx.businessId);
  if (!settings.stripe_account_id) return paymentJson({ settings });
  const account = await stripeAccount(cfg.secretKey, settings.stripe_account_id);
  const status = await saveAccountStatus(ctx.admin, ctx.businessId, account);
  return paymentJson({ settings: { ...settings, ...status }, account });
}

async function saveSettings(ctx: Context, payload: any) {
  await requireEnabled(ctx.admin, ctx.businessId);
  const feeMode = String(payload?.fee_mode || 'bear');
  if (!['bear', 'split', 'pass'].includes(feeMode)) throw new Error('Choose Bear, Split or Pass for payment fees.');
  const { data, error } = await ctx.admin.from('invoice_payment_settings').upsert({
    business_id: ctx.businessId,
    fee_mode: feeMode,
    allow_partial_payments: payload?.allow_partial_payments !== false,
    updated_at: new Date().toISOString(),
  }, { onConflict: 'business_id' }).select('*').single();
  if (error) throw error;
  return paymentJson({ settings: data });
}

async function details(admin: any, payload: any) {
  const token = String(payload?.token || '').trim();
  if (!token) return bad('Payment token is required.', 400);
  const record = await loadPublicPayment(admin, token);
  const enabled = await admin.rpc('v6181_invoice_payments_enabled', { p_business_id: record.link.business_id });
  if (enabled.error || enabled.data !== true) return bad('Online payments are not currently enabled for this business.', 403);
  const fee = calculateCustomerFee(record.balance, record.settings);
  return paymentJson({
    invoice: {
      invoice_number: record.invoice.invoice_number,
      customer_name: record.invoice.customer_name,
      due_date: record.invoice.due_date,
      total: Number(record.invoice.total || 0),
      amount_paid: Number(record.invoice.amount_paid || 0),
      balance_due: record.balance,
    },
    business_name: record.businessName,
    currency: record.currency,
    fee_mode: record.settings.fee_mode,
    fee_percent: Number(record.settings.fee_percent || 0),
    fee_fixed_amount: Number(record.settings.fee_fixed_amount || 0),
    estimated_customer_fee: fee,
    allow_partial_payments: record.settings.allow_partial_payments === true,
  });
}

async function checkout(admin: any, payload: any, req: Request) {
  const token = String(payload?.token || '').trim();
  if (!token) return bad('Payment token is required.', 400);
  const record = await loadPublicPayment(admin, token);
  const enabled = await admin.rpc('v6181_invoice_payments_enabled', { p_business_id: record.link.business_id });
  if (enabled.error || enabled.data !== true) return bad('Online payments are not currently enabled for this business.', 403);
  if (!record.settings.stripe_account_id || record.settings.connect_status !== 'active') return bad('This business has not finished Stripe payment setup.', 409);
  const cfg = await getStripeConfig(admin, true);
  const account = await stripeAccount(cfg.secretKey, String(record.settings.stripe_account_id));
  if (cardStatus(account) !== 'active') {
    await saveAccountStatus(admin, String(record.link.business_id), account);
    return bad('This business needs to finish Stripe payment setup before accepting payments.', 409);
  }

  const amount = roundCents(Number(payload?.amount));
  if (!Number.isFinite(amount) || amount <= 0) return bad('Enter a payment amount greater than zero.', 400);
  if (!record.settings.allow_partial_payments && Math.abs(amount - record.balance) > 0.005) return bad('This business requires the invoice balance to be paid in full.', 400);
  if (amount > record.balance + 0.005) return bad(`The maximum payment for this invoice is ${record.balance.toFixed(2)}.`, 400);

  const fee = calculateCustomerFee(amount, record.settings);
  const gross = roundCents(amount + fee);
  const currency = record.currency;
  const { data: transaction, error: transactionError } = await admin.from('invoice_payment_transactions').insert({
    business_id: record.link.business_id,
    invoice_id: record.invoice.id,
    payment_link_id: record.link.id,
    stripe_account_id: record.settings.stripe_account_id,
    amount,
    gross_amount: gross,
    customer_fee_amount: fee,
    currency,
    fee_mode: record.settings.fee_mode,
    status: 'pending',
    metadata: { invoice_number: record.invoice.invoice_number, payment_link_id: record.link.id },
  }).select('*').single();
  if (transactionError || !transaction) throw transactionError || new Error('Unable to prepare the payment.');

  const form = new URLSearchParams();
  form.set('mode', 'payment');
  form.set('line_items[0][price_data][currency]', currency);
  form.set('line_items[0][price_data][product_data][name]', `Invoice ${record.invoice.invoice_number}`);
  form.set('line_items[0][price_data][unit_amount]', String(cents(amount)));
  form.set('line_items[0][quantity]', '1');
  if (fee > 0) {
    form.set('line_items[1][price_data][currency]', currency);
    form.set('line_items[1][price_data][product_data][name]', 'Payment processing fee');
    form.set('line_items[1][price_data][unit_amount]', String(cents(fee)));
    form.set('line_items[1][quantity]', '1');
  }
  if (record.invoice.customer_email) form.set('customer_email', String(record.invoice.customer_email));
  form.set('billing_address_collection', 'auto');
  const origin = appOrigin(req);
  form.set('success_url', `${origin}/pay.html?token=${encodeURIComponent(token)}&status=success&session_id={CHECKOUT_SESSION_ID}`);
  form.set('cancel_url', `${origin}/pay.html?token=${encodeURIComponent(token)}&status=cancelled`);
  form.set('client_reference_id', record.invoice.id);
  form.set('metadata[business_id]', String(record.link.business_id));
  form.set('metadata[invoice_id]', String(record.invoice.id));
  form.set('metadata[payment_link_id]', String(record.link.id));
  form.set('metadata[payment_transaction_id]', String(transaction.id));
  form.set('metadata[fee_mode]', String(record.settings.fee_mode));
  form.set('payment_intent_data[metadata][business_id]', String(record.link.business_id));
  form.set('payment_intent_data[metadata][invoice_id]', String(record.invoice.id));
  form.set('payment_intent_data[metadata][payment_transaction_id]', String(transaction.id));
  form.set('integration_identifier', `frindly_invoice_${randomIntegrationSuffix()}`);

  const response = await fetch('https://api.stripe.com/v1/checkout/sessions', {
    method: 'POST',
    headers: { ...stripeConnectHeaders(cfg.secretKey), 'Stripe-Account': String(record.settings.stripe_account_id) },
    body: form,
  });
  const session = await response.json();
  if (!response.ok) {
    await admin.from('invoice_payment_transactions').update({ status: 'failed', failure_reason: session?.error?.message || 'Stripe Checkout creation failed.', updated_at: new Date().toISOString() }).eq('id', transaction.id);
    throw new Error(session?.error?.message || 'Unable to open Stripe Checkout.');
  }
  await admin.from('invoice_payment_transactions').update({
    stripe_checkout_session_id: session.id,
    status: 'processing',
    updated_at: new Date().toISOString(),
  }).eq('id', transaction.id);
  await admin.from('invoice_payment_links').update({ last_used_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('id', record.link.id);
  return paymentJson({ url: session.url, transaction_id: transaction.id });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: PAYMENT_CORS });
  try {
    const url = Deno.env.get('SUPABASE_URL');
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !service) return bad('Supabase configuration is missing.', 500);
    const admin = createClient(url, service);
    const payload = await req.json().catch(() => ({}));
    const action = String(payload?.action || '');

    if (action === 'details') return await details(admin, payload);
    if (action === 'checkout') return await checkout(admin, payload, req);

    const ctx = await contextFor(req, action !== 'status');
    if (ctx instanceof Response) return ctx;
    await requireEnabled(ctx.admin, ctx.businessId);
    if (action === 'get-settings') return paymentJson({ settings: await getSettings(ctx.admin, ctx.businessId) });
    if (action === 'save-settings') return await saveSettings(ctx, payload);
    if (action === 'create-account') return await createConnectAccount(ctx, req);
    if (action === 'create-account-link') return await createAccountLink(ctx, req);
    if (action === 'status') return await refreshStatus(ctx);
    return bad('Unknown invoice payment action.', 400);
  } catch (error) {
    return bad(error instanceof Error ? error.message : 'Invoice payment request failed.', 400);
  }
});
