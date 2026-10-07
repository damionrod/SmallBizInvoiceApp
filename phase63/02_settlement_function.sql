-- DISPOSABLE TEST DATABASE ONLY. Reconstructed from read-only production pg_get_functiondef.
-- Phase46 exception guard and Phase50 succeeded-branch guard; TEST FIXTURE ONLY, NOT production.
-- DISPOSABLE FIXTURE ONLY: one shared predicate prevents divergent duplicate acknowledgements.
CREATE OR REPLACE FUNCTION public.v6181_fixture_payment_link_verified(p_tx public.invoice_payment_transactions)
RETURNS boolean LANGUAGE sql STABLE SET search_path TO 'public' AS $verify$
 SELECT p_tx.status = 'succeeded'
   AND p_tx.customer_payment_id IS NOT NULL
   AND EXISTS (
     SELECT 1 FROM public.customer_payments cp
     WHERE cp.id = p_tx.customer_payment_id
       AND cp.invoice_payment_transaction_id = p_tx.id
       AND cp.business_id = p_tx.business_id
       AND cp.invoice_id = p_tx.invoice_id
       AND cp.payment_source = 'stripe_connect'
       AND cp.amount = p_tx.amount
       AND upper(coalesce(cp.currency, '')) = upper(p_tx.currency)
       AND cp.stripe_payment_intent_id IS NOT DISTINCT FROM p_tx.stripe_payment_intent_id
       AND cp.stripe_checkout_session_id IS NOT DISTINCT FROM p_tx.stripe_checkout_session_id
   );
$verify$;

CREATE OR REPLACE FUNCTION public.v6181_record_online_invoice_payment(p_transaction_id uuid, p_payment_date date DEFAULT CURRENT_DATE, p_reference text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
declare
  v_tx public.invoice_payment_transactions%rowtype;
  v_invoice public.invoices%rowtype;
  v_paid numeric := 0;
  v_outstanding numeric := 0;
  v_payment_id uuid;
  v_reference text;
begin
  select * into v_tx from public.invoice_payment_transactions where id = p_transaction_id for update;
  if v_tx.id is null then raise exception 'Online payment transaction not found'; end if;
  -- Fixture-only backend defence: do not settle an unbound Stripe transaction.
  if nullif(btrim(coalesce(v_tx.stripe_payment_intent_id, '')), '') is null
     and nullif(btrim(coalesce(v_tx.stripe_checkout_session_id, '')), '') is null then
    raise exception 'Online payment has no Stripe payment identity';
  end if;
  if v_tx.status = 'succeeded' then
    if not public.v6181_fixture_payment_link_verified(v_tx) then
      raise exception 'Succeeded online payment has no matching customer payment record';
    end if;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'succeeded',
      'customer_payment_id', v_tx.customer_payment_id, 'already_recorded', true);
  end if;
  select * into v_invoice from public.invoices
    where id = v_tx.invoice_id and business_id = v_tx.business_id for update;
  if v_invoice.id is null then
    update public.invoice_payment_transactions set status = 'needs_review', failure_reason = 'Invoice was not found for the payment.', updated_at = now() where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;
  if coalesce(v_invoice.lifecycle_state, 'issued') = 'voided' then
    update public.invoice_payment_transactions set status = 'needs_review', failure_reason = 'Payment received for a voided invoice.', updated_at = now() where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review');
  end if;
  select coalesce(sum(cp.amount), 0) into v_paid from public.customer_payments cp where cp.invoice_id = v_invoice.id;
  v_outstanding := greatest(0, coalesce(v_invoice.total, 0) - v_paid);
  if v_tx.amount > v_outstanding + 0.005 then
    update public.invoice_payment_transactions set status = 'needs_review',
      failure_reason = format('Payment amount %s exceeds the remaining invoice balance %s.', v_tx.amount, v_outstanding), updated_at = now() where id = v_tx.id;
    return jsonb_build_object('transaction_id', v_tx.id, 'status', 'needs_review', 'remaining_balance', v_outstanding);
  end if;
  v_reference := coalesce(nullif(trim(p_reference), ''), 'Stripe Connect online payment');
  insert into public.customer_payments (business_id, invoice_id, payment_date, amount, reference, notes, payment_source,
    stripe_payment_intent_id, stripe_checkout_session_id, invoice_payment_transaction_id, currency)
  values (v_tx.business_id, v_tx.invoice_id, coalesce(p_payment_date, current_date), v_tx.amount, v_reference,
    'Recorded automatically from a verified Stripe Connect payment.', 'stripe_connect', v_tx.stripe_payment_intent_id,
    v_tx.stripe_checkout_session_id, v_tx.id, upper(v_tx.currency)) returning id into v_payment_id;
  update public.invoice_payment_transactions set status = 'succeeded', customer_payment_id = v_payment_id,
    payment_date = coalesce(payment_date, now()), updated_at = now() where id = v_tx.id;
  return jsonb_build_object('transaction_id', v_tx.id, 'status', 'succeeded', 'customer_payment_id', v_payment_id,
    'remaining_balance', greatest(0, v_outstanding - v_tx.amount));
exception when unique_violation then
  select * into v_tx from public.invoice_payment_transactions where id = p_transaction_id;
  if public.v6181_fixture_payment_link_verified(v_tx) then
    return jsonb_build_object('transaction_id', p_transaction_id, 'status', 'succeeded',
      'customer_payment_id', v_tx.customer_payment_id, 'already_recorded', true);
  end if;
  raise;
end;
$function$;
