-- v61.108: Stripe Connect invoice payment accounting.
--
-- Online invoice payments now post through Payment Clearing instead of direct
-- bank. The gross Stripe charge clears Accounts Receivable, customer-paid
-- processing fees are recognised separately, and Stripe fees are expensed so
-- the remaining clearing balance matches the future net payout.

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
  ('1050','Payment Clearing','asset','debit','asset','payment_clearing','payment_clearing','1050','CURRENT','Temporary clearing account for Stripe, refunds and bank settlement timing.',true,false),
  ('4150','Payment Fee Recoveries','revenue','credit','income','payment_fee_recovery','payment_fee_recovery','4150','REVENUE','Customer-paid payment processing fee recoveries.',false,true),
  ('6300','Stripe Fees','expense','debit','operating_expenses','stripe_fee_expense','stripe_fee_expense','6300','EXPENSE','Stripe card and platform processing fees.',false,true)
) as x(account_code,account_name,account_type,normal_balance,report_section,system_key,system_account_key,xero_account_code,xero_account_type,description,is_control,allow_manual_posting)
where not exists (
  select 1
  from public.accounting_accounts a
  where a.business_id = b.id
    and a.account_code = x.account_code
);

update public.accounting_accounts a
set system_key = coalesce(a.system_key, x.system_key),
    system_account_key = coalesce(a.system_account_key, x.system_account_key),
    updated_at = now()
from (values
  ('1050','payment_clearing','payment_clearing'),
  ('4150','payment_fee_recovery','payment_fee_recovery'),
  ('6300','stripe_fee_expense','stripe_fee_expense')
) as x(account_code,system_key,system_account_key)
where a.account_code = x.account_code
  and (a.system_key is null or a.system_account_key is null);

do $$
declare
  d text;
  old_customer_payment text;
  new_customer_payment text;
begin
  select pg_get_functiondef(p.oid)
    into d
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'v6192_post_operational_ledger';

  if d is null then
    raise exception 'v6192_post_operational_ledger was not found';
  end if;

  if position('v_stripe_fee_expense uuid' in d) = 0 then
    d := replace(
      d,
      '  v_expense_fallback uuid;
  v_fixed_assets uuid;',
      '  v_expense_fallback uuid;
  v_payment_clearing uuid;
  v_stripe_fee_expense uuid;
  v_payment_fee_recovery uuid;
  v_fixed_assets uuid;'
    );
  end if;

  if position('v_payment_clearing :=' in d) = 0 then
    d := replace(
      d,
      '  v_ar := public.v61105_account_role_id(v_business_id,''accounts_receivable'');',
      '  insert into public.accounting_accounts(
    business_id, account_code, account_name, account_type, normal_balance,
    report_section, system_key, system_account_key, xero_account_code,
    xero_account_type, description, is_system, is_control, allow_manual_posting,
    created_by, updated_by
  ) values
    (v_business_id,''1050'',''Payment Clearing'',''asset'',''debit'',''asset'',''payment_clearing'',''payment_clearing'',''1050'',''CURRENT'',''Temporary clearing account for Stripe, refunds and bank settlement timing.'',true,true,false,v_user,v_user),
    (v_business_id,''4150'',''Payment Fee Recoveries'',''revenue'',''credit'',''income'',''payment_fee_recovery'',''payment_fee_recovery'',''4150'',''REVENUE'',''Customer-paid payment processing fee recoveries.'',true,false,true,v_user,v_user),
    (v_business_id,''6300'',''Stripe Fees'',''expense'',''debit'',''operating_expenses'',''stripe_fee_expense'',''stripe_fee_expense'',''6300'',''EXPENSE'',''Stripe card and platform processing fees.'',true,false,true,v_user,v_user)
  on conflict (business_id, account_code) do nothing;

  v_ar := public.v61105_account_role_id(v_business_id,''accounts_receivable'');'
    );

    d := replace(
      d,
      '  v_expense_fallback := public.v61105_account_role_id(v_business_id,''general_expense'');',
      '  v_expense_fallback := public.v61105_account_role_id(v_business_id,''general_expense'');
  v_payment_clearing := coalesce(
    public.v6170b_account(v_business_id,''payment_clearing''),
    (select id from public.accounting_accounts where business_id=v_business_id and system_key=''payment_clearing'' and not coalesce(archived,false) order by account_code limit 1)
  );
  v_stripe_fee_expense := coalesce(
    public.v6170b_account(v_business_id,''stripe_fee_expense''),
    (select id from public.accounting_accounts where business_id=v_business_id and system_key=''stripe_fee_expense'' and not coalesce(archived,false) order by account_code limit 1),
    v_expense_fallback
  );
  v_payment_fee_recovery := coalesce(
    public.v6170b_account(v_business_id,''payment_fee_recovery''),
    (select id from public.accounting_accounts where business_id=v_business_id and system_key=''payment_fee_recovery'' and not coalesce(archived,false) order by account_code limit 1),
    v_sales
  );'
    );
  end if;

  old_customer_payment := $old$
    select p.*, i.invoice_number, i.customer_id, i.job_costing_id
    from public.customer_payments p
    join public.invoices i on i.id = p.invoice_id and i.business_id = p.business_id
    where p.business_id = v_business_id
      and p.payment_date between p_from and p_to
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'customer_payment'
          and j.source_id = p.id
          and j.status in ('posted','reversed')
      )
    order by p.payment_date, p.created_at
  loop
    v_amount := round(coalesce(r.amount,0),2);
    if v_amount > 0 then
      v_posted := public.v6192_create_posted_journal(
        v_business_id,r.payment_date,'customer_payment','customer_payment',r.id,coalesce(r.reference,r.invoice_number),'Customer payment for '||coalesce(r.invoice_number,'invoice'),
        jsonb_build_array(
          jsonb_build_object('account_id',v_bank,'description','Customer payment','debit',v_amount,'credit',0,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id),
          jsonb_build_object('account_id',v_ar,'description','Clear receivable','debit',0,'credit',v_amount,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id)
        )
      );
      v_customer_payment_count := v_customer_payment_count + 1;
    end if;
  end loop;
