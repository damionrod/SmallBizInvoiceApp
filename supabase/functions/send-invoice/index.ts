import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { appOrigin, createOpaqueToken, hashOpaqueToken } from '../_shared/invoice-payments.ts';
import { platformFrom, validReplyTo, corsHeaders, clientIp, enforceRateLimit } from '../_shared/email-sender.ts';
import { storePdfAndAttachment, storedPdfAttachment } from '../_shared/document-attachment.ts';

const json = (req: Request, value: unknown, status = 200) => new Response(
  JSON.stringify(value),
  { status, headers: { ...corsHeaders(req), 'Content-Type': 'application/json' } },
);
const esc = (value: any) => String(value ?? '').replace(/[&<>"']/g, (match) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[match] || match));
const money = (value: any, currency = 'NZD') => {
  try {
    return new Intl.NumberFormat('en-NZ', { style: 'currency', currency: String(currency || 'NZD').toUpperCase(), currencyDisplay: 'code' }).format(Number(value || 0));
  } catch {
    return `${String(currency || 'NZD').toUpperCase()} ${Number(value || 0).toFixed(2)}`;
  }
};
const fill = (template: string, values: Record<string, string>) => String(template || '').replace(/\{(\w+)\}/g, (_, key) => values[key] ?? `{${key}}`);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const resendKey = Deno.env.get('RESEND_API_KEY');
    if (!supabaseUrl || !anonKey || !serviceKey) throw new Error('Supabase configuration is missing.');
    if (!resendKey) throw new Error('RESEND_API_KEY is not configured.');

    const auth = req.headers.get('Authorization') || '';
    const client = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: auth } } });
    const admin = createClient(supabaseUrl, serviceKey);
    const { data: { user } } = await client.auth.getUser();
    if (!user) return json(req, { error: 'Not authenticated' }, 401);
    await enforceRateLimit(admin, 'send-invoice:user', user.id || clientIp(req), 30, 3600);

    const isMultipart = (req.headers.get('content-type') || '').toLowerCase().includes('multipart/form-data');
    let to = '', invoiceId = '', action = 'invoice', subjectOverride = '', bodyOverride = '', pdf: File | null = null;
    if (isMultipart) {
      const form = await req.formData();
      to = String(form.get('to') || '').trim(); invoiceId = String(form.get('invoiceId') || '').trim(); action = String(form.get('action') || 'invoice').trim(); subjectOverride = String(form.get('subject') || '').trim(); bodyOverride = String(form.get('body') || '').trim();
      const incoming = form.get('pdf'); pdf = incoming instanceof File ? incoming : null;
    } else {
      const body = await req.json(); to = String(body?.to || '').trim(); invoiceId = String(body?.invoice?.id || body?.invoiceId || '').trim(); action = String(body?.action || 'invoice').trim(); subjectOverride = String(body?.subject || '').trim(); bodyOverride = String(body?.body || '').trim();
    }
    if (!to || !invoiceId || (isMultipart && !pdf)) return json(req, { error: 'Invoice and recipient are required.' }, 400);
    await enforceRateLimit(admin, 'send-invoice:invoice', invoiceId, 12, 3600);
    const { data: owned, error: ownedError } = await client
      .from('invoices')
      .select('id,business_id,invoice_number,customer_name,total,balance_due,due_date,company_snapshot,lifecycle_state')
      .eq('id', invoiceId)
      .single();
    if (ownedError || !owned) return json(req, { error: 'Invoice not found for this account.' }, 403);

    const isReminder = action === 'reminder';
    if (isReminder) {
      if (String(owned.lifecycle_state || '').toLowerCase() !== 'issued') return json(req, { error: 'Only issued invoices can receive payment reminders.' }, 400);
      if (Number(owned.balance_due ?? owned.total ?? 0) <= 0.005) return json(req, { error: 'This invoice is already fully paid.' }, 400);
      if (!subjectOverride || !bodyOverride) return json(req, { error: 'Reminder subject and message are required.' }, 400);
    } else {
      const { error: issueError } = await client.rpc('v6170c1_issue_invoice', { p_invoice_id: owned.id });
      if (issueError) return json(req, { error: issueError.message || 'This invoice could not be issued safely.' }, 400);
    }

    const snapshot = owned.company_snapshot || {};
    const { data: businessRow } = await client.from('businesses').select('name,settings').eq('id', owned.business_id).single();
    const { data: subscriberProfile } = await client.from('profiles').select('email').eq('business_id', owned.business_id).eq('role', 'owner').limit(1).maybeSingle();
    const currentSettings = businessRow?.settings || {};
    const emailSettings = isReminder ? (currentSettings.reminderEmailSettings || snapshot.reminderEmailSettings || {}) : (currentSettings.emailSettings || snapshot.emailSettings || {});
    const currency = currentSettings.currency || snapshot.currency || 'NZD';
    const currentInvoice = (await admin.from('invoices').select('id,business_id,invoice_number,customer_name,total,balance_due,due_date,company_snapshot,lifecycle_state').eq('id', owned.id).single()).data || owned;
    const trading = currentSettings.trading || currentSettings.company || businessRow?.name || snapshot.trading || snapshot.company || 'Your Business';
    const companyName = currentSettings.company || businessRow?.name || snapshot.company || trading;
    const phone = currentSettings.phone || snapshot.phone || '';
    const contactEmail = currentSettings.email || snapshot.email || '';
    const subscriberEmail = String(subscriberProfile?.email || contactEmail || user.email || '').trim();
    const values = {
      customerName: currentInvoice.customer_name || 'Customer',
      invoiceNumber: currentInvoice.invoice_number || 'Invoice',
      tradingName: trading,
      companyName,
      total: money(currentInvoice.total, currency),
      balanceDue: money(currentInvoice.balance_due ?? currentInvoice.total, currency),
      dueDate: currentInvoice.due_date ? new Date(`${currentInvoice.due_date}T00:00:00`).toLocaleDateString('en-NZ', { day: 'numeric', month: 'long', year: 'numeric' }) : '',
      phone,
      email: contactEmail,
      amountPaid: money(Math.max(0, Number(currentInvoice.total || 0) - Number(currentInvoice.balance_due ?? currentInvoice.total ?? 0)), currency),
      amountOutstanding: money(currentInvoice.balance_due ?? currentInvoice.total, currency),
      overdueAmount: money((currentInvoice.due_date && new Date(`${currentInvoice.due_date}T00:00:00`).getTime() < new Date(new Date().toISOString().slice(0,10)+'T00:00:00').getTime()) ? (currentInvoice.balance_due ?? currentInvoice.total) : 0, currency),
      daysOverdue: String(currentInvoice.due_date ? Math.max(0, Math.floor((new Date(new Date().toISOString().slice(0,10)+'T00:00:00').getTime() - new Date(`${currentInvoice.due_date}T00:00:00`).getTime()) / 86400000)) : 0),
      statusLine: '',
    };
    const daysOverdue = Number(values.daysOverdue || 0);
    values.statusLine = daysOverdue > 0 ? `The invoice is ${daysOverdue} day${daysOverdue === 1 ? '' : 's'} overdue.` : `The invoice is due on ${values.dueDate}.`;
    const senderName = fill(emailSettings.senderName || '{tradingName} Accounts', values).trim() || trading;
    const subject = isReminder ? fill(subjectOverride, values) : fill(emailSettings.subject || 'Invoice {invoiceNumber} from {tradingName}', values);
    const body = isReminder ? fill(bodyOverride, values) : fill(emailSettings.body || 'Hi {customerName},\n\nPlease find attached invoice {invoiceNumber}.\n\nTotal: {total}\nBalance due: {balanceDue}\nDue date: {dueDate}\n\nKind regards,\n{tradingName}\n{phone}\n{email}', values);

    let paymentUrl: string | null = null;
    // If the online-payments migration is not installed yet, preserve the
    // existing email flow and send without the optional Pay Now block.
    try {
      const { data: enabled, error: enabledError } = await admin.rpc('v6181_invoice_payments_enabled', { p_business_id: owned.business_id });
      if (!enabledError && enabled === true) {
        const { data: paymentSettings } = await admin.from('invoice_payment_settings').select('stripe_account_id,connect_status').eq('business_id', owned.business_id).maybeSingle();
        const balance = Number(currentInvoice.balance_due ?? currentInvoice.total ?? 0);
        if (paymentSettings?.stripe_account_id && paymentSettings.connect_status === 'active' && balance > 0.005) {
          const token = createOpaqueToken();
          const tokenHash = await hashOpaqueToken(token);
          await admin.from('invoice_payment_links').update({ active: false, updated_at: new Date().toISOString() }).eq('business_id', owned.business_id).eq('invoice_id', owned.id).eq('active', true);
          const { error: linkError } = await admin.from('invoice_payment_links').insert({ business_id: owned.business_id, invoice_id: owned.id, token_hash: tokenHash, active: true });
          if (linkError) throw linkError;
          paymentUrl = `${appOrigin(req)}/pay.html?token=${encodeURIComponent(token)}`;
        }
      }
    } catch (paymentLinkError) {
      console.warn('Invoice payment link was not created; sending without Pay Now.', paymentLinkError);
    }

    const paymentBlock = paymentUrl
      ? `<div style="margin:28px 0;padding:20px;border:1px solid #d9e4ec;border-radius:12px;background:#f6fafc"><p style="margin:0 0 12px;color:#24313a">Pay this invoice securely online, including a partial payment if enabled by the business.</p><a href="${esc(paymentUrl)}" style="display:inline-block;padding:12px 20px;border-radius:8px;background:#1769aa;color:#ffffff;text-decoration:none;font-weight:700">Pay Now</a></div>`
      : '';
    const html = `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#24313a">${body.split(/\r?\n/).map((line: string) => line ? esc(line) : '&nbsp;').join('<br>')}${paymentBlock}</div>`;
    const payload: any = { from: platformFrom(senderName, trading), to: [to], subject, html };
    const replyTo = validReplyTo(currentSettings.outboundEmail || subscriberEmail);
    if (replyTo) payload.reply_to = replyTo;
    payload.attachments = [isMultipart && pdf ? await storePdfAndAttachment(admin, owned.business_id, "invoice", owned.id, pdf, `${currentInvoice.invoice_number}.pdf`) : await storedPdfAttachment(admin, owned.business_id, "invoice", owned.id, `${currentInvoice.invoice_number}.pdf`)];
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await response.json();
    if (!response.ok) return json(req, { error: data?.message || 'Email provider rejected the message.', details: data }, response.status);
    if (isReminder) {
      const { error: historyError } = await admin.from('invoice_reminder_history').insert({
        business_id: owned.business_id,
        invoice_id: owned.id,
        recipient: to,
        subject,
        provider_message_id: data.id,
        sent_by: user.id
      });
      if (historyError) console.warn('Reminder sent but history could not be recorded.', historyError);
    }
    return json(req, { success: true, id: data.id, payment_enabled: Boolean(paymentUrl), action: isReminder ? 'reminder' : 'invoice' });
  } catch (error) {
    return json(req, { error: error instanceof Error ? error.message : 'Unknown email error' }, (error as any)?.status || 400);
  }
});

