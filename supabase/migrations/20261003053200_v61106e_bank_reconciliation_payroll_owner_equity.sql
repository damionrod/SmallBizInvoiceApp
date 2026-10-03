-- V61.106E: Bank reconciliation support for payroll cash matching and owner/equity movements.
-- This migration is append-only for existing records. It does not change invoice, expense, payroll or refund behaviour.

alter table if exists public.bank_reconciliation_allocations
  add column if not exists pay_run_id uuid,
  add column if not exists equity_transaction_type text,
  add column if not exists equity_note text,
  add column if not exists accounting_journal_id uuid;

do $$
declare
  c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid='public.bank_reconciliation_allocations'::regclass
      and contype='c'
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
    'owner_equity'
  ));

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='bank_reconciliation_allocations_pay_run_fk'
      and conrelid='public.bank_reconciliation_allocations'::regclass
  ) then
    alter table public.bank_reconciliation_allocations
      add constraint bank_reconciliation_allocations_pay_run_fk
      foreign key (pay_run_id) references public.payroll_pay_runs(id) on delete set null;
  end if;
  if to_regclass('public.accounting_journals') is not null and not exists (
    select 1 from pg_constraint
    where conname='bank_reconciliation_allocations_journal_fk'
      and conrelid='public.bank_reconciliation_allocations'::regclass
  ) then
    alter table public.bank_reconciliation_allocations
      add constraint bank_reconciliation_allocations_journal_fk
      foreign key (accounting_journal_id) references public.accounting_journals(id) on delete set null;
  end if;
end$$;

create or replace function public.v61106e_reconcile_owner_equity_bank_transaction(
  p_bank_transaction_id uuid,
  p_equity_type text,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_amount numeric;
  v_bank uuid;
  v_equity uuid;
  v_journal uuid;
  v_label text;
  v_lines jsonb := '[]'::jsonb;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx
  from public.bank_transactions
  where id=p_bank_transaction_id and business_id=v_bid
  for update;
  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;

  v_amount := round(abs(coalesce(v_tx.amount,0)),2);
  if v_amount <= 0 then raise exception 'Bank transaction amount is invalid'; end if;

  if v_tx.amount > 0 and p_equity_type not in ('owner_funds_introduced','director_loan_received','capital_contribution') then
    raise exception 'Choose a money-in owner/equity type for this bank deposit';
  end if;
  if v_tx.amount < 0 and p_equity_type not in ('owner_drawings','repay_owner_loan','director_payment','dividend_distribution') then
    raise exception 'Choose a money-out owner/equity type for this bank payment';
  end if;

  insert into public.accounting_accounts(
    business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,
    xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by
  ) values
    (v_bid,'310','Owner / Director Loan','liability','credit','liabilities','owner_director_loan','310','CURRLIAB','Temporary funds introduced by, or repaid to, owners/directors.',true,false,v_uid,v_uid),
    (v_bid,'800','Owner Capital Introduced','equity','credit','equity','owner_capital','800','EQUITY','Permanent owner capital introduced to the business.',true,false,v_uid,v_uid),
    (v_bid,'850','Owner Drawings / Distributions','equity','debit','equity','owner_drawings','850','EQUITY','Owner drawings, repayments and distributions that are not operating expenses.',true,false,v_uid,v_uid)
  on conflict (business_id,account_code) do nothing;

  select id into v_bank
  from public.accounting_accounts
  where business_id=v_bid and system_key='bank_main' and not archived
  order by account_code
  limit 1;

  select id into v_equity
  from public.accounting_accounts
  where business_id=v_bid
    and system_key = case
      when p_equity_type in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment') then 'owner_director_loan'
      when p_equity_type='capital_contribution' then 'owner_capital'
      else 'owner_drawings'
    end
    and not archived
  order by account_code
  limit 1;

  if v_bank is null or v_equity is null then
    raise exception 'Required bank/equity accounting accounts are not available';
  end if;

  v_label := case p_equity_type
    when 'owner_funds_introduced' then 'Owner funds introduced'
    when 'director_loan_received' then 'Director/shareholder loan received'
    when 'capital_contribution' then 'Capital contribution'
    when 'owner_drawings' then 'Owner drawings'
    when 'repay_owner_loan' then 'Repay owner/director loan'
    when 'director_payment' then 'Director/shareholder payment'
    when 'dividend_distribution' then 'Dividend / distribution'
    else 'Owner / equity movement'
  end;

  if v_tx.amount > 0 then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id',v_bank,'description',v_label,'debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_equity,'description',v_label,'debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    );
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id',v_equity,'description',v_label,'debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_bank,'description',v_label,'debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    );
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    v_tx.transaction_date,
    'bank_reconciliation',
    'owner_equity',
    v_tx.id,
    coalesce(nullif(v_tx.reference,''),'BANK-'||left(v_tx.id::text,8)),
    v_label,
    v_lines
  );

  insert into public.bank_reconciliation_allocations(
    business_id,bank_transaction_id,allocation_type,amount,equity_transaction_type,equity_note,accounting_journal_id,created_by
  ) values (
    v_bid,v_tx.id,'owner_equity',v_amount,p_equity_type,nullif(btrim(coalesce(p_note,'')),''),v_journal,v_uid
  );

  update public.bank_transactions
  set status='reconciled',
      reconciliation_type=p_equity_type,
      reconciled_at=now(),
      reconciled_by=v_uid,
      updated_at=now(),
      updated_by=v_uid
  where id=v_tx.id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(
    business_id,bank_transaction_id,action,details,created_by
  ) values (
    v_bid,
    v_tx.id,
    'owner_equity_reconciled',
    jsonb_build_object('equity_type',p_equity_type,'amount',v_amount,'journal_id',v_journal),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'equity_type',p_equity_type,'amount',v_amount);
