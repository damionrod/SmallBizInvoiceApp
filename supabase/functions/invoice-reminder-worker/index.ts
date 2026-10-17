import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { appOrigin, createOpaqueToken, hashOpaqueToken } from "../_shared/invoice-payments.ts";
import { platformFrom, validReplyTo, corsHeaders, recordEmailActivity } from "../_shared/email-sender.ts";
import { storedPdfAttachment } from "../_shared/document-attachment.ts";

const json = (req: Request, value: unknown, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { ...corsHeaders(req), "Content-Type": "application/json" },
});

const esc = (value: unknown) => String(value ?? "").replace(/[&<>"']/g, (match) => ({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#039;",
}[match] || match));

const fill = (template: string, values: Record<string, string>) =>
  String(template || "").replace(/\{(\w+)\}/g, (_, key) => values[key] ?? `{${key}}`);

const money = (value: unknown, currency = "NZD") => {
  try {
    return new Intl.NumberFormat("en-NZ", {
      style: "currency",
      currency: String(currency || "NZD").toUpperCase(),
      currencyDisplay: "code",
    }).format(Number(value || 0));
  } catch {
    return `${String(currency || "NZD").toUpperCase()} ${Number(value || 0).toFixed(2)}`;
  }
};

const aucklandDate = () => new Intl.DateTimeFormat("en-CA", {
  timeZone: "Pacific/Auckland",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
}).format(new Date());

const dateLabel = (value: string) => value ? new Date(`${value}T00:00:00`).toLocaleDateString("en-NZ", {
  day: "numeric",
  month: "long",
  year: "numeric",
}) : "";

const daysBetween = (from: string, to: string) => {
  const a = new Date(`${from}T00:00:00Z`).getTime();
  const b = new Date(`${to}T00:00:00Z`).getTime();
  return Math.floor((b - a) / 86400000);
};

