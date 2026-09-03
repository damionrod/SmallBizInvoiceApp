import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok',{headers:{'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type'}});
  try {
    const { to, invoice, pdf_base64, filename } = await req.json();
    const apiKey = Deno.env.get('RESEND_API_KEY');
    if (!apiKey) throw new Error('RESEND_API_KEY is not configured');
    const r = await fetch('https://api.resend.com/emails', {
      method:'POST',
      headers:{'Authorization':`Bearer ${apiKey}`,'Content-Type':'application/json'},
      body:JSON.stringify({
        from:Deno.env.get('RESEND_FROM') || 'Invoice Manager <onboarding@resend.dev>',
        to:[to],
        subject:`${invoice?.company_snapshot?.trading || invoice?.company_snapshot?.company || 'Invoice'} ${invoice.invoice_number}`, 
        html:`<p>Hi ${invoice.customer_name || 'Customer'},</p><p>Please find attached invoice <strong>${invoice.invoice_number}</strong> for <strong>$${Number(invoice.total || 0).toFixed(2)}</strong>.</p><p>Thank you for your business.</p><p>${invoice?.company_snapshot?.trading || invoice?.company_snapshot?.company || 'Invoice Manager'}${invoice?.company_snapshot?.phone ? '<br>'+invoice.company_snapshot.phone : ''}${invoice?.company_snapshot?.email ? '<br>'+invoice.company_snapshot.email : ''}</p>`,
        attachments:[{filename,content:pdf_base64}]
      })
    });
    const body=await r.text(); if(!r.ok) throw new Error(body);
    return new Response(body,{headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':'*'}});
  } catch(e) { return new Response(JSON.stringify({error:String(e.message||e)}),{status:400,headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':'*'}}); }
});
