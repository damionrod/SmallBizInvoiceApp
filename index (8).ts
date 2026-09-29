import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getStripeConfig } from '../_shared/payment-config.ts';
import { activeBillingSubscriptions, billingRequest, billingSubscription, billingPortalConfiguration, billingReturnUrl, syncBillingSubscription, pendingPlanChange } from '../_shared/subscription-billing.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const out = (value: any, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { ...cors, 'Content-Type': 'application/json' },
});

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (request.method !== 'POST') return out({ error: 'Method not allowed' }, 405);
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const client = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: request.headers.get('Authorization') || '' } } });
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: { user } } = await client.auth.getUser();
    if (!user) return out({ error: 'Not authenticated' }, 401);
    const { data: businessId, error: businessError } = await client.rpc('current_business_id');
    if (businessError || !businessId) return out({ error: 'No active business context found' }, 403);
    const { action = 'portal', returnUrl } = await request.json();
    if (!['portal', 'payment_method', 'history', 'cancel', 'keep', 'status'].includes(action)) return out({ error: 'Unknown billing action' }, 400);
    const { data: role, error: roleError } = await client.rpc('v6147_current_business_role', { p_business_id: businessId });
    const permitted = ['cancel', 'keep', 'status'].includes(action) ? ['owner', 'bookkeeper'].includes(role) : role === 'owner';
    if (roleError || !permitted) return out({ error: 'Your role cannot perform this billing action.' }, 403);
    const { data: row, error } = await client.from('subscriptions').select('*').eq('business_id', businessId).maybeSingle();
    if (error) throw error;
    if (!row?.stripe_customer_id) return action === 'status' ? out({ subscription: row }) : out({ error: 'This business has no Stripe subscription to manage.' }, 400);
    const { secretKey } = await getStripeConfig(admin, false);
    let sub = row.stripe_subscription_id ? await billingSubscription(secretKey, row, businessId) : null;
    const activeSubscriptions = await activeBillingSubscriptions(secretKey, row.stripe_customer_id, businessId, row.stripe_subscription_id);
    const duplicateSubscriptions = activeSubscriptions.length > 1 ? activeSubscriptions.map(s => ({
      amount: s.items?.data?.[0]?.price?.unit_amount ?? null,
      currency: s.currency || s.items?.data?.[0]?.price?.currency || 'nzd',
      interval: s.items?.data?.[0]?.price?.recurring?.interval || 'month',
    })) : [];
    if (duplicateSubscriptions.length && ['cancel', 'keep', 'payment_method'].includes(action)) {
      return out({ error: 'More than one active Stripe subscription exists for this business. Review both in Stripe before changing billing.' }, 409);
    }
    if (['cancel', 'keep'].includes(action)) {
      if (!sub || !['active', 'trialing', 'past_due'].includes(sub.status)) return out({ error: 'This subscription is no longer active.' }, 409);
      const end = sub.cancel_at || sub.current_period_end || sub.items?.data?.[0]?.current_period_end;
      if (!end || end * 1000 <= Date.now()) return out({ error: 'The subscription period has ended. Refresh Subscription & Billing.' }, 409);
      if (action === 'keep') {
        if (sub.schedule) {
          const scheduleId = typeof sub.schedule === 'string' ? sub.schedule : sub.schedule.id;
          const schedule = await billingRequest(secretKey, 'subscription_schedules/' + encodeURIComponent(scheduleId));
          if (schedule.subscription !== sub.id || schedule.metadata?.frindly_cancel !== businessId || schedule.end_behavior !== 'cancel')
            return out({ error: 'This subscription has a plan schedule. Contact support before renewing it.' }, 409);
          await billingRequest(secretKey, 'subscription_schedules/' + encodeURIComponent(scheduleId) + '/release', new URLSearchParams(), 'frindly-keep-' + scheduleId);
          sub = await billingSubscription(secretKey, row, businessId);
        }
        if (sub.cancel_at_period_end || sub.cancel_at) {
          const form = new URLSearchParams(sub.cancel_at_period_end ? { cancel_at_period_end: 'false' } : { cancel_at: '' });
          sub = await billingRequest(secretKey, 'subscriptions/' + encodeURIComponent(sub.id), form);
        }
        const patch = await syncBillingSubscription(admin, businessId, sub, row);
        return out({ subscription: { ...row, ...patch } });
      }
      if (sub.cancel_at_period_end || sub.cancel_at) return out({ error: 'Cancellation is already scheduled. Refresh Subscription & Billing.' }, 409);
      const pending = await pendingPlanChange(secretKey, sub, businessId);
      if (pending) {
        // Stripe's portal cannot cancel a subscription with a scheduled price change.
        // The user confirmed in Frindly; convert that schedule to cancellation at
        // the existing paid period end while keeping this period's current price.
        const item = sub.items?.data?.[0];
        if (!item?.price?.id || !Number.isFinite(item.quantity || 1)) throw new Error('The subscription requires billing review.');
        const form = new URLSearchParams({ 'end_behavior': 'cancel', 'proration_behavior': 'none',
          'metadata[frindly_plan_change]': '', 'metadata[frindly_cancel]': businessId,
          'phases[0][items][0][price]': item.price.id,
          'phases[0][items][0][quantity]': String(item.quantity || 1),
          'phases[0][start_date]': String(sub.current_period_start || item.current_period_start),
          'phases[0][end_date]': String(end) });
        await billingRequest(secretKey, 'subscription_schedules/' + encodeURIComponent(pending.scheduleId), form,
          'frindly-cancel-scheduled-' + pending.scheduleId);
        sub = await billingSubscription(secretKey, row, businessId);
        if (sub.cancel_at !== end && !sub.cancel_at_period_end)
          throw new Error('Stripe has not confirmed the period-end cancellation. Refresh billing before retrying.');
        const patch = await syncBillingSubscription(admin, businessId, sub, row);
        return out({ subscription: { ...row, ...patch }, canceledAtPeriodEnd: true });
      }
    }
    if (action === 'status') {
      const patch = sub ? await syncBillingSubscription(admin, businessId, sub, row) : {};
      const price = sub?.items?.data?.[0]?.price;
      const pending = sub && !duplicateSubscriptions.length ? await pendingPlanChange(secretKey, sub, businessId) : null;
      let scheduledChange = null;
      if (pending) {
        const { data: plans, error: planError } = await admin.from('plans').select('name,stripe_price_id,stripe_annual_price_id,monthly_price,annual_price');
        if (planError) throw planError;
        const plan = plans?.find((p: any) => p.stripe_price_id === pending.priceId || p.stripe_annual_price_id === pending.priceId);
        scheduledChange = { planName: plan?.name || 'New plan', priceId: pending.priceId,
          amount: plan ? Math.round(Number(pending.priceId === plan.stripe_annual_price_id ? plan.annual_price : plan.monthly_price) * 100) : null,
          interval: plan?.stripe_annual_price_id === pending.priceId ? 'year' : 'month', effectiveAt: pending.effectiveAt };
      }
      return out({ subscription: { ...row, ...patch }, price: price ? { amount: price.unit_amount, currency: price.currency, interval: price.recurring?.interval } : null, duplicateSubscriptions, scheduledChange });
    }
    const safeReturnUrl = billingReturnUrl(returnUrl, request);
    const purpose = action === 'cancel' ? 'cancel' : action === 'history' ? 'history' : 'owner';
    const configuration = await billingPortalConfiguration(secretKey, purpose);
    const form = new URLSearchParams({ customer: row.stripe_customer_id, configuration, return_url: safeReturnUrl });
    if (action === 'cancel' || action === 'payment_method') {
      form.set('flow_data[type]', action === 'cancel' ? 'subscription_cancel' : 'payment_method_update');
      if (action === 'cancel') form.set('flow_data[subscription_cancel][subscription]', sub.id);
      form.set('flow_data[after_completion][type]', 'redirect');
      form.set('flow_data[after_completion][redirect][return_url]', safeReturnUrl);
    }
    const session = await billingRequest(secretKey, 'billing_portal/sessions', form);
    return out({ url: session.url });
  } catch (error) {
    return out({ error: error instanceof Error ? error.message : 'Billing is unavailable.' }, 400);
  }
});
