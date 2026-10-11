-- v61.108C: payment exception accounting and stale checkout cleanup.
--
-- Stripe refund events now create auditably linked credit note/refund records and
-- posted journals. Abandoned Checkout sessions that never produced a payment
-- intent are moved out of processing without touching successful payments.

insert into public.accounting_accounts (
  business_id, account_code, account_name, account_type, normal_balance,
  report_section, system_key, system_account_key, xero_account_code,
  xero_account_type, description, is_system, is_control, allow_manual_posting
)
select
  b.id, x.account_code, x.account_name, x.account_type, x.normal_balance,
  x.report_section, x.system_key, x.system_account_key, x.xero_account_code,
  x.xero_account_type, x.description, true, x.is_control, x.allow_manual_posting
from public.businesses b
cross join (values
  ('1100','Accounts Receivable','asset','debit','asset','accounts_receivable','accounts_receivable','1100','CURRENT','Customer invoice receivables.',true,false),
  ('2100','GST Payable','liability','credit','liability','gst_collected','gst_collected','2100','CURRLIAB','GST collected on sales and credit notes.',true,false),
  ('4000','Sales','revenue','credit','income','sales','sales','4000','REVENUE','Sales income.',false,true)
) as x(account_code,account_name,account_type,normal_balance,report_section,system_key,system_account_key,xero_account_code,xero_account_type,description,is_control,allow_manual_posting)
where not exists (
  select 1
  from public.accounting_accounts a
  where a.business_id = b.id
    and a.account_code = x.account_code
);

