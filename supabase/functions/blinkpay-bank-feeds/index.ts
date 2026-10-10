import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders, clientIp, enforceRateLimit } from '../_shared/email-sender.ts';

const json = (req: Request, value: unknown, status = 200) => new Response(
  JSON.stringify(value),
  { status, headers: { ...corsHeaders(req), 'Content-Type': 'application/json' } },
);

const clean = (value: unknown, max = 500) => String(value ?? '').trim().slice(0, max);
const env = (name: string) => clean(Deno.env.get(name), 1000);
const appUrl = () => (env('PUBLIC_APP_URL') || env('SITE_URL') || 'https://frindly.co.nz').replace(/\/$/, '');
const randomState = () => crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '');
const money = (value: unknown) => Number(Number(value || 0).toFixed(2));

async function blinkPayConfig(admin: any, req?: Request, requireEnabled = false) {
  const { data: row, error: rowError } = await admin
    .from('payment_provider_settings')
    .select('enabled,mode,public_config')
    .eq('provider', 'blinkpay')
    .maybeSingle();
  if (rowError && !String(rowError.message || '').includes('payment_provider_settings')) throw rowError;

  const { data: secretText } = await admin.rpc('v34_get_payment_provider_secret', { p_provider: 'blinkpay' });
  let stored: Record<string, string> = {};
  if (secretText) {
    try { stored = JSON.parse(secretText) || {}; } catch { stored = {}; }
  }

  const publicConfig = row?.public_config || {};
  const clientId = clean(publicConfig.client_id || env('BLINKPAY_CLIENT_ID'), 500);
  const clientSecret = clean(stored.client_secret || env('BLINKPAY_CLIENT_SECRET'), 1000);
  const authUrl = clean(publicConfig.auth_url || env('BLINKPAY_AUTH_URL'), 1000);
  const tokenUrl = clean(publicConfig.token_url || env('BLINKPAY_TOKEN_URL'), 1000);
  const dataBaseUrl = clean(publicConfig.data_base_url || env('BLINKPAY_DATA_BASE_URL'), 1000).replace(/\/$/, '');
  const redirectUri = clean(publicConfig.redirect_uri || env('BLINKPAY_REDIRECT_URI') || (req ? `${new URL(req.url).origin}/functions/v1/blinkpay-bank-feeds?action=callback` : ''), 1000);
  const scopes = clean(publicConfig.scopes || env('BLINKPAY_SCOPES') || 'accounts balances transactions statements', 500);
  const accountsPath = clean(publicConfig.accounts_path || env('BLINKPAY_ACCOUNTS_PATH') || '/accounts', 500);
  const transactionsPath = clean(publicConfig.transactions_path || env('BLINKPAY_TRANSACTIONS_PATH') || '/accounts/{accountId}/transactions', 500);
  const enabled = row ? row.enabled === true : Boolean(clientId && clientSecret);
  const environment = row?.mode === 'live' || env('BLINKPAY_ENV') === 'production' ? 'production' : 'sandbox';
  const configured = Boolean(clientId && clientSecret && authUrl && tokenUrl && dataBaseUrl);
  if (requireEnabled && !enabled) throw new Error('BlinkPay live bank feeds are disabled in Super Admin → Payment Settings.');
  return { clientId, clientSecret, authUrl, tokenUrl, dataBaseUrl, redirectUri, scopes, accountsPath, transactionsPath, enabled, environment, configured };
}

async function userFromRequest(req: Request, supabaseUrl: string, anonKey: string) {
  const auth = req.headers.get('Authorization') || '';
  const client = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await client.auth.getUser();
  return { user, client };
}

async function canUseLiveFeeds(admin: any, businessId: string, userId: string) {
  const [{ data: profile }, { data: membership }, { data: entitled }] = await Promise.all([
    admin.from('profiles').select('is_super_admin,business_id,role').eq('id', userId).maybeSingle(),
    admin.from('business_memberships').select('role,status').eq('business_id', businessId).eq('user_id', userId).eq('status', 'active').maybeSingle(),
    admin.rpc('v61118_live_bank_feeds_enabled', { p_business_id: businessId }),
  ]);
  if (profile?.is_super_admin === true) return true;
  const role = String(membership?.role || '');
  const profileRole = String(profile?.role || '');
  const profileMatchesBusiness = String(profile?.business_id || '') === String(businessId);
  return Boolean(entitled) && (['owner', 'admin'].includes(role) || (profileMatchesBusiness && ['owner', 'admin'].includes(profileRole)));
}

