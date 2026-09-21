import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getStripeConfig, randomIntegrationSuffix, stripeHeaders } from "../_shared/payment-config.ts";

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
    const {planSlug,billingInterval='monthly',returnUrl}=await req.json();
    const interval=billingInterval==='annual'?'annual':'monthly';
    const safeReturnUrl=validateReturnUrl(returnUrl,req);

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
    const {data:sub}=await client.from('subscriptions').select('*').eq('business_id',businessId).maybeSingle();
    let customer=sub?.stripe_customer_id;

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
