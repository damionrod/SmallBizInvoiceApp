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

async function userFromRequest(req: Request, supabaseUrl: string, anonKey: string) {
  const auth = req.headers.get('Authorization') || '';
  const client = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await client.auth.getUser();
  return { user, client };
}

async function akahuConfig(admin: any, req?: Request, requireEnabled = false) {
  const { data: row, error: rowError } = await admin
    .from('payment_provider_settings')
    .select('enabled,mode,public_config')
    .eq('provider', 'akahu')
    .maybeSingle();
  if (rowError && !String(rowError.message || '').includes('payment_provider_settings')) throw rowError;

  const { data: secretText } = await admin.rpc('v34_get_payment_provider_secret', { p_provider: 'akahu' });
  let stored: Record<string, string> = {};
  if (secretText) {
    try { stored = JSON.parse(secretText) || {}; } catch { stored = {}; }
  }

  const publicConfig = row?.public_config || {};
  const appToken = clean(publicConfig.app_token || env('AKAHU_APP_TOKEN'), 800);
  const appSecret = clean(stored.app_secret || env('AKAHU_APP_SECRET'), 1000);
  const authUrl = clean(publicConfig.auth_url || env('AKAHU_AUTH_URL') || 'https://oauth.akahu.nz', 1000);
  const tokenUrl = clean(publicConfig.token_url || env('AKAHU_TOKEN_URL') || 'https://oauth.akahu.nz/token', 1000);
  const apiBaseUrl = clean(publicConfig.api_base_url || env('AKAHU_API_BASE_URL') || 'https://api.akahu.io/v1', 1000).replace(/\/$/, '');
  const redirectUri = clean(publicConfig.redirect_uri || env('AKAHU_REDIRECT_URI') || (req ? `${new URL(req.url).origin}/functions/v1/akahu-bank-feeds?action=callback` : ''), 1000);
  const scopes = clean(publicConfig.scopes || env('AKAHU_SCOPES') || 'ENDURING_CONSENT ACCOUNTS TRANSACTIONS', 500);
  const accountsPath = clean(publicConfig.accounts_path || env('AKAHU_ACCOUNTS_PATH') || '/accounts', 500);
  const transactionsPath = clean(publicConfig.transactions_path || env('AKAHU_TRANSACTIONS_PATH') || '/transactions', 500);
  const revokePath = clean(publicConfig.revoke_path || env('AKAHU_REVOKE_PATH') || '/token', 500);
  const syncStartDays = Math.max(1, Math.min(730, Number(publicConfig.sync_start_days || env('AKAHU_SYNC_START_DAYS') || 90) || 90));
  const enabled = row ? row.enabled === true : Boolean(appToken && appSecret);
  const environment = row?.mode === 'live' ? 'production' : 'sandbox';
  const configured = Boolean(appToken && appSecret && authUrl && tokenUrl && apiBaseUrl);
  if (requireEnabled && !enabled) throw new Error('Akahu live bank feeds are disabled in Super Admin → Payment Settings.');
  return { appToken, appSecret, authUrl, tokenUrl, apiBaseUrl, redirectUri, scopes, accountsPath, transactionsPath, revokePath, syncStartDays, enabled, environment, configured };
}

async function canUseLiveFeeds(admin: any, businessId: string, userId: string) {
  const [{ data: profile }, { data: membership }, { data: entitled }] = await Promise.all([
    admin.from('profiles').select('is_super_admin,business_id,role').eq('id', userId).maybeSingle(),
    admin.from('business_memberships').select('role,status').eq('business_id', businessId).eq('user_id', userId).eq('status', 'active').maybeSingle(),
    admin.rpc('v61122_akahu_bank_feeds_enabled', { p_business_id: businessId }),
  ]);
  if (profile?.is_super_admin === true) return true;
  const role = String(membership?.role || '');
  const profileRole = String(profile?.role || '');
  const profileMatchesBusiness = String(profile?.business_id || '') === String(businessId);
  return Boolean(entitled) && (['owner', 'admin'].includes(role) || (profileMatchesBusiness && ['owner', 'admin'].includes(profileRole)));
}

