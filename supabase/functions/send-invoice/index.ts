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
        from:'CareClean <info@careclean.co.nz>',
        to:[to],
        subject:`CareClean invoice ${invoice.invoice_number}`,
        html:`<p>Hi ${invoice.customer_name},</p><p>Please find attached your CareClean invoice <strong>${invoice.invoice_number}</strong> for <strong>$${Number(invoice.total).toFixed(2)}</strong>.</p><p>Thank you for choosing CareClean.</p><p>CareClean<br>Care New Zealand Limited<br>027 499 4445</p>`,
        attachments:[{filename,content:pdf_base64}]
      })
    });
    const body=await r.text(); if(!r.ok) throw new Error(body);
    return new Response(body,{headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':'*'}});
  } catch(e) { return new Response(JSON.stringify({error:String(e.message||e)}),{status:400,headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':'*'}}); }
});
