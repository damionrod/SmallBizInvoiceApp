import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getStripeConfig } from "../_shared/payment-config.ts";

const cors={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS"
};
const out=(x:any,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,'Content-Type':'application/json'}});

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
    const admin=createClient(url,service);
    const {secretKey:stripe}=await getStripeConfig(admin,false);
    const client=createClient(url,anon,{global:{headers:{Authorization:req.headers.get('Authorization')||''}}});

    const {data:{user}}=await client.auth.getUser();
    if(!user)return out({error:'Not authenticated'},401);

    const {data:businessId,error:businessError}=await client.rpc('current_business_id');
    if(businessError||!businessId)return out({error:'No active business context found'},403);

    // Billing is server-authorised Owner-only. UI visibility is not a security boundary.
    const {data:billingRole,error:roleError}=await client.rpc('v6147_current_business_role',{p_business_id:businessId});
    if(roleError||billingRole!=='owner')return out({error:'Only the Business Owner can manage billing'},403);

    const {data:s}=await client.from('subscriptions').select('stripe_customer_id').eq('business_id',businessId).single();
    if(!s?.stripe_customer_id)return out({error:'No paid subscription found'},400);

    const {returnUrl}=await req.json();
    const safeReturnUrl=validateReturnUrl(returnUrl,req);
    const f=new URLSearchParams({customer:s.stripe_customer_id,return_url:safeReturnUrl});
    const r=await fetch('https://api.stripe.com/v1/billing_portal/sessions',{
      method:'POST',
      headers:{Authorization:`Bearer ${stripe}`,'Content-Type':'application/x-www-form-urlencoded'},
      body:f
    });
    const d=await r.json();
    if(!r.ok)throw new Error(d?.error?.message||'Unable to open billing portal');
    return out({url:d.url});
  }catch(e){
    return out({error:e instanceof Error?e.message:'Portal failed'},400);
  }
});
