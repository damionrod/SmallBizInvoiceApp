import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(x:any,status=200)=>new Response(JSON.stringify(x),{status,headers:{...cors,"Content-Type":"application/json"}});
const esc=(s:any)=>String(s??'').replace(/[&<>"']/g,(m)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':'&quot;',"'":"&#039;"}[m]||m));
const money=(n:any,currency='NZD')=>{try{return new Intl.NumberFormat('en-NZ',{style:'currency',currency:String(currency||'NZD').toUpperCase(),currencyDisplay:'code'}).format(Number(n||0))}catch{return `${String(currency||'NZD').toUpperCase()} ${Number(n||0).toFixed(2)}`}};
const fill=(tpl:string,v:Record<string,string>)=>String(tpl||'').replace(/\{(\w+)\}/g,(_,k)=>v[k]??`{${k}}`);

Deno.serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  try{
    const SUPABASE_URL=Deno.env.get('SUPABASE_URL')!;
    const SUPABASE_ANON_KEY=Deno.env.get('SUPABASE_ANON_KEY')!;
    const RESEND_API_KEY=Deno.env.get('RESEND_API_KEY');
    const FROM_EMAIL=Deno.env.get('EMAIL_FROM_ADDRESS');
    if(!RESEND_API_KEY)throw new Error('RESEND_API_KEY is not configured.');
    if(!FROM_EMAIL)throw new Error('EMAIL_FROM_ADDRESS is not configured.');
    const auth=req.headers.get('Authorization')||'';
    const client=createClient(SUPABASE_URL,SUPABASE_ANON_KEY,{global:{headers:{Authorization:auth}}});
    const {data:{user}}=await client.auth.getUser();if(!user)return json({error:'Not authenticated'},401);
    const {quoteId,to,pdfBase64,filename}=await req.json();
    if(!quoteId||!to)return json({error:'Quote and recipient are required.'},400);
    const {data:q,error}=await client.from('quotes').select('*').eq('id',quoteId).single();
    if(error||!q)return json({error:'Quote not found for this account.'},403);
    const {data:b}=await client.from('businesses').select('name,settings').eq('id',q.business_id).single();
    const s=b?.settings||{}, trading=s.trading||s.company||b?.name||'Your Business';
    const currency=s.currency||'NZD';
    const fromEmail=String(s.outboundEmail||FROM_EMAIL).trim();
    const e=s.quoteEmailSettings||{};
    const values={customerName:q.customer_name||'Customer',quoteNumber:q.quote_number||'Quote',tradingName:trading,companyName:s.company||b?.name||trading,amountExGst:money(q.quoted_price_ex_gst,currency),gst:money(q.gst_amount,currency),total:money(q.total_incl_gst,currency),validUntil:q.valid_until||'—',phone:s.phone||'',email:s.email||''};
    const senderName=fill(e.senderName||'{tradingName}',values).trim().replace(/[<>]/g,'')||trading;
    const subject=fill(e.subject||'Quote {quoteNumber} from {tradingName}',values);
    const body=fill(e.body||'Hi {customerName},\n\nPlease find attached quote {quoteNumber}.\n\nAmount (ex GST): {amountExGst}\nGST: {gst}\nTotal: {total}\nValid until: {validUntil}\n\nKind regards,\n{tradingName}\n{phone}\n{email}',values);
    const payload:any={from:`${senderName} <${fromEmail}>`,to:[to],subject,html:`<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a">${body.split(/\r?\n/).map((line:string)=>line?esc(line):'&nbsp;').join('<br>')}</div>`};
    if(s.email)payload.reply_to=s.email;
    if(pdfBase64)payload.attachments=[{filename:filename||`${q.quote_number}.pdf`,content:pdfBase64}];
    const r=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${RESEND_API_KEY}`,'Content-Type':'application/json'},body:JSON.stringify(payload)});
    const data=await r.json();if(!r.ok)return json({error:data?.message||'Email provider rejected the message.',details:data},r.status);
    return json({success:true,id:data.id});
  }catch(e){return json({error:e instanceof Error?e.message:'Unknown quote email error'},400)}
});
