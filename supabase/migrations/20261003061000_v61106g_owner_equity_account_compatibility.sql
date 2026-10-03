-- Frindly v61.106G: owner/equity bank-reconciliation account compatibility.
-- Forward-safe: no journal amounts, dates, tax, source links, or reconciliations are rewritten.
-- Corrects the v61.106E account-code collision where code 800 could mean either
-- legacy Owner Drawings or the newly-added Owner Capital account.

-- If 106E created Owner Capital on legacy drawings code 800, move only that
-- specifically-keyed account to the first free capital-equity code. Journal lines
-- reference account IDs, so this metadata correction preserves every posting.
do $$
declare r record; v_code text;
begin
  for r in
    select id,business_id
    from public.accounting_accounts
    where system_key='owner_capital' and account_code='800'
  loop
    select gs::text into v_code
    from generate_series(860,899) gs
    where not exists (
      select 1 from public.accounting_accounts a
      where a.business_id=r.business_id and a.account_code=gs::text
    )
    order by gs limit 1;
    if v_code is null then
      raise exception 'No free owner-capital account code is available for business %',r.business_id;
    end if;
    update public.accounting_accounts
       set account_code=v_code,
           xero_account_code=case when xero_account_code='800' then v_code else xero_account_code end,
           updated_at=now()
     where id=r.id and business_id=r.business_id;
  end loop;
end $$;

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
  v_code text;
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

  -- Bank: accept every chart generation already supported elsewhere in Frindly.
  select a.id into v_bank
  from public.accounting_accounts a
  where a.business_id=v_bid and not coalesce(a.archived,false)
    and (a.system_key in ('bank_main','bank') or a.account_code in ('090','1000'))
  order by case when a.system_key='bank_main' then 0 when a.system_key='bank' then 1
                when a.account_code='090' then 2 else 3 end, a.account_code
  limit 1;
  if v_bank is null then raise exception 'A bank ledger account is not available for this business'; end if;

  if p_equity_type in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment') then
    select a.id into v_equity from public.accounting_accounts a
     where a.business_id=v_bid and not coalesce(a.archived,false) and a.system_key='owner_director_loan'
     order by a.account_code limit 1;
    if v_equity is null then
      select gs::text into v_code from generate_series(310,339) gs
       where not exists(select 1 from public.accounting_accounts a where a.business_id=v_bid and a.account_code=gs::text)
       order by gs limit 1;
      if v_code is null then raise exception 'No free owner/director loan account code is available'; end if;
      insert into public.accounting_accounts(
        business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,
        xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by
      ) values (v_bid,v_code,'Owner / Director Loan','liability','credit','liabilities','owner_director_loan',v_code,'CURRLIAB','Temporary funds introduced by, or repaid to, owners/directors.',true,false,v_uid,v_uid)
      returning id into v_equity;
    end if;
  elsif p_equity_type='capital_contribution' then
    select a.id into v_equity from public.accounting_accounts a
     where a.business_id=v_bid and not coalesce(a.archived,false) and a.system_key='owner_capital'
     order by a.account_code limit 1;
    if v_equity is null then
      select gs::text into v_code from generate_series(860,899) gs
       where not exists(select 1 from public.accounting_accounts a where a.business_id=v_bid and a.account_code=gs::text)
       order by gs limit 1;
      if v_code is null then raise exception 'No free owner-capital account code is available'; end if;
      insert into public.accounting_accounts(
        business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,
        xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by
      ) values (v_bid,v_code,'Owner Capital Introduced','equity','credit','equity','owner_capital',v_code,'EQUITY','Permanent owner capital introduced to the business.',true,false,v_uid,v_uid)
      returning id into v_equity;
    end if;
  else
    -- Drawings compatibility: prefer an explicit key, then legacy 800/3100 only
    -- when the account is not the new owner-capital account.
    select a.id into v_equity from public.accounting_accounts a
     where a.business_id=v_bid and not coalesce(a.archived,false)
       and (a.system_key='owner_drawings' or (a.account_code in ('800','3100') and coalesce(a.system_key,'')<>'owner_capital'))
     order by case when a.system_key='owner_drawings' then 0 else 1 end,a.account_code limit 1;
    if v_equity is null then
      select gs::text into v_code from generate_series(850,858) gs
       where not exists(select 1 from public.accounting_accounts a where a.business_id=v_bid and a.account_code=gs::text)
       order by gs limit 1;
      if v_code is null then raise exception 'No free owner-drawings account code is available'; end if;
      insert into public.accounting_accounts(
        business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,
        xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by
      ) values (v_bid,v_code,'Owner Drawings / Distributions','equity','debit','equity','owner_drawings',v_code,'EQUITY','Owner drawings and distributions that are not operating expenses.',true,false,v_uid,v_uid)
      returning id into v_equity;
    end if;
  end if;

  if v_equity is null then raise exception 'Required owner/equity accounting account is not available'; end if;

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

  -- Double-entry invariant before posting.
  if round((select coalesce(sum((x->>'debit')::numeric),0) from jsonb_array_elements(v_lines) x),2)
     <> round((select coalesce(sum((x->>'credit')::numeric),0) from jsonb_array_elements(v_lines) x),2) then
    raise exception 'Owner/equity journal is not balanced';
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,v_tx.transaction_date,'bank_reconciliation','owner_equity',v_tx.id,
    coalesce(nullif(v_tx.reference,''),'BANK-'||left(v_tx.id::text,8)),v_label,v_lines
  );

  insert into public.bank_reconciliation_allocations(
    business_id,bank_transaction_id,allocation_type,amount,equity_transaction_type,equity_note,accounting_journal_id,created_by
  ) values (v_bid,v_tx.id,'owner_equity',v_amount,p_equity_type,nullif(btrim(coalesce(p_note,'')),''),v_journal,v_uid);

  update public.bank_transactions
  set status='reconciled',reconciliation_type=p_equity_type,reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
  where id=v_tx.id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values (v_bid,v_tx.id,'owner_equity_reconciled',jsonb_build_object('equity_type',p_equity_type,'amount',v_amount,'journal_id',v_journal,'bank_account_id',v_bank,'counter_account_id',v_equity),v_uid);

  return jsonb_build_object('ok',true,'journal_id',v_journal,'equity_type',p_equity_type,'amount',v_amount,'bank_account_id',v_bank,'counter_account_id',v_equity);
end;
$$;

revoke execute on function public.v61106e_reconcile_owner_equity_bank_transaction(uuid,text,text) from public, anon;
grant execute on function public.v61106e_reconcile_owner_equity_bank_transaction(uuid,text,text) to authenticated;