end;
$$;

revoke execute on function public.v61106e_reconcile_owner_equity_bank_transaction(uuid,text,text) from public, anon;
grant execute on function public.v61106e_reconcile_owner_equity_bank_transaction(uuid,text,text) to authenticated;

create or replace function public.v61106e_undo_owner_equity_bank_transaction(
  p_bank_transaction_id uuid,
  p_reason text default 'Undo owner/equity bank reconciliation'
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
  where business_id=v_bid
    and bank_transaction_id=p_bank_transaction_id
    and allocation_type='owner_equity'
  order by created_at desc
  limit 1;

  if v_alloc.bank_transaction_id is null then
    raise exception 'Owner/equity reconciliation was not found for this bank transaction';
  end if;

  if v_alloc.accounting_journal_id is not null then
    if to_regprocedure('public.v6170a_reverse_journal(uuid,text)') is null then
      raise exception 'Journal reversal function is not available; owner/equity reconciliation was not undone';
    end if;
    execute 'select public.v6170a_reverse_journal($1,$2)'
      into v_reversal
      using v_alloc.accounting_journal_id, coalesce(nullif(btrim(p_reason),''),'Undo owner/equity bank reconciliation');
  end if;

  delete from public.bank_reconciliation_allocations
  where business_id=v_bid and bank_transaction_id=p_bank_transaction_id and allocation_type='owner_equity';

  update public.bank_transactions
  set status='unreconciled',
      reconciliation_type=null,
      reconciled_at=null,
      reconciled_by=null,
      updated_at=now(),
      updated_by=v_uid
  where id=p_bank_transaction_id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(
    business_id,bank_transaction_id,action,details,created_by
  ) values (
    v_bid,
    p_bank_transaction_id,
    'owner_equity_undo',
    jsonb_build_object('journal_id',v_alloc.accounting_journal_id,'reversal_journal_id',v_reversal,'reason',p_reason),
    v_uid
  );

  return jsonb_build_object('ok',true,'reversal_journal_id',v_reversal);
end;
$$;

revoke execute on function public.v61106e_undo_owner_equity_bank_transaction(uuid,text) from public, anon;
grant execute on function public.v61106e_undo_owner_equity_bank_transaction(uuid,text) to authenticated;