const secureEqual = (a: string, b: string) => { const x = new TextEncoder().encode(a); const y = new TextEncoder().encode(b); let diff = x.length ^ y.length; for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0); return diff === 0; };
Deno.serve(async (req) => {
  if (req.method !== "POST") return json(req, { error: "Method not allowed" }, 405);
  const expected = Deno.env.get("INVOICE_REMINDER_WORKER_SECRET") || "";
  const provided = req.headers.get("x-frindly-worker-secret") || "";
  if (expected.length < 32 || !provided || !secureEqual(expected, provided)) return json(req, { error: "Unauthorized" }, 401);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!supabaseUrl || !serviceKey) throw new Error("Supabase server configuration is missing.");
    if (!resendKey) throw new Error("Email service is not configured.");

    const admin = createClient(supabaseUrl, serviceKey);
    const today = aucklandDate();
    const { data: jobs, error: claimError } = await admin.rpc("v61126_claim_invoice_auto_reminders", {
      p_today: today,
      p_limit: 50,
    });
    if (claimError) throw claimError;

    const results: Array<Record<string, unknown>> = [];
    for (const job of jobs || []) {
      let subject = "";
      try {
        const settings = job.business_settings || {};
        const trading = settings.trading || settings.company || "Your Business";
        const companyName = settings.company || trading;
        const phone = settings.phone || "";
        const contactEmail = settings.email || "";
        const due = String(job.due_date || "");
        const overdueDays = Math.max(0, daysBetween(due, today));
        const values = {
          customerName: job.customer_name || "Customer",
          invoiceNumber: job.invoice_number || "Invoice",
          tradingName: trading,
          companyName,
          total: money(job.total, job.currency),
          balanceDue: money(job.balance_due, job.currency),
          amountPaid: money(Math.max(0, Number(job.total || 0) - Number(job.balance_due || 0)), job.currency),
          amountOutstanding: money(job.balance_due, job.currency),
          overdueAmount: overdueDays > 0 ? money(job.balance_due, job.currency) : money(0, job.currency),
          dueDate: dateLabel(due),
          daysOverdue: String(overdueDays),
          statusLine: overdueDays > 0
            ? `The invoice is ${overdueDays} day${overdueDays === 1 ? "" : "s"} overdue.`
            : `The invoice is due on ${dateLabel(due)}.`,
          phone,
          email: contactEmail,
        };
        const senderName = fill(job.sender_template || "{tradingName} Accounts", values).trim() || trading;
        subject = fill(job.subject_template || "Payment reminder - Invoice {invoiceNumber}", values);
        const body = fill(job.body_template || "", values);

        let paymentUrl: string | null = null;
        try {
          const { data: enabled, error: enabledError } = await admin.rpc("v6181_invoice_payments_enabled", { p_business_id: job.business_id });
          if (!enabledError && enabled === true) {
            const { data: paymentSettings } = await admin.from("invoice_payment_settings").select("stripe_account_id,connect_status").eq("business_id", job.business_id).maybeSingle();
            if (paymentSettings?.stripe_account_id && paymentSettings.connect_status === "active" && Number(job.balance_due || 0) > 0.005) {
              const token = createOpaqueToken();
              const tokenHash = await hashOpaqueToken(token);
              await admin.from("invoice_payment_links").update({ active: false, updated_at: new Date().toISOString() }).eq("business_id", job.business_id).eq("invoice_id", job.invoice_id).eq("active", true);
              const { error: linkError } = await admin.from("invoice_payment_links").insert({ business_id: job.business_id, invoice_id: job.invoice_id, token_hash: tokenHash, active: true });
              if (linkError) throw linkError;
              paymentUrl = `${appOrigin(req)}/pay.html?token=${encodeURIComponent(token)}`;
            }
          }
        } catch (paymentLinkError) {
          console.warn("Automatic reminder payment link was not created.", paymentLinkError);
        }

        const paymentBlock = paymentUrl
          ? `<div style="margin:28px 0;padding:20px;border:1px solid #d9e4ec;border-radius:12px;background:#f6fafc"><p style="margin:0 0 12px;color:#24313a">Pay this invoice securely online, including a partial payment if enabled by the business.</p><a href="${esc(paymentUrl)}" style="display:inline-block;padding:12px 20px;border-radius:8px;background:#1769aa;color:#ffffff;text-decoration:none;font-weight:700">Pay Now</a></div>`
          : "";
        const html = `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a">${body.split(/\r?\n/).map((line) => line ? esc(line) : "&nbsp;").join("<br>")}${paymentBlock}</div>`;
        const payload: any = {
          from: platformFrom(senderName, trading),
          to: [job.customer_email],
          subject,
          html,
          attachments: [await storedPdfAttachment(admin, job.business_id, "invoice", job.invoice_id, `${job.invoice_number}.pdf`)],
        };
        const replyTo = validReplyTo(settings.outboundEmail || contactEmail);
        if (replyTo) payload.reply_to = replyTo;

        const response = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        const sent = await response.json();
        if (!response.ok) throw new Error(sent?.message || "Email provider rejected the automatic reminder.");

        await recordEmailActivity(admin, {
          business_id: job.business_id,
          message_type: "invoice_reminder",
          source_table: "invoices",
          source_id: job.invoice_id,
          recipient: job.customer_email,
          subject,
          provider_message_id: sent.id,
          sent_by: null,
          metadata: {
            action: "automatic_reminder",
            invoice_number: job.invoice_number,
            reminder_key: job.reminder_key,
            scheduled_for: job.scheduled_for,
            payment_enabled: Boolean(paymentUrl),
          },
        });
        await admin.from("invoice_reminder_history").insert({
          business_id: job.business_id,
          invoice_id: job.invoice_id,
          recipient: job.customer_email,
          subject,
          provider_message_id: sent.id,
          sent_by: null,
        });
        await admin.rpc("v61126_finish_invoice_auto_reminder", {
          p_run_id: job.run_id,
          p_status: "sent",
          p_subject: subject,
          p_provider_message_id: sent.id,
          p_error_message: null,
        });
        results.push({ run_id: job.run_id, invoice: job.invoice_number, status: "sent" });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown automatic reminder error";
        await admin.rpc("v61126_finish_invoice_auto_reminder", {
          p_run_id: job.run_id,
          p_status: "failed",
          p_subject: subject || null,
          p_provider_message_id: null,
          p_error_message: message,
        });
        results.push({ run_id: job.run_id, invoice: job.invoice_number, status: "failed", error: message });
      }
    }

    return json(req, { success: true, claimed: (jobs || []).length, results });
  } catch (error) {
    return json(req, { error: error instanceof Error ? error.message : "Unknown automatic reminder worker error" }, 400);
  }
});