async function status(req: Request, admin: any, businessId: string, userId: string) {
  const allowed = await canUseLiveFeeds(admin, businessId, userId);
  const cfg = await akahuConfig(admin, req);
  if (!allowed) return json(req, { enabled: false, configured: cfg.configured, connections: [], message: 'Live Bank Feeds is not enabled for this plan or user role.' });
  const [{ data: connections }, { data: accounts }, { data: runs }] = await Promise.all([
    admin.from('akahu_feed_connections').select('id,status,environment,akahu_user_id,last_sync_at,last_sync_status,last_sync_message,created_at').eq('business_id', businessId).order('created_at', { ascending: false }),
    admin.from('akahu_feed_accounts').select('id,connection_id,bank_account_id,provider_account_id,account_name,account_number,currency,status,last_balance,last_balance_at,last_synced_at').eq('business_id', businessId).order('account_name'),
    admin.from('akahu_feed_sync_runs').select('id,connection_id,status,started_at,finished_at,imported_count,duplicate_count,account_count,error_message').eq('business_id', businessId).order('started_at', { ascending: false }).limit(5),
  ]);
  return json(req, {
    provider: 'akahu',
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
  const cfg = await akahuConfig(admin, req, true);
  if (!cfg.configured) return json(req, { error: 'Akahu is not configured yet. Add the App ID Token, App Secret and URLs in Super Admin → Payment Settings.' }, 400);
  const state = randomState();
  const scopes = cfg.scopes.split(/\s+/).filter(Boolean);
  const { data, error } = await admin.from('akahu_feed_connections').insert({
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
  url.searchParams.set('client_id', cfg.appToken);
  url.searchParams.set('redirect_uri', cfg.redirectUri);
  url.searchParams.set('scope', scopes.join(' '));
  url.searchParams.set('state', state);
  return json(req, { url: url.toString(), connection_id: data.id });
}

async function exchangeCode(code: string, cfg: any) {
  const body = new URLSearchParams();
  body.set('grant_type', 'authorization_code');
  body.set('code', code);
  body.set('redirect_uri', cfg.redirectUri);
  body.set('client_id', cfg.appToken);
  body.set('client_secret', cfg.appSecret);
  const response = await fetch(cfg.tokenUrl, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error_description || payload?.error || payload?.message || 'Akahu token exchange failed.');
  return payload;
}

async function akahuFetch(cfg: any, path: string, token: string, init: RequestInit = {}) {
  const response = await fetch(`${cfg.apiBaseUrl}${path.startsWith('/') ? path : `/${path}`}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      'X-Akahu-Id': cfg.appToken,
      Accept: 'application/json',
      ...(init.headers || {}),
    },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.message || payload?.error_description || payload?.error || `Akahu request failed (${response.status}).`);
  return payload;
}

async function callback(req: Request, admin: any) {
  const url = new URL(req.url);
  const state = clean(url.searchParams.get('state'), 200);
  const code = clean(url.searchParams.get('code'), 2000);
  const error = clean(url.searchParams.get('error'), 500);
  const { data: connection } = await admin.from('akahu_feed_connections').select('*').eq('consent_state', state).maybeSingle();
  if (!connection) return new Response('Invalid Akahu connection state.', { status: 400 });
  if (error || !code) {
    await admin.from('akahu_feed_connections').update({ status: 'error', last_sync_status: 'failed', last_sync_message: error || 'Akahu did not return an authorization code.', updated_at: new Date().toISOString() }).eq('id', connection.id);
    return Response.redirect(`${appUrl()}/#bankreconciliation/import?akahu=error`, 302);
  }
  try {
    const cfg = await akahuConfig(admin, req, true);
    const token = await exchangeCode(code, cfg);
    const accessToken = token.access_token || token.user_access_token || token.token || null;
    if (!accessToken) throw new Error('Akahu did not return a User Access Token.');
    const expires = token.expires_in ? new Date(Date.now() + Number(token.expires_in) * 1000).toISOString() : null;
    let akahuUserId = null;
    try {
      const me = await akahuFetch(cfg, '/me', accessToken);
      akahuUserId = me?.item?._id || me?._id || me?.user?._id || null;
    } catch {
      akahuUserId = null;
    }
    await admin.from('akahu_feed_connections').update({
      status: 'active',
      access_token: accessToken,
      refresh_token: token.refresh_token || null,
      token_expires_at: expires,
      akahu_user_id: akahuUserId,
      last_sync_status: 'connected',
      last_sync_message: null,
      updated_at: new Date().toISOString(),
    }).eq('id', connection.id);
    return Response.redirect(`${appUrl()}/#bankreconciliation/import?akahu=connected`, 302);
  } catch (err) {
    await admin.from('akahu_feed_connections').update({ status: 'error', last_sync_status: 'failed', last_sync_message: err instanceof Error ? err.message : 'Akahu callback failed.', updated_at: new Date().toISOString() }).eq('id', connection.id);
    return Response.redirect(`${appUrl()}/#bankreconciliation/import?akahu=error`, 302);
  }
}

async function refreshTokenIfNeeded(admin: any, connection: any, cfg: any) {
  if (!connection.refresh_token || !connection.token_expires_at || new Date(connection.token_expires_at).getTime() > Date.now() + 120000) return connection;
  const body = new URLSearchParams();
  body.set('grant_type', 'refresh_token');
  body.set('refresh_token', connection.refresh_token);
  body.set('client_id', cfg.appToken);
  body.set('client_secret', cfg.appSecret);
  const response = await fetch(cfg.tokenUrl, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error_description || payload?.error || payload?.message || 'Akahu token refresh failed.');
  const expires = payload.expires_in ? new Date(Date.now() + Number(payload.expires_in) * 1000).toISOString() : connection.token_expires_at;
  const updated = { ...connection, access_token: payload.access_token || connection.access_token, refresh_token: payload.refresh_token || connection.refresh_token, token_expires_at: expires };
  await admin.from('akahu_feed_connections').update({ access_token: updated.access_token, refresh_token: updated.refresh_token, token_expires_at: expires, updated_at: new Date().toISOString() }).eq('id', connection.id);
  return updated;
}

function rows(payload: any, key: string) {
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload?.items)) return payload.items;
  if (Array.isArray(payload?.data)) return payload.data;
  if (Array.isArray(payload?.[key])) return payload[key];
  return [];
}
function accountId(row: any) { return clean(row?._id || row?.id || row?.account_id, 200); }
function txId(row: any) { return clean(row?._id || row?.id || row?.transaction_id, 240); }
function txDate(row: any) { return clean(row?.date || row?.created_at || row?.settled_at, 30).slice(0, 10); }
function txAmount(row: any) {
  const raw = row?.amount?.amount ?? row?.amount ?? row?.value ?? 0;
  const value = Number(String(raw).replace(/[$,\s]/g, ''));
  const type = clean(row?.type, 40).toUpperCase();
  if (type === 'DEBIT' && value > 0) return -value;
  return value;
}
function fingerprint(row: any) {
  const raw = [txDate(row), money(txAmount(row)).toFixed(2), clean(row?.description, 200).toLowerCase(), txId(row)].join('|');
  let h = 2166136261;
  for (let i = 0; i < raw.length; i++) { h ^= raw.charCodeAt(i); h = Math.imul(h, 16777619); }
  return `${(h >>> 0).toString(16).padStart(8, '0')}-${raw.length}`;
}

async function upsertAccount(admin: any, businessId: string, connectionId: string, row: any, userId: string) {
  const providerAccountId = accountId(row);
  if (!providerAccountId) return null;
  const accountNumber = clean(row?.formatted_account || row?.account_number || row?.meta?.account_number, 120);
  const accountName = clean(row?.name || row?.display_name || 'Akahu bank account', 180);
  const currency = clean(row?.balance?.currency || row?.currency || 'NZD', 3).toUpperCase() || 'NZD';
  const { data: existing } = await admin.from('akahu_feed_accounts').select('id,bank_account_id').eq('connection_id', connectionId).eq('provider_account_id', providerAccountId).maybeSingle();
  let bankAccountId = existing?.bank_account_id || null;
  if (!bankAccountId) {
    const { data: bank, error } = await admin.from('bank_accounts').insert({
      business_id: businessId,
      name: accountName,
      bank_name: clean(row?.connection?.name || 'Akahu', 120),
      account_number: accountNumber || null,
      currency,
      is_default: false,
      created_by: userId,
      updated_by: userId,
    }).select('id').single();
    if (error) throw error;
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
    account_type: clean(row?.type, 80) || null,
    status: clean(row?.status, 40).toUpperCase() === 'INACTIVE' ? 'inactive' : 'active',
    last_balance: row?.balance?.current !== undefined ? money(row.balance.current) : null,
    last_balance_at: row?.refreshed?.balance || null,
    raw_account: row || {},
    updated_at: new Date().toISOString(),
  };
  if (existing?.id) await admin.from('akahu_feed_accounts').update(payload).eq('id', existing.id);
  else await admin.from('akahu_feed_accounts').insert(payload);
  return { providerAccountId, bankAccountId };
}

async function pagedAkahuFetch(cfg: any, path: string, token: string, key: string) {
  let next: string | null = path;
  const out: any[] = [];
  let guard = 0;
  while (next && guard++ < 8) {
    const payload = await akahuFetch(cfg, next, token);
    out.push(...rows(payload, key));
    const cursor = payload?.cursor?.next || payload?.next_cursor || payload?.pagination?.next_cursor || null;
    if (!cursor) break;
    const u = new URL(`${cfg.apiBaseUrl}${path.startsWith('/') ? path : `/${path}`}`);
    u.searchParams.set('cursor', cursor);
    next = `${u.pathname}${u.search}`;
  }
  return out;
}

async function sync(req: Request, admin: any, businessId: string, userId: string) {
  if (!await canUseLiveFeeds(admin, businessId, userId)) return json(req, { error: 'Live Bank Feeds is not enabled for this plan or user role.' }, 403);
  const cfg = await akahuConfig(admin, req, true);
  if (!cfg.configured) return json(req, { error: 'Akahu is not configured yet.' }, 400);
  const { data: connection } = await admin.from('akahu_feed_connections').select('*').eq('business_id', businessId).eq('status', 'active').order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (!connection?.access_token) return json(req, { error: 'No active Akahu feed is connected yet.' }, 400);
  const { data: run } = await admin.from('akahu_feed_sync_runs').insert({ business_id: businessId, connection_id: connection.id, status: 'running', created_by: userId }).select('id').single();
  let imported = 0, duplicates = 0, accountCount = 0;
  try {
    const active = await refreshTokenIfNeeded(admin, connection, cfg);
    const accountRows = await pagedAkahuFetch(cfg, cfg.accountsPath, active.access_token, 'accounts');
    const accountMap = new Map<string, string>();
    for (const account of accountRows) {
      const mapped = await upsertAccount(admin, businessId, active.id, account, userId);
      if (!mapped?.bankAccountId) continue;
      accountCount++;
      accountMap.set(mapped.providerAccountId, mapped.bankAccountId);
      await admin.from('akahu_feed_accounts').update({ last_synced_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('connection_id', active.id).eq('provider_account_id', mapped.providerAccountId);
    }

    const start = new Date(Date.now() - cfg.syncStartDays * 86400000).toISOString();
    const txUrl = new URL(`${cfg.apiBaseUrl}${cfg.transactionsPath.startsWith('/') ? cfg.transactionsPath : `/${cfg.transactionsPath}`}`);
    txUrl.searchParams.set('start', start);
    const transactionRows = await pagedAkahuFetch(cfg, `${txUrl.pathname}${txUrl.search}`, active.access_token, 'transactions');
    for (const row of transactionRows) {
      const externalId = txId(row);
      const providerAccountId = clean(row?._account || row?.account || row?.account_id, 200);
      const bankAccountId = accountMap.get(providerAccountId);
      const date = txDate(row);
      const amount = txAmount(row);
      if (!externalId || !providerAccountId || !bankAccountId || !date || !amount) continue;
      const insert = await admin.from('bank_transactions').insert({
        business_id: businessId,
        bank_account_id: bankAccountId,
        transaction_date: date,
        amount: money(amount),
        payee: clean(row?.merchant?.name || row?.particulars || row?.other_account || '', 240) || null,
        description: clean(row?.description || row?.memo || row?.narrative || '', 500) || null,
        reference: clean(row?.reference || row?.code || row?.particulars || '', 240) || null,
        bank_transaction_id: externalId,
        import_fingerprint: fingerprint(row),
        duplicate_status: 'new',
        status: 'unreconciled',
        source_provider: 'akahu',
        external_transaction_id: externalId,
        external_account_id: providerAccountId,
        source_payload: row || {},
        pending_status: null,
        created_by: userId,
        updated_by: userId,
      });
      if (insert.error) {
        if (String(insert.error.message || '').toLowerCase().includes('duplicate')) duplicates++;
        else throw insert.error;
      } else imported++;
    }
    await admin.from('akahu_feed_connections').update({ last_sync_at: new Date().toISOString(), last_sync_status: 'completed', last_sync_message: null, updated_at: new Date().toISOString() }).eq('id', active.id);
    await admin.from('akahu_feed_sync_runs').update({ status: 'completed', finished_at: new Date().toISOString(), imported_count: imported, duplicate_count: duplicates, account_count: accountCount }).eq('id', run?.id);
    return json(req, { success: true, imported_count: imported, duplicate_count: duplicates, account_count: accountCount });
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Akahu sync failed.';
    await admin.from('akahu_feed_connections').update({ last_sync_at: new Date().toISOString(), last_sync_status: 'failed', last_sync_message: message, updated_at: new Date().toISOString() }).eq('id', connection.id);
    if (run?.id) await admin.from('akahu_feed_sync_runs').update({ status: 'failed', finished_at: new Date().toISOString(), imported_count: imported, duplicate_count: duplicates, account_count: accountCount, error_message: message }).eq('id', run.id);
    return json(req, { error: message }, 400);
  }
}

async function disconnect(req: Request, admin: any, businessId: string, userId: string, body: any) {
  if (!await canUseLiveFeeds(admin, businessId, userId)) return json(req, { error: 'Live Bank Feeds is not enabled for this plan or user role.' }, 403);
  const id = clean(body.connection_id, 80);
  if (!id) return json(req, { error: 'Connection id is required.' }, 400);
  const { data: connection } = await admin.from('akahu_feed_connections').select('*').eq('business_id', businessId).eq('id', id).maybeSingle();
  if (connection?.access_token) {
    try {
      const cfg = await akahuConfig(admin, req);
      await akahuFetch(cfg, cfg.revokePath, connection.access_token, { method: 'DELETE' });
    } catch {
      // Keep local disconnect reliable even if Akahu has already revoked the token.
    }
  }
  const { error } = await admin.from('akahu_feed_connections').update({ status: 'disconnected', access_token: null, refresh_token: null, updated_by: userId, updated_at: new Date().toISOString() }).eq('business_id', businessId).eq('id', id);
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
    await enforceRateLimit(admin, 'akahu-bank-feeds:user', user.id || clientIp(req), 60, 3600);
    const body = await req.json().catch(() => ({}));
    const action = clean(body.action || actionFromUrl || 'status', 80);
    const businessId = clean(body.business_id, 80);
    if (!businessId) return json(req, { error: 'Business id is required.' }, 400);
    if (action === 'status') return status(req, admin, businessId, user.id);
    if (action === 'connect-start') return connectStart(req, admin, businessId, user.id);
    if (action === 'sync') return sync(req, admin, businessId, user.id);
    if (action === 'disconnect') return disconnect(req, admin, businessId, user.id, body);
    return json(req, { error: 'Unknown Akahu bank feed action.' }, 400);
  } catch (err) {
    return json(req, { error: err instanceof Error ? err.message : 'Akahu bank feed error.' }, (err as any)?.status || 400);
  }
});
