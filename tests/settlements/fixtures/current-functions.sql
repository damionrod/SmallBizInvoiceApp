set check_function_bodies=false;
CREATE OR REPLACE FUNCTION public.current_business_id()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_active uuid; v_home uuid;
begin
 if auth.uid() is null then return null; end if;
 select p.active_business_id,p.business_id into v_active,v_home from public.profiles p where p.id=auth.uid();
 if public.is_super_admin() then return coalesce(v_active,v_home); end if;
 if v_active is not null and exists(select 1 from public.business_memberships bm where bm.user_id=auth.uid() and bm.business_id=v_active and bm.status='active') then return v_active; end if;
 if v_home is not null and exists(select 1 from public.business_memberships bm where bm.user_id=auth.uid() and bm.business_id=v_home and bm.status='active') then return v_home; end if;
 return null;
end $function$;

CREATE OR REPLACE FUNCTION public.is_super_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select coalesce((select is_super_admin from public.profiles where id=auth.uid()),false) $function$;

CREATE OR REPLACE FUNCTION public.v61109_bank_accounting_account(p_business_id uuid, p_bank_transaction_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_bank_account public.bank_accounts%rowtype;
  v_account uuid;
  v_code text;
begin
  if auth.uid() is null or not coalesce(public.v6147_can_write_area(p_business_id, 'bank'), false) then
    raise exception 'Bank reconciliation write access denied' using errcode = '42501';
  end if;

  if p_business_id is null or p_bank_transaction_id is null then
    return null;
  end if;

  select ba.* into v_bank_account
  from public.bank_transactions bt
  join public.bank_accounts ba
    on ba.id = bt.bank_account_id
   and ba.business_id = bt.business_id
  where bt.id = p_bank_transaction_id
    and bt.business_id = p_business_id;

  if v_bank_account.id is null then
    return null;
  end if;

  if v_bank_account.accounting_account_id is not null then
    select a.id into v_account
    from public.accounting_accounts a
    where a.id = v_bank_account.accounting_account_id
      and a.business_id = p_business_id
      and not coalesce(a.archived, false);
    if v_account is not null then
      return v_account;
    end if;
  end if;

  select a.id into v_account
  from public.accounting_accounts a
  where a.business_id = p_business_id
    and not coalesce(a.archived, false)
    and a.account_type = 'asset'
    and a.account_subtype = 'bank'
    and lower(a.account_name) = lower(v_bank_account.name)
  limit 1;

  if v_account is null then
    select gs::text into v_code
    from generate_series(1000, 1099) gs
    where not exists (
      select 1 from public.accounting_accounts a
      where a.business_id = p_business_id
        and a.account_code = gs::text
    )
    order by gs
    limit 1;

    if v_code is null then
      raise exception 'No free bank ledger account code is available';
    end if;

    insert into public.accounting_accounts(
      business_id, account_code, account_name, account_type, account_subtype,
      normal_balance, tax_default, allow_manual_posting, report_section,
      is_system, is_control, xero_account_code, xero_account_type, xero_tax_type,
      description, created_by, updated_by
    ) values (
      p_business_id, v_code, v_bank_account.name, 'asset', 'bank',
      'debit', 'NO_GST', false, 'asset',
      true, true, v_code, 'BANK', 'NONE',
      'Bank ledger linked to imported bank account ' || coalesce(v_bank_account.account_number, v_bank_account.name),
      v_uid, v_uid
    )
    returning id into v_account;
  end if;

  update public.bank_accounts
  set accounting_account_id = v_account,
      updated_at = now(),
      updated_by = v_uid
  where id = v_bank_account.id
    and business_id = p_business_id
    and accounting_account_id is distinct from v_account;

  return v_account;
end;
$function$;

CREATE OR REPLACE FUNCTION public.v61109_reconcile_payroll_bank_transaction(p_bank_transaction_id uuid, p_pay_run_id uuid, p_pay_run_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_amount numeric;
  v_expected numeric;
  v_run public.payroll_pay_runs%rowtype;
  v_employee public.payroll_pay_run_employees%rowtype;
  v_bank uuid;
  v_payable uuid;
  v_journal uuid;
  v_legacy_bank_posted boolean := false;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions where id = p_bank_transaction_id and business_id = v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;
  if coalesce(v_tx.amount,0) >= 0 then raise exception 'Payroll payments must be matched to a money-out bank transaction'; end if;
  v_amount := round(abs(coalesce(v_tx.amount,0)),2);

  select * into v_run from public.payroll_pay_runs where id = p_pay_run_id and business_id = v_bid;
  if v_run.id is null then raise exception 'Pay run not found in active business'; end if;
  if v_run.status <> 'finalised' then raise exception 'Only finalised pay runs can be matched to bank payments'; end if;

  if p_pay_run_employee_id is not null then
    select * into v_employee
    from public.payroll_pay_run_employees
    where id = p_pay_run_employee_id
      and business_id = v_bid
      and pay_run_id = v_run.id;
    if v_employee.id is null then raise exception 'Pay run employee was not found in this pay run'; end if;
    v_expected := round(coalesce(v_employee.net_pay,0),2);
  else
    v_expected := round(coalesce(v_run.net_pay,0),2);
  end if;

  if v_expected <= 0 or v_amount <> v_expected then
    raise exception 'Bank amount % does not match payroll net amount %', v_amount, v_expected;
  end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and v_tx.transaction_date between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this bank transaction is locked';
  end if;

  v_bank := public.v61109_bank_accounting_account(v_bid, v_tx.id);
  select id into v_payable from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_net_payable' or system_key = 'payroll_net_payable' or account_code = '266') order by account_code limit 1;
  if v_bank is null or v_payable is null then raise exception 'Bank or payroll payable account is not available'; end if;

  select exists(
    select 1
    from public.accounting_journals j
    join public.accounting_journal_lines l
      on l.journal_id = j.id
     and l.business_id = j.business_id
    join public.accounting_accounts a
      on a.id = l.account_id
     and a.business_id = l.business_id
    where j.business_id = v_bid
      and j.source_type = 'payroll'
      and j.source_id = v_run.id
      and j.status in ('posted','reversed')
      and l.credit > 0
      and (a.account_subtype = 'bank' or a.system_account_key = 'bank' or a.system_key in ('bank','bank_main') or a.account_code in ('090','1000'))
  ) into v_legacy_bank_posted;

  if not v_legacy_bank_posted then
    v_journal := public.v6192_create_posted_journal(
      v_bid,
      v_tx.transaction_date,
      'bank',
      'payroll_bank_payment',
      v_tx.id,
      coalesce(nullif(v_tx.reference,''), v_run.pay_run_number),
      'Payroll bank payment for ' || coalesce(v_run.pay_run_number, 'pay run'),
      jsonb_build_array(
        jsonb_build_object('account_id',v_payable,'description','Clear net payroll payable','debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
        jsonb_build_object('account_id',v_bank,'description','Payroll payment from bank','debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
      )
    );
  end if;

  insert into public.bank_reconciliation_allocations(
    business_id, bank_transaction_id, allocation_type, amount, pay_run_id,
    pay_run_employee_id, accounting_journal_id, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_pay_run', v_amount, v_run.id,
    p_pay_run_employee_id, v_journal, v_uid
  );

  update public.bank_transactions
  set status = 'reconciled',
      reconciliation_type = 'payroll_pay_run',
      reconciled_at = now(),
      reconciled_by = v_uid,
      updated_at = now(),
      updated_by = v_uid
  where id = v_tx.id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_bank_reconciled',
    jsonb_build_object('pay_run_id',v_run.id,'pay_run_employee_id',p_pay_run_employee_id,'journal_id',v_journal,'legacy_bank_posted',v_legacy_bank_posted),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'legacy_bank_posted',v_legacy_bank_posted,'amount',v_amount);
end;
$function$;

CREATE OR REPLACE FUNCTION public.v61109_reconcile_payroll_ird_bank_transaction(p_bank_transaction_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bid uuid := public.current_business_id();
  v_uid uuid := auth.uid();
  v_tx public.bank_transactions%rowtype;
  v_amount numeric;
  v_bank uuid;
  v_liability uuid;
  v_journal uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if v_bid is null then raise exception 'No active authorised business'; end if;
  if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;

  select * into v_tx from public.bank_transactions where id = p_bank_transaction_id and business_id = v_bid for update;
  if v_tx.id is null then raise exception 'Bank transaction not found in the active business'; end if;
  if coalesce(v_tx.status,'unreconciled') <> 'unreconciled' then raise exception 'Only unreconciled bank transactions can be matched'; end if;
  if coalesce(v_tx.amount,0) >= 0 then raise exception 'IRD / PAYE payments must be matched to a money-out bank transaction'; end if;
  v_amount := round(abs(coalesce(v_tx.amount,0)),2);
  if v_amount <= 0 then raise exception 'Bank transaction amount is invalid'; end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_bid
      and p.status <> 'open'
      and v_tx.transaction_date between p.period_start and p.period_end
  ) then
    raise exception 'The accounting period for this bank transaction is locked';
  end if;

  v_bank := public.v61109_bank_accounting_account(v_bid, v_tx.id);
  select id into v_liability from public.accounting_accounts where business_id = v_bid and not coalesce(archived,false) and (system_account_key = 'payroll_liability' or system_key = 'payroll_liability' or account_code in ('265','267')) order by case when account_code = '267' then 0 else 1 end, account_code limit 1;
  if v_bank is null or v_liability is null then raise exception 'Bank or payroll liability account is not available'; end if;

  v_journal := public.v6192_create_posted_journal(
    v_bid,
    v_tx.transaction_date,
    'bank',
    'payroll_ird_payment',
    v_tx.id,
    coalesce(nullif(v_tx.reference,''),'IRD / PAYE payment'),
    'IRD / PAYE payment from bank',
    jsonb_build_array(
      jsonb_build_object('account_id',v_liability,'description','Clear payroll liability payment','debit',v_amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
      jsonb_build_object('account_id',v_bank,'description','IRD / PAYE payment from bank','debit',0,'credit',v_amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
    )
  );

  insert into public.bank_reconciliation_allocations(
    business_id, bank_transaction_id, allocation_type, amount,
    accounting_journal_id, note, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_ird', v_amount,
    v_journal, nullif(btrim(coalesce(p_note,'')),''), v_uid
  );

  update public.bank_transactions
  set status = 'reconciled',
      reconciliation_type = 'payroll_ird',
      reconciled_at = now(),
      reconciled_by = v_uid,
      updated_at = now(),
      updated_by = v_uid
  where id = v_tx.id and business_id = v_bid;

  insert into public.bank_reconciliation_audit(
    business_id, bank_transaction_id, action, details, created_by
  ) values (
    v_bid, v_tx.id, 'payroll_ird_reconciled',
    jsonb_build_object('journal_id',v_journal,'amount',v_amount,'note',p_note),
    v_uid
  );

  return jsonb_build_object('ok',true,'journal_id',v_journal,'amount',v_amount);
end;
$function$;

CREATE OR REPLACE FUNCTION public.v6147_can_read_area(p_business_id uuid, p_area text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare r text;m_id uuid;o_read boolean; begin if auth.uid() is null then return false;end if;if public.is_super_admin() then return true;end if;if p_business_id is null or p_business_id<>public.current_business_id() then return false;end if;select bm.id,bm.role into m_id,r from public.business_memberships bm where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' limit 1;if m_id is null then return false;end if;if p_area in ('team','business_settings','billing') then if r in ('owner','admin') then return p_area<>'billing' or r='owner';end if;return false;end if;select o.can_read into o_read from public.business_member_access_overrides o where o.membership_id=m_id and o.business_id=p_business_id and o.area=p_area;if found then return o_read;end if;return public.v6149_effective_role_default_read(p_business_id,r,p_area);end $function$;

CREATE OR REPLACE FUNCTION public.v6147_can_write_area(p_business_id uuid, p_area text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r text;m_id uuid;o_write boolean;
begin
  if auth.uid() is null then return false;end if;
  if public.is_super_admin() then return true;end if;
  if p_business_id is null or p_business_id<>public.current_business_id() then return false;end if;
  select bm.id,bm.role into m_id,r from public.business_memberships bm
    where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' limit 1;
  if m_id is null then return false;end if;
  if p_area='billing' then return r='owner';end if;
  if p_area in ('team','business_settings') then return r in ('owner','admin');end if;
  if public.v6187_subscription_read_only(p_business_id) then return false;end if;
  select o.can_write into o_write from public.business_member_access_overrides o
    where o.membership_id=m_id and o.business_id=p_business_id and o.area=p_area;
  if found then return o_write;end if;
  return public.v6149_effective_role_default_write(p_business_id,r,p_area);
end;
$function$;

CREATE OR REPLACE FUNCTION public.v6148_role_default_read(p_role text, p_area text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    when p_role in ('owner','admin') then true
    when p_area='core' then p_role in ('accountant','bookkeeper','staff','viewer')
    when p_area in ('expenses','bank') then p_role in ('accountant','bookkeeper')
    when p_area='financials' then p_role in ('accountant','bookkeeper')
    when p_area='payroll' then false
    when p_area='reports' then p_role in ('accountant','bookkeeper','viewer')
    else false
  end
$function$;

CREATE OR REPLACE FUNCTION public.v6148_role_default_write(p_role text, p_area text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    when p_role='owner' then true
    when p_role='admin' then p_area in ('core','expenses','bank','financials','payroll','reports')
    when p_area='core' then p_role in ('accountant','bookkeeper','staff')
    when p_area in ('expenses','bank') then p_role in ('accountant','bookkeeper')
    when p_area='financials' then p_role='accountant'
    else false
  end
$function$;

CREATE OR REPLACE FUNCTION public.v6149_effective_role_default_read(p_business_id uuid, p_role text, p_area text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select coalesce((select d.can_read from public.business_role_access_defaults d where d.business_id=p_business_id and d.role=p_role and d.area=p_area),public.v6148_role_default_read(p_role,p_area)) $function$;

CREATE OR REPLACE FUNCTION public.v6149_effective_role_default_write(p_business_id uuid, p_role text, p_area text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select coalesce((select d.can_write from public.business_role_access_defaults d where d.business_id=p_business_id and d.role=p_role and d.area=p_area),public.v6148_role_default_write(p_role,p_area)) $function$;

CREATE OR REPLACE FUNCTION public.v6187_subscription_read_only(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(
 select 1 from public.subscriptions s where s.business_id=p_business_id and
 (s.manual_access_until is null or s.manual_access_until<=now()) and
 (s.status='canceled' or s.cancel_at<=now() or
 (s.cancel_at_period_end and s.current_period_end<=now()) or
 (s.status='trialing' and s.trial_ends_at<=now()))
 ) and (p_business_id=public.current_business_id() or auth.role()='service_role' or public.is_super_admin());
$function$;

CREATE OR REPLACE FUNCTION public.v6192_create_posted_journal(p_business_id uuid, p_journal_date date, p_journal_type text, p_source_type text, p_source_id uuid, p_source_reference text, p_description text, p_lines jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_journal_id uuid;
  v_debits numeric := 0;
  v_credits numeric := 0;
  v_line_count integer := 0;
  v_journal_number text;
begin
  if p_business_id is null or p_journal_date is null then
    raise exception 'Business and journal date are required';
  end if;

  select count(*), round(coalesce(sum((x.debit)::numeric),0),2), round(coalesce(sum((x.credit)::numeric),0),2)
    into v_line_count, v_debits, v_credits
  from jsonb_to_recordset(coalesce(p_lines,'[]'::jsonb)) as x(
    account_id uuid,
    debit numeric,
    credit numeric
  )
  where round(coalesce(x.debit,0),2) > 0 or round(coalesce(x.credit,0),2) > 0;

  if v_line_count < 2 or v_debits <= 0 or v_debits <> v_credits then
    raise exception 'Posted journal must have at least two balanced lines';
  end if;

  v_journal_number :=
    'AUTO-' || to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS') || '-' ||
    upper(left(regexp_replace(coalesce(p_source_type,p_journal_type),'[^a-zA-Z0-9]+','','g'),4)) || '-' ||
    left(replace(coalesce(p_source_id, gen_random_uuid())::text,'-',''),8);

  insert into public.accounting_journals(
    business_id, journal_number, journal_date, period_date, source_type, source_id,
    source_reference, posting_version, migration_origin, description, journal_type,
    status, created_by
  ) values (
    p_business_id, v_journal_number, p_journal_date, p_journal_date, p_source_type, p_source_id,
    p_source_reference, 1, 'v6192_posting_engine', p_description, p_journal_type,
    'draft', auth.uid()
  )
  returning id into v_journal_id;

  insert into public.accounting_journal_lines(
    business_id, journal_id, account_id, description, debit, credit, tax_code,
    tax_rate, tax_amount, customer_id, supplier_id, job_costing_id, source_line_id
  )
  select
    p_business_id,
    v_journal_id,
    x.account_id,
    nullif(x.description,''),
    round(coalesce(x.debit,0),2),
    round(coalesce(x.credit,0),2),
    nullif(x.tax_code,''),
    x.tax_rate,
    round(coalesce(x.tax_amount,0),2),
    case
      when x.customer_id is not null and exists (
        select 1 from public.customers c
        where c.business_id = p_business_id and c.id = x.customer_id
      ) then x.customer_id
      else null
    end,
    case
      when x.supplier_id is not null and exists (
        select 1 from public.suppliers s
        where s.business_id = p_business_id and s.id = x.supplier_id
      ) then x.supplier_id
      else null
    end,
    case
      when x.job_costing_id is not null and exists (
        select 1 from public.job_costings j
        where j.business_id = p_business_id and j.id = x.job_costing_id
      ) then x.job_costing_id
      else null
    end,
    x.source_line_id
  from jsonb_to_recordset(p_lines) as x(
    account_id uuid,
    description text,
    debit numeric,
    credit numeric,
    tax_code text,
    tax_rate numeric,
    tax_amount numeric,
    customer_id uuid,
    supplier_id uuid,
    job_costing_id uuid,
    source_line_id uuid
  )
  where round(coalesce(x.debit,0),2) > 0 or round(coalesce(x.credit,0),2) > 0;

  update public.accounting_journals
  set status = 'posted',
      posted_at = now(),
      posted_by = auth.uid()
  where id = v_journal_id
    and business_id = p_business_id;

  return v_journal_id;
end
$function$;

set check_function_bodies=true;
