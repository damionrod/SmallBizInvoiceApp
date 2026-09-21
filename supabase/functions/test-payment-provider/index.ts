import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getStripeConfig, stripeHeaders } from './_shared/payment-config.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const out = (value: any, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { ...cors, 'Content-Type': 'application/json' },
});

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth = request.headers.get('Authorization') || '';
    const client = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const admin = createClient(url, service);
    const { data: { user } } = await client.auth.getUser();
    if (!user) return out({ error: 'Not authenticated' }, 401);
    const { data: profile } = await client.from('profiles').select('is_super_admin').eq('id', user.id).maybeSingle();
    if (profile?.is_super_admin !== true) return out({ error: 'Super Admin access required' }, 403);
    const { provider } = await request.json();
    if (provider !== 'stripe') return out({ error: 'Only the Stripe connection test is available.' }, 400);
    const { secretKey } = await getStripeConfig(admin, false);
    const response = await fetch('https://api.stripe.com/v1/account', { headers: stripeHeaders(secretKey) });
    const data = await response.json();
    if (!response.ok) return out({ error: data?.error?.message || 'Stripe rejected the API key.' }, 400);
    return out({ ok: true, account_id: data.id, account_name: data.business_profile?.name || data.settings?.dashboard?.display_name || data.email || '' });
  } catch (error) {
    return out({ error: error instanceof Error ? error.message : 'Connection test failed' }, 400);
  }
});
