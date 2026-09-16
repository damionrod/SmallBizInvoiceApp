import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(x:any,status=200)=>new Response(JSON.stringify(x),{status,headers:{...cors,"Content-Type":"application/json"}});
const normEmail=(v:any)=>String(v||'').trim().toLowerCase();
const validRole=(r:string)=>['admin','accountant','bookkeeper','staff','viewer'].includes(r);
const esc=(s:any)=>String(s??'').replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]||m));
const roleLabel=(r:string)=>({admin:'Admin',accountant:'Accountant',bookkeeper:'Bookkeeper',staff:'Staff',viewer:'Viewer'} as any)[r]||r;
const bytesToToken=(bytes:Uint8Array)=>btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
async function hashToken(token:string){const d=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token));return Array.from(new Uint8Array(d)).map(b=>b.toString(16).padStart(2,'0')).join('')}
function makeToken(){const b=new Uint8Array(32);crypto.getRandomValues(b);return bytesToToken(b)}
function cleanBaseUrl(value:any,origin:string|null){for(const raw of [String(value||''),String(origin||'')]){try{const u=new URL(raw);if(u.protocol==='https:'||u.protocol==='http:'){u.search='';u.hash='';return u.toString()}}catch{}}return ''}

Deno.serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  try{
    const SUPABASE_URL=Deno.env.get('SUPABASE_URL')!;
    const ANON=Deno.env.get('SUPABASE_ANON_KEY')!;
    const SERVICE=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const RESEND=Deno.env.get('RESEND_API_KEY');
    const FROM=Deno.env.get('EMAIL_FROM_ADDRESS');
    const service=createClient(SUPABASE_URL,SERVICE,{auth:{persistSession:false,autoRefreshToken:false}});
    const body=await req.json().catch(()=>({}));
    const action=String(body.action||'').toLowerCase();
    const bearer=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'').trim();
    const getUser=async()=>{if(!bearer)return null;const {data}=await service.auth.getUser(bearer);return data.user||null};
    const manager=async(user:any,businessId:string)=>{
      if(!user)return null;
      const {data:p}=await service.from('profiles').select('is_super_admin').eq('id',user.id).maybeSingle();
      if(p?.is_super_admin)return {role:'owner',super:true};
      const {data:m}=await service.from('business_memberships').select('role,status').eq('user_id',user.id).eq('business_id',businessId).maybeSingle();
      return m?.status==='active'&&['owner','admin'].includes(m.role)?{role:m.role,super:false}:null;
    };
    const sendInvite=async(inv:any,token:string,redirectUrl:any)=>{
      if(!RESEND||!FROM)throw new Error('Invitation email is not configured. RESEND_API_KEY and EMAIL_FROM_ADDRESS are required.');
      const base=cleanBaseUrl(redirectUrl,req.headers.get('origin'));
      if(!base)throw new Error('Open Finlo from its deployed http/https address before sending invitations.');
      const u=new URL(base);u.searchParams.set('invite',token);
      const {data:b}=await service.from('businesses').select('name,settings').eq('id',inv.business_id).single();
      const businessName=b?.name||'A Finlo business';
      const fromEmail=String(b?.settings?.outboundEmail||FROM).trim();
      const html=`<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a"><h2 style="margin:0 0 12px">You're invited to Finlo</h2><p><strong>${esc(businessName)}</strong> has invited you to join their business account.</p><p><strong>Role:</strong> ${esc(roleLabel(inv.role))}</p><p><a href="${esc(u.toString())}" style="display:inline-block;padding:10px 16px;background:#2f8dbc;color:#fff;text-decoration:none;border-radius:4px">Accept Invitation</a></p><p style="color:#6b7780;font-size:13px">This invitation expires on ${esc(new Date(inv.expires_at).toLocaleString('en-NZ'))}.</p></div>`;
      const r=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${RESEND}`,'Content-Type':'application/json'},body:JSON.stringify({from:`Finlo <${fromEmail}>`,to:[inv.email],subject:`${businessName} invited you to Finlo`,html})});
      const data=await r.json();if(!r.ok)throw new Error(data?.message||'Email provider rejected the invitation.');return data?.id;
    };

    if(action==='inspect'){
      const token=String(body.token||'');if(!token)return json({error:'Invitation token is required.'},400);
      const hash=await hashToken(token);
      const {data:inv}=await service.from('business_invites').select('id,business_id,email,role,status,expires_at,businesses(name)').eq('token_hash',hash).maybeSingle();
      if(!inv||inv.status!=='pending'||new Date(inv.expires_at).getTime()<=Date.now())return json({error:'This invitation is invalid or has expired.'},404);
      return json({ok:true,email:inv.email,role:inv.role,businessName:(inv as any).businesses?.name||'Business',expiresAt:inv.expires_at});
    }

    const user=await getUser();
    if(!user)return json({error:'Not authenticated'},401);

    if(action==='create'){
      const businessId=String(body.businessId||''),email=normEmail(body.email),role=String(body.role||'').toLowerCase();
      const actor=await manager(user,businessId);if(!actor)return json({error:'Owner or Admin access required.'},403);
      if(!email||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))return json({error:'Enter a valid email address.'},400);
      if(!validRole(role))return json({error:'Invalid role.'},400);
      if(actor.role==='admin'&&role==='admin')return json({error:'Only an Owner can invite another Admin.'},403);
      const {data:existingUser}=await service.from('profiles').select('id').ilike('email',email).maybeSingle();
      if(existingUser){const {data:existingMembership}=await service.from('business_memberships').select('status').eq('business_id',businessId).eq('user_id',existingUser.id).maybeSingle();if(existingMembership&&existingMembership.status!=='removed')return json({error:'This user already has access to this business.'},409)}
      const {data:pending}=await service.from('business_invites').select('id').eq('business_id',businessId).ilike('email',email).eq('status','pending').maybeSingle();
      if(pending)return json({error:'A pending invitation already exists for this email. Use Resend instead.'},409);
      const token=makeToken(),tokenHash=await hashToken(token),expiresAt=new Date(Date.now()+7*86400000).toISOString();
      const {data:inv,error}=await service.from('business_invites').insert({business_id:businessId,email,role,token_hash:tokenHash,status:'pending',invited_by:user.id,expires_at:expiresAt,last_sent_at:new Date().toISOString()}).select('*').single();
      if(error)return json({error:error.message},400);
      try{await sendInvite(inv,token,body.redirectUrl)}catch(e){await service.from('business_invites').delete().eq('id',inv.id);throw e}
      return json({ok:true,id:inv.id,email:inv.email,role:inv.role,expiresAt:inv.expires_at});
    }

    if(action==='list'){
      const businessId=String(body.businessId||'');const actor=await manager(user,businessId);if(!actor)return json({error:'Owner or Admin access required.'},403);
      const {data,error}=await service.from('business_invites').select('id,email,role,status,expires_at,last_sent_at,created_at').eq('business_id',businessId).eq('status','pending').order('created_at',{ascending:false});
      if(error)return json({error:error.message},400);return json({ok:true,invites:data||[]});
    }

    if(action==='resend'||action==='revoke'){
      const businessId=String(body.businessId||''),inviteId=String(body.inviteId||'');const actor=await manager(user,businessId);if(!actor)return json({error:'Owner or Admin access required.'},403);
      const {data:inv}=await service.from('business_invites').select('*').eq('id',inviteId).eq('business_id',businessId).eq('status','pending').maybeSingle();
      if(!inv)return json({error:'Pending invitation not found.'},404);
      if(action==='revoke'){await service.from('business_invites').update({status:'revoked',updated_at:new Date().toISOString()}).eq('id',inviteId);return json({ok:true})}
      const token=makeToken(),tokenHash=await hashToken(token),expiresAt=new Date(Date.now()+7*86400000).toISOString();
      const updated={...inv,token_hash:tokenHash,expires_at:expiresAt,last_sent_at:new Date().toISOString(),updated_at:new Date().toISOString()};
      const {error}=await service.from('business_invites').update({token_hash:tokenHash,expires_at:expiresAt,last_sent_at:updated.last_sent_at,updated_at:updated.updated_at}).eq('id',inviteId);if(error)return json({error:error.message},400);
      await sendInvite(updated,token,body.redirectUrl);return json({ok:true});
    }

    if(action==='accept'){
      const token=String(body.token||'');if(!token)return json({error:'Invitation token is required.'},400);const hash=await hashToken(token);
      const {data:inv}=await service.from('business_invites').select('*').eq('token_hash',hash).maybeSingle();
      if(!inv)return json({error:'Invitation not found.'},404);
      if(normEmail(user.email)!==normEmail(inv.email))return json({error:'Please sign in with the email address that was invited.'},403);
      if(inv.status==='pending'&&new Date(inv.expires_at).getTime()<=Date.now()){await service.from('business_invites').update({status:'expired',updated_at:new Date().toISOString()}).eq('id',inv.id);return json({error:'This invitation has expired.'},410)}
      if(!['pending','accepted'].includes(inv.status))return json({error:'This invitation is no longer active.'},410);
      const {data:membership,error:mErr}=await service.from('business_memberships').upsert({business_id:inv.business_id,user_id:user.id,role:inv.role,status:'active',invited_by:inv.invited_by,joined_at:new Date().toISOString(),updated_at:new Date().toISOString()},{onConflict:'business_id,user_id'}).select('id').single();
      if(mErr)return json({error:mErr.message},400);
      await service.from('profiles').update({active_business_id:inv.business_id}).eq('id',user.id);
      if(inv.status==='pending')await service.from('business_invites').update({status:'accepted',accepted_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq('id',inv.id);
      return json({ok:true,businessId:inv.business_id,membershipId:membership.id});
    }

    if(action==='recover-current'){
      const userClient=createClient(SUPABASE_URL,ANON,{global:{headers:{Authorization:`Bearer ${bearer}`}},auth:{persistSession:false,autoRefreshToken:false}});
      const {data:resolved}=await userClient.rpc('current_business_id');if(resolved)return json({ok:true,businessId:resolved,recovered:false});
      const {data:next}=await service.from('business_memberships').select('business_id').eq('user_id',user.id).eq('status','active').order('joined_at',{ascending:true}).limit(1).maybeSingle();
      if(!next?.business_id)return json({ok:true,businessId:null,recovered:false});
      const {error}=await service.from('profiles').update({active_business_id:next.business_id,updated_at:new Date().toISOString()}).eq('id',user.id);if(error)return json({error:error.message},400);
      return json({ok:true,businessId:next.business_id,recovered:true});
    }

    if(action==='my-businesses'){
      const {data,error}=await service.from('business_memberships').select('business_id,role,status,businesses(id,name)').eq('user_id',user.id).eq('status','active');if(error)return json({error:error.message},400);
      // Never echo a stale profile business as current. Resolve through the same hardened backend function used by tenant RLS.
      const userClient=createClient(SUPABASE_URL,ANON,{global:{headers:{Authorization:`Bearer ${bearer}`}},auth:{persistSession:false,autoRefreshToken:false}});
      const {data:resolved,error:resolvedError}=await userClient.rpc('current_business_id');if(resolvedError)return json({error:resolvedError.message},400);
      return json({ok:true,currentBusinessId:resolved||null,businesses:(data||[]).map((x:any)=>({id:x.business_id,name:x.businesses?.name||'Business',role:x.role}))});
    }

    if(action==='switch'){
      const businessId=String(body.businessId||'');const {data:m}=await service.from('business_memberships').select('id').eq('user_id',user.id).eq('business_id',businessId).eq('status','active').maybeSingle();if(!m)return json({error:'You do not have active access to this business.'},403);
      const {error}=await service.from('profiles').update({active_business_id:businessId}).eq('id',user.id);if(error)return json({error:error.message},400);return json({ok:true,businessId});
    }

    return json({error:'Unknown action.'},400);
  }catch(e){return json({error:e instanceof Error?e.message:'Unknown invitation error'},400)}
});
