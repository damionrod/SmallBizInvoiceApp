import { stripeHeaders } from './payment-config.ts';

// Subscription billing only. Invoice payments and connected accounts use their
// own endpoints and are never changed by these helpers.
export async function billingRequest(secret: string, path: string, form?: URLSearchParams, key?: string) {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: form ? 'POST' : 'GET',
    headers: { ...stripeHeaders(secret, !!form), ...(key ? { 'Idempotency-Key': key } : {}) },
    ...(form ? { body: form } : {}),
    signal: AbortSignal.timeout(15000),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || 'Stripe billing is temporarily unavailable.');
  return data;
}

export async function billingSubscription(secret: string, row: any, businessId: string) {
  if (!row?.stripe_subscription_id || !row?.stripe_customer_id) throw new Error('This business has no Stripe subscription.');
  const sub = await billingRequest(secret, `subscriptions/${encodeURIComponent(row.stripe_subscription_id)}`);
  const customer = typeof sub.customer === 'string' ? sub.customer : sub.customer?.id;
  if (customer !== row.stripe_customer_id || (sub.metadata?.business_id && sub.metadata.business_id !== businessId)) {
    throw new Error('The Stripe subscription does not match this business.');
  }
  return sub;
}

export async function activeBillingSubscriptions(secret: string, customer: string, businessId: string, currentId?: string) {
  const results: any[] = [];
  let cursor = '';
  for (let page = 0; page < 10; page++) {
    const list = await billingRequest(secret, `subscriptions?customer=${encodeURIComponent(customer)}&status=all&limit=100${cursor ? `&starting_after=${encodeURIComponent(cursor)}` : ''}`);
    for (const sub of list.data || []) {
      if (['active', 'trialing', 'past_due', 'unpaid'].includes(sub.status) &&
          (sub.id === currentId || sub.metadata?.business_id === businessId)) results.push(sub);
    }
    if (!list.has_more) return results;
    cursor = list.data?.[list.data.length - 1]?.id;
    if (!cursor) break;
  }
  throw new Error('Too many Stripe subscriptions to check safely. Contact the platform administrator.');
}

export async function pendingPlanChange(secret: string, sub: any, businessId: string) {
  const id = typeof sub.schedule === 'string' ? sub.schedule : sub.schedule?.id;
  if (!id) return null;
  const schedule = await billingRequest(secret, `subscription_schedules/${encodeURIComponent(id)}`);
  if (schedule.status !== 'active' || schedule.subscription !== sub.id) return null;
  if (schedule.metadata?.frindly_cancel === businessId && schedule.end_behavior === 'cancel') return null;
  if (schedule.metadata?.frindly_plan_change !== businessId) {
    throw new Error('This subscription has a schedule managed outside Frindly. Contact support before changing plans.');
  }
  const future = schedule.phases?.find((phase: any) => phase.start_date >= (sub.items?.data?.[0]?.current_period_end || sub.current_period_end));
  const priceId = future?.items?.[0]?.price;
  return priceId ? { scheduleId: id, priceId: typeof priceId === 'string' ? priceId : priceId.id,
    effectiveAt: future.start_date, interval: future.items?.[0]?.price?.recurring?.interval || null } : null;
}

export function subscriptionCancellationPatch(sub: any) {
  const date = Number.isFinite(sub.cancel_at) && sub.cancel_at > 0 ? new Date(sub.cancel_at * 1000).toISOString() : null;
  return { cancel_at_period_end: sub.cancel_at_period_end === true, cancel_at: date };
}

export async function subscriptionPlanPatch(db: any, sub: any) {
  const price = sub.items?.data?.[0]?.price;
  const priceId = typeof price === 'string' ? price : price?.id;
  if (priceId) {
    const { data: plans, error } = await db.from('plans').select('id,stripe_price_id,stripe_annual_price_id');
    if (error) throw error;
    const plan = (plans || []).find((p: any) => p.stripe_price_id === priceId || p.stripe_annual_price_id === priceId);
    if (plan) return { plan_id: plan.id, billing_interval: plan.stripe_annual_price_id === priceId ? 'annual' : 'monthly' };
  }
  // Preserve older subscriptions whose Stripe price was not entered in Plans.
  return sub.metadata?.plan_id ? {
    plan_id: sub.metadata.plan_id,
    billing_interval: sub.metadata.billing_interval === 'annual' ? 'annual' : 'monthly',
  } : {};
}

