import Stripe from 'npm:stripe@22.4.0';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getStripeConfig, stripeHeaders, STRIPE_API_VERSION } from '../_shared/payment-config.ts';
import { subscriptionPlanPatch, subscriptionCancellationPatch } from '../_shared/subscription-billing.ts';
import { platformFrom, validReplyTo, recordEmailActivity } from '../_shared/email-sender.ts';

function subscriptionBillingPeriod(subscription:any){
  // Frindly Checkout creates one recurring plan item. New Stripe versions keep
  // its billing dates on that item; older event snapshots used the subscription.
  const item=subscription?.items?.data?.[0];
  const start=subscription?.current_period_start??item?.current_period_start;
  const end=subscription?.current_period_end??item?.current_period_end;
  const startDate=new Date(start*1000),endDate=new Date(end*1000);
  if(!Number.isFinite(start)||!Number.isFinite(end)||end<start||
    !Number.isFinite(startDate.getTime())||!Number.isFinite(endDate.getTime())){
    throw new Error('Stripe subscription billing period is missing or invalid.');
  }
  return {current_period_start:startDate.toISOString(),current_period_end:endDate.toISOString()};
}

function stripeEventDate(created:any){
  const date=new Date(Number(created||Date.now()/1000)*1000);
  return new Intl.DateTimeFormat('en-CA',{
    timeZone:'Pacific/Auckland',
    year:'numeric',
    month:'2-digit',
    day:'2-digit'
  }).format(date);
}

function stripeEventIso(created:any){
  return new Date(Number(created||Date.now()/1000)*1000).toISOString();
}

