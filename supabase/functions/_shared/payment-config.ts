export const STRIPE_API_VERSION = '2026-07-29.dahlia';

/** Read Stripe credentials from Supabase Vault, with env vars as a deployment fallback. */
export async function getStripeConfig(admin: any, requireEnabled = false) {
  const { data: row, error: rowError } = await admin
    .from('payment_provider_settings')
    .select('provider,enabled,mode,public_config')
    .eq('provider', 'stripe')
    .maybeSingle();

  if (rowError && !String(rowError.message || '').includes('payment_provider_settings')) {
    throw rowError;
  }

  const { data: secretText, error: secretError } = await admin.rpc(
    'v34_get_payment_provider_secret',
    { p_provider: 'stripe' },
  );

  let stored: Record<string, string> = {};
  if (!secretError && secretText) {
    try {
      stored = JSON.parse(secretText) || {};
    } catch {
      stored = {};
    }
  }

  const secretKey = String(stored.secret_key || Deno.env.get('STRIPE_SECRET_KEY') || '').trim();
  const webhookSecret = String(stored.webhook_secret || Deno.env.get('STRIPE_WEBHOOK_SECRET') || '').trim();
  const publishableKey = String(row?.public_config?.publishable_key || '').trim();
  const enabled = row ? row.enabled === true : Boolean(secretKey);
  const mode = row?.mode === 'live' ? 'live' : 'test';

  if (requireEnabled && !enabled) {
    throw new Error('Stripe payments are disabled in Super Admin → Payment gateway settings.');
  }
  if (!secretKey) {
    throw new Error('Stripe secret key is not configured. Add it in Super Admin → Payment gateway settings.');
  }

  // Catch accidental test/live mismatches before a customer reaches Checkout.
  const keyLooksLive = /_(live)_/.test(secretKey);
  const keyLooksTest = /_(test)_/.test(secretKey);
  if (mode === 'live' && keyLooksTest) throw new Error('Stripe is set to Live mode but a test API key is configured.');
  if (mode === 'test' && keyLooksLive) throw new Error('Stripe is set to Test mode but a live API key is configured.');

  return { secretKey, webhookSecret, publishableKey, enabled, mode };
}

export function stripeHeaders(secretKey: string, form = false): Record<string, string> {
  return {
    Authorization: `Bearer ${secretKey}`,
    'Stripe-Version': STRIPE_API_VERSION,
    ...(form ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}),
  };
}

export function randomIntegrationSuffix(): string {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz';
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}
