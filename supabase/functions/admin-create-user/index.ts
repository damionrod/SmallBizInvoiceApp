import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(x:any,status=200)=>new Response(JSON.stringify(x),{status,headers:{...cors,"Content-Type":"application/json"}});

Deno.serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  try{
    const url=Deno.env.get('SUPABASE_URL')!;
    const anon=Deno.env.get('SUPABASE_ANON_KEY')!;
    const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth=req.headers.get('Authorization')||'';
    const caller=createClient(url,anon,{global:{headers:{Authorization:auth}}});
    const admin=createClient(url,service);
    const {data:{user}}=await caller.auth.getUser();
    if(!user)return reply({error:'Not authenticated'},401);
    const {data:profile}=await caller.from('profiles').select('is_super_admin').eq('id',user.id).single();
    if(!profile?.is_super_admin)return reply({error:'Super Admin access required'},403);

    const body=await req.json();
    const email=String(body.email||'').trim().toLowerCase();
    const password=String(body.password||'');
    const fullName=String(body.fullName||'').trim();
    const businessName=String(body.businessName||'').trim();
    const address=String(body.address||'').trim();
    const phone=String(body.phone||'').trim();
    const trialDays=Math.max(0,Math.min(365,Number(body.trialDays??14)||14));
    if(!email||!fullName||!businessName||password.length<8)return reply({error:'Name, business, email and a password of at least 8 characters are required.'},400);

    const {data:created,error}=await admin.auth.admin.createUser({
      email,password,email_confirm:true,
      user_metadata:{full_name:fullName,business_name:businessName,business_address:address,phone}
    });
    if(error)throw error;

    // handle_new_user creates the profile/business/subscription. Wait briefly for the trigger result.
    let businessId:string|undefined;
    for(let i=0;i<10;i++){
      const {data:p}=await admin.from('profiles').select('business_id').eq('id',created.user.id).maybeSingle();
      if(p?.business_id){businessId=p.business_id;break}
      await new Promise(r=>setTimeout(r,150));
    }
    if(!businessId)throw new Error('User was created but business provisioning did not complete. Check the v22 database trigger.');

    const now=new Date();const end=new Date(now.getTime()+trialDays*86400000);
    await admin.from('subscriptions').update({status:'trialing',trial_ends_at:end.toISOString(),current_period_start:now.toISOString(),current_period_end:end.toISOString(),updated_at:now.toISOString()}).eq('business_id',businessId);
    return reply({success:true,userId:created.user.id,businessId});
  }catch(e){return reply({error:e instanceof Error?e.message:'Unable to create user'},400)}
});
