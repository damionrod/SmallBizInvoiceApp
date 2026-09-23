import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getStripeConfig, randomIntegrationSuffix, stripeHeaders } from "../_shared/payment-config.ts";
import { activeBillingSubscriptions, billingRequest, billingSubscription, pendingPlanChange } from "../_shared/subscription-billing.ts";
import { refereeCheckoutDiscount } from "../_shared/referral-checkout.ts";

const cors={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS"
};
const out=(x:any,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,"Content-Type":"application/json"}});

function validateReturnUrl(raw:any,req:Request){
  const value=String(raw||'').trim();
  if(!value) throw new Error('Missing return URL');
  let target:URL;
  try{target=new URL(value)}catch{throw new Error('Invalid return URL')}
  if(!['https:','http:'].includes(target.protocol)) throw new Error('Return URL must use HTTP or HTTPS');
  const origin=req.headers.get('origin');
  if(origin){
    try{
      const source=new URL(origin);
      if(source.origin!==target.origin) throw new Error('Return URL origin does not match the app origin');
    }catch(e){
      if(e instanceof Error && e.message==='Return URL origin does not match the app origin') throw e;
    }
  }
  return target.toString();
}

Deno.serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  if(req.method!=='POST')return out({error:'Method not allowed'},405);
  let stage='initialising';
  try{
    stage='loading Stripe configuration';
    const url=Deno.env.get('SUPABASE_URL')!;
    const anon=Deno.env.get('SUPABASE_ANON_KEY')!;
    const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth=req.headers.get('Authorization')||'';
    const client=createClient(url,anon,{global:{headers:{Authorization:auth}}});
    const admin=createClient(url,service);
    const {secretKey:stripe}=await getStripeConfig(admin,true);

    stage='authenticating the current user';
    const {data:{user}}=await client.auth.getUser();
    if(!user)return out({error:'Not authenticated'},401);

    stage='resolving the active business';
    const {data:businessId,error:businessError}=await client.rpc('current_business_id');
    if(businessError||!businessId)return out({error:'No active business context found'},403);

    // Billing is server-authorised Owner-only. UI visibility is not a security boundary.
    stage='checking billing permission';
    const {data:billingRole,error:roleError}=await client.rpc('v6147_current_business_role',{p_business_id:businessId});
    if(roleError||billingRole!=='owner')return out({error:'Only the Business Owner can manage billing'},403);

    const {data:profile}=await client.from('profiles').select('email').eq('id',user.id).maybeSingle();
    const {planSlug,billingInterval='monthly',returnUrl,action='start',quote}=await req.json();
    if(!['start','preview','confirm','undo'].includes(action))return out({error:'Unknown plan change action.'},400);
    const interval=billingInterval==='annual'?'annual':'monthly';
    const safeReturnUrl=action==='start'?validateReturnUrl(returnUrl,req):'';

    if(action==='undo'){
      const {data:row,error}=await client.from('subscriptions').select('*').eq('business_id',businessId).maybeSingle();
      if(error)throw error;
      const current=await billingSubscription(stripe,row,businessId);
      const change=await pendingPlanChange(stripe,current,businessId);
      if(!change)return out({error:'There is no scheduled plan change to undo.'},409);
      const active=await activeBillingSubscriptions(stripe,row.stripe_customer_id,businessId,current.id);
      if(active.length!==1)return out({error:'Review the active Stripe subscriptions before changing billing.'},409);
      await billingRequest(stripe,`subscription_schedules/${encodeURIComponent(change.scheduleId)}/release`,new URLSearchParams(),`frindly-undo-${change.scheduleId}`);
      return out({undone:true});
    }

    stage='loading the selected plan';
    const {data:plan,error:planError}=await client.from('plans').select('*').eq('slug',planSlug).eq('is_public',true).maybeSingle();
    if(planError)throw new Error(`Unable to load the selected plan: ${planError.message}`);
    if(!plan)throw new Error('The selected plan is not available for checkout.');
    const selectedPriceId=interval==='annual'?plan?.stripe_annual_price_id:plan?.stripe_price_id;
    const selectedAmount=interval==='annual'?plan?.annual_price:plan?.monthly_price;
    if(!selectedPriceId||selectedAmount==null)return out({error:`This plan does not have a valid ${interval} billing price configured yet.`},400);

    stage='verifying the Stripe price';
    const priceResponse=await fetch('https://api.stripe.com/v1/prices/'+encodeURIComponent(selectedPriceId),{headers:stripeHeaders(stripe)});
    const priceData=await priceResponse.json();
    if(!priceResponse.ok)throw new Error(priceData?.error?.message||'Unable to verify Stripe price');
    if(priceData?.active!==true)return out({error:'The configured Stripe price is inactive.'},400);
    const expectedInterval=interval==='annual'?'year':'month',expectedAmount=Math.round(Number(selectedAmount)*100);
    if(priceData?.recurring?.interval!==expectedInterval)return out({error:`Configured Stripe price is not a genuine ${interval} recurring price.`},400);
    if(Number(priceData?.unit_amount)!==expectedAmount)return out({error:`Configured Stripe price amount does not match the ${interval} plan price.`},400);

    stage='loading the billing record';
    const {data:sub,error:subscriptionError}=await client.from('subscriptions').select('*').eq('business_id',businessId).maybeSingle();
    if(subscriptionError)throw subscriptionError;
    let customer=sub?.stripe_customer_id;
    if(customer){
      const activeSubscriptions=await activeBillingSubscriptions(stripe,customer,businessId,sub?.stripe_subscription_id);
      if(activeSubscriptions.length>1)throw new Error('More than one active Stripe subscription exists for this business. Review both in Subscription & Billing before choosing a plan.');
      if(activeSubscriptions.length===1&&activeSubscriptions[0].id!==sub?.stripe_subscription_id){
        throw new Error('An active Stripe subscription is not yet linked to this business. Refresh billing before starting a new checkout.');
      }
    }

    // An existing subscription must be changed, never purchased a second time.
    // Retrieve Stripe's current state rather than trusting a delayed webhook.
    if(sub?.stripe_subscription_id){
      stage='opening the existing subscription';
      const existing=await billingSubscription(stripe,sub,businessId);
      if(!['canceled','incomplete_expired'].includes(existing.status)){
        if(existing.cancel_at_period_end||existing.cancel_at)throw new Error('Choose Keep subscription before changing your plan.');
        if(!['active','trialing'].includes(existing.status))throw new Error('Resolve the outstanding subscription payment in Subscription & Billing before changing your plan.');
        if(existing.status==='trialing')throw new Error('A Stripe trial is still running. Contact support to change this plan without ending the trial early.');
        const items=existing.items?.data||[];
        if(items.length!==1)throw new Error('This subscription needs a plan review by the platform administrator.');
        if(items[0].price?.id===selectedPriceId)throw new Error('This is already your current plan and billing interval.');
        if(existing.pending_update)throw new Error('A prior plan payment is pending. Complete or resolve that payment first.');
        if(await pendingPlanChange(stripe,existing,businessId))throw new Error('A plan change is already scheduled. Undo it before choosing another plan.');
        const oldPrice=items[0].price;
        if(!Number.isInteger(oldPrice?.unit_amount)||!oldPrice?.recurring?.interval||oldPrice.currency!==priceData.currency)
          throw new Error('The current Stripe price cannot be compared safely with the selected plan.');
        const oldInterval=oldPrice.recurring.interval,newInterval=priceData.recurring.interval;
        const downgrade=(oldInterval==='year'&&newInterval==='month') ||
          (oldInterval===newInterval&&priceData.unit_amount<=oldPrice.unit_amount);
        const end=existing.current_period_end||items[0].current_period_end;
        if(!Number.isFinite(end)||end*1000<=Date.now())throw new Error('Your current billing period has ended. Refresh and try again.');
        const now=Math.floor(Date.now()/1000);
        if(action==='confirm'&&(quote?.oldPriceId!==oldPrice.id||Number(quote?.periodEnd)!==end))
          return out({error:'Your current plan or renewal date changed. Review a new price preview.'},409);
        let amountDue=0,prorationDate=now;
        if(!downgrade){
          if(existing.collection_method!=='charge_automatically')throw new Error('Immediate plan changes require automatic Stripe payment collection.');
          if(action==='confirm'){
            prorationDate=Number(quote?.prorationDate);
            if(!Number.isInteger(prorationDate)||prorationDate>now+15||prorationDate<now-300||quote?.subscriptionId!==existing.id||quote?.priceId!==selectedPriceId)
              return out({error:'Your price preview has expired. Review the amount again.'},409);
          }
          const previewForm=new URLSearchParams({customer,subscription:existing.id,
            'subscription_details[items][0][id]':items[0].id,
            'subscription_details[items][0][price]':selectedPriceId,
            'subscription_details[items][0][quantity]':String(items[0].quantity||1),
            'subscription_details[proration_date]':String(prorationDate),
            'subscription_details[proration_behavior]':'always_invoice'});
          const preview=await billingRequest(stripe,'invoices/create_preview',previewForm);
          amountDue=Number(preview.amount_due);
          if(!Number.isInteger(amountDue)||amountDue<0||preview.currency!==priceData.currency)
            throw new Error('Stripe could not confirm the amount payable now.');
          if(action==='confirm'&&Number(quote.amountDue)!==amountDue)return out({error:'The amount changed. Please review an updated preview.'},409);
        }
        if(action==='preview'||action==='start')return out({change:{kind:downgrade?'downgrade':'upgrade',
          planName:plan.name,interval,currency:priceData.currency,amountDue,
          nextAmount:priceData.unit_amount,effectiveAt:downgrade?end:now,
          renewsAt:downgrade?end:(oldInterval===newInterval?end:null),
          quote:{subscriptionId:existing.id,priceId:selectedPriceId,oldPriceId:oldPrice.id,periodEnd:end,prorationDate,amountDue}}});
        if(action!=='confirm')return out({error:'Confirm the preview to change plans.'},400);
        if(downgrade){
          if(quote?.subscriptionId!==existing.id||quote?.priceId!==selectedPriceId||Number(quote?.amountDue)!==0||
            !Number.isInteger(Number(quote?.prorationDate))||Number(quote.prorationDate)>now+15||Number(quote.prorationDate)<now-300)
            return out({error:'Review the plan change before confirming.'},409);
          if(existing.schedule)throw new Error('This subscription already has a schedule. Contact support before changing plans.');
          if(existing.discounts?.length||existing.default_tax_rates?.length||items[0].discounts?.length||items[0].tax_rates?.length)
            throw new Error('This subscription has custom discounts or tax rates. Contact support to schedule a change without losing them.');
          const schedule=await billingRequest(stripe,'subscription_schedules',new URLSearchParams({from_subscription:existing.id}),
            `frindly-schedule-${existing.id}-${end}-${selectedPriceId}-${quote.prorationDate}`);
          try{
            const form=new URLSearchParams({'end_behavior':'release','proration_behavior':'none',
              'metadata[frindly_plan_change]':businessId,
              'phases[0][items][0][price]':oldPrice.id,
              'phases[0][items][0][quantity]':String(items[0].quantity||1),
              'phases[0][start_date]':String(schedule.current_phase?.start_date||existing.current_period_start||items[0].current_period_start),
              'phases[0][end_date]':String(end),
              'phases[1][items][0][price]':selectedPriceId,
              'phases[1][items][0][quantity]':String(items[0].quantity||1),
              'phases[1][iterations]':'1',
              'phases[1][proration_behavior]':'none'});
            await billingRequest(stripe,`subscription_schedules/${encodeURIComponent(schedule.id)}`,form,
              `frindly-schedule-update-${schedule.id}-${selectedPriceId}`);
          }catch(error){
            await billingRequest(stripe,`subscription_schedules/${encodeURIComponent(schedule.id)}/release`,new URLSearchParams());
            throw error;
          }
          return out({scheduled:true,effectiveAt:end});
        }
        const form=new URLSearchParams({'items[0][id]':items[0].id,'items[0][price]':selectedPriceId,
          'items[0][quantity]':String(items[0].quantity||1),
          'proration_behavior':'always_invoice','payment_behavior':'error_if_incomplete',
          'proration_date':String(prorationDate),'expand[0]':'latest_invoice'});
        const updated=await billingRequest(stripe,`subscriptions/${encodeURIComponent(existing.id)}`,form,
          `frindly-upgrade-${existing.id}-${selectedPriceId}-${prorationDate}`);
        if(updated.pending_update||updated.items?.data?.[0]?.price?.id!==selectedPriceId||
          (amountDue>0&&updated.latest_invoice?.paid!==true))
          throw new Error('Stripe has not confirmed the upgrade payment. Your plan will update only after successful payment.');
        return out({upgraded:true});
      }
    }

    if(action!=='start')return out({error:'This business has no active paid subscription to change.'},409);

    stage='creating the Stripe Checkout session';
    const f=new URLSearchParams();
    f.set('mode','subscription');
    // Reuse an existing Stripe customer when available. For a first purchase,
    // let Checkout create the customer from the signed-in user's email. This
    // avoids a separate customer-creation request and is handled by the
    // checkout.session.completed webhook.
    if(customer)f.set('customer',customer);
    else {
      const email=String(user.email||profile?.email||'').trim();
      if(email)f.set('customer_email',email);
    }
    f.set('line_items[0][price]',selectedPriceId);
    f.set('line_items[0][quantity]','1');
    f.set('success_url',`${safeReturnUrl}${safeReturnUrl.includes('?')?'&':'?'}billing=success`);
    f.set('cancel_url',`${safeReturnUrl}${safeReturnUrl.includes('?')?'&':'?'}billing=cancel`);
    f.set('client_reference_id',businessId);
    f.set('metadata[business_id]',businessId);
    f.set('metadata[plan_id]',plan.id);
    f.set('metadata[billing_interval]',interval);
    f.set('subscription_data[metadata][business_id]',businessId);
    f.set('subscription_data[metadata][plan_id]',plan.id);
   f.set('subscription_data[metadata][billing_interval]',interval);
    // Apply the welcome benefit to this subscription's first Checkout. Only a
    // recorded referral, its immutable campaign version, and first purchase qualify.
    const reward=await refereeCheckoutDiscount(admin,stripe,businessId,plan,interval,priceData);
    if(reward){
      f.set('discounts[0][coupon]',reward.couponId);
      f.set('payment_method_collection','always');
      f.set('metadata[referral_id]',reward.referralId);
      f.set('metadata[referee_coupon_id]',reward.couponId);
      f.set('subscription_data[metadata][referral_id]',reward.referralId);
      f.set('subscription_data[metadata][referee_coupon_id]',reward.couponId);
    }
    f.set('integration_identifier','finlo_subscriptions_'+randomIntegrationSuffix());

    const r=await fetch('https://api.stripe.com/v1/checkout/sessions',{
      method:'POST',
      headers:stripeHeaders(stripe,true),
      body:f
    });
    const d=await r.json();
    if(!r.ok)throw new Error(d?.error?.message||'Unable to open checkout');
    return out({url:d.url});
  }catch(e){
    const error=e instanceof Error?e.message:'Checkout failed';
    return out({error,stage},400);
  }
});
