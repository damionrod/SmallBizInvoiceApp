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
    const {data:{user}}=await client.auth.getUser(); if(!user)return json({error:'Not authenticated'},401);
    const {to,invoice,pdfBase64,filename}=await req.json();
    if(!to||!invoice?.id)return json({error:'Invoice and recipient are required.'},400);
    const {data:owned,error}=await client.from('invoices').select('id,business_id,invoice_number,customer_name,total,balance_due,due_date,company_snapshot').eq('id',invoice.id).single();
    if(error||!owned)return json({error:'Invoice not found for this account.'},403);
    const s=owned.company_snapshot||{}; const e=s.emailSettings||{};
    const {data:businessRow}=await client.from('businesses').select('settings').eq('id',owned.business_id).single();
    const currentSettings=businessRow?.settings||{};
    const currency=currentSettings.currency||s.currency||'NZD';
    const fromEmail=String(currentSettings.outboundEmail||s.outboundEmail||FROM_EMAIL).trim();
    const trading=s.trading||s.company||'Your Business';
    const values={customerName:owned.customer_name||'Customer',invoiceNumber:owned.invoice_number||'Invoice',tradingName:trading,companyName:s.company||trading,total:money(owned.total,currency),balanceDue:money(owned.balance_due??owned.total,currency),dueDate:owned.due_date||'',phone:s.phone||'',email:s.email||''};
    const senderName=fill(e.senderName||'{tradingName} Accounts',values).trim()||trading;
    const subject=fill(e.subject||'Invoice {invoiceNumber} from {tradingName}',values);
    const body=fill(e.body||'Hi {customerName},\n\nPlease find attached invoice {invoiceNumber}.\n\nTotal: {total}\nBalance due: {balanceDue}\nDue date: {dueDate}\n\nKind regards,\n{tradingName}',values);
    const payload:any={from:`${senderName.replace(/[<>]/g,'')} <${fromEmail}>`,to:[to],subject,html:`<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a;white-space:normal">${body.split(/\r?\n/).map((line:string)=>line?esc(line):'&nbsp;').join('<br>')}</div>`};
    if(s.email)payload.reply_to=s.email;
    if(pdfBase64)payload.attachments=[{filename:filename||`${owned.invoice_number}.pdf`,content:pdfBase64}];
    const r=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${RESEND_API_KEY}`,'Content-Type':'application/json'},body:JSON.stringify(payload)});const data=await r.json();
    if(!r.ok)return json({error:data?.message||'Email provider rejected the message.',details:data},r.status);
    return json({success:true,id:data.id});
  }catch(e){return json({error:e instanceof Error?e.message:'Unknown email error'},400)}
});
