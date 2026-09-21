import Stripe from 'npm:stripe@22.4.0';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getStripeConfig, stripeHeaders, STRIPE_API_VERSION } from './_shared/payment-config.ts';

Deno.serve(async(req)=>{
  const url=Deno.env.get('SUPABASE_URL');
  const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!url||!service) return new Response('Missing Supabase configuration',{status:500});

  const db=createClient(url,service);
  let cfg;
  try{cfg=await getStripeConfig(db,false)}catch(e){return new Response(e instanceof Error?e.message:'Missing Stripe configuration',{status:500})}

  const secret=cfg.secretKey;
  const wh=cfg.webhookSecret;
  if(!wh) return new Response('Stripe webhook signing secret is not configured in Super Admin → Payment gateway settings.',{status:500});

  const stripe=new Stripe(secret,{apiVersion:STRIPE_API_VERSION});
  const sig=req.headers.get('stripe-signature');
  if(!sig) return new Response('Missing signature',{status:400});

  let event:Stripe.Event;
  try{
    event=await stripe.webhooks.constructEventAsync(await req.text(),sig,wh);
  }catch(e){
    return new Response(`Webhook signature error: ${e instanceof Error?e.message:'invalid'}`,{status:400});
  }

  const referralEvent=async(bid:string|undefined,eventName:string)=>{
    if(!bid)return;
    const {error}=await db.rpc('v6151_process_referral_event',{p_business_id:bid,p_event:eventName});
    if(error) console.warn('Referral event failed',eventName,bid,error.message);
  };

  const resolveBusiness=async(invoice:Stripe.Invoice)=>{
    const subscriptionId=invoice.subscription?String(invoice.subscription):'';
    if(subscriptionId){
      const {data:s}=await db.from('subscriptions').select('business_id').eq('stripe_subscription_id',subscriptionId).maybeSingle();
      if(s?.business_id) return String(s.business_id);
      try{
        const sub=await stripe.subscriptions.retrieve(subscriptionId);
        if(sub.metadata?.business_id) return String(sub.metadata.business_id);
      }catch{}
    }

    const customerId=invoice.customer?String(invoice.customer):'';
    if(customerId){
      const {data:s}=await db.from('subscriptions').select('business_id').eq('stripe_customer_id',customerId).maybeSingle();
      if(s?.business_id) return String(s.business_id);
    }
    return '';
  };

  const applyFinloCredit=async(invoice:Stripe.Invoice)=>{
    const invoiceId=String(invoice.id||'');
    const customerId=invoice.customer?String(invoice.customer):'';
    if(!invoiceId||!customerId)return;

    const bid=await resolveBusiness(invoice);
    if(!bid)return;

    const currency=String(invoice.currency||'nzd').toUpperCase();
    const {data:reservation,error:reserveError}=await db.rpc('v6152_reserve_credits',{
      p_business_id:bid,
      p_stripe_invoice_id:invoiceId,
      p_stripe_customer_id:customerId,
      p_currency:currency
    });

    if(reserveError){
      console.warn('Finlo credit reservation failed',invoiceId,reserveError.message);
      return;
    }

    const amount=Number(reservation?.amount||0);
    const applicationId=String(reservation?.applicationId||'');
    if(reservation?.alreadyCredited||amount<=0||!applicationId)return;

    try{
      const form=new URLSearchParams();
      form.set('amount',String(-Math.round(amount*100)));
      form.set('currency',currency.toLowerCase());
      form.set('description','Finlo credit applied to subscription');
      form.set('metadata[finlo_redemption_id]',applicationId);
      form.set('metadata[finlo_business_id]',bid);
      form.set('metadata[stripe_invoice_id]',invoiceId);

      const r=await fetch(`https://api.stripe.com/v1/customers/${encodeURIComponent(customerId)}/balance_transactions`,{
        method:'POST',
        headers:{
          Authorization:`Bearer ${secret}`,
          'Content-Type':'application/x-www-form-urlencoded',
          'Stripe-Version':STRIPE_API_VERSION,
          'Idempotency-Key':`finlo-credit-${applicationId}`
        },
        body:form
      });
      const d=await r.json();
      if(!r.ok) throw new Error(d?.error?.message||'Unable to apply Finlo credit in Stripe');

      const {error:completeError}=await db.rpc('v6152_complete_credit_redemption',{
        p_application_id:applicationId,
        p_stripe_balance_transaction_id:String(d.id||'')
      });
      if(completeError) throw new Error(completeError.message);
    }catch(e){
      const msg=e instanceof Error?e.message:'Stripe credit application failed';
      const {error:releaseError}=await db.rpc('v6152_release_credit_redemption',{
        p_application_id:applicationId,
        p_error:msg
      });
      if(releaseError) console.warn('Finlo credit release failed',applicationId,releaseError.message);
      throw e;
    }
  };

  try{
    // V61.52 additive behavior: when Stripe creates the next subscription invoice,
    // transfer eligible earned Finlo credit to the Stripe customer invoice balance.
    // Stripe then applies that credit to the invoice during normal finalization.
    if(event.type==='invoice.created'){
      const invoice=event.data.object as Stripe.Invoice;
      await applyFinloCredit(invoice);
    }

    // Existing V61.51 subscription + referral behavior below remains unchanged.
    if(event.type==='checkout.session.completed'){
      const cs=event.data.object as Stripe.Checkout.Session;
      const bid=cs.metadata?.business_id;
      const pid=cs.metadata?.plan_id;
      if(bid&&pid&&cs.subscription){
        const sub=await stripe.subscriptions.retrieve(String(cs.subscription));
        await db.from('subscriptions').update({
          plan_id:pid,
          status:'active',
          stripe_customer_id:String(cs.customer||''),
          stripe_subscription_id:sub.id,
          current_period_start:new Date(sub.current_period_start*1000).toISOString(),
          current_period_end:new Date(sub.current_period_end*1000).toISOString(),
          trial_ends_at:null,
          billing_interval:cs.metadata?.billing_interval==='annual'?'annual':'monthly',
          updated_at:new Date().toISOString()
        }).eq('business_id',bid);
        await referralEvent(bid,'subscription_activated');
      }
    }

    if(event.type==='customer.subscription.created'||event.type==='customer.subscription.updated'||event.type==='customer.subscription.deleted'){
      const sub=event.data.object as Stripe.Subscription;
      const bid=sub.metadata?.business_id;
      if(bid){
        const status=event.type==='customer.subscription.deleted'?'canceled':(sub.status==='active'?'active':sub.status==='past_due'?'past_due':sub.status==='trialing'?'trialing':'canceled');
        const patch:any={
          status,
          current_period_start:new Date(sub.current_period_start*1000).toISOString(),
          current_period_end:new Date(sub.current_period_end*1000).toISOString(),
          cancel_at_period_end:sub.cancel_at_period_end,
          updated_at:new Date().toISOString()
        };
        if(sub.metadata?.plan_id)patch.plan_id=sub.metadata.plan_id;
        if(sub.customer)patch.stripe_customer_id=String(sub.customer);
        patch.stripe_subscription_id=sub.id;
        await db.from('subscriptions').update(patch).eq('business_id',bid);
        if(status==='active') await referralEvent(bid,'subscription_activated');
      }
    }

    if(event.type==='invoice.payment_failed'){
      const invoice=event.data.object as Stripe.Invoice;
      const bid=await resolveBusiness(invoice);
      if(bid) await db.from('subscriptions').update({status:'past_due',updated_at:new Date().toISOString()}).eq('business_id',bid);
    }

    if(event.type==='invoice.payment_succeeded'){
      const invoice=event.data.object as Stripe.Invoice;
      const subscriptionId=invoice.subscription?String(invoice.subscription):'';
      if(subscriptionId){
        const {data:s}=await db.from('subscriptions').select('business_id').eq('stripe_subscription_id',subscriptionId).maybeSingle();
        let bid=s?.business_id;
        if(!bid){
          try{
            const sub=await stripe.subscriptions.retrieve(subscriptionId);
            bid=sub.metadata?.business_id;
          }catch{}
        }
        if(bid) await referralEvent(bid,'first_successful_payment');
      }
    }

    return new Response('ok');
  }catch(e){
    return new Response(e instanceof Error?e.message:'Webhook failed',{status:500});
  }
});