Deno.serve(async(req)=>{
  const url=Deno.env.get('SUPABASE_URL');
  const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!url||!service) return new Response('Missing Supabase configuration',{status:500});

  const db=createClient(url,service);
  let cfg;
  try{cfg=await getStripeConfig(db,false)}catch(e){return new Response(e instanceof Error?e.message:'Missing Stripe configuration',{status:500})}

  const secret=cfg.secretKey;
  const webhookSecrets=String(cfg.webhookSecret||'').split(',').map((s)=>s.trim()).filter(Boolean);
  if(!webhookSecrets.length) return new Response('Stripe webhook signing secret is not configured in Super Admin → Payment gateway settings.',{status:500});

  const stripe=new Stripe(secret,{apiVersion:STRIPE_API_VERSION});
  const sig=req.headers.get('stripe-signature');
  if(!sig) return new Response('Missing signature',{status:400});

  let event:Stripe.Event|null=null;
  const body=await req.text();
  let signatureError='';
  for(const wh of webhookSecrets){
    try{
      event=await stripe.webhooks.constructEventAsync(body,sig,wh);
      break;
    }catch(e){
      signatureError=e instanceof Error?e.message:'invalid';
    }
  }
  if(!event){
    return new Response(`Webhook signature error: ${signatureError||'invalid'}`,{status:400});
  }
  const auditEvent=async(status:'completed'|'failed',message?:string)=>{
    await db.rpc('v61111_finish_stripe_webhook_event',{
      p_event_id:event!.id,
      p_status:status,
      p_error_message:message||null
    });
  };
  const ok=async()=>{await auditEvent('completed');return new Response('ok')};
  const {data:eventAudit,error:eventAuditError}=await db.rpc('v61111_begin_stripe_webhook_event',{
    p_event_id:event.id,
    p_event_type:event.type,
    p_stripe_account_id:String((event as any).account||'')
  });
  if(eventAuditError)return new Response(eventAuditError.message,{status:500});
  if(eventAudit?.process===false)return new Response('ok');

  const referralEvent=async(bid:string|undefined,eventName:string)=>{
    if(!bid)return;
    const {error}=await db.rpc('v6151_process_referral_event',{p_business_id:bid,p_event:eventName});
    if(error) throw new Error(`Referral event ${eventName} failed: ${error.message}`);
  };

  const invoiceSubscriptionId=(invoice:Stripe.Invoice)=>{
    const related=(invoice as any).parent?.subscription_details?.subscription||(invoice as any).subscription;
    return typeof related==='string'?related:String(related?.id||'');
  };
  const recordRefereeDiscount=async(bid:string,referralId:string|undefined,couponId:string|undefined)=>{
    if(!bid||!referralId||!couponId)return;
    const {data,error}=await db.from('referrals')
      .update({referee_checkout_coupon_id:couponId})
      .eq('id',referralId).eq('referred_business_id',bid)
      .is('referee_checkout_coupon_id',null).select('id');
    if(error)throw error;
    // On retries the existing coupon is already recorded; only a missing
    // referral signals a mismatch that would otherwise award twice.
    if(!data?.length){
      const {data:existing,error:lookupError}=await db.from('referrals')
        .select('referee_checkout_coupon_id').eq('id',referralId)
        .eq('referred_business_id',bid).maybeSingle();
      if(lookupError||existing?.referee_checkout_coupon_id!==couponId)
        throw new Error('Referral coupon could not be matched to the business.');
    }
  };

  const resolveBusiness=async(invoice:Stripe.Invoice)=>{
    const subscriptionId=invoiceSubscriptionId(invoice);
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
      const {data:s}=await db.from('subscriptions').select('business_id').eq('stripe_customer_id',customerId).limit(1).maybeSingle();
      if(s?.business_id) return String(s.business_id);
    }
    return '';
  };

  const applyFinloCredit=async(invoice:Stripe.Invoice)=>{
    // Credits belong to the subscriber's Billing invoice, never an unrelated
    // invoice that happens to share the same Stripe customer.
    if(!invoiceSubscriptionId(invoice))return;
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

    if(reserveError)throw new Error(`Finlo credit reservation failed for ${invoiceId}: ${reserveError.message}`);

    const amount=Number(reservation?.amount||0);
    const applicationId=String(reservation?.applicationId||'');
    if(reservation?.alreadyCredited||amount<=0||!applicationId)return;

    try{
      const form=new URLSearchParams();
      form.set('amount',String(-Math.round(amount*100)));
      form.set('currency',currency.toLowerCase());
      form.set('description','Frindly credit applied to subscription');
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
    const connectedAccountId=String((event as any).account||'');
    const connectedInvoiceEvent=connectedAccountId&&[
      'checkout.session.completed',
      'checkout.session.expired',
      'checkout.session.async_payment_succeeded',
      'checkout.session.async_payment_failed',
      'payment_intent.succeeded',
      'payment_intent.payment_failed',
      'payment_intent.canceled',
      'charge.refunded',
      'charge.dispute.created',
      'charge.dispute.closed'
    ].includes(event.type)&&(
      !!(event.data.object as any)?.metadata?.payment_transaction_id||
      !!(event.data.object as any)?.payment_intent||
      !!(event.data.object as any)?.id
    );

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
      const {data:tx,error:txError}=await db.from('invoice_payment_transactions').select('id,business_id,invoice_id,amount,gross_amount,customer_fee_amount,currency,status,payment_date,stripe_payment_intent_id,stripe_checkout_session_id,metadata,invoices(invoice_number,customer_name,customer_email,total,balance_due),businesses(name,settings)').eq('id',transactionId).maybeSingle();
      if(txError||!tx||tx.status!=='succeeded'||tx.metadata?.receipt_sent_at||!tx.invoices?.customer_email)return;
      const settings=tx.businesses?.settings||{},invoice=tx.invoices||{},currency=String(tx.currency||settings.currency||'NZD').toUpperCase();

      const businessName=String(settings.trading||settings.company||tx.businesses?.name||'Your Business');
      const esc=(value:any)=>String(value??'').replace(/[&<>"']/g,(m)=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]||m));
      const money=(value:any)=>{try{return new Intl.NumberFormat('en-NZ',{style:'currency',currency}).format(Number(value||0))}catch{return `${currency} ${Number(value||0).toFixed(2)}`}};
      const invoiceNumber=String(invoice.invoice_number||'Invoice');
      const subject=`Payment received for ${invoiceNumber} · ${businessName}`;
      const html=`<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a"><h2>Payment received</h2><p>Hi ${esc(invoice.customer_name||'Customer')},</p><p>${esc(businessName)} has received your payment for invoice <strong>${esc(invoiceNumber)}</strong>.</p><table cellpadding="6" cellspacing="0"><tr><td>Invoice payment</td><td><strong>${money(tx.amount)}</strong></td></tr>${Number(tx.customer_fee_amount||0)>0?`<tr><td>Payment processing fee</td><td>${money(tx.customer_fee_amount)}</td></tr>`:''}<tr><td>Total charged</td><td><strong>${money(tx.gross_amount)}</strong></td></tr><tr><td>Remaining invoice balance</td><td>${money(invoice.balance_due)}</td></tr></table><p>Reference: ${esc(tx.stripe_payment_intent_id||tx.stripe_checkout_session_id||'Stripe payment')}</p><p>Thank you,<br>${esc(businessName)}</p></div>`;
      try{
      const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resendKey}`,'Content-Type':'application/json','Idempotency-Key':`invoice-payment-receipt-${transactionId}`},body:JSON.stringify({from:platformFrom(businessName),to:[invoice.customer_email],reply_to:validReplyTo(settings.outboundEmail||settings.email),subject,html})});
      if(!response.ok)throw new Error(`Resend HTTP ${response.status}: ${(await response.text()).slice(0,300)}`);
      const sent=await response.json();
      await db.from('invoice_payment_transactions').update({
        metadata:{...(tx.metadata||{}),receipt_sent_at:new Date().toISOString(),receipt_resend_message_id:String(sent?.id||'')},
        updated_at:new Date().toISOString()
      }).eq('id',transactionId).is('metadata->>receipt_sent_at',null);
      const {error:activityError}=await recordEmailActivity(db,{business_id:tx.business_id,message_type:'payment_receipt',source_table:'invoices',source_id:tx.invoice_id,recipient:invoice.customer_email,subject,provider_message_id:String(sent?.id||''),sent_by:null,metadata:{invoice_number:invoiceNumber,transaction_id:transactionId}});
      if(activityError)console.warn('Receipt email activity could not be recorded',activityError);
      }catch(e){
        // Never automatically release a claimed receipt after a provider request.
        // An expired claim is quarantined for manual Resend reconciliation.
        console.warn('Invoice receipt delivery requires reconciliation',transactionId,e);
      }
    };

    const ownerAdminEmails=async(businessId:string)=>{
      const emails=new Set<string>();
      const {data:members,error:membersError}=await db.from('business_memberships')
        .select('user_id,role,status')
        .eq('business_id',businessId)
        .in('role',['owner','admin'])
        .in('status',['active','accepted']);
      if(membersError)console.warn('Payment alert membership lookup failed',businessId,membersError.message);
      const ids=(members||[]).map((m:any)=>String(m.user_id||'')).filter(Boolean);
      if(ids.length){
        const {data:profiles,error:profilesError}=await db.from('profiles').select('id,email').in('id',ids);
        if(profilesError)console.warn('Payment alert profile lookup failed',businessId,profilesError.message);
        for(const profile of profiles||[]){
          const email=String((profile as any).email||'').trim();
          if(email.includes('@'))emails.add(email);
        }
      }
      const {data:business}=await db.from('businesses').select('settings').eq('id',businessId).maybeSingle();
      const settings=business?.settings||{};
      for(const fallback of [settings.outboundEmail,settings.email,settings.ownerEmail]){
        const email=String(fallback||'').trim();
        if(email.includes('@'))emails.add(email);
      }
      return [...emails].slice(0,5);
    };

    const sendPaymentExceptionAlert=async(transactionId:string,kind:string,details:string)=>{
      const resendKey=Deno.env.get('RESEND_API_KEY');
      if(!resendKey)return;
      const {data:tx,error:txError}=await db.from('invoice_payment_transactions')
        .select('id,business_id,invoice_id,amount,gross_amount,currency,status,failure_reason,metadata,stripe_payment_intent_id,stripe_checkout_session_id,invoices(invoice_number,customer_name,customer_email,total,balance_due),businesses(name,settings)')
        .eq('id',transactionId).maybeSingle();
      if(txError||!tx)return;
      const recipients=await ownerAdminEmails(String(tx.business_id));
      if(!recipients.length)return;
      const settings=tx.businesses?.settings||{},invoice=tx.invoices||{};
      const businessName=String(settings.trading||settings.company||tx.businesses?.name||'Frindly business');
      const currency=String(tx.currency||settings.currency||'NZD').toUpperCase();
      const esc=(value:any)=>String(value??'').replace(/[&<>"']/g,(m)=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]||m));
      const money=(value:any)=>{try{return new Intl.NumberFormat('en-NZ',{style:'currency',currency}).format(Number(value||0))}catch{return `${currency} ${Number(value||0).toFixed(2)}`}};
      const invoiceNumber=String(invoice.invoice_number||'Invoice');
      const subject=`Frindly payment ${kind}: ${invoiceNumber}`;
      const html=`<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a"><h2>Payment ${esc(kind)}</h2><p>A Stripe invoice payment needs attention in Frindly.</p><table cellpadding="6" cellspacing="0"><tr><td>Business</td><td><strong>${esc(businessName)}</strong></td></tr><tr><td>Invoice</td><td>${esc(invoiceNumber)}</td></tr><tr><td>Customer</td><td>${esc(invoice.customer_name||invoice.customer_email||'Customer')}</td></tr><tr><td>Invoice payment</td><td>${money(tx.amount)}</td></tr><tr><td>Total charged</td><td>${money(tx.gross_amount||tx.amount)}</td></tr><tr><td>Status</td><td>${esc(tx.status)}</td></tr><tr><td>Reason</td><td>${esc(details||tx.failure_reason||'Review required')}</td></tr></table><p>Stripe reference: ${esc(tx.stripe_payment_intent_id||tx.stripe_checkout_session_id||'Stripe payment')}</p></div>`;
      try{
        const response=await fetch('https://api.resend.com/emails',{
          method:'POST',
          headers:{Authorization:`Bearer ${resendKey}`,'Content-Type':'application/json','Idempotency-Key':`invoice-payment-alert-${transactionId}-${kind}-${event.id}`},
          body:JSON.stringify({from:platformFrom('Frindly'),to:recipients,reply_to:validReplyTo(settings.outboundEmail||settings.email),subject,html})
        });
        if(!response.ok)throw new Error(`Resend HTTP ${response.status}: ${(await response.text()).slice(0,300)}`);
        await db.from('invoice_payment_transactions').update({
          metadata:{...(tx.metadata||{}),last_payment_alert_at:new Date().toISOString(),last_payment_alert_kind:kind,last_payment_alert_event_id:event.id},
          updated_at:new Date().toISOString()
        }).eq('id',transactionId);
      }catch(e){
        console.warn('Payment exception alert failed',transactionId,e);
      }
    };

    // Validate the Stripe object against the transaction created by Frindly.
    const verifiedInvoiceTransaction=async(session:any,accountId:string,transactionId:string)=>{
      const {data:tx,error}=await db.from('invoice_payment_transactions')
        .select('id,stripe_account_id,stripe_checkout_session_id,stripe_payment_intent_id,gross_amount,currency,status,customer_payment_id')
        .eq('id',transactionId).maybeSingle();
      if(error)throw error;
      if(!tx)throw new Error('Stripe payment transaction does not exist.');
      const sessionId=String(session?.id||'');
      const intentId=String(session?.payment_intent||'');
      if(!accountId||String(tx.stripe_account_id||'')!==accountId)throw new Error('Stripe connected account mismatch.');
      if(sessionId&&tx.stripe_checkout_session_id&&tx.stripe_checkout_session_id!==sessionId)throw new Error('Stripe Checkout session mismatch.');
      if(intentId&&tx.stripe_payment_intent_id&&tx.stripe_payment_intent_id!==intentId)throw new Error('Stripe payment intent mismatch.');
      const amount=Number(session?.amount_total);
      if(!Number.isSafeInteger(amount)||amount<=0||amount!==Math.round(Number(tx.gross_amount)*100))throw new Error('Stripe payment amount mismatch.');
      if(String(session?.currency||'').toLowerCase()!==String(tx.currency||'').toLowerCase())throw new Error('Stripe payment currency mismatch.');
      return tx;
    };
    const invoiceTransactionForStripeObject=async(obj:any,accountId:string)=>{
      if(!accountId)return null;
      const metadataId=String(obj?.metadata?.payment_transaction_id||'');
      const paymentIntentId=String(obj?.payment_intent||obj?.id||'');
      const chargeId=String(obj?.charge||obj?.latest_charge?.id||obj?.id||'');
      let query=db.from('invoice_payment_transactions')
        .select('id,status,amount,gross_amount,customer_fee_amount,stripe_account_id,stripe_checkout_session_id,stripe_payment_intent_id,stripe_charge_id,metadata,customer_payment_id')
        .eq('stripe_account_id',accountId)
        .limit(1);
      if(metadataId)query=query.eq('id',metadataId);
      else if(String(obj?.object||'')==='charge'||String(obj?.object||'')==='dispute')query=query.or(`stripe_charge_id.eq.${chargeId},stripe_payment_intent_id.eq.${paymentIntentId}`);
      else if(paymentIntentId)query=query.eq('stripe_payment_intent_id',paymentIntentId);
      else return null;
      const {data,error}=await query.maybeSingle();
      if(error)throw error;
      return data||null;
    };
    const markExpiredCheckout=async(session:any)=>{
      const accountId=String((event as any).account||'');
      const transactionId=String(session?.metadata?.payment_transaction_id||'');
      if(!accountId||!transactionId)return false;
      await verifiedInvoiceTransaction({
        id:session?.id,
        payment_intent:session?.payment_intent,
        amount_total:session?.amount_total,
        currency:session?.currency,
        metadata:session?.metadata
      },accountId,transactionId);
      const {error}=await db.from('invoice_payment_transactions').update({
        status:'failed',
        failure_reason:'Stripe Checkout expired before the customer completed payment.',
        stripe_checkout_session_id:session?.id||null,
        stripe_event_id:event.id,
        updated_at:new Date().toISOString()
      }).eq('id',transactionId).in('status',['pending','processing']);
      if(error)throw error;
      return true;
    };
    const markRefundOrDispute=async(obj:any,kind:'refund'|'dispute'|'dispute_closed')=>{
      const accountId=String((event as any).account||'');
      const tx=await invoiceTransactionForStripeObject(obj,accountId);
      if(!tx)return false;
      if(kind==='refund'){
        const refunded=Number(obj?.amount_refunded||0);
        const gross=Number(obj?.amount||Math.round(Number(tx.gross_amount||0)*100));
        const full=refunded>0&&gross>0&&refunded>=gross;
        const meta={...(tx.metadata||{}),stripe_refund_event_id:event.id,stripe_refunded_amount:refunded/100,stripe_refund_seen_at:new Date().toISOString()};
        const {error}=await db.from('invoice_payment_transactions').update({
          status:full?'refunded':'partially_refunded',
          failure_reason:full?'Stripe reported this payment was refunded. Review the invoice/payment accounting before relying on the balance.':'Stripe reported a partial refund. Review the invoice/payment accounting before relying on the balance.',
          stripe_charge_id:String(obj?.id||tx.stripe_charge_id||'')||null,
          stripe_event_id:event.id,
          metadata:meta,
          updated_at:new Date().toISOString()
        }).eq('id',tx.id).neq('status','disputed');
        if(error)throw error;
        const refundAmount=refunded>0?refunded/100:0;
        if(refundAmount>0){
          const {error:refundError}=await db.rpc('v61108_record_stripe_refund_accounting',{
            p_transaction_id:tx.id,
            p_refund_amount:refundAmount,
            p_refund_date:stripeEventDate(event.created),
            p_reference:`Stripe refund ${String(obj?.id||tx.stripe_charge_id||'')}`
          });
          if(refundError){
            await db.from('invoice_payment_transactions').update({
              status:'needs_review',
              failure_reason:`Stripe refund received but Frindly could not record refund accounting automatically: ${refundError.message}`,
              stripe_event_id:event.id,
              updated_at:new Date().toISOString()
            }).eq('id',tx.id).neq('status','succeeded');
            await sendPaymentExceptionAlert(tx.id,'needs review',`Stripe refund accounting failed: ${refundError.message}`);
            return true;
          }
        }
        await sendPaymentExceptionAlert(tx.id,full?'refunded':'partially refunded',full?'Stripe reported this payment was refunded.':'Stripe reported this payment was partially refunded.');
        return true;
      }
      const disputeStatus=String(obj?.status||'');
      const won=['won','warning_closed'].includes(disputeStatus);
      const meta={...(tx.metadata||{}),stripe_dispute_event_id:event.id,stripe_dispute_id:String(obj?.id||''),stripe_dispute_status:disputeStatus,stripe_dispute_seen_at:new Date().toISOString()};
      const {error}=await db.from('invoice_payment_transactions').update({
        status:won&&tx.customer_payment_id?'succeeded':'disputed',
        failure_reason:won?'Stripe dispute closed in the business favour.':'Stripe reported a dispute/chargeback. Review this payment and invoice accounting.',
        stripe_event_id:event.id,
        metadata:meta,
        updated_at:new Date().toISOString()
      }).eq('id',tx.id);
      if(error)throw error;
      await sendPaymentExceptionAlert(tx.id,won?'dispute closed':'disputed',won?'Stripe dispute closed in the business favour.':'Stripe reported a dispute/chargeback. Review this payment and invoice accounting.');
      return true;
    };
    const verifiedCommunityCampaign=async(session:any,campaignId:string)=>{
      if(String((event as any).account||''))throw new Error('Community ad payment must be on the platform account.');
      const {data:campaign,error}=await db.from('community_ad_campaigns')
        .select('id,stripe_checkout_session_id,stripe_payment_intent_id,price_charged,currency,payment_status,status')
        .eq('id',campaignId).maybeSingle();
      if(error)throw error;
      if(!campaign)throw new Error('Community ad campaign does not exist.');
      if(!session?.id||campaign.stripe_checkout_session_id!==String(session.id))throw new Error('Community ad Checkout session mismatch.');
      if(campaign.stripe_payment_intent_id&&session.payment_intent&&campaign.stripe_payment_intent_id!==String(session.payment_intent))throw new Error('Community ad payment intent mismatch.');
      if(!Number.isSafeInteger(Number(session.amount_total))||Number(session.amount_total)!==Math.round(Number(campaign.price_charged)*100))throw new Error('Community ad payment amount mismatch.');
      if(String(session.currency||'').toLowerCase()!==String(campaign.currency||'').toLowerCase())throw new Error('Community ad payment currency mismatch.');
      return campaign;
    };
    const settleOnlineCheckout=async(session:any,success:boolean)=>{
      const accountId=String((event as any).account||'');
      const transactionId=String(session?.metadata?.payment_transaction_id||'');
      if(!accountId||!transactionId)return false;
      const paymentIntentId=String(session?.payment_intent||'');
      const tx=await verifiedInvoiceTransaction(session,accountId,transactionId);
      if(!success){
        const {error}=await db.from('invoice_payment_transactions').update({status:'failed',failure_reason:'Stripe reported that the customer payment failed.',stripe_checkout_session_id:session?.id||null,stripe_payment_intent_id:paymentIntentId||null,stripe_event_id:event.id,updated_at:new Date().toISOString()}).eq('id',transactionId).neq('status','succeeded').neq('status','needs_review');
        if(error)throw error;
        return true;
      }

      // Replayed Stripe events must never downgrade or double-record an already
      // settled Frindly payment.
      if(tx.status==='succeeded'||tx.customer_payment_id){
        if(tx.status!=='succeeded'){
          const {error}=await db.from('invoice_payment_transactions').update({
            status:'succeeded',
            failure_reason:null,
            stripe_checkout_session_id:session?.id||tx.stripe_checkout_session_id||null,
            stripe_payment_intent_id:paymentIntentId||tx.stripe_payment_intent_id||null,
            stripe_event_id:event.id,
            updated_at:new Date().toISOString()
          }).eq('id',transactionId);
          if(error)throw error;
        }
        return true;
      }
      // Unrecorded payments flagged for manual review must not be automatically
      // settled by delayed Stripe events.
      if(tx.status==='needs_review')return true;
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
        payment_date:stripeEventIso(event.created),
        updated_at:new Date().toISOString()
      };
      Object.keys(patch).forEach(k=>patch[k]===undefined&&delete patch[k]);
      const {error:updateError}=await db.from('invoice_payment_transactions').update(patch).eq('id',transactionId).neq('status','succeeded');
      if(updateError)throw updateError;
      const {data:recordData,error:recordError}=await db.rpc('v6181_record_online_invoice_payment',{
        p_transaction_id:transactionId,
        p_payment_date:stripeEventDate(event.created),
        p_reference:`Stripe Checkout ${String(session?.id||paymentIntentId||'payment')}`
      });
      if(recordError){
        await db.from('invoice_payment_transactions').update({
          status:'needs_review',
          failure_reason:`Payment received but Frindly could not record it automatically: ${recordError.message}`,
          stripe_event_id:event.id,
          updated_at:new Date().toISOString()
        }).eq('id',transactionId).neq('status','succeeded');
        await sendPaymentExceptionAlert(transactionId,'needs review',`Payment received but Frindly could not record it automatically: ${recordError.message}`);
        return true;
      }
      if(recordData?.status==='needs_review'){
        const {data:reviewTx}=await db.from('invoice_payment_transactions').select('failure_reason').eq('id',transactionId).maybeSingle();
        await sendPaymentExceptionAlert(transactionId,'needs review',reviewTx?.failure_reason||'Payment received but requires manual review before it can be recorded.');
        return true;
      }
      await sendOnlineReceipt(transactionId);
      return true;
    };

    const settleCommunityAdCheckout=async(session:any,success:boolean)=>{
      const campaignId=String(session?.metadata?.community_ad_campaign_id||'');
      if(!campaignId)return false;
      const paymentIntentId=session?.payment_intent?String(session.payment_intent):'';
      const campaign=await verifiedCommunityCampaign(session,campaignId);
      if(campaign.payment_status==='paid')return true;
      const patch:any={
        stripe_checkout_session_id:session?.id||null,
        stripe_payment_intent_id:paymentIntentId||null,
        payment_status:success?'paid':'failed',
        status:success?'pending_review':'pending_payment',
        updated_at:new Date().toISOString()
      };
      const {error}=await db.from('community_ad_campaigns').update(patch).eq('id',campaignId).neq('payment_status','paid');
      if(error)throw error;
      return true;
    };

    const settleOnlinePaymentIntent=async(intent:any,success:boolean)=>{
      const accountId=String((event as any).account||'');
      const transactionId=String(intent?.metadata?.payment_transaction_id||'');
      if(!accountId||!transactionId)return false;
      const sessionLike={id:null,payment_intent:intent?.id,amount_total:intent?.amount_received||intent?.amount,currency:intent?.currency,metadata:intent?.metadata};
      if(!success){
        await verifiedInvoiceTransaction(sessionLike,accountId,transactionId);
        const {error}=await db.from('invoice_payment_transactions').update({status:'failed',failure_reason:'Stripe reported that the payment intent failed.',stripe_payment_intent_id:intent?.id||null,stripe_event_id:event.id,updated_at:new Date().toISOString()}).eq('id',transactionId).neq('status','succeeded').neq('status','needs_review');
        if(error)throw error;
        return true;
      }
      return settleOnlineCheckout(sessionLike,true);
    };

    // Connected-account events are for business invoice payments only. Platform
    // subscription/referral handlers below must not trust connected-account metadata.
    if(connectedAccountId&&!connectedInvoiceEvent)return await ok();

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
      if(cs.metadata?.community_ad_campaign_id){
        if(cs.payment_status==='paid' && await settleCommunityAdCheckout(cs,true)) return await ok();
        // Checkout completion alone is not proof of failure for delayed payment methods.
        await verifiedCommunityCampaign(cs,String(cs.metadata.community_ad_campaign_id));
        return await ok();
      }
      if(cs.metadata?.payment_transaction_id&&cs.payment_status!=='paid'){
        await verifiedInvoiceTransaction(cs,String((event as any).account||''),String(cs.metadata.payment_transaction_id));
        const {error}=await db.from('invoice_payment_transactions').update({status:'processing',stripe_checkout_session_id:cs.id,stripe_payment_intent_id:cs.payment_intent?String(cs.payment_intent):null,stripe_event_id:event.id,updated_at:new Date().toISOString()}).eq('id',String(cs.metadata.payment_transaction_id)).neq('status','succeeded').neq('status','needs_review');
        if(error)throw error;
        return await ok();
      }
      if(await settleOnlineCheckout(cs,true)) return await ok();
      const bid=cs.metadata?.business_id;
      const pid=cs.metadata?.plan_id;
      if(bid&&pid&&cs.subscription){
        const sub=await stripe.subscriptions.retrieve(String(cs.subscription));
        // Checkout is the only place the referee's free months are redeemed.
        // Persist that redemption before a later paid invoice issues rewards.
        await recordRefereeDiscount(bid,cs.metadata?.referral_id,cs.metadata?.referee_coupon_id);
        const {error:subscriptionError}=await db.from('subscriptions').update({
          plan_id:pid,
          status:'active',
          stripe_customer_id:String(cs.customer||''),
          stripe_subscription_id:sub.id,
          ...subscriptionBillingPeriod(sub),
          ...subscriptionCancellationPatch(sub),
          trial_ends_at:null,
          billing_interval:cs.metadata?.billing_interval==='annual'?'annual':'monthly',
          updated_at:new Date().toISOString()
        }).eq('business_id',bid);
        if(subscriptionError)throw subscriptionError;
        await referralEvent(bid,'subscription_activated');
      }
    }

    if(event.type==='checkout.session.expired'){
      const cs=event.data.object as Stripe.Checkout.Session;
      if(cs.metadata?.community_ad_campaign_id){
        const campaignId=String(cs.metadata.community_ad_campaign_id);
        await verifiedCommunityCampaign(cs,campaignId);
        const {error}=await db.from('community_ad_campaigns').update({
          payment_status:'failed',
          status:'pending_payment',
          updated_at:new Date().toISOString()
        }).eq('id',campaignId).neq('payment_status','paid');
        if(error)throw error;
        return await ok();
      }
      if(await markExpiredCheckout(cs))return await ok();
    }

    if(event.type==='checkout.session.async_payment_succeeded'){
      const cs=event.data.object as Stripe.Checkout.Session;
      if(await settleCommunityAdCheckout(cs,true)) return await ok();
      if(await settleOnlineCheckout(cs,true)) return await ok();
    }

    if(event.type==='checkout.session.async_payment_failed'){
      const cs=event.data.object as Stripe.Checkout.Session;
      if(await settleCommunityAdCheckout(cs,false)) return await ok();
      if(await settleOnlineCheckout(cs,false)) return await ok();
    }

    if(event.type==='payment_intent.succeeded'){
      const intent=event.data.object as Stripe.PaymentIntent;
      if(await settleOnlinePaymentIntent(intent,true)) return await ok();
    }

    if(event.type==='payment_intent.payment_failed'){
      const intent=event.data.object as Stripe.PaymentIntent;
      if(await settleOnlinePaymentIntent(intent,false)) return await ok();
    }

    if(event.type==='payment_intent.canceled'){
      const intent=event.data.object as Stripe.PaymentIntent;
      if(await settleOnlinePaymentIntent(intent,false)) return await ok();
    }

    if(event.type==='charge.refunded'){
      const charge=event.data.object as Stripe.Charge;
      if(await markRefundOrDispute(charge,'refund'))return await ok();
    }

    if(event.type==='charge.dispute.created'){
      const dispute=event.data.object as Stripe.Dispute;
      if(await markRefundOrDispute(dispute,'dispute'))return await ok();
    }

    if(event.type==='charge.dispute.closed'){
      const dispute=event.data.object as Stripe.Dispute;
      if(await markRefundOrDispute(dispute,'dispute_closed'))return await ok();
    }

    if(event.type==='customer.subscription.created'||event.type==='customer.subscription.updated'||event.type==='customer.subscription.deleted'){
      // Read current state so delayed cancellation events cannot undo Keep subscription.
      const snapshot=event.data.object as Stripe.Subscription;
      const sub=event.type==='customer.subscription.deleted'?snapshot:await stripe.subscriptions.retrieve(snapshot.id);
      const bid=sub.metadata?.business_id;
      if(bid){
        const {data:current,error:currentError}=await db.from('subscriptions').select('stripe_subscription_id,status').eq('business_id',bid).maybeSingle();
        if(currentError)throw currentError;
        // A deleted older subscription must not cancel its replacement.
        if(current?.stripe_subscription_id&&current.stripe_subscription_id!==sub.id&&
          (event.type==='customer.subscription.deleted'||current.status!=='canceled'))return await ok();
        const status=event.type==='customer.subscription.deleted'?'canceled':(sub.status==='active'?'active':sub.status==='past_due'?'past_due':sub.status==='trialing'?'trialing':'canceled');
        const patch:any={
          status,
          ...subscriptionBillingPeriod(sub),
          ...subscriptionCancellationPatch(sub),
          updated_at:new Date().toISOString()
        };
        // Portal changes update the Stripe price, not the original Checkout metadata.
        Object.assign(patch,await subscriptionPlanPatch(db,sub));
        patch.trial_ends_at=sub.trial_end?new Date(sub.trial_end*1000).toISOString():null;
        if(sub.customer)patch.stripe_customer_id=String(sub.customer);
        patch.stripe_subscription_id=sub.id;
        if(current?.status==='suspended')patch.status='suspended';
        const {error:subscriptionError}=await db.from('subscriptions').update(patch).eq('business_id',bid);
        if(subscriptionError)throw subscriptionError;
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
      const subscriptionId=invoiceSubscriptionId(invoice);
      // A fully discounted invoice is successful, but no first payment has been received.
      if(subscriptionId&&Number(invoice.amount_paid||0)>0){
        const {data:s}=await db.from('subscriptions').select('business_id').eq('stripe_subscription_id',subscriptionId).maybeSingle();
        let bid=s?.business_id;
        if(!bid){
          try{
            const sub=await stripe.subscriptions.retrieve(subscriptionId);
            bid=sub.metadata?.business_id;
          }catch{}
        }
        if(bid){
          const {data:pending,error:pendingError}=await db.from('referrals')
            .select('id').eq('referred_business_id',bid)
            .in('status',['signed_up','pending_qualification','qualified']).maybeSingle();
          if(pendingError)throw pendingError;
          if(pending){
            const billingSub=await stripe.subscriptions.retrieve(subscriptionId);
            await recordRefereeDiscount(bid,billingSub.metadata?.referral_id,billingSub.metadata?.referee_coupon_id);
          }
          await referralEvent(bid,'first_successful_payment');
        }
      }
    }

    return await ok();
  }catch(e){
    try{await auditEvent('failed',e instanceof Error?e.message:String(e))}catch{}
    return new Response(e instanceof Error?e.message:'Webhook failed',{status:500});
  }
});
