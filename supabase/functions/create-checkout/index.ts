import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const out=(x:any,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 try{
  const url=Deno.env.get('SUPABASE_URL')!, anon=Deno.env.get('SUPABASE_ANON_KEY')!, service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, stripe=Deno.env.get('STRIPE_SECRET_KEY');
  if(!stripe)throw new Error('STRIPE_SECRET_KEY is not configured.');
  const auth=req.headers.get('Authorization')||'',client=createClient(url,anon,{global:{headers:{Authorization:auth}}}),admin=createClient(url,service);
  const {data:{user}}=await client.auth.getUser();if(!user)return out({error:'Not authenticated'},401);
  const {data:profile}=await client.from('profiles').select('business_id,email').eq('id',user.id).single();if(!profile)return out({error:'Profile not found'},403);
  const {planSlug,returnUrl}=await req.json();const {data:plan}=await client.from('plans').select('*').eq('slug',planSlug).eq('is_public',true).single();if(!plan?.stripe_price_id)return out({error:'This plan does not have a Stripe Price ID yet.'},400);
  const {data:sub}=await client.from('subscriptions').select('*').eq('business_id',profile.business_id).single();let customer=sub?.stripe_customer_id;
  if(!customer){const form=new URLSearchParams();form.set('email',user.email||profile.email||'');form.set('metadata[business_id]',profile.business_id);const cr=await fetch('https://api.stripe.com/v1/customers',{method:'POST',headers:{Authorization:`Bearer ${stripe}`,'Content-Type':'application/x-www-form-urlencoded'},body:form});const cd=await cr.json();if(!cr.ok)throw new Error(cd?.error?.message||'Unable to create Stripe customer');customer=cd.id;await admin.from('subscriptions').update({stripe_customer_id:customer}).eq('business_id',profile.business_id)}
  const f=new URLSearchParams();f.set('mode','subscription');f.set('customer',customer);f.set('line_items[0][price]',plan.stripe_price_id);f.set('line_items[0][quantity]','1');f.set('success_url',`${returnUrl}?billing=success`);f.set('cancel_url',`${returnUrl}?billing=cancel`);f.set('client_reference_id',profile.business_id);f.set('metadata[business_id]',profile.business_id);f.set('metadata[plan_id]',plan.id);f.set('subscription_data[metadata][business_id]',profile.business_id);f.set('subscription_data[metadata][plan_id]',plan.id);
  const r=await fetch('https://api.stripe.com/v1/checkout/sessions',{method:'POST',headers:{Authorization:`Bearer ${stripe}`,'Content-Type':'application/x-www-form-urlencoded'},body:f});const d=await r.json();if(!r.ok)throw new Error(d?.error?.message||'Unable to open checkout');return out({url:d.url});
 }catch(e){return out({error:e instanceof Error?e.message:'Checkout failed'},400)}
});
