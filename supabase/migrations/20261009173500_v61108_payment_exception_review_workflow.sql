-- v61.108D: Super Admin payment exception review workflow.
--
-- Adds a safe review-note action for Stripe invoice payment exceptions. This
-- records what was checked without changing invoice balances or payment status.

create or replace function public.v61108_admin_note_invoice_payment_exception(
  p_transaction_id uuid,
  p_note text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_is_super_admin boolean := false;
  v_tx public.invoice_payment_transactions%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if v_uid is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(is_super_admin, false)
  into v_is_super_admin
  from public.profiles
  where id = v_uid;

  if not coalesce(v_is_super_admin, false) then
    raise exception 'Super Admin access required';
  end if;

  if v_note is null then
    raise exception 'Review note is required';
  end if;

  select * into v_tx
  from public.invoice_payment_transactions
  where id = p_transaction_id
  for update;

  if v_tx.id is null then
    raise exception 'Invoice payment transaction not found';
  end if;

  if coalesce(v_tx.status, '') not in ('needs_review','refunded','partially_refunded','disputed','failed') then
    raise exception 'Only exception payment statuses can be reviewed';
  end if;

  update public.invoice_payment_transactions
  set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'admin_review_note', v_note,
        'admin_reviewed_at', now(),
        'admin_reviewed_by', v_uid
      ),
      updated_at = now()
  where id = v_tx.id;

  return jsonb_build_object('ok', true, 'transaction_id', v_tx.id);
end;
$$;

revoke execute on function public.v61108_admin_note_invoice_payment_exception(uuid,text) from public, anon;
grant execute on function public.v61108_admin_note_invoice_payment_exception(uuid,text) to authenticated;

-- Guard old succeeded rows against duplicate legacy receipt replay. Current rows
-- already store receipt_sent_at when a receipt is sent; this marker only stops
-- old Stripe replays from sending a surprise duplicate.
update public.invoice_payment_transactions
set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
      'legacy_receipt_replay_guard_at', now()
    ),
    updated_at = now()
where status = 'succeeded'
  and customer_payment_id is not null
  and (coalesce(metadata, '{}'::jsonb) ? 'receipt_sent_at') = false
  and (coalesce(metadata, '{}'::jsonb) ? 'legacy_receipt_replay_guard_at') = false;
