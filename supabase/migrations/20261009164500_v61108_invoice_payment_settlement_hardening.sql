-- v61.108: harden Stripe Connect invoice payment settlement.
-- - keep settlement callable by service_role only
-- - reject draft/voided invoices
-- - compare payment currency to the invoice snapshot currency
-- - use stored invoice balance_due first so credits/adjustments are respected

create or replace function public.v6181_record_online_invoice_payment(
  p_transaction_id uuid,
  p_payment_date date default current_date,
  p_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tx public.invoice_payment_transactions%rowtype;
  v_invoice public.invoices%rowtype;
  v_paid numeric := 0;
  v_outstanding numeric := 0;
  v_payment_id uuid;
  v_reference text;
  v_invoice_currency text;
begin
  select * into v_tx
  from public.invoice_payment_transactions
  where id = p_transaction_id
  for update;

  if v_tx.id is null then
    raise exception 'Online payment transaction not found';
  end if;

  if v_tx.status = 'succeeded' then
    return jsonb_build_object(
      'transaction_id', v_tx.id,
      'status', v_tx.status,
      'customer_payment_id', v_tx.customer_payment_id,
      'already_recorded', true
    );
  end if;

  select * into v_invoice
  from public.invoices
  where id = v_tx.invoice_id
    and business_id = v_tx.business_id
  for update;

  if v_invoice.id is null then
    update public.invoice_payment_transactions
    set status = 'needs_review',
        failure_reason = 'Invoice was not found for the payment.',
        updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;

  if coalesce(v_invoice.lifecycle_state, 'issued') <> 'issued' then
    update public.invoice_payment_transactions
    set status = 'needs_review',
        failure_reason = format('Payment received for a %s invoice.', coalesce(v_invoice.lifecycle_state, 'unknown')),
        updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;

  v_invoice_currency := lower(coalesce(nullif(v_invoice.company_snapshot->>'currency', ''), 'nzd'));
  if lower(v_tx.currency) <> v_invoice_currency then
    update public.invoice_payment_transactions
    set status = 'needs_review',
        failure_reason = format('Payment currency %s does not match invoice currency %s.', upper(v_tx.currency), upper(v_invoice_currency)),
        updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;

  select coalesce(sum(cp.amount), 0)
  into v_paid
  from public.customer_payments cp
  where cp.invoice_id = v_invoice.id;

  v_outstanding := greatest(0, coalesce(v_invoice.balance_due, coalesce(v_invoice.total, 0) - v_paid));

  if v_tx.amount > v_outstanding + 0.005 then
    update public.invoice_payment_transactions
    set status = 'needs_review',
        failure_reason = format('Payment amount %s exceeds the remaining invoice balance %s.', v_tx.amount, v_outstanding),
        updated_at = now()
    where id = v_tx.id;
    return jsonb_build_object(
      'transaction_id', v_tx.id,
      'status', 'needs_review',
      'remaining_balance', v_outstanding
    );
  end if;

  v_reference := coalesce(nullif(trim(p_reference), ''), 'Stripe Connect online payment');
  insert into public.customer_payments (
    business_id,
    invoice_id,
    payment_date,
    amount,
    reference,
    notes,
    payment_source,
    stripe_payment_intent_id,
    stripe_checkout_session_id,
    invoice_payment_transaction_id,
    currency
  ) values (
    v_tx.business_id,
    v_tx.invoice_id,
    coalesce(p_payment_date, current_date),
    v_tx.amount,
    v_reference,
    'Recorded automatically from a verified Stripe Connect payment.',
    'stripe_connect',
    v_tx.stripe_payment_intent_id,
    v_tx.stripe_checkout_session_id,
    v_tx.id,
    upper(v_tx.currency)
  )
  returning id into v_payment_id;

  update public.invoice_payment_transactions
  set status = 'succeeded',
      customer_payment_id = v_payment_id,
      payment_date = coalesce(payment_date, now()),
      updated_at = now()
  where id = v_tx.id;

  return jsonb_build_object(
    'transaction_id', v_tx.id,
    'status', 'succeeded',
    'customer_payment_id', v_payment_id,
    'remaining_balance', greatest(0, v_outstanding - v_tx.amount)
  );
exception
  when unique_violation then
    select * into v_tx
    from public.invoice_payment_transactions
    where id = p_transaction_id;
    return jsonb_build_object(
      'transaction_id', p_transaction_id,
      'status', coalesce(v_tx.status, 'needs_review'),
      'customer_payment_id', v_tx.customer_payment_id,
      'already_recorded', true
    );
end;
$function$;

revoke execute on function public.v6181_record_online_invoice_payment(uuid,date,text) from public, anon, authenticated;
grant execute on function public.v6181_record_online_invoice_payment(uuid,date,text) to service_role;
