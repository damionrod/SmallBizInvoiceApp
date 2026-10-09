import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { platformFrom, validReplyTo, corsHeaders, clientIp, enforceRateLimit } from '../_shared/email-sender.ts';
import { storePdfAndAttachment, storedPdfAttachment } from "../_shared/document-attachment.ts";

const cors = corsHeaders();

const json = (x:any,status=200) =>
  new Response(
    JSON.stringify(x),
    {
      status,
      headers:{
        ...cors,
        "Content-Type":"application/json"
      }
    }
  );

const esc = (s:any) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (m) =>
      ({
        "&":"&amp;",
        "<":"&lt;",
        ">":"&gt;",
        '"':"&quot;",
        "'":"&#039;"
      }[m] || m)
  );

const money = (n:any,currency="NZD") => {
  try{
    return new Intl.NumberFormat(
      "en-NZ",
      {
        style:"currency",
        currency:
          String(currency || "NZD").toUpperCase(),
        currencyDisplay:"code"
      }
    ).format(Number(n || 0));
  }catch{
    return `${String(currency || "NZD").toUpperCase()} ${Number(n || 0).toFixed(2)}`;
  }
};

const fill = (
  tpl:string,
  v:Record<string,string>
) =>
  String(tpl || "").replace(
    /\{(\w+)\}/g,
    (_,k) => v[k] ?? `{${k}}`
  );

Deno.serve(async(req)=>{

  if(req.method === "OPTIONS"){
    return new Response(
      "ok",
      {headers:cors}
    );
  }

  try{

    const SUPABASE_URL =
      Deno.env.get("SUPABASE_URL")!;

    const SUPABASE_ANON_KEY =
      Deno.env.get("SUPABASE_ANON_KEY")!;

    const RESEND_API_KEY =
      Deno.env.get("RESEND_API_KEY");

    const SUPABASE_SERVICE_ROLE_KEY =
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if(!RESEND_API_KEY){
      throw new Error(
        "RESEND_API_KEY is not configured."
      );
    }
    if(!SUPABASE_SERVICE_ROLE_KEY){
      throw new Error("Supabase server configuration is missing.");
    }

    const auth =
      req.headers.get("Authorization") || "";

    const client =
      createClient(
        SUPABASE_URL,
        SUPABASE_ANON_KEY,
        {
          global:{
            headers:{
              Authorization:auth
            }
          }
        }
      );

    const admin =
      createClient(
        SUPABASE_URL,
        SUPABASE_SERVICE_ROLE_KEY
      );

    const {
      data:{user}
    } =
      await client.auth.getUser();

    if(!user){
      return json(
        {error:"Not authenticated"},
        401
      );
    }
    await enforceRateLimit(admin,"send-quote:user",user.id||clientIp(req),30,3600);

    const isMultipart = (req.headers.get("content-type") || "").toLowerCase().includes("multipart/form-data");
    let quoteId="", to="", pdf:File|null=null;
    if(isMultipart){const form=await req.formData();quoteId=String(form.get("quoteId")||"").trim();to=String(form.get("to")||"").trim();const incoming=form.get("pdf");pdf=incoming instanceof File?incoming:null;}
    else{const body=await req.json();quoteId=String(body?.quoteId||"").trim();to=String(body?.to||"").trim();}

    if(!quoteId || !to || (isMultipart && !pdf)){
      return json(
        {
          error:
            "Quote and recipient are required."
        },
        400
      );
    }
    await enforceRateLimit(admin,"send-quote:quote",quoteId,10,3600);

    const {
      data:q,
      error
    } =
      await client
        .from("quotes")
        .select("*")
        .eq("id",quoteId)
        .single();

    if(error || !q){
      return json(
        {
          error:
            "Quote not found for this account."
        },
        403
      );
    }

    const {
      data:b
    } =
      await client
        .from("businesses")
        .select("name,settings")
        .eq("id",q.business_id)
        .single();

    const s =
      b?.settings || {};

    const {
      data:subscriberProfile
    } =
      await client
        .from("profiles")
        .select("email")
        .eq("business_id",q.business_id)
        .eq("role","owner")
        .limit(1)
        .maybeSingle();

    const trading =
      s.trading ||
      s.company ||
      b?.name ||
      "Your Business";

    const currency =
      s.currency || "NZD";

    const subscriberEmail =
      String(
        subscriberProfile?.email ||
        s.email ||
        user.email ||
        ""
      ).trim();

    const e =
      s.quoteEmailSettings || {};

    const values = {

      customerName:
        q.customer_name || "Customer",

      quoteNumber:
        q.quote_number || "Quote",

      tradingName:
        trading,

      companyName:
        s.company ||
        b?.name ||
        trading,

      amountExGst:
        money(
          q.quoted_price_ex_gst,
          currency
        ),

      gst:
        money(
          q.gst_amount,
          currency
        ),

      total:
        money(
          q.total_incl_gst,
          currency
        ),

      validUntil:
        q.valid_until || "—",

      phone:
        s.phone || "",

      email:
        s.email || ""
    };

    const senderName =
      fill(
        e.senderName ||
        "{tradingName}",
        values
      )
        .trim()
        .replace(/[<>]/g,"") ||
      trading;

    const subject =
      fill(
        e.subject ||
        "Quote {quoteNumber} from {tradingName}",
        values
      );

    const body =
      fill(
        e.body ||
`Hi {customerName},

Please find attached quote {quoteNumber}.

Amount (ex GST): {amountExGst}
GST: {gst}
Total: {total}
Valid until: {validUntil}

Kind regards,
{tradingName}
{phone}
{email}`,
        values
      );

    const payload:any = {

      from:
        platformFrom(senderName, trading),

      to:[to],

      subject,

      html:
        `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a">` +
        body
          .split(/\r?\n/)
          .map(
            (line:string) =>
              line ? esc(line) : "&nbsp;"
          )
          .join("<br>") +
        `</div>`
    };

    const replyTo = validReplyTo(s.outboundEmail || subscriberEmail);
    if(replyTo){
      payload.reply_to = replyTo;
    }

    payload.attachments = [
      isMultipart && pdf ? await storePdfAndAttachment(
        admin, q.business_id, "quote", q.id, pdf, `${q.quote_number}.pdf`
      ) : await storedPdfAttachment(
        admin, q.business_id, "quote", q.id, `${q.quote_number}.pdf`
      )
    ];

    const r =
      await fetch(
        "https://api.resend.com/emails",
        {
          method:"POST",
          headers:{
            Authorization:
              `Bearer ${RESEND_API_KEY}`,
            "Content-Type":
              "application/json"
          },
          body:JSON.stringify(payload)
        }
      );

    const data =
      await r.json();

    if(!r.ok){
      return json(
        {
          error:
            data?.message ||
            "Email provider rejected the message.",
          details:data
        },
        r.status
      );
    }

    return json({
      success:true,
      id:data.id
    });

  }catch(e){

    return json(
      {
        error:
          e instanceof Error
            ? e.message
            : "Unknown quote email error"
      },
      (e as any)?.status || 400
    );
  }
});
