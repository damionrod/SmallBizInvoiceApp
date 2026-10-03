-- Frindly v61.106H: production-chart-safe owner/equity bank reconciliation.
-- Scope: replaces only v61106e_reconcile_owner_equity_bank_transaction().
-- Existing accounts, journals, journal lines, GST records, bank transactions and reconciliations are not rewritten.
-- Reuses the production chart roles already present in accounting_accounts and creates only a missing
-- Owner / Director Loan liability account when that treatment is actually used.

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
  v_counterpart uuid;
  v_journal uuid;
  v_label text;
  v_lines jsonb := '[]'::jsonb;
  v_code text;
  v_is_short_chart boolean := false;
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

  -- Resolve the existing bank ledger. Production charts use 1000 / bank; legacy charts may use 090 / bank_main.
  -- Check both system key columns and the bank subtype before falling back to known chart codes.
  select a.id into v_bank
  from public.accounting_accounts a
  where a.business_id=v_bid
    and not coalesce(a.archived,false)
    and a.account_type='asset'
    and (
      a.system_account_key='bank'
      or a.system_key in ('bank_main','bank')
      or a.account_subtype='bank'
      or a.account_code in ('090','1000')
    )
  order by case
    when a.system_account_key='bank' then 0
    when a.system_key='bank_main' then 1
    when a.system_key='bank' then 2
    when a.account_subtype='bank' then 3
    when a.account_code='090' then 4
    when a.account_code='1000' then 5
    else 6 end,
    a.account_code
  limit 1;
  if v_bank is null then raise exception 'A bank ledger account is not available for this business'; end if;

  if p_equity_type in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment') then
    -- Temporary owner/director funding is a liability, not permanent equity.
    select a.id into v_counterpart
    from public.accounting_accounts a
    where a.business_id=v_bid
      and not coalesce(a.archived,false)
      and a.account_type='liability'
      and (a.system_account_key='owner_director_loan' or a.system_key='owner_director_loan')
    order by a.account_code
    limit 1;

    if v_counterpart is null then
      select exists(
        select 1 from public.accounting_accounts a
        where a.business_id=v_bid and length(regexp_replace(coalesce(a.account_code,''),'[^0-9]','','g'))=3
      ) and not exists(
        select 1 from public.accounting_accounts a
        where a.business_id=v_bid and length(regexp_replace(coalesce(a.account_code,''),'[^0-9]','','g'))=4
      ) into v_is_short_chart;

      if v_is_short_chart then
        select lpad(gs::text,3,'0') into v_code
        from generate_series(270,279) gs
        where not exists (
          select 1 from public.accounting_accounts a
          where a.business_id=v_bid and a.account_code=lpad(gs::text,3,'0')
        )
        order by gs limit 1;
      else
        select gs::text into v_code
        from generate_series(2300,2399) gs
        where not exists (
          select 1 from public.accounting_accounts a
          where a.business_id=v_bid and a.account_code=gs::text
        )
        order by gs limit 1;
      end if;

      if v_code is null then raise exception 'No free owner/director loan liability account code is available'; end if;

      insert into public.accounting_accounts(
        business_id,account_code,account_name,account_type,account_subtype,normal_balance,tax_default,
        system_account_key,system_key,allow_manual_posting,report_section,is_system,is_control,
        xero_account_code,xero_account_type,xero_tax_type,description,created_by,updated_by
      ) values (
        v_bid,v_code,'Owner / Director Loan','liability','owner_loan','credit','NO_GST',
        'owner_director_loan','owner_director_loan',true,'current_liabilities',true,false,
        v_code,'CURRLIAB','NONE','Temporary funds introduced by, or repaid to, owners/directors. No GST.',v_uid,v_uid
      )
      returning id into v_counterpart;
    end if;

  elsif p_equity_type='capital_contribution' then
    -- Reuse the production permanent-equity account (3000 Owner funds / share capital).
    select a.id into v_counterpart
    from public.accounting_accounts a
    where a.business_id=v_bid
      and not coalesce(a.archived,false)
      and a.account_type='equity'
      and a.normal_balance='credit'
      and (
        a.system_account_key in ('owner_contributions','owner_funds','owner_capital')
        or a.system_key in ('owner_funds','owner_capital','opening_balance_equity')
        or a.account_subtype='capital'
        or a.account_code in ('859','3000')
      )
    order by case
      when a.system_account_key='owner_contributions' then 0
      when a.system_key='owner_funds' then 1
      when a.account_subtype='capital' then 2
      when a.account_code='3000' then 3
      else 4 end,
      a.account_code
    limit 1;
    if v_counterpart is null then
      raise exception 'Owner funds / share capital ledger account is not available for this business';
    end if;

  else
    -- Drawings/distributions reduce equity and therefore carry a debit normal balance.
    select a.id into v_counterpart
    from public.accounting_accounts a
    where a.business_id=v_bid
      and not coalesce(a.archived,false)
      and a.account_type='equity'
      and a.normal_balance='debit'
      and (
        a.system_account_key='owner_drawings'
        or a.system_key='owner_drawings'
        or a.account_subtype='drawings'
        or a.account_code in ('800','3100')
      )
    order by case
      when a.system_account_key='owner_drawings' then 0
      when a.system_key='owner_drawings' then 1
      when a.account_subtype='drawings' then 2
      when a.account_code='3100' then 3
      else 4 end,
      a.account_code
    limit 1;
    if v_counterpart is null then
      raise exception 'Owner drawings ledger account is not available for this business';
    end if;
  end if;

  if v_counterpart is null then raise exception 'Required owner/equity accounting account is not available'; end if;

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
      jsonb_build_object('account_id',v_counterpart,'description',v_label,'debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    );
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id',v_counterpart,'description',v_label,'debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_bank,'description',v_label,'debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    );
  end if;

  -- Hard accounting invariants: balanced journal and no GST on owner/equity movements.
  if round((select coalesce(sum((x->>'debit')::numeric),0) from jsonb_array_elements(v_lines) x),2)
     <> round((select coalesce(sum((x->>'credit')::numeric),0) from jsonb_array_elements(v_lines) x),2) then
    raise exception 'Owner/equity journal is not balanced';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_lines) x
    where coalesce(x->>'tax_code','') <> 'NO_GST'
       or coalesce((x->>'tax_rate')::numeric,0) <> 0
       or coalesce((x->>'tax_amount')::numeric,0) <> 0
  ) then
    raise exception 'Owner/equity journal must not contain GST';
  end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,v_tx.transaction_date,'bank_reconciliation','owner_equity',v_tx.id,
    coalesce(nullif(v_tx.reference,''),'BANK-'||left(v_tx.id::text,8)),v_label,v_lines
  );
  if v_journal is null then raise exception 'Owner/equity accounting journal was not created'; end if;

  insert into public.bank_reconciliation_allocations(
    business_id,bank_transaction_id,allocation_type,amount,equity_transaction_type,equity_note,accounting_journal_id,created_by
  ) values (
    v_bid,v_tx.id,'owner_equity',v_amount,p_equity_type,nullif(btrim(coalesce(p_note,'')),''),v_journal,v_uid
  );

  update public.bank_transactions
  set status='reconciled',reconciliation_type=p_equity_type,reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
  where id=v_tx.id and business_id=v_bid;

  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values (
    v_bid,v_tx.id,'owner_equity_reconciled',
    jsonb_build_object('equity_type',p_equity_type,'amount',v_amount,'journal_id',v_journal,'bank_account_id',v_bank,'counterpart_account_id',v_counterpart),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'equity_type',p_equity_type,'amount',v_amount,'bank_account_id',v_bank,'counterpart_account_id',v_counterpart);
end;
$$;

revoke execute on function public.v61106e_reconcile_owner_equity_bank_transaction(uuid,text,text) from public, anon;
grant execute on function public.v61106e_reconcile_owner_equity_bank_transaction(uuid,text,text) to authenticated;