async function status(req: Request, admin: any, businessId: string, userId: string) {
  const allowed = await canUseLiveFeeds(admin, businessId, userId);
  const cfg = await blinkPayConfig(admin, req);
  if (!allowed) return json(req, { enabled: false, configured: cfg.configured, connections: [], message: 'Live Bank Feeds is not enabled for this plan or user role.' });
  const [{ data: connections }, { data: accounts }, { data: runs }] = await Promise.all([
    admin.from('blinkpay_feed_connections').select('id,status,environment,bank_name,consent_id,consent_expires_at,last_sync_at,last_sync_status,last_sync_message,created_at').eq('business_id', businessId).order('created_at', { ascending: false }),
    admin.from('blinkpay_feed_accounts').select('id,connection_id,bank_account_id,provider_account_id,account_name,account_number,currency,status,last_balance,last_balance_at,last_synced_at').eq('business_id', businessId).order('account_name'),
    admin.from('blinkpay_feed_sync_runs').select('id,connection_id,status,started_at,finished_at,imported_count,duplicate_count,account_count,error_message').eq('business_id', businessId).order('started_at', { ascending: false }).limit(5),
  ]);
  return json(req, {
    enabled: true,
    configured: cfg.configured,
    provider_enabled: cfg.enabled,
    environment: cfg.environment,
    connections: connections || [],
    accounts: accounts || [],
    recent_syncs: runs || [],
  });
}

async function connectStart(req: Request, admin: any, businessId: string, userId: string) {
  if (!await canUseLiveFeeds(admin, businessId, userId)) return json(req, { error: 'Live Bank Feeds is not enabled for this plan or user role.' }, 403);
  const cfg = await blinkPayConfig(admin, req, true);
  if (!cfg.configured) return json(req, { error: 'BlinkPay is not configured yet. Add the Blink Data client ID, secret, auth URL, token URL and data base URL in Super Admin → Payment Settings.' }, 400);
  const state = randomState();
  const scopes = cfg.scopes.split(/\s+/).filter(Boolean);
  const { data, error } = await admin.from('blinkpay_feed_connections').insert({
    business_id: businessId,
    environment: cfg.environment,
    status: 'pending',
    consent_state: state,
    scopes,
    created_by: userId,
    updated_by: userId,
  }).select('id').single();
  if (error) return json(req, { error: error.message }, 400);
  const url = new URL(cfg.authUrl);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', cfg.clientId);
  url.searchParams.set('redirect_uri', cfg.redirectUri);
  url.searchParams.set('scope', scopes.join(' '));
  url.searchParams.set('state', state);
  return json(req, { url: url.toString(), connection_id: data.id });
}

async function exchangeCode(code: string, req: Request, cfg: any) {
  const body = new URLSearchParams();
  body.set('grant_type', 'authorization_code');
  body.set('code', code);
  body.set('redirect_uri', cfg.redirectUri);
  body.set('client_id', cfg.clientId);
  body.set('client_secret', cfg.clientSecret);
  const response = await fetch(cfg.tokenUrl, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error_description || payload?.error || 'BlinkPay token exchange failed.');
  return payload;
}