export async function syncBillingSubscription(db: any, businessId: string, sub: any, currentRow?: any) {
  const item = sub.items?.data?.[0];
  const start = sub.current_period_start ?? item?.current_period_start;
  const end = sub.current_period_end ?? item?.current_period_end;
  if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) throw new Error('Stripe subscription billing period is missing or invalid.');
  const patch = {
    ...await subscriptionPlanPatch(db, sub), ...subscriptionCancellationPatch(sub),
    status: sub.status === 'active' ? 'active' : sub.status === 'trialing' ? 'trialing' : sub.status === 'past_due' ? 'past_due' : 'canceled',
    current_period_start: new Date(start * 1000).toISOString(), current_period_end: new Date(end * 1000).toISOString(),
    trial_ends_at: sub.trial_end ? new Date(sub.trial_end * 1000).toISOString() : null,
    updated_at: new Date().toISOString(),
  };
  if (currentRow?.status === 'suspended') patch.status = 'suspended';
  const { error } = await db.from('subscriptions').update(patch).eq('business_id', businessId).eq('stripe_subscription_id', sub.id);
  if (error) throw error;
  return patch;
}

// Configurations are private to this feature. Never modify a platform's default
// portal or enable a hosted login that could bypass Frindly's role checks.
export async function billingPortalConfiguration(secret: string, purpose: 'owner' | 'cancel' | 'history' | 'update', price?: any) {
  const marker = `frindly-v6187-${purpose}${price ? `-${price.id}` : ''}`;
  let cursor = '';
  for (let page = 0; page < 10; page++) {
    const list = await billingRequest(secret, `billing_portal/configurations?limit=100${cursor ? `&starting_after=${encodeURIComponent(cursor)}` : ''}`);
    const existing = list.data?.find((c: any) => c.active && c.metadata?.frindly_configuration === marker);
    if (existing) {
      const f = existing.features || {}, cancel = f.subscription_cancel;
      if (f.customer_update?.enabled || f.subscription_pause?.enabled ||
          f.payment_method_update?.enabled !== (purpose === 'owner') ||
          f.invoice_history?.enabled !== ['owner', 'history'].includes(purpose) ||
          f.subscription_update?.enabled !== (purpose === 'update') ||
          cancel?.enabled !== ['owner', 'cancel'].includes(purpose) ||
          (cancel.enabled && cancel.mode !== 'at_period_end') ||
          existing.login_page?.enabled) throw new Error('The Stripe billing portal configuration needs review by the platform administrator.');
      return existing.id;
    }
    if (!list.has_more) break;
    cursor = list.data[list.data.length - 1].id;
  }
  const form = new URLSearchParams({
    name: `Frindly ${purpose} billing`, 'metadata[frindly_configuration]': marker,
    'login_page[enabled]': 'false', 'features[customer_update][enabled]': 'false',
    'features[invoice_history][enabled]': String(['owner', 'history'].includes(purpose)),
    'features[payment_method_update][enabled]': String(purpose === 'owner'),
    'features[subscription_cancel][enabled]': String(['owner', 'cancel'].includes(purpose)),
    'features[subscription_cancel][mode]': 'at_period_end',
    'features[subscription_cancel][proration_behavior]': 'none',
    'features[subscription_update][enabled]': String(purpose === 'update'),
  });
  if (purpose === 'update') {
    if (!price?.id || !price?.product) throw new Error('The selected Stripe plan is unavailable.');
    form.set('features[subscription_update][default_allowed_updates][0]', 'price');
    form.set('features[subscription_update][products][0][product]', typeof price.product === 'string' ? price.product : price.product.id);
    form.set('features[subscription_update][products][0][prices][0]', price.id);
    form.set('features[subscription_update][proration_behavior]', 'create_prorations');
  }
  const created = await billingRequest(secret, 'billing_portal/configurations', form, marker);
  return created.id;
}

export function billingReturnUrl(raw: any, request: Request) {
  let target: URL;
  try { target = new URL(String(raw || '')); } catch { throw new Error('Invalid return URL'); }
  if (!['http:', 'https:'].includes(target.protocol)) throw new Error('Return URL must use HTTP or HTTPS');
  const origin = request.headers.get('origin');
  if (origin && origin !== 'null' && new URL(origin).origin !== target.origin) throw new Error('Return URL origin does not match the app origin');
  if ((!origin || origin === 'null') && target.origin !== 'https://frindly.co.nz') throw new Error('Return URL must use the deployed Frindly site');
  target.search = ''; target.hash = 'settings/subscription';
  return target.toString();
}
