import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(x:any,status=200)=>new Response(JSON.stringify(x),{status,headers:{...cors,"Content-Type":"application/json"}});
const esc=(s:any)=>String(s??"").replace(/[&<>"']/g,(m)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]||m));
Deno.serve(async(req)=>{if(req.method==="OPTIONS")return new Response("ok",{headers:cors});try{
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,key=Deno.env.get("RESEND_API_KEY"),platformFrom=Deno.env.get("EMAIL_FROM_ADDRESS");
  if(!key||!platformFrom)throw new Error("Email service is not configured.");
  const auth=req.headers.get("Authorization")||"",client=createClient(url,anon,{global:{headers:{Authorization:auth}}});
  const {data:{user}}=await client.auth.getUser();if(!user)return json({error:"Not authenticated"},401);
  const {payslipId,to,pdfBase64,filename}=await req.json();if(!payslipId||!to)return json({error:"Payslip and recipient are required."},400);
  const {data:p,error}=await client.from("payroll_payslips").select("id,business_id,payslip_number,payslip_data").eq("id",payslipId).single();if(error||!p)return json({error:"Payslip not found for this account."},403);
  const {data:b}=await client.from("businesses").select("name,settings").eq("id",p.business_id).single();const s=b?.settings||{},trading=s.trading||s.company||b?.name||"Your Business",from=String(s.outboundEmail||platformFrom).trim(),sender=`${trading.replace(/[<>]/g,"")} Payroll`,employee=p.payslip_data?.employee?.name||"Employee",payDate=p.payslip_data?.run?.pay_date||"";
  const payload:any={from:`${sender} <${from}>`,to:[to],subject:`Payslip ${p.payslip_number} from ${trading}`,html:`<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a"><p>Hi ${esc(employee)},</p><p>Please find attached your payslip <strong>${esc(p.payslip_number)}</strong>${payDate?` for pay date ${esc(payDate)}`:""}.</p><p>Kind regards,<br><strong>${esc(trading)}</strong></p></div>`};
  if(s.email)payload.reply_to=s.email;if(pdfBase64)payload.attachments=[{filename:filename||`${p.payslip_number}.pdf`,content:pdfBase64}];
  const r=await fetch("https://api.resend.com/emails",{method:"POST",headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},body:JSON.stringify(payload)}),data=await r.json();if(!r.ok)return json({error:data?.message||"Email provider rejected the message.",details:data},r.status);return json({success:true,id:data.id});
}catch(e){return json({error:e instanceof Error?e.message:"Unknown payslip email error"},400)}});