$old$;

  new_customer_payment := $new$
    select
      p.*,
      i.invoice_number,
      i.customer_id,
      i.job_costing_id,
      t.gross_amount,
      t.customer_fee_amount,
      t.stripe_fee_amount,
      t.net_amount,
      t.status as online_payment_status
    from public.customer_payments p
    join public.invoices i on i.id = p.invoice_id and i.business_id = p.business_id
    left join public.invoice_payment_transactions t
      on t.customer_payment_id = p.id
     and t.business_id = p.business_id
     and t.status = 'succeeded'
    where p.business_id = v_business_id
      and p.payment_date between p_from and p_to
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'customer_payment'
          and j.source_id = p.id
          and j.status in ('posted','reversed')
      )
    order by p.payment_date, p.created_at
  loop
    v_amount := round(coalesce(r.amount,0),2);
    if v_amount > 0 then
      if r.payment_source = 'stripe_connect'
         and r.online_payment_status = 'succeeded'
         and v_payment_clearing is not null then
        v_lines := jsonb_build_array(
          jsonb_build_object(
            'account_id',v_payment_clearing,
            'description','Stripe gross charge',
            'debit',round(greatest(coalesce(r.gross_amount,r.amount),r.amount),2),
            'credit',0,
            'tax_code','NO_GST',
            'tax_rate',0,
            'tax_amount',0,
            'customer_id',r.customer_id,
            'job_costing_id',r.job_costing_id
          ),
          jsonb_build_object(
            'account_id',v_ar,
            'description','Clear receivable',
            'debit',0,
            'credit',v_amount,
            'tax_code','NO_GST',
            'tax_rate',0,
            'tax_amount',0,
            'customer_id',r.customer_id,
            'job_costing_id',r.job_costing_id
          )
        );

        if round(coalesce(r.customer_fee_amount,0),2) > 0 then
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'account_id',v_payment_fee_recovery,
            'description','Customer-paid payment processing fee',
            'debit',0,
            'credit',round(coalesce(r.customer_fee_amount,0),2),
            'tax_code','NO_GST',
            'tax_rate',0,
            'tax_amount',0,
            'customer_id',r.customer_id,
            'job_costing_id',r.job_costing_id
          ));
        end if;

        if round(coalesce(r.stripe_fee_amount,0),2) > 0 then
          v_lines := v_lines || jsonb_build_array(
            jsonb_build_object(
              'account_id',v_stripe_fee_expense,
              'description','Stripe processing fee',
              'debit',round(coalesce(r.stripe_fee_amount,0),2),
              'credit',0,
              'tax_code','NO_GST',
              'tax_rate',0,
              'tax_amount',0,
              'customer_id',r.customer_id,
              'job_costing_id',r.job_costing_id
            ),
            jsonb_build_object(
              'account_id',v_payment_clearing,
              'description','Stripe fee deducted before payout',
              'debit',0,
              'credit',round(coalesce(r.stripe_fee_amount,0),2),
              'tax_code','NO_GST',
              'tax_rate',0,
              'tax_amount',0,
              'customer_id',r.customer_id,
              'job_costing_id',r.job_costing_id
            )
          );
        end if;

        v_posted := public.v6192_create_posted_journal(
          v_business_id,
          r.payment_date,
          'customer_payment',
          'customer_payment',
          r.id,
          coalesce(r.reference,r.invoice_number),
          'Stripe payment for '||coalesce(r.invoice_number,'invoice'),
          v_lines
        );
      else
        v_posted := public.v6192_create_posted_journal(
          v_business_id,r.payment_date,'customer_payment','customer_payment',r.id,coalesce(r.reference,r.invoice_number),'Customer payment for '||coalesce(r.invoice_number,'invoice'),
          jsonb_build_array(
            jsonb_build_object('account_id',v_bank,'description','Customer payment','debit',v_amount,'credit',0,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id),
            jsonb_build_object('account_id',v_ar,'description','Clear receivable','debit',0,'credit',v_amount,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id)
          )
        );
      end if;
      v_customer_payment_count := v_customer_payment_count + 1;
    end if;
  end loop;
