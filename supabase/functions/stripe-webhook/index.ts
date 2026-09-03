import Stripe from 'npm:stripe@14.25.0';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
Deno.serve(async(req)=>{
 const secret=Deno.env.get('STRIPE_SECRET_KEY'),wh=Deno.env.get('STRIPE_WEBHOOK_SECRET'),url=Deno.env.get('SUPABASE_URL'),service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');if(!secret||!wh||!url||!service)return new Response('Missing configuration',{status:500});
 const stripe=new Stripe(secret,{apiVersion:'2023-10-16'});const sig=req.headers.get('stripe-signature');if(!sig)return new Response('Missing signature',{status:400});
 let event:Stripe.Event;try{event=await stripe.webhooks.constructEventAsync(await req.text(),sig,wh)}catch(e){return new Response(`Webhook signature error: ${e instanceof Error?e.message:'invalid'}`,{status:400})}
 const db=createClient(url,service);
 try{
  if(event.type==='checkout.session.completed'){
   const cs=event.data.object as Stripe.Checkout.Session,bid=cs.metadata?.business_id,pid=cs.metadata?.plan_id;if(bid&&pid&&cs.subscription){const sub=await stripe.subscriptions.retrieve(String(cs.subscription));await db.from('subscriptions').update({plan_id:pid,status:'active',stripe_customer_id:String(cs.customer||''),stripe_subscription_id:sub.id,current_period_start:new Date(sub.current_period_start*1000).toISOString(),current_period_end:new Date(sub.current_period_end*1000).toISOString(),trial_ends_at:null,updated_at:new Date().toISOString()}).eq('business_id',bid)}
  }
  if(event.type==='customer.subscription.updated'||event.type==='customer.subscription.deleted'){
   const sub=event.data.object as Stripe.Subscription,bid=sub.metadata?.business_id;if(bid){const status=event.type==='customer.subscription.deleted'?'canceled':(sub.status==='active'?'active':sub.status==='past_due'?'past_due':sub.status==='trialing'?'trialing':'canceled');await db.from('subscriptions').update({status,current_period_start:new Date(sub.current_period_start*1000).toISOString(),current_period_end:new Date(sub.current_period_end*1000).toISOString(),cancel_at_period_end:sub.cancel_at_period_end,updated_at:new Date().toISOString()}).eq('business_id',bid)}
  }
  return new Response('ok');
 }catch(e){return new Response(e instanceof Error?e.message:'Webhook failed',{status:500})}
});
