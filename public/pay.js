(() => {
  const config = window.APP_CONFIG || {};
  const params = new URLSearchParams(location.search);
  const token = String(params.get('token') || '').trim();
  const $ = (id) => document.getElementById(id);
  let details = null;

  function esc(value) {
    return String(value ?? '').replace(/[&<>"']/g, (match) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[match] || match));
  }
  function money(value) {
    try { return new Intl.NumberFormat('en-NZ', { style: 'currency', currency: String(details?.currency || 'nzd').toUpperCase() }).format(Number(value || 0)); } catch { return `${String(details?.currency || 'NZD').toUpperCase()} ${Number(value || 0).toFixed(2)}`; }
  }
  function showMessage(message, kind = 'error') {
    const el = $('paymentMessage');
    el.hidden = false;
    el.className = `public-payment-message ${kind}`;
    el.innerHTML = message;
    $('paymentLoading').hidden = true;
    $('paymentContent').hidden = true;
  }
  async function call(action, body = {}) {
    const url = `${String(config.supabaseUrl || '').replace(/\/$/, '')}/functions/v1/invoice-payments`;
    const response = await fetch(url, { method: 'POST', headers: { apikey: config.supabaseKey || '', 'Content-Type': 'application/json' }, body: JSON.stringify({ action, token, ...body }) });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data?.error || 'Unable to load this payment page.');
    return data;
  }
  function updateTotals() {
    if (!details) return;
    const amount = Math.min(details.invoice.balance_due, Math.max(0, Number($('paymentAmount').value || 0)));
    const percent = Math.max(0, Number(details.fee_percent || 0)) / 100;
    const fixed = Math.max(0, Number(details.fee_fixed_amount || 0));
    const estimate = percent >= 0.9999 ? fixed : (amount * percent + fixed) / (1 - percent);
    const fee = details.fee_mode === 'bear' ? 0 : Math.round((details.fee_mode === 'split' ? estimate / 2 : estimate) * 100) / 100;
    $('paymentFee').textContent = money(fee);
    $('paymentGross').textContent = money(amount + fee);
    $('paymentSubmit').disabled = amount <= 0 || amount > details.invoice.balance_due + 0.005;
  }
  function render(data) {
    details = data;
    const invoice = data.invoice;
    $('paymentInvoiceNumber').textContent = invoice.invoice_number || 'Invoice';
    $('paymentBusinessName').textContent = data.business_name || 'Your business';
    $('paymentTotal').textContent = money(invoice.total);
    $('paymentPaid').textContent = money(invoice.amount_paid);
    $('paymentBalance').textContent = money(invoice.balance_due);
    $('paymentDueDate').textContent = invoice.due_date ? new Date(`${invoice.due_date}T00:00:00`).toLocaleDateString('en-NZ') : '—';
    $('paymentAmount').value = Number(invoice.balance_due || 0).toFixed(2);
    $('paymentAmount').max = Number(invoice.balance_due || 0).toFixed(2);
    $('paymentPartialHint').textContent = data.allow_partial_payments ? 'Partial payments are available. Pay any amount up to the balance due.' : 'This business requires the full balance to be paid.';
    $('paymentAmount').disabled = !data.allow_partial_payments;
    $('paymentStatusPill').textContent = invoice.balance_due <= 0.005 ? 'Paid' : 'Balance due';
    $('paymentStatusPill').classList.toggle('paid', invoice.balance_due <= 0.005);
    $('paymentForm').hidden = invoice.balance_due <= 0.005;
    $('paymentLoading').hidden = true;
    $('paymentMessage').hidden = true;
    $('paymentContent').hidden = false;
    updateTotals();
  }
  async function load() {
    if (!token) return showMessage('This payment link is missing its secure token. Please ask the business to send the invoice again.');
    if (params.get('status') === 'cancelled') showMessage('Payment cancelled. No payment was taken.', 'info');
    if (params.get('status') === 'success') showMessage('Payment submitted. Stripe is confirming it now; this page will refresh shortly.', 'success');
    try { render(await call('details')); } catch (error) { showMessage(esc(error.message)); }
  }
  $('paymentAmount')?.addEventListener('input', updateTotals);
  $('paymentSubmit')?.addEventListener('click', async () => {
    const button = $('paymentSubmit');
    const amount = Number($('paymentAmount').value || 0);
    button.disabled = true; button.textContent = 'Opening secure checkout…';
    try { const result = await call('checkout', { amount }); if (!result?.url) throw new Error('Stripe checkout did not return a payment link.'); location.href = result.url; }
    catch (error) { showMessage(esc(error.message)); button.disabled = false; button.textContent = 'Pay Now'; }
  });
  load();
})();
