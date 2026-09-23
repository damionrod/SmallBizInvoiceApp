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
    const connectedPaymentIntent=async(accountId:string,paymentIntentId:string)=>{
      if(!accountId||!paymentIntentId)return null;
      const params=new URLSearchParams();params.append('expand[]','latest_charge.balance_transaction');
      const response=await fetch(`https://api.stripe.com/v1/payment_intents/${encodeURIComponent(paymentIntentId)}?${params.toString()}`,{headers:{...stripeHeaders(secret), 'Stripe-Account':accountId}});
      const data=await response.json();
      if(!response.ok){console.warn('Connected payment intent lookup failed',paymentIntentId,data?.error?.message||response.status);return null}
      return data;
    };

    const sendOnlineReceipt=async(transactionId:string)=>{
      const resendKey=Deno.env.get('RESEND_API_KEY');
      if(!resendKey)return;
      const {data:tx,error:txError}=await db.from('invoice_payment_transactions').select('id,amount,gross_amount,customer_fee_amount,currency,status,payment_date,stripe_payment_intent_id,stripe_checkout_session_id,metadata,invoices(invoice_number,customer_name,customer_email,total,balance_due),businesses(name,settings)').eq('id',transactionId).maybeSingle();
      if(txError||!tx||tx.status!=='succeeded'||tx.metadata?.receipt_sent_at||!tx.invoices?.customer_email)return;
      const settings=tx.businesses?.settings||{},invoice=tx.invoices||{},currency=String(tx.currency||settings.currency||'NZD').toUpperCase();
      const fromEmail=String(Deno.env.get('RESEND_FROM_EMAIL')||Deno.env.get('EMAIL_FROM_ADDRESS')||'notifications@frindly.co.nz').trim();
      const businessName=String(settings.trading||settings.company||tx.businesses?.name||'Your Business');
      const esc=(value:any)=>String(value??'').replace(/[&<>"']/g,(m)=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]||m));
      const money=(value:any)=>{try{return new Intl.NumberFormat('en-NZ',{style:'currency',currency}).format(Number(value||0))}catch{return `${currency} ${Number(value||0).toFixed(2)}`}};
      const invoiceNumber=String(invoice.invoice_number||'Invoice');
      const subject=`Payment received for ${invoiceNumber} · ${businessName}`;
      const html=`<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a"><h2>Payment received</h2><p>Hi ${esc(invoice.customer_name||'Customer')},</p><p>${esc(businessName)} has received your payment for invoice <strong>${esc(invoiceNumber)}</strong>.</p><table cellpadding="6" cellspacing="0"><tr><td>Invoice payment</td><td><strong>${money(tx.amount)}</strong></td></tr>${Number(tx.customer_fee_amount||0)>0?`<tr><td>Payment processing fee</td><td>${money(tx.customer_fee_amount)}</td></tr>`:''}<tr><td>Total charged</td><td><strong>${money(tx.gross_amount)}</strong></td></tr><tr><td>Remaining invoice balance</td><td>${money(invoice.balance_due)}</td></tr></table><p>Reference: ${esc(tx.stripe_payment_intent_id||tx.stripe_checkout_session_id||'Stripe payment')}</p><p>Thank you,<br>${esc(businessName)}</p></div>`;
      const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resendKey}`,'Content-Type':'application/json'},body:JSON.stringify({from:`${businessName.replace(/[<>]/g,'')} <${fromEmail}>`,to:[invoice.customer_email],reply_to:settings.email||settings.outboundEmail||undefined,subject,html})});
      if(!response.ok){console.warn('Online payment receipt email failed',await response.text());return;}
      await db.from('invoice_payment_transactions').update({metadata:{...(tx.metadata||{}),receipt_sent_at:new Date().toISOString()},updated_at:new Date().toISOString()}).eq('id',transactionId);
    };

    const settleOnlineCheckout=async(session:any,success:boolean)=>{
      const accountId=String((event as any).account||'');
      const transactionId=String(session?.metadata?.payment_transaction_id||'');
      if(!accountId||!transactionId)return false;
      const paymentIntentId=String(session?.payment_intent||'');
      if(!success){
        const {error}=await db.from('invoice_payment_transactions').update({status:'failed',failure_reason:'Stripe reported that the customer payment failed.',stripe_checkout_session_id:session?.id||null,stripe_payment_intent_id:paymentIntentId||null,stripe_event_id:event.id,updated_at:new Date().toISOString()}).eq('id',transactionId).neq('status','succeeded');
        if(error)throw error;
        return true;
      }

      const intent=paymentIntentId?await connectedPaymentIntent(accountId,paymentIntentId):null;
      const charge=intent?.latest_charge&&typeof intent.latest_charge==='object'?intent.latest_charge:null;
      const balance=intent?.latest_charge?.balance_transaction&&typeof intent.latest_charge.balance_transaction==='object'?intent.latest_charge.balance_transaction:null;
      const grossAmount=Number(session?.amount_total||intent?.amount||0)/100;
      const stripeFee=balance?.fee==null?null:Number(balance.fee)/100;
      const netAmount=balance?.net==null?null:Number(balance.net)/100;
      const patch:any={
        status:'processing',
        stripe_checkout_session_id:session?.id||null,
        stripe_payment_intent_id:paymentIntentId||null,
        stripe_charge_id:charge?.id?String(charge.id):null,
        stripe_event_id:event.id,
        gross_amount:grossAmount>0?grossAmount:undefined,
        stripe_fee_amount:stripeFee,
        net_amount:netAmount,
        payment_date:new Date(Number(event.created||Date.now()/1000)*1000).toISOString(),
        updated_at:new Date().toISOString()
      };
      Object.keys(patch).forEach(k=>patch[k]===undefined&&delete patch[k]);
      const {error:updateError}=await db.from('invoice_payment_transactions').update(patch).eq('id',transactionId);
      if(updateError)throw updateError;
      const {error:recordError}=await db.rpc('v6181_record_online_invoice_payment',{
        p_transaction_id:transactionId,
        p_payment_date:new Date(Number(event.created||Date.now()/1000)*1000).toISOString().slice(0,10),
        p_reference:`Stripe Checkout ${String(session?.id||paymentIntentId||'payment')}`
      });
      if(recordError)throw recordError;
      await sendOnlineReceipt(transactionId);
      return true;
    };

    const settleOnlinePaymentIntent=async(intent:any,success:boolean)=>{
      const accountId=String((event as any).account||'');
      const transactionId=String(intent?.metadata?.payment_transaction_id||'');
      if(!accountId||!transactionId)return false;
      if(!success){
        const {error}=await db.from('invoice_payment_transactions').update({status:'failed',failure_reason:'Stripe reported that the payment intent failed.',stripe_payment_intent_id:intent?.id||null,stripe_event_id:event.id,updated_at:new Date().toISOString()}).eq('id',transactionId).neq('status','succeeded');
        if(error)throw error;
        return true;
      }
      const sessionLike={id:null,payment_intent:intent?.id,amount_total:intent?.amount_received||intent?.amount,metadata:intent?.metadata};
      return settleOnlineCheckout(sessionLike,true);
    };

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
      if(cs.metadata?.payment_transaction_id&&cs.payment_status!=='paid'){
        const {error}=await db.from('invoice_payment_transactions').update({status:'processing',stripe_checkout_session_id:cs.id,stripe_payment_intent_id:cs.payment_intent?String(cs.payment_intent):null,stripe_event_id:event.id,updated_at:new Date().toISOString()}).eq('id',String(cs.metadata.payment_transaction_id)).neq('status','succeeded');
        if(error)throw error;
        return new Response('ok');
      }
      if(await settleOnlineCheckout(cs,true)) return new Response('ok');
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

    if(event.type==='checkout.session.async_payment_succeeded'){
      const cs=event.data.object as Stripe.Checkout.Session;
      if(await settleOnlineCheckout(cs,true)) return new Response('ok');
    }

    if(event.type==='checkout.session.async_payment_failed'){
      const cs=event.data.object as Stripe.Checkout.Session;
      if(await settleOnlineCheckout(cs,false)) return new Response('ok');
    }

    if(event.type==='payment_intent.succeeded'){
      const intent=event.data.object as Stripe.PaymentIntent;
      if(await settleOnlinePaymentIntent(intent,true)) return new Response('ok');
    }

    if(event.type==='payment_intent.payment_failed'){
      const intent=event.data.object as Stripe.PaymentIntent;
      if(await settleOnlinePaymentIntent(intent,false)) return new Response('ok');
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