async function callback(req: Request, admin: any) {
  const url = new URL(req.url);
  const state = clean(url.searchParams.get('state'), 200);
  const code = clean(url.searchParams.get('code'), 2000);
  const error = clean(url.searchParams.get('error'), 500);
  const { data: connection } = await admin.from('blinkpay_feed_connections').select('*').eq('consent_state', state).maybeSingle();
  if (!connection) return new Response('Invalid BlinkPay connection state.', { status: 400 });
  if (error || !code) {
    await admin.from('blinkpay_feed_connections').update({ status: 'error', last_sync_status: 'failed', last_sync_message: error || 'BlinkPay did not return an authorization code.', updated_at: new Date().toISOString() }).eq('id', connection.id);
    return Response.redirect(`${appUrl()}/#bankreconciliation/import?blinkpay=error`, 302);
  }
  try {
    const cfg = await blinkPayConfig(admin, req, true);
    const token = await exchangeCode(code, req, cfg);
    const expires = token.expires_in ? new Date(Date.now() + Number(token.expires_in) * 1000).toISOString() : null;
    await admin.from('blinkpay_feed_connections').update({
      status: 'active',
      access_token: token.access_token || null,
      refresh_token: token.refresh_token || null,
      token_expires_at: expires,
      consent_id: token.consent_id || token.consentId || connection.consent_id || null,
      last_sync_status: 'connected',
      last_sync_message: null,
      updated_at: new Date().toISOString(),
    }).eq('id', connection.id);
    return Response.redirect(`${appUrl()}/#bankreconciliation/import?blinkpay=connected`, 302);
  } catch (err) {
    await admin.from('blinkpay_feed_connections').update({ status: 'error', last_sync_status: 'failed', last_sync_message: err instanceof Error ? err.message : 'BlinkPay callback failed.', updated_at: new Date().toISOString() }).eq('id', connection.id);
    return Response.redirect(`${appUrl()}/#bankreconciliation/import?blinkpay=error`, 302);
  }
}

async function refreshTokenIfNeeded(admin: any, connection: any, cfg: any) {
  if (!connection.refresh_token || !connection.token_expires_at || new Date(connection.token_expires_at).getTime() > Date.now() + 120000) return connection;
  const body = new URLSearchParams();
  body.set('grant_type', 'refresh_token');
  body.set('refresh_token', connection.refresh_token);
  body.set('client_id', cfg.clientId);
  body.set('client_secret', cfg.clientSecret);
  const response = await fetch(cfg.tokenUrl, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error_description || payload?.error || 'BlinkPay token refresh failed.');
  const expires = payload.expires_in ? new Date(Date.now() + Number(payload.expires_in) * 1000).toISOString() : connection.token_expires_at;
  const updated = { ...connection, access_token: payload.access_token || connection.access_token, refresh_token: payload.refresh_token || connection.refresh_token, token_expires_at: expires };
  await admin.from('blinkpay_feed_connections').update({ access_token: updated.access_token, refresh_token: updated.refresh_token, token_expires_at: expires, updated_at: new Date().toISOString() }).eq('id', connection.id);
  return updated;
}