create or replace function public.v61108_record_stripe_refund_accounting(
  p_transaction_id uuid,
  p_refund_amount numeric,
  p_refund_date date default current_date,
  p_reference text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx public.invoice_payment_transactions%rowtype;
  v_invoice public.invoices%rowtype;
  v_refund_amount numeric := round(coalesce(p_refund_amount, 0), 2);
  v_ex_gst numeric;
  v_gst numeric;
  v_cn_id uuid;
  v_refund_id uuid;
  v_cn_journal uuid;
  v_refund_journal uuid;
  v_cn_lines jsonb;
  v_sales uuid;
  v_gst_output uuid;
  v_ar uuid;
  v_clearing uuid;
  v_suffix text;
  v_ref text;
begin
  select * into v_tx
  from public.invoice_payment_transactions
  where id = p_transaction_id
  for update;

  if v_tx.id is null then
    raise exception 'Online payment transaction not found';
  end if;

  select * into v_invoice
  from public.invoices
  where id = v_tx.invoice_id
    and business_id = v_tx.business_id
  for update;

  if v_invoice.id is null then
    raise exception 'Invoice was not found for the refunded payment';
  end if;

  if v_invoice.customer_id is null then
    raise exception 'Refund accounting requires the invoice to have a customer record';
  end if;

  if v_refund_amount <= 0 then
    raise exception 'Refund amount must be greater than zero';
  end if;

  if lower(coalesce(v_tx.currency, 'nzd')) <> lower(coalesce(nullif(v_invoice.company_snapshot->>'currency',''), 'nzd')) then
    raise exception 'Refund currency does not match the invoice currency';
  end if;

  if exists (
    select 1
    from public.accounting_periods p
    where p.business_id = v_tx.business_id
      and p.status <> 'open'
      and coalesce(p_refund_date, current_date) between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this refund is locked';
  end if;

  select id into v_cn_id
  from public.customer_credit_notes
  where business_id = v_tx.business_id
    and idempotency_key = v_tx.id;

  select id into v_refund_id
  from public.customer_refunds
  where business_id = v_tx.business_id
    and idempotency_key = v_tx.id;

  select id into v_cn_journal
  from public.accounting_journals
  where business_id = v_tx.business_id
    and source_type = 'stripe_refund_credit_note'
    and source_id = v_tx.id
    and status in ('posted','reversed')
  limit 1;

  select id into v_refund_journal
  from public.accounting_journals
  where business_id = v_tx.business_id
    and source_type = 'stripe_refund'
    and source_id = v_tx.id
    and status in ('posted','reversed')
  limit 1;

  if v_cn_id is not null and v_refund_id is not null and v_cn_journal is not null and v_refund_journal is not null then
    return jsonb_build_object(
      'ok', true,
      'already_recorded', true,
      'credit_note_id', v_cn_id,
      'refund_id', v_refund_id,
      'credit_note_journal_id', v_cn_journal,
      'refund_journal_id', v_refund_journal
    );
  end if;

  v_suffix := upper(left(replace(v_tx.id::text, '-', ''), 10));
  v_ref := coalesce(nullif(btrim(p_reference), ''), coalesce(v_tx.stripe_charge_id, v_tx.stripe_payment_intent_id, 'Stripe refund'));

  v_gst := case
    when coalesce(v_invoice.total, 0) > 0
      then round(v_refund_amount * coalesce(v_invoice.gst, 0) / v_invoice.total, 2)
    else 0
  end;
  v_ex_gst := round(v_refund_amount - v_gst, 2);

  if v_cn_id is null then
    insert into public.customer_credit_notes(
      business_id,
      original_invoice_id,
      customer_id,
      credit_note_number,
      credit_date,
      reason,
      credit_type,
      currency,
      ex_gst,
      gst_amount,
      total_amount,
      lifecycle_state,
      issued_at,
      idempotency_key
    ) values (
      v_tx.business_id,
      v_invoice.id,
      v_invoice.customer_id,
      'CN-STRIPE-' || v_suffix,
      coalesce(p_refund_date, current_date),
      'Stripe refund for ' || coalesce(v_invoice.invoice_number, 'invoice'),
      case when v_refund_amount >= round(coalesce(v_invoice.total, 0), 2) then 'full' else 'partial' end,
      upper(coalesce(v_tx.currency, 'NZD')),
      v_ex_gst,
      v_gst,
      v_refund_amount,
      'issued',
      now(),
      v_tx.id
    )
    returning id into v_cn_id;

    insert into public.customer_credit_note_lines(
      business_id,
      credit_note_id,
      description,
      quantity,
      unit_amount,
      ex_gst,
      gst_amount,
      total_amount,
      tax_rate,
      tax_code,
      source_detail
    ) values (
      v_tx.business_id,
      v_cn_id,
      'Stripe refund',
      1,
      v_ex_gst,
      v_ex_gst,
      v_gst,
      v_refund_amount,
      case when v_gst > 0 and v_ex_gst > 0 then round(v_gst / v_ex_gst * 100, 4) else 0 end,
      case when v_gst > 0 then 'GST' else 'NO_GST' end,
      jsonb_build_object('invoice_payment_transaction_id', v_tx.id, 'reference', v_ref)
    );
  end if;

  if v_refund_id is null then
    insert into public.customer_refunds(
      business_id,
      customer_id,
      refund_number,
      refund_date,
      amount,
      currency,
      method,
      reference,
      notes,
      lifecycle_state,
      idempotency_key,
      recorded_at
    ) values (
      v_tx.business_id,
      v_invoice.customer_id,
      'RF-STRIPE-' || v_suffix,
      coalesce(p_refund_date, current_date),
      v_refund_amount,
      upper(coalesce(v_tx.currency, 'NZD')),
      'card',
      v_ref,
      'Recorded automatically from a Stripe refund event.',
      'recorded',
      v_tx.id,
      now()
    )
    returning id into v_refund_id;
  end if;

  v_sales := (
    select id from public.accounting_accounts
    where business_id = v_tx.business_id
      and not coalesce(archived, false)
      and (system_key = 'sales' or system_account_key = 'sales' or account_code in ('200','4000'))
    order by case when system_key = 'sales' or system_account_key = 'sales' then 0 else 1 end, account_code
    limit 1
  );
  v_gst_output := (
    select id from public.accounting_accounts
    where business_id = v_tx.business_id
      and not coalesce(archived, false)
      and (system_key in ('gst_collected','gst_payable') or system_account_key in ('gst_collected','gst_payable') or account_code in ('260','2100'))
    order by case when system_key = 'gst_collected' or system_account_key = 'gst_collected' then 0 else 1 end, account_code
    limit 1
  );
  v_ar := (
    select id from public.accounting_accounts
    where business_id = v_tx.business_id
      and not coalesce(archived, false)
      and (system_key = 'accounts_receivable' or system_account_key = 'accounts_receivable' or account_code in ('120','1100'))
    order by case when system_key = 'accounts_receivable' or system_account_key = 'accounts_receivable' then 0 else 1 end, account_code
    limit 1
  );
  v_clearing := coalesce(
    public.v6170b_account(v_tx.business_id, 'payment_clearing'),
    (select id from public.accounting_accounts where business_id = v_tx.business_id and system_key = 'payment_clearing' and not coalesce(archived,false) order by account_code limit 1)
  );

  if v_sales is null or v_ar is null or v_clearing is null or (v_gst > 0 and v_gst_output is null) then
    raise exception 'Refund accounting accounts are not available';
  end if;

  if v_cn_journal is null then
    v_cn_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_sales, 'description', 'Reverse sales for Stripe refund', 'debit', v_ex_gst, 'credit', 0, 'tax_code', case when v_gst > 0 then 'GST' else 'NO_GST' end, 'tax_rate', case when v_ex_gst > 0 then round(v_gst / v_ex_gst * 100, 4) else 0 end, 'tax_amount', v_gst, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id),
      jsonb_build_object('account_id', v_ar, 'description', 'Credit customer receivable', 'debit', 0, 'credit', v_refund_amount, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id)
    );
    if v_gst > 0 then
      v_cn_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_sales, 'description', 'Reverse sales for Stripe refund', 'debit', v_ex_gst, 'credit', 0, 'tax_code', 'GST', 'tax_rate', case when v_ex_gst > 0 then round(v_gst / v_ex_gst * 100, 4) else 0 end, 'tax_amount', v_gst, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id),
        jsonb_build_object('account_id', v_gst_output, 'description', 'Reverse GST for Stripe refund', 'debit', v_gst, 'credit', 0, 'tax_code', 'GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id),
        jsonb_build_object('account_id', v_ar, 'description', 'Credit customer receivable', 'debit', 0, 'credit', v_refund_amount, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id)
      );
    end if;

    v_cn_journal := public.v6192_create_posted_journal(
      v_tx.business_id,
      coalesce(p_refund_date, current_date),
      'credit_note',
      'stripe_refund_credit_note',
      v_tx.id,
      'CN-STRIPE-' || v_suffix,
      'Stripe refund credit note for ' || coalesce(v_invoice.invoice_number, 'invoice'),
      v_cn_lines
    );
  end if;

  if v_refund_journal is null then
    v_refund_journal := public.v6192_create_posted_journal(
      v_tx.business_id,
      coalesce(p_refund_date, current_date),
      'customer_refund',
      'stripe_refund',
      v_tx.id,
      'RF-STRIPE-' || v_suffix,
      'Stripe refund paid from clearing for ' || coalesce(v_invoice.invoice_number, 'invoice'),
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar, 'description', 'Apply customer refund', 'debit', v_refund_amount, 'credit', 0, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id),
        jsonb_build_object('account_id', v_clearing, 'description', 'Stripe refund deducted from clearing', 'debit', 0, 'credit', v_refund_amount, 'tax_code', 'NO_GST', 'tax_rate', 0, 'tax_amount', 0, 'customer_id', v_invoice.customer_id, 'job_costing_id', v_invoice.job_costing_id)
      )
    );
  end if;

  update public.invoice_payment_transactions
  set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'stripe_refund_accounting_recorded_at', now(),
        'stripe_refund_credit_note_id', v_cn_id,
        'stripe_refund_id', v_refund_id,
        'stripe_refund_credit_note_journal_id', v_cn_journal,
        'stripe_refund_journal_id', v_refund_journal
      ),
      updated_at = now()
  where id = v_tx.id;

  return jsonb_build_object(
    'ok', true,
    'credit_note_id', v_cn_id,
    'refund_id', v_refund_id,
    'credit_note_journal_id', v_cn_journal,
    'refund_journal_id', v_refund_journal
  );
end;
$$;

revoke execute on function public.v61108_record_stripe_refund_accounting(uuid,numeric,date,text) from public, anon, authenticated;
grant execute on function public.v61108_record_stripe_refund_accounting(uuid,numeric,date,text) to service_role;

update public.invoice_payment_transactions
set status = 'failed',
    failure_reason = 'Checkout was abandoned before Stripe created a payment intent.',
    metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('stale_processing_cleanup_at', now()),
    updated_at = now()
where status = 'processing'
  and customer_payment_id is null
  and stripe_payment_intent_id is null
  and updated_at < now() - interval '30 minutes';

update public.invoice_payment_transactions
set status = 'needs_review',
    failure_reason = 'Payment stayed in processing after Stripe created a payment intent. Verify Stripe before changing the invoice.',
    metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('stale_processing_review_at', now()),
    updated_at = now()
where status = 'processing'
  and customer_payment_id is null
  and stripe_payment_intent_id is not null
  and updated_at < now() - interval '30 minutes';
