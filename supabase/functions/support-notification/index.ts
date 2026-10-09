import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { platformFrom, corsHeaders, clientIp, enforceRateLimit } from '../_shared/email-sender.ts';
const cors=corsHeaders();
const json=(v:unknown,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{...cors,'Content-Type':'application/json'}});
const esc=(s:string)=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]||c));
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 try{
  const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,resend=Deno.env.get('RESEND_API_KEY');
  if(!resend)return json({ok:true,email:false,reason:'Email provider is not configured.'});
  const auth=req.headers.get('Authorization')||'';
  const userDb=createClient(url,anon,{global:{headers:{Authorization:auth}}});
  const service=createClient(url,serviceKey,{auth:{persistSession:false}});
  const {data:{user}}=await userDb.auth.getUser(); if(!user)return json({error:'Unauthorized'},401);
  await enforceRateLimit(service,'support-notification:user',user.id||clientIp(req),40,3600);
  const body=await req.json(); const threadId=String(body.threadId||''),action=String(body.action||'customer_message');
  const {data:t,error}=await userDb.from('support_threads').select('id,business_id,created_by_user_id,subject,category,status,businesses(name)').eq('id',threadId).single();
  if(error||!t)return json({error:'Support conversation not found.'},404);
  const {data:last}=await service.from('support_messages').select('body,created_at,sender_role').eq('thread_id',threadId).order('created_at',{ascending:false}).limit(1).maybeSingle();
  const supportEmail=(Deno.env.get('SUPPORT_NOTIFICATION_EMAIL')||'notifications@frindly.co.nz').trim();
  let to=supportEmail,subject=`New Frindly support message — ${String(t.businesses?.name||'Customer')}`;
  if(action==='support_reply'){
    const {data:u}=await service.auth.admin.getUserById(t.created_by_user_id); to=u?.user?.email||''; subject=`Frindly Support replied — ${t.subject}`;
  }
  if(!to)return json({ok:true,email:false,reason:'No notification recipient.'});
  const html=`<div style="font-family:Arial,sans-serif;color:#20365a;line-height:1.55"><h2>${esc(subject)}</h2><p><strong>Conversation:</strong> ${esc(t.subject)}</p><p><strong>Category:</strong> ${esc(t.category)}</p><div style="padding:12px 14px;background:#f5f8fd;border-radius:10px">${esc(String(last?.body||'New support activity')).replace(/\n/g,'<br>')}</div><p style="font-size:12px;color:#71809a">Open Frindly and go to Help &amp; Support / Support Inbox to continue the conversation.</p></div>`;
  const rr=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json'},body:JSON.stringify({from:platformFrom('Frindly Support'),to:[to],subject,html})});
  const d=await rr.json(); if(!rr.ok)return json({ok:false,email:false,error:d?.message||'Email provider rejected notification.'},200);
  return json({ok:true,email:true,id:d.id});
 }catch(e){return json({error:e instanceof Error?e.message:'Support notification failed.'},(e as any)?.status||500)}
});
