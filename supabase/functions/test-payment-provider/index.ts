import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getStripeConfig } from "../_shared/payment-config.ts";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const out=(x:any,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 try{
  const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const auth=req.headers.get('Authorization')||'',client=createClient(url,anon,{global:{headers:{Authorization:auth}}}),admin=createClient(url,service);
  const {data:{user}}=await client.auth.getUser();if(!user)return out({error:'Not authenticated'},401);
  const {data:p}=await client.from('profiles').select('is_super_admin').eq('id',user.id).maybeSingle();if(p?.is_super_admin!==true)return out({error:'Super Admin access required'},403);
  const {provider}=await req.json();if(provider!=='stripe')return out({error:'Only the Stripe connection test is available in this version.'},400);
  const {secretKey}=await getStripeConfig(admin,false);
  const r=await fetch('https://api.stripe.com/v1/account',{headers:{Authorization:`Bearer ${secretKey}`}});const d=await r.json();if(!r.ok)return out({error:d?.error?.message||'Stripe rejected the API key.'},400);
  return out({ok:true,account_id:d.id,account_name:d.business_profile?.name||d.settings?.dashboard?.display_name||d.email||''});
 }catch(e){return out({error:e instanceof Error?e.message:'Connection test failed'},400)}
});
