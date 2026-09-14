import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getStripeConfig } from "../_shared/payment-config.ts";

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
  try{
    const url=Deno.env.get('SUPABASE_URL')!;
    const anon=Deno.env.get('SUPABASE_ANON_KEY')!;
    const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth=req.headers.get('Authorization')||'';
    const client=createClient(url,anon,{global:{headers:{Authorization:auth}}});
    const admin=createClient(url,service);
    const {secretKey:stripe}=await getStripeConfig(admin,true);

    const {data:{user}}=await client.auth.getUser();
    if(!user)return out({error:'Not authenticated'},401);

    const {data:businessId,error:businessError}=await client.rpc('current_business_id');
    if(businessError||!businessId)return out({error:'No active business context found'},403);

    const {data:profile}=await client.from('profiles').select('email').eq('id',user.id).single();
    const {planSlug,returnUrl}=await req.json();
    const safeReturnUrl=validateReturnUrl(returnUrl,req);

    const {data:plan}=await client.from('plans').select('*').eq('slug',planSlug).eq('is_public',true).single();
    if(!plan?.stripe_price_id)return out({error:'This plan does not have a Stripe Price ID yet. Add one in Super Admin → Subscription plans.'},400);

    const {data:sub}=await client.from('subscriptions').select('*').eq('business_id',businessId).single();
    let customer=sub?.stripe_customer_id;

    if(!customer){
      const form=new URLSearchParams();
      form.set('email',user.email||profile?.email||'');
      form.set('metadata[business_id]',businessId);
      const cr=await fetch('https://api.stripe.com/v1/customers',{
        method:'POST',
        headers:{
          Authorization:`Bearer ${stripe}`,
          'Content-Type':'application/x-www-form-urlencoded',
          'Idempotency-Key':`finlo-customer-${businessId}`
        },
        body:form
      });
      const cd=await cr.json();
      if(!cr.ok)throw new Error(cd?.error?.message||'Unable to create Stripe customer');
      customer=cd.id;
      await admin.from('subscriptions').update({stripe_customer_id:customer}).eq('business_id',businessId);
    }

    const f=new URLSearchParams();
    f.set('mode','subscription');
    f.set('customer',customer);
    f.set('line_items[0][price]',plan.stripe_price_id);
    f.set('line_items[0][quantity]','1');
    f.set('success_url',`${safeReturnUrl}${safeReturnUrl.includes('?')?'&':'?'}billing=success`);
    f.set('cancel_url',`${safeReturnUrl}${safeReturnUrl.includes('?')?'&':'?'}billing=cancel`);
    f.set('client_reference_id',businessId);
    f.set('metadata[business_id]',businessId);
    f.set('metadata[plan_id]',plan.id);
    f.set('subscription_data[metadata][business_id]',businessId);
    f.set('subscription_data[metadata][plan_id]',plan.id);

    const r=await fetch('https://api.stripe.com/v1/checkout/sessions',{
      method:'POST',
      headers:{Authorization:`Bearer ${stripe}`,'Content-Type':'application/x-www-form-urlencoded'},
      body:f
    });
    const d=await r.json();
    if(!r.ok)throw new Error(d?.error?.message||'Unable to open checkout');
    return out({url:d.url});
  }catch(e){
    return out({error:e instanceof Error?e.message:'Checkout failed'},400);
  }
});