async function blinkFetch(path: string, token: string, cfg: any) {
  const response = await fetch(`${cfg.dataBaseUrl}${path.startsWith('/') ? path : `/${path}`}`, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' } });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error_description || payload?.error || `BlinkPay request failed (${response.status}).`);
  return payload;
}

function accountRows(payload: any) {
  return Array.isArray(payload) ? payload : Array.isArray(payload?.accounts) ? payload.accounts : Array.isArray(payload?.data) ? payload.data : [];
}

function transactionRows(payload: any) {
  return Array.isArray(payload) ? payload : Array.isArray(payload?.transactions) ? payload.transactions : Array.isArray(payload?.data) ? payload.data : [];
}

function accountId(row: any) { return clean(row?.id || row?.account_id || row?.accountId || row?.resourceId, 200); }
function transactionId(row: any) { return clean(row?.id || row?.transaction_id || row?.transactionId || row?.entryReference || row?.reference, 240); }
function transactionDate(row: any) { return clean(row?.bookingDate || row?.transaction_date || row?.transactionDate || row?.date || row?.valueDate, 20).slice(0, 10); }
function transactionAmount(row: any) {
  const amount = row?.amount?.amount ?? row?.amount?.total ?? row?.amount ?? row?.transactionAmount?.amount ?? 0;
  const value = Number(String(amount).replace(/[$,\s]/g, ''));
  const direction = clean(row?.creditDebitIndicator || row?.direction || row?.type, 20).toLowerCase();
  return direction.includes('debit') || direction === 'out' ? -Math.abs(value) : value;
}

function fingerprint(row: any) {
  const raw = [transactionDate(row), money(transactionAmount(row)).toFixed(2), clean(row?.reference || row?.remittanceInformation || row?.description, 200).toLowerCase(), transactionId(row)].join('|');
  let h = 2166136261;
  for (let i = 0; i < raw.length; i++) { h ^= raw.charCodeAt(i); h = Math.imul(h, 16777619); }
  return `${(h >>> 0).toString(16).padStart(8, '0')}-${raw.length}`;
}

async function upsertAccount(admin: any, businessId: string, connectionId: string, row: any, userId: string) {
  const providerAccountId = accountId(row);
  if (!providerAccountId) return null;
  const accountNumber = clean(row?.accountNumber || row?.account_number || row?.iban || row?.bban, 120);
  const accountName = clean(row?.name || row?.displayName || row?.nickname || row?.accountName || 'BlinkPay bank account', 180);
  const currency = clean(row?.currency || row?.currencyCode || 'NZD', 3).toUpperCase() || 'NZD';
  const { data: existing } = await admin.from('blinkpay_feed_accounts').select('id,bank_account_id').eq('connection_id', connectionId).eq('provider_account_id', providerAccountId).maybeSingle();
  let bankAccountId = existing?.bank_account_id || null;
  if (!bankAccountId) {
    const { data: bank } = await admin.from('bank_accounts').insert({
      business_id: businessId,
      name: accountName,
      bank_name: 'BlinkPay',
      account_number: accountNumber || null,
      currency,
      is_default: false,
      created_by: userId,
      updated_by: userId,
    }).select('id').single();
    bankAccountId = bank?.id || null;
  }
  const payload = {
    business_id: businessId,
    connection_id: connectionId,
    bank_account_id: bankAccountId,
    provider_account_id: providerAccountId,
    account_name: accountName,
    account_number: accountNumber || null,
    currency,
    account_type: clean(row?.accountType || row?.type, 80) || null,
    status: 'active',
    last_balance: row?.balance?.amount !== undefined ? money(row.balance.amount) : null,
    last_balance_at: row?.balance ? new Date().toISOString() : null,
    raw_account: row || {},
    updated_at: new Date().toISOString(),
  };
  if (existing?.id) await admin.from('blinkpay_feed_accounts').update(payload).eq('id', existing.id);
  else await admin.from('blinkpay_feed_accounts').insert(payload);
  return { providerAccountId, bankAccountId };
}

async function sync(req: Request, admin: any, businessId: string, userId: string) {
  if (!await canUseLiveFeeds(admin, businessId, userId)) return json(req, { error: 'Live Bank Feeds is not enabled for this plan or user role.' }, 403);
  const cfg = await blinkPayConfig(admin, req, true);
  if (!cfg.configured) return json(req, { error: 'BlinkPay is not configured yet.' }, 400);
  const { data: connection } = await admin.from('blinkpay_feed_connections').select('*').eq('business_id', businessId).eq('status', 'active').order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (!connection?.access_token) return json(req, { error: 'No active BlinkPay feed is connected yet.' }, 400);
  const { data: run } = await admin.from('blinkpay_feed_sync_runs').insert({ business_id: businessId, connection_id: connection.id, status: 'running', created_by: userId }).select('id').single();
  let imported = 0, duplicates = 0, accounts = 0;
  try {
    const active = await refreshTokenIfNeeded(admin, connection, cfg);
    const accountPayload = await blinkFetch(cfg.accountsPath, active.access_token, cfg);
    for (const account of accountRows(accountPayload)) {
      const mapped = await upsertAccount(admin, businessId, active.id, account, userId);
      if (!mapped?.bankAccountId) continue;
      accounts++;
      const path = cfg.transactionsPath.replace('{accountId}', encodeURIComponent(mapped.providerAccountId));
      const txPayload = await blinkFetch(path, active.access_token, cfg);
      const rows = transactionRows(txPayload);
      for (const row of rows) {
        const externalId = transactionId(row);
        const date = transactionDate(row);
        const amount = transactionAmount(row);
        if (!externalId || !date || !amount) continue;
        const insert = await admin.from('bank_transactions').insert({
          business_id: businessId,
          bank_account_id: mapped.bankAccountId,
          transaction_date: date,
          amount: money(amount),
          payee: clean(row?.counterpartyName || row?.creditorName || row?.debtorName || row?.merchantName, 240) || null,
          description: clean(row?.description || row?.remittanceInformation || row?.narrative || row?.details, 500) || null,
          reference: clean(row?.reference || row?.entryReference || row?.transactionReference, 240) || null,
          bank_transaction_id: externalId,
          import_fingerprint: fingerprint(row),
          duplicate_status: 'new',
          status: 'unreconciled',
          source_provider: 'blinkpay',
          external_transaction_id: externalId,
          external_account_id: mapped.providerAccountId,
          source_payload: row || {},
          pending_status: clean(row?.status || row?.entryStatus, 50) || null,
          created_by: userId,
          updated_by: userId,
        });
        if (insert.error) {
          if (String(insert.error.message || '').toLowerCase().includes('duplicate')) duplicates++;
          else throw insert.error;
        } else imported++;
      }
      await admin.from('blinkpay_feed_accounts').update({ last_synced_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('connection_id', active.id).eq('provider_account_id', mapped.providerAccountId);
    }
    await admin.from('blinkpay_feed_connections').update({ last_sync_at: new Date().toISOString(), last_sync_status: 'completed', last_sync_message: null, updated_at: new Date().toISOString() }).eq('id', active.id);
    await admin.from('blinkpay_feed_sync_runs').update({ status: 'completed', finished_at: new Date().toISOString(), imported_count: imported, duplicate_count: duplicates, account_count: accounts }).eq('id', run?.id);
    return json(req, { success: true, imported_count: imported, duplicate_count: duplicates, account_count: accounts });
  } catch (err) {
    const message = err instanceof Error ? err.message : 'BlinkPay sync failed.';
    await admin.from('blinkpay_feed_connections').update({ last_sync_at: new Date().toISOString(), last_sync_status: 'failed', last_sync_message: message, updated_at: new Date().toISOString() }).eq('id', connection.id);
    if (run?.id) await admin.from('blinkpay_feed_sync_runs').update({ status: 'failed', finished_at: new Date().toISOString(), imported_count: imported, duplicate_count: duplicates, account_count: accounts, error_message: message }).eq('id', run.id);
    return json(req, { error: message }, 400);
  }
}

async function disconnect(req: Request, admin: any, businessId: string, userId: string, body: any) {
  if (!await canUseLiveFeeds(admin, businessId, userId)) return json(req, { error: 'Live Bank Feeds is not enabled for this plan or user role.' }, 403);
  const id = clean(body.connection_id, 80);
  if (!id) return json(req, { error: 'Connection id is required.' }, 400);
  const { error } = await admin.from('blinkpay_feed_connections').update({ status: 'disconnected', access_token: null, refresh_token: null, updated_by: userId, updated_at: new Date().toISOString() }).eq('business_id', businessId).eq('id', id);
  if (error) return json(req, { error: error.message }, 400);
  return json(req, { success: true });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceKey) return json(req, { error: 'Supabase configuration is missing.' }, 500);
  const admin = createClient(supabaseUrl, serviceKey);
  const actionFromUrl = clean(new URL(req.url).searchParams.get('action'), 80);
  if (actionFromUrl === 'callback') return callback(req, admin);
  try {
    const { user } = await userFromRequest(req, supabaseUrl, anonKey);
    if (!user) return json(req, { error: 'Not authenticated' }, 401);
    await enforceRateLimit(admin, 'blinkpay-bank-feeds:user', user.id || clientIp(req), 60, 3600);
    const body = await req.json().catch(() => ({}));
    const action = clean(body.action || actionFromUrl || 'status', 80);
    const businessId = clean(body.business_id, 80);
    if (!businessId) return json(req, { error: 'Business id is required.' }, 400);
    if (action === 'status') return status(req, admin, businessId, user.id);
    if (action === 'connect-start') return connectStart(req, admin, businessId, user.id);
    if (action === 'sync') return sync(req, admin, businessId, user.id);
    if (action === 'disconnect') return disconnect(req, admin, businessId, user.id, body);
    return json(req, { error: 'Unknown BlinkPay bank feed action.' }, 400);
  } catch (err) {
    return json(req, { error: err instanceof Error ? err.message : 'BlinkPay bank feed error.' }, (err as any)?.status || 400);
  }
});
