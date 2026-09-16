import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.98.0';
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type, x-finlo-monitor-secret','Access-Control-Allow-Methods':'POST, OPTIONS'};
const out=(x:any,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,'Content-Type':'application/json'}});
const hex=(b:ArrayBuffer)=>Array.from(new Uint8Array(b)).map(x=>x.toString(16).padStart(2,'0')).join('');
const sha=async(b:ArrayBuffer)=>hex(await crypto.subtle.digest('SHA-256',b));
const abs=(base:string,href:string)=>{try{return new URL(href,base).toString()}catch{return ''}};
function htmlDecode(v:string){return String(v||'').replace(/&amp;/gi,'&').replace(/&#38;/gi,'&').replace(/&quot;/gi,'\"').replace(/&#39;|&#x27;/gi,"'");}
function safeDecode(v:string){try{return decodeURIComponent(v)}catch{return v}}
function isIrd(url:string){try{const h=new URL(url).hostname.toLowerCase();return h==='ird.govt.nz'||h.endsWith('.ird.govt.nz')}catch{return false}}
function findSpec(html:string,base:string){
  const candidates:string[]=[];
  const add=(href:string)=>{const u=abs(base,htmlDecode(href));if(u&&isIrd(u)&&/\.pdf(?:[?#]|$)/i.test(safeDecode(u)))candidates.push(u)};
  for(const m of html.matchAll(/href\s*=\s*["']([^"']+)["']/gi))add(m[1]);
  for(const m of html.matchAll(/https?:\/\/[^\s"'<>]+\.pdf(?:\?[^\s"'<>]*)?/gi))add(m[0]);
  const ranked=[...new Set(candidates)].map(u=>{const x=safeDecode(u).toLowerCase();let score=0;if(x.includes('payroll-calculations-and-business-rules-specification'))score+=100;if(x.includes('payroll-calculations-business-rules-specifications'))score+=40;if(x.includes('payroll')&&x.includes('business')&&x.includes('rules'))score+=25;if(x.includes('/-/media/'))score+=10;return {u,score}}).sort((a,b)=>b.score-a.score);
  if(ranked[0]?.score>=25)return ranked[0].u;
  // IRD currently uses a stable canonical media path for this specification. Use it only as
  // a same-domain fallback when the official landing page still identifies the specification
  // but its markup no longer exposes a link in a form the parser can recognise.
  if(/Payroll\s+Calculations\s*(?:&|&amp;|and)\s*Business\s+Rules\s+Specification/i.test(html)){
    return 'https://www.ird.govt.nz/-/media/project/ir/home/documents/digital-service-providers/software-providers/payroll-calculations-business-rules-specifications/payroll-calculations-and-business-rules-specification.pdf';
  }
  return '';
}
function versionFrom(text:string,url:string){
  const m=text.match(/Version\s*[:\-]?\s*([0-9]+(?:\.[0-9]+)+)/i); if(m)return m[1];
  const d=text.match(/1\s+April\s+(\d{4})\s+to\s+31\s+March\s+(\d{4})/i); if(d)return `${d[1]}/${String(d[2]).slice(-2)}`;
  const q=new URL(url).searchParams.get('modified');return q?`modified-${q}`:null;
}
Deno.serve(async req=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  if(req.method!=='POST')return out({error:'Method not allowed'},405);
  const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  if(!url||!anon||!service)return out({error:'Server configuration incomplete'},500);
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const supplied=req.headers.get('x-finlo-monitor-secret')||'';
  const suppliedHash=supplied?await sha(new TextEncoder().encode(supplied).buffer):'';
  let actor:string|null=null,scheduled=false;
  if(suppliedHash==='a92ab7c4574a89ee6d46a8743ea2721197d60705643f9a0435169e5bee7cbcfa'){scheduled=true}else{
    const auth=req.headers.get('Authorization')||'';const client=createClient(url,anon,{global:{headers:{Authorization:auth}}});
    const {data:{user}}=await client.auth.getUser();if(!user)return out({error:'Not authenticated'},401);
    const {data:p}=await client.from('profiles').select('is_super_admin').eq('id',user.id).single();if(!p?.is_super_admin)return out({error:'Super Admin access required'},403);actor=user.id;
  }
  const body=await req.json().catch(()=>({}));const only=String(body?.source_id||'');
  let q=admin.from('payroll_compliance_sources').select('*').eq('active',true);if(only)q=q.eq('id',only);const {data:sources,error}=await q;if(error)return out({error:error.message},500);
  const results:any[]=[];
  for(const s of sources||[]){
    const checked=new Date().toISOString();
    try{
      const landing=await fetch(s.source_url,{headers:{'User-Agent':'Finlo-Payroll-Compliance-Monitor/1.0'}});if(!landing.ok)throw new Error(`Official source returned HTTP ${landing.status}`);
      const html=await landing.text();const spec=findSpec(html,s.source_url);if(!spec)throw new Error('Official payroll specification document link was not found');
      const doc=await fetch(spec,{headers:{'User-Agent':'Finlo-Payroll-Compliance-Monitor/1.0'}});if(!doc.ok)throw new Error(`Official specification returned HTTP ${doc.status}`);
      const bytes=await doc.arrayBuffer();const fp=await sha(bytes);const version=versionFrom(html,spec);const previous=s.last_known_fingerprint||null;const changed=!!previous&&previous!==fp;
      if(!previous){
        await admin.from('payroll_compliance_sources').update({last_checked_at:checked,last_successful_check_at:checked,last_known_fingerprint:fp,last_known_version:version,last_source_reference:spec,last_check_status:'no_change',last_error:null,updated_at:checked}).eq('id',s.id);
      }else if(changed){
        const {data:u,error:ue}=await admin.from('payroll_compliance_updates').upsert({source_id:s.id,country_code:s.country_code,detected_at:checked,source_version:version,source_fingerprint:fp,previous_fingerprint:previous,status:'review_required',summary:'Official source changed — manual review required',source_reference:spec,updated_at:checked},{onConflict:'source_id,source_fingerprint',ignoreDuplicates:true}).select('id').maybeSingle();if(ue)throw ue;
        await admin.from('payroll_compliance_sources').update({last_checked_at:checked,last_successful_check_at:checked,last_changed_at:checked,last_known_fingerprint:fp,last_known_version:version,last_source_reference:spec,last_check_status:'change_detected',last_error:null,updated_at:checked}).eq('id',s.id);
        await admin.from('payroll_compliance_audit').insert({country_code:s.country_code,source_id:s.id,update_id:u?.id||null,action:'change_detected',actor_user_id:actor,detail:{scheduled,source_reference:spec,version}});
      }else{
        await admin.from('payroll_compliance_sources').update({last_checked_at:checked,last_successful_check_at:checked,last_known_version:version||s.last_known_version,last_source_reference:spec,last_check_status:'no_change',last_error:null,updated_at:checked}).eq('id',s.id);
      }
      await admin.from('payroll_compliance_audit').insert({country_code:s.country_code,source_id:s.id,action:'source_checked',actor_user_id:actor,detail:{scheduled,result:changed?'change_detected':'no_change',source_reference:spec}});
      results.push({source_id:s.id,country:s.country_code,status:changed?'change_detected':'no_change',version,source_reference:spec});
    }catch(e){const msg=e instanceof Error?e.message:'Source check failed';await admin.from('payroll_compliance_sources').update({last_checked_at:checked,last_check_status:'check_error',last_error:msg.slice(0,500),updated_at:checked}).eq('id',s.id);await admin.from('payroll_compliance_audit').insert({country_code:s.country_code,source_id:s.id,action:'source_check_failed',actor_user_id:actor,detail:{scheduled,error:msg.slice(0,500)}});results.push({source_id:s.id,country:s.country_code,status:'check_error',error:msg});}
  }
  return out({ok:true,scheduled,results});
});
