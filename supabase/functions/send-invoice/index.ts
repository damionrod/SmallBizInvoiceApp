import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { appOrigin, createOpaqueToken, hashOpaqueToken } from '../_shared/invoice-payments.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (value: unknown, status = 200) => new Response(
  JSON.stringify(value),
  { status, headers: { ...cors, 'Content-Type': 'application/json' } },
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
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const resendKey = Deno.env.get('RESEND_API_KEY');
    if (!supabaseUrl || !anonKey || !serviceKey) throw new Error('Supabase configuration is missing.');
    const configuredFrom = (Deno.env.get('RESEND_FROM_EMAIL') || Deno.env.get('EMAIL_FROM_ADDRESS') || '').trim();
    const fromEmail = configuredFrom && configuredFrom.toLowerCase() !== 'info@careclean.co.nz' ? configuredFrom : 'notifications@frindly.co.nz';
    if (!resendKey) throw new Error('RESEND_API_KEY is not configured.');

    const auth = req.headers.get('Authorization') || '';
    const client = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: auth } } });
    const admin = createClient(supabaseUrl, serviceKey);
    const { data: { user } } = await client.auth.getUser();
    if (!user) return json({ error: 'Not authenticated' }, 401);

    const { to, invoice, pdfBase64, filename } = await req.json();
    if (!to || !invoice?.id) return json({ error: 'Invoice and recipient are required.' }, 400);
    const { data: owned, error: ownedError } = await client
      .from('invoices')
      .select('id,business_id,invoice_number,customer_name,total,balance_due,due_date,company_snapshot')
      .eq('id', invoice.id)
      .single();
    if (ownedError || !owned) return json({ error: 'Invoice not found for this account.' }, 403);

    const { error: issueError } = await client.rpc('v6170c1_issue_invoice', { p_invoice_id: owned.id });
    if (issueError) return json({ error: issueError.message || 'This invoice could not be issued safely.' }, 400);

    const snapshot = owned.company_snapshot || {};
    const { data: businessRow } = await client.from('businesses').select('name,settings').eq('id', owned.business_id).single();
    const { data: subscriberProfile } = await client.from('profiles').select('email').eq('business_id', owned.business_id).eq('role', 'owner').limit(1).maybeSingle();
    const currentSettings = businessRow?.settings || {};
    const emailSettings = currentSettings.emailSettings || snapshot.emailSettings || {};
    const currency = currentSettings.currency || snapshot.currency || 'NZD';
    const currentInvoice = (await admin.from('invoices').select('id,business_id,invoice_number,customer_name,total,balance_due,due_date,company_snapshot').eq('id', owned.id).single()).data || owned;
    const from = String(currentSettings.outboundEmail || snapshot.outboundEmail || fromEmail).trim();
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
      dueDate: currentInvoice.due_date || '',
      phone,
      email: contactEmail,
    };
    const senderName = fill(emailSettings.senderName || '{tradingName} Accounts', values).trim() || trading;
    const subject = fill(emailSettings.subject || 'Invoice {invoiceNumber} from {tradingName}', values);
    const body = fill(emailSettings.body || 'Hi {customerName},\n\nPlease find attached invoice {invoiceNumber}.\n\nTotal: {total}\nBalance due: {balanceDue}\nDue date: {dueDate}\n\nKind regards,\n{tradingName}\n{phone}\n{email}', values);

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
    const payload: any = { from: `${senderName.replace(/[<>]/g, '')} <${from}>`, to: [to], subject, html };
    if (subscriberEmail) payload.reply_to = subscriberEmail;
    if (pdfBase64) payload.attachments = [{ filename: filename || `${currentInvoice.invoice_number}.pdf`, content: pdfBase64 }];
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await response.json();
    if (!response.ok) return json({ error: data?.message || 'Email provider rejected the message.', details: data }, response.status);
    return json({ success: true, id: data.id, payment_enabled: Boolean(paymentUrl) });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : 'Unknown email error' }, 400);
  }
});