$new$;

  if position(old_customer_payment in d) = 0 and position('Stripe gross charge' in d) = 0 then
    raise exception 'Customer payment posting block did not match expected v6192 source';
  end if;

  if position('Stripe gross charge' in d) = 0 then
    d := replace(d, old_customer_payment, new_customer_payment);
  end if;

  execute d;
end$$;

alter table if exists public.bank_reconciliation_allocations
  add column if not exists invoice_payment_transaction_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'bank_reconciliation_allocations_invoice_payment_tx_fk'
      and conrelid = 'public.bank_reconciliation_allocations'::regclass
  ) then
    alter table public.bank_reconciliation_allocations
      add constraint bank_reconciliation_allocations_invoice_payment_tx_fk
      foreign key (invoice_payment_transaction_id)
      references public.invoice_payment_transactions(id)
      on delete restrict;
  end if;
end$$;

do $$
declare
  c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.bank_reconciliation_allocations'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%allocation_type%'
  loop
    execute format('alter table public.bank_reconciliation_allocations drop constraint %I', c.conname);
  end loop;
end$$;

alter table if exists public.bank_reconciliation_allocations
  add constraint bank_reconciliation_allocations_allocation_type_ck
  check (allocation_type in (
    'invoice',
    'expense',
    'transfer',
    'customer_refund',
    'supplier_refund',
    'payroll_pay_run',
    'owner_equity',
    'expense_deposit_refund',
    'stripe_payout'
  ));

