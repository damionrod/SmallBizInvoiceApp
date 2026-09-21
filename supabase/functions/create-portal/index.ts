import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getStripeConfig, stripeHeaders } from '../_shared/payment-config.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const out = (value: any, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { ...cors, 'Content-Type': 'application/json' },
});

function validateReturnUrl(raw: any, request: Request) {
  const value = String(raw || '').trim();
  if (!value) throw new Error('Missing return URL');
  let target: URL;
  try { target = new URL(value); } catch { throw new Error('Invalid return URL'); }
  if (!['https:', 'http:'].includes(target.protocol)) throw new Error('Return URL must use HTTP or HTTPS');
  const origin = request.headers.get('origin');
  if (origin && new URL(origin).origin !== target.origin) throw new Error('Return URL origin does not match the app origin');
  return target.toString();
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth = request.headers.get('Authorization') || '';
    const client = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const admin = createClient(url, service);
    const { secretKey: stripe } = await getStripeConfig(admin, false);
    const { data: { user } } = await client.auth.getUser();
    if (!user) return out({ error: 'Not authenticated' }, 401);
    const { data: businessId, error: businessError } = await client.rpc('current_business_id');
    if (businessError || !businessId) return out({ error: 'No active business context found' }, 403);
    const { data: billingRole, error: roleError } = await client.rpc('v6147_current_business_role', { p_business_id: businessId });
    if (roleError || billingRole !== 'owner') return out({ error: 'Only the Business Owner can manage billing' }, 403);
    const { data: subscription } = await client.from('subscriptions').select('stripe_customer_id').eq('business_id', businessId).maybeSingle();
    if (!subscription?.stripe_customer_id) return out({ error: 'No paid subscription is attached to this business yet.' }, 400);
    const { returnUrl } = await request.json();
    const safeReturnUrl = validateReturnUrl(returnUrl, request);
    const form = new URLSearchParams({ customer: subscription.stripe_customer_id, return_url: safeReturnUrl });
    const response = await fetch('https://api.stripe.com/v1/billing_portal/sessions', {
      method: 'POST', headers: stripeHeaders(stripe, true), body: form,
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data?.error?.message || 'Unable to open billing portal');
    return out({ url: data.url });
  } catch (error) {
    return out({ error: error instanceof Error ? error.message : 'Portal failed' }, 400);
  }
});