create or replace function public.v61108_reconcile_stripe_payout_bank_transaction(
  p_bank_transaction_id uuid,
  p_transaction_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_bank uuid;
  v_clearing uuid;
  v_total numeric := 0;
  v_journal uuid;
  v_ids uuid[];
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select array(select distinct unnest(coalesce(p_transaction_ids,'{}'::uuid[]))) into v_ids;
  if coalesce(array_length(v_ids,1),0) = 0 then
    raise exception 'Choose at least one Stripe payment to match to this payout';
  end if;

  select * into v_tx
  from public.bank_transactions
  where id = p_bank_transaction_id and business_id = v_bid
  for update;

  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;
  if coalesce(v_tx.amount,0) <= 0 then raise exception 'Stripe payouts must be matched to a money-in bank transaction'; end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and v_tx.transaction_date between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this bank transaction is locked';
  end if;

  select coalesce(round(sum(
    coalesce(t.net_amount, t.gross_amount - coalesce(t.stripe_fee_amount,0), t.gross_amount)
  ),2),0)
  into v_total
  from public.invoice_payment_transactions t
  where t.business_id = v_bid
    and t.id = any(v_ids)
    and t.status = 'succeeded'
    and t.customer_payment_id is not null
    and not exists (
      select 1
      from public.bank_reconciliation_allocations a
      where a.business_id = v_bid
        and a.allocation_type = 'stripe_payout'
        and a.invoice_payment_transaction_id = t.id
    );

  if round(v_total,2) <> round(v_tx.amount,2) then
    raise exception 'Selected Stripe payments total %, but the bank payout is %', v_total, v_tx.amount;
  end if;

  v_bank := public.v61105_account_role_id(v_bid,'bank');
  v_clearing := coalesce(
    public.v6170b_account(v_bid,'payment_clearing'),
    (select id from public.accounting_accounts where business_id=v_bid and system_key='payment_clearing' and not coalesce(archived,false) order by account_code limit 1)
  );

  if v_bank is null or v_clearing is null then
    raise exception 'Bank or payment clearing account is not available';
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    v_tx.transaction_date,
    'bank',
    'stripe_payout',
    v_tx.id,
    coalesce(nullif(v_tx.reference,''),'Stripe payout'),
    'Stripe payout matched to online payments',
    jsonb_build_array(
      jsonb_build_object('account_id',v_bank,'description','Stripe payout received','debit',v_total,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_clearing,'description','Clear Stripe payment clearing','debit',0,'credit',v_total,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    )
  );

  insert into public.bank_reconciliation_allocations(
    business_id,
    bank_transaction_id,
    allocation_type,
    amount,
    invoice_payment_transaction_id,
    accounting_journal_id,
    created_by
  )
  select
    v_bid,
    v_tx.id,
    'stripe_payout',
    round(coalesce(t.net_amount, t.gross_amount - coalesce(t.stripe_fee_amount,0), t.gross_amount),2),
    t.id,
    v_journal,
    v_uid
  from public.invoice_payment_transactions t
  where t.business_id = v_bid
    and t.id = any(v_ids)
    and t.status = 'succeeded'
    and t.customer_payment_id is not null;

  update public.bank_transactions
  set status = 'reconciled',
      reconciliation_type = 'stripe_payout',
      reconciled_at = now(),
      reconciled_by = v_uid,
      updated_at = now(),
      updated_by = v_uid
  where id = v_tx.id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid,
    v_tx.id,
    'stripe_payout_reconciled',
    jsonb_build_object('journal_id',v_journal,'amount',v_total,'transaction_ids',to_jsonb(v_ids)),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'amount',v_total,'matched_count',array_length(v_ids,1));
end;
$$;

revoke execute on function public.v61108_reconcile_stripe_payout_bank_transaction(uuid,uuid[]) from public, anon;
grant execute on function public.v61108_reconcile_stripe_payout_bank_transaction(uuid,uuid[]) to authenticated;

create or replace function public.v61108_undo_stripe_payout_bank_transaction(
  p_bank_transaction_id uuid,
  p_reason text default 'Undo Stripe payout bank reconciliation'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_alloc record;
  v_reversal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select *
  into v_alloc
  from public.bank_reconciliation_allocations
  where business_id = v_bid
    and bank_transaction_id = p_bank_transaction_id
    and allocation_type = 'stripe_payout'
    and accounting_journal_id is not null
  order by created_at desc
  limit 1;

  if v_alloc.bank_transaction_id is null then
    raise exception 'Stripe payout reconciliation was not found for this bank transaction';
  end if;

  if to_regprocedure('public.v6170a_reverse_journal(uuid,text)') is null then
    raise exception 'Journal reversal function is not available; Stripe payout reconciliation was not undone';
  end if;

  execute 'select public.v6170a_reverse_journal($1,$2)'
    into v_reversal
    using v_alloc.accounting_journal_id, coalesce(nullif(btrim(p_reason),''),'Undo Stripe payout bank reconciliation');

  delete from public.bank_reconciliation_allocations
  where business_id = v_bid
    and bank_transaction_id = p_bank_transaction_id
    and allocation_type = 'stripe_payout';

  update public.bank_transactions
  set status = 'unreconciled',
      reconciliation_type = null,
      reconciled_at = null,
      reconciled_by = null,
      updated_at = now(),
      updated_by = v_uid
  where id = p_bank_transaction_id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid,
    p_bank_transaction_id,
    'stripe_payout_undo',
    jsonb_build_object('journal_id',v_alloc.accounting_journal_id,'reversal_journal_id',v_reversal,'reason',p_reason),
    v_uid
  );

  return jsonb_build_object('ok',true,'reversal_journal_id',v_reversal);
end;
$$;

revoke execute on function public.v61108_undo_stripe_payout_bank_transaction(uuid,text) from public, anon;
grant execute on function public.v61108_undo_stripe_payout_bank_transaction(uuid,text) to authenticated;
