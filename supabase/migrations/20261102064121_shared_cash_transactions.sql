-- Shared non-standard cash entry. Statement evidence is never manufactured for manual entries.
create schema frindly_cash;
revoke all on schema frindly_cash from public,anon;
grant usage on schema frindly_cash to authenticated;
create table public.cash_transactions (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id),
 request_id uuid not null, request_payload jsonb not null, kind text not null check(kind in ('in','out','transfer')),
 purpose text not null, description text not null, reference text, note text, party text, tax_year integer,
 taxpayer text, owner_id uuid references public.business_owners(id), account_id uuid references public.accounting_accounts(id),
 amount numeric(18,2) not null check(amount>0), gst_amount numeric(18,2) not null default 0 check(gst_amount>=0),
 gst_treatment text not null default 'NO_GST' check(gst_treatment in ('NO_GST','GST','ZERO')),
 interest_amount numeric(18,2) not null default 0 check(interest_amount>=0), withheld_amount numeric(18,2) not null default 0 check(withheld_amount>=0),
 status text not null default 'recorded' check(status in ('recorded','void')),
 created_at timestamptz not null default now(),created_by uuid not null references auth.users(id),
 unique(business_id,request_id)
);
create table public.cash_transaction_legs (
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id),
 transaction_id uuid not null references public.cash_transactions(id),bank_account_id uuid not null references public.bank_accounts(id),
 original_date date not null,transaction_date date not null,amount numeric(18,2) not null check(amount<>0),
 accounting_journal_id uuid not null references public.accounting_journals(id),unique(transaction_id,bank_account_id)
);
create index cash_transactions_business_idx on public.cash_transactions(business_id,created_at);
create index cash_legs_business_idx on public.cash_transaction_legs(business_id,bank_account_id,transaction_date);
alter table public.bank_reconciliation_allocations add column cash_leg_id uuid references public.cash_transaction_legs(id);
create unique index bank_cash_leg_once on public.bank_reconciliation_allocations(cash_leg_id) where cash_leg_id is not null;
alter table public.cash_transactions enable row level security;
alter table public.cash_transaction_legs enable row level security;
revoke all on public.cash_transactions,public.cash_transaction_legs from public,anon,authenticated;
grant select on public.cash_transactions,public.cash_transaction_legs to authenticated;
create policy cash_read on public.cash_transactions for select to authenticated using(business_id=public.current_business_id() and public.v6147_can_read_area(business_id,'financials'));
create policy cash_legs_read on public.cash_transaction_legs for select to authenticated using(business_id=public.current_business_id() and public.v6147_can_read_area(business_id,'financials'));

create function frindly_cash.access(p_write boolean default false,p_bank boolean default false) returns uuid
language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id();
begin
 if auth.uid() is null or b is null or not coalesce(case when p_write then public.v6147_can_write_area(b,'financials') else public.v6147_can_read_area(b,'financials') end,false) then raise exception 'Financial access denied' using errcode='42501';end if;
 if p_bank and (not public.v6147_can_write_area(b,'bank') or not public.v6135_bank_module_enabled(b)) then raise exception 'Bank reconciliation access denied' using errcode='42501';end if;
 return b;
end $$;

create function frindly_cash.check_date(b uuid,d date,p_tax boolean default false) returns void
language plpgsql security definer set search_path='' as $$
begin
 if d is null or not public.v6170a_period_is_open(b,d) or exists(select 1 from public.accounting_periods where business_id=b and d between period_start and period_end and status<>'open') then raise exception 'The accounting period is locked or unavailable';end if;
 if p_tax and (exists(select 1 from public.gst_returns where business_id=b and d between period_start and period_end and status='finalised') or exists(select 1 from public.ird_filing_batches where business_id=b and filing_type='gst_return' and d between period_start and period_end and status='filed_in_myir')) then raise exception 'This date affects a finalised or filed GST period. Review the tax period first';end if;
end $$;

-- Reuse mapped or matching purpose accounts; provision only missing categories, under the business lock.
create function frindly_cash.account(b uuid,k text,n text,t text) returns uuid
language plpgsql security definer set search_path='' as $$
declare a uuid;code text;matches int;
begin
 select count(*),min(id::text)::uuid into matches,a from public.accounting_accounts where business_id=b and not coalesce(archived,false) and (system_key=k or system_account_key=k);
 if matches>1 then raise exception 'Multiple mapped accounts for %. Review account mappings',n;end if;
 if a is not null then
  if not exists(select 1 from public.accounting_accounts where id=a and account_type=t) then raise exception 'Incorrect account type for %',n;end if;return a;
 end if;
 select count(*),min(id::text)::uuid into matches,a from public.accounting_accounts where business_id=b and not coalesce(archived,false) and account_type=t and lower(account_name)=lower(n) and not coalesce(is_control,false);
 if matches>1 then raise exception 'Multiple accounts named %. Review account mappings',n;end if;
 if a is not null then return a;end if;
 if exists(select 1 from public.accounting_accounts where business_id=b and lower(account_name)=lower(n)) then raise exception 'Existing account named % needs mapping or reactivation; no duplicate account was created',n;end if;
 select s::text into code from generate_series(case t when 'asset' then 1600 when 'liability' then 2400 when 'equity' then 3200 when 'other_income' then 4800 when 'income' then 4800 else 6800 end,case t when 'asset' then 1699 when 'liability' then 2499 when 'equity' then 3299 when 'other_income' then 4899 when 'income' then 4899 else 6899 end) s where not exists(select 1 from public.accounting_accounts where business_id=b and account_code=s::text) order by s limit 1;
 if code is null then raise exception 'No free account code for %',n;end if;
 insert into public.accounting_accounts(business_id,account_code,account_name,account_type,normal_balance,system_key,system_account_key,tax_default,report_section,is_system,is_control,allow_manual_posting,created_by,updated_by)
 values(b,code,n,t,case when t in ('asset','expense') then 'debit' else 'credit' end,k,k,'NO_GST',case t when 'asset' then 'current_assets' when 'liability' then 'current_liabilities' when 'other_income' then 'other_income' when 'income' then 'other_income' when 'expense' then 'operating_expenses' else 'equity' end,true,false,true,auth.uid(),auth.uid()) returning id into a;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'account',a,'cash_purpose_account_created',jsonb_build_object('key',k),auth.uid());return a;
end $$;

create function frindly_cash.bank_gl(b uuid,bank_id uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare a uuid;
begin
 select bk.accounting_account_id into a from public.bank_accounts bk join public.accounting_accounts gl on gl.id=bk.accounting_account_id and gl.business_id=bk.business_id and not coalesce(gl.archived,false) and gl.account_type='asset' and gl.account_subtype='bank' where bk.business_id=b and bk.id=bank_id and not coalesce(bk.archived,false);
 if a is null then raise exception 'Select an active bank linked to this business ledger';end if;
 if exists(select 1 from public.bank_accounts bk join public.businesses bs on bs.id=bk.business_id where bk.id=bank_id and bk.currency::text<>coalesce(bs.settings->>'currency','NZD')) then raise exception 'Foreign-currency bank entries require an exchange-rate workflow';end if;return a;
end $$;

create function frindly_cash.line(a uuid,d numeric,c numeric,label text) returns jsonb language sql immutable set search_path='' as $$select jsonb_build_object('account_id',a,'debit',d,'credit',c,'description',label,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)$$;

-- Return journal line data for a cash leg; transfers use clearing so each bank keeps its own date.
create function frindly_cash.lines(p public.cash_transactions,p_bank uuid,p_amount numeric) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid;bank uuid;lines jsonb;net numeric;g uuid;
begin
 bank:=frindly_cash.bank_gl(p.business_id,p_bank);
 lines:=jsonb_build_array(frindly_cash.line(bank,greatest(p_amount,0),greatest(-p_amount,0),p.description));
 if p.kind='transfer' then
  a:=frindly_cash.account(p.business_id,'bank_transfer_clearing','Bank Transfer Clearing','asset');
  return lines||jsonb_build_array(frindly_cash.line(a,greatest(-p_amount,0),greatest(p_amount,0),'Transfer in transit'));
 end if;
 net:=p.amount+p.withheld_amount-p.gst_amount-p.interest_amount;
 lines:=lines||jsonb_build_array(frindly_cash.line(p.account_id,case when p_amount<0 then net else 0 end,case when p_amount>0 then net else 0 end,p.description));
 if p.gst_amount>0 then
  g:=public.v61105_account_role_id(p.business_id,'gst_output');if g is null then raise exception 'GST output account mapping is missing';end if;
  lines:=lines||jsonb_build_array(frindly_cash.line(g,0,p.gst_amount,'GST on grant receipt'));
 end if;
 if p.interest_amount>0 then
  a:=frindly_cash.account(p.business_id,'loan_interest','Loan Interest','expense');lines:=lines||jsonb_build_array(frindly_cash.line(a,p.interest_amount,0,'Loan interest'));
 end if;
 if p.withheld_amount>0 then
  a:=frindly_cash.account(p.business_id,'withholding_tax_receivable','Withholding Tax Receivable','asset');lines:=lines||jsonb_build_array(frindly_cash.line(a,p.withheld_amount,0,'Tax withheld from interest'));
 end if;
 return lines;
end $$;

-- Extracted existing owner/equity account resolver; both manual entry and reconciliation use it.
create function frindly_cash.owner_account(v_bid uuid,p_equity_type text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_counterpart uuid;v_uid uuid:=auth.uid();v_is_short_chart boolean;v_code text;
begin
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


return v_counterpart;
end $$;

create function frindly_cash.record(p_request uuid,p jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare b uuid:=frindly_cash.access(true);c public.cash_transactions%rowtype;old public.cash_transactions%rowtype;v_id uuid:=gen_random_uuid();bank uuid:=(p->>'bank_id')::uuid;dest uuid:=nullif(p->>'to_bank_id','')::uuid;d date:=(p->>'date')::date;d2 date:=coalesce(nullif(p->>'received_date','')::date,d);kind text:=p->>'kind';purpose text:=p->>'purpose';amt numeric:=(p->>'amount')::numeric;interest numeric:=coalesce((p->>'interest_amount')::numeric,0);withheld numeric:=coalesce((p->>'withheld_amount')::numeric,0);gst numeric:=0;rate numeric;tax text:=coalesce(p->>'gst_treatment','NO_GST');a uuid;owner uuid:=nullif(p->>'owner_id','')::uuid;owner_entry uuid;balance numeric;j uuid;settings jsonb;taxpayer text:=p->>'taxpayer';yr int:=nullif(p->>'tax_year','')::int;label text:=nullif(btrim(p->>'description'),'');
begin
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 if p_request is null or p is null then raise exception 'Request ID and transaction details are required';end if;
 select * into old from public.cash_transactions where business_id=b and request_id=p_request;
 if old.id is not null then if old.request_payload<>p then raise exception 'Request ID already used for a different transaction';end if;return old.id;end if;
 if kind not in ('in','out','transfer') or kind is null or amt is null or amt<=0 or amt<>round(amt,2) or amt>999999999999.99 or interest<0 or interest<>round(interest,2) or withheld<0 or withheld<>round(withheld,2) or label is null or length(label)>500 then raise exception 'Enter a purpose, valid amount and description';end if;
 perform frindly_cash.check_date(b,d,tax in ('GST','ZERO'));
 perform frindly_cash.bank_gl(b,bank);
 if exists(select 1 from public.bank_accounts where business_id=b and id=bank and opening_balance_journal_id is not null and d<opening_balance_date) then raise exception 'This payment predates the bank opening balance. Review opening history before posting it again';end if;
 if tax not in ('NO_GST','GST','ZERO') or tax is null then raise exception 'Choose a valid GST treatment';end if;
 if tax<>'NO_GST' and purpose<>'grant' then raise exception 'Only grant receipts use GST in this workflow';end if;
 if interest>0 and purpose<>'loan_repayment' or withheld>0 and purpose<>'interest' then raise exception 'Invalid interest or withholding allocation';end if;
 if interest>=amt then raise exception 'Loan interest must be less than the payment; record ordinary interest costs in Expenses';end if;
 if kind='transfer' then
  if purpose<>'transfer' or dest is null or dest=bank or interest<>0 or withheld<>0 or owner is not null then raise exception 'Choose two different bank accounts';end if;
  perform frindly_cash.bank_gl(b,dest);perform frindly_cash.check_date(b,d2);
  if exists(select 1 from public.bank_accounts where business_id=b and id=dest and opening_balance_journal_id is not null and d2<opening_balance_date) then raise exception 'Transfer predates the destination bank opening balance';end if;
  if (select currency from public.bank_accounts where id=bank) is distinct from (select currency from public.bank_accounts where id=dest) or (select accounting_account_id from public.bank_accounts where id=bank)=(select accounting_account_id from public.bank_accounts where id=dest) then raise exception 'Transfers require separate ledgers in the same currency';end if;
 else
  if kind='in' and purpose not in ('grant','interest','loan_received','owner_funds_introduced','director_loan_received','capital_contribution','income_tax_refund','deposit_return','other_receipt') or kind='out' and purpose not in ('income_tax','loan_repayment','owner_drawings','repay_owner_loan','director_payment','dividend_distribution','deposit_paid','other_payment') or purpose is null then raise exception 'Choose a supported non-standard transaction purpose';end if;
  if purpose in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment','capital_contribution','owner_drawings','dividend_distribution') then
   a:=frindly_cash.owner_account(b,purpose);
   if owner is not null and not exists(select 1 from public.business_owners where business_id=b and id=owner and status='active') then raise exception 'Select an active owner/shareholder';end if;
   if purpose in ('repay_owner_loan','director_payment') and owner is not null then
    select coalesce(sum(amount),0) into balance from public.owner_current_account_entries where business_id=b and owner_id=owner;
    if balance<amt then raise exception 'Repayment exceeds this owner current-account balance';end if;
   end if;
  elsif purpose in ('income_tax','income_tax_refund') then
   if yr is null or yr<2000 or yr>2200 or taxpayer not in ('business','owner') or taxpayer is null then raise exception 'Select who the tax is for and the tax year';end if;
   if taxpayer='owner' then
    if owner is null or not exists(select 1 from public.business_owners where business_id=b and id=owner and status='active') then raise exception 'Select the owner whose income tax this is';end if;
    a:=frindly_cash.owner_account(b,'owner_drawings');
   else
    if exists(select 1 from public.financial_settings where business_id=b and business_entity_type in ('sole_trader','partnership')) then raise exception 'Personal income tax must be recorded for the owner, not as business income tax';end if;
    select ac.id into a from public.accounting_accounts ac where ac.business_id=b and not coalesce(ac.archived,false) and ac.account_type in ('asset','current_asset','liability','current_liability') and (ac.system_key in ('income_tax_payable','income_tax_paid','provisional_tax') or ac.system_account_key in ('income_tax_payable','income_tax_paid','provisional_tax')) order by case when ac.system_key='income_tax_payable' or ac.system_account_key='income_tax_payable' then 0 else 1 end,ac.account_code limit 1;
    if a is null then a:=frindly_cash.account(b,'income_tax_paid','Income Tax Paid','asset');end if;
   end if;
  elsif purpose in ('loan_received','loan_repayment') then a:=frindly_cash.account(b,'bank_loan','Bank Loan','liability');
  elsif purpose in ('deposit_paid','deposit_return') then a:=frindly_cash.account(b,'refundable_deposits','Refundable Deposits','asset');
  elsif purpose='grant' then
   if nullif(btrim(p->>'party'),'') is null or nullif(btrim(p->>'note'),'') is null then raise exception 'Enter the grant funder and purpose/tax treatment note';end if;
   a:=frindly_cash.account(b,'grants_received','Grants Received','other_income');
  elsif purpose='interest' then a:=frindly_cash.account(b,'bank_interest_received','Bank Interest Received','other_income');
  else
   a:=nullif(p->>'account_id','')::uuid;
   if not exists(select 1 from public.accounting_accounts where business_id=b and id=a and not coalesce(archived,false) and not coalesce(is_control,false) and coalesce(allow_manual_posting,false) and account_type in ('asset','liability','equity','revenue','other_income') and coalesce(system_key,system_account_key,'') !~ '(bank|receivable|payable|gst|payroll|tax|clearing|sales|opening_balance)' and account_subtype is distinct from 'bank' and id not in(select accounting_account_id from public.bank_accounts where business_id=b and accounting_account_id is not null)) then raise exception 'Choose an eligible non-standard category; use existing payment workflows for control accounts';end if;
  end if;
  if purpose='loan_repayment' then
   select coalesce(sum(l.credit-l.debit),0) into balance from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=a and j.status in ('posted','reversed') and j.journal_date<=d;
   if amt-interest>round(balance,2) then raise exception 'Loan principal repayment exceeds the recorded loan balance. Review the opening loan balance first';end if;
  elsif purpose='deposit_return' then
   select coalesce(sum(l.debit-l.credit),0) into balance from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=a and j.status in ('posted','reversed') and j.journal_date<=d;
   if amt>round(balance,2) then raise exception 'Deposit return exceeds the recorded refundable deposit balance';end if;
  end if;
  if owner is not null and purpose not in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment','capital_contribution','owner_drawings','dividend_distribution','income_tax','income_tax_refund') then raise exception 'Owner is not applicable';end if;
  if tax<>'NO_GST' then
   select bs.settings into settings from public.businesses bs where id=b;
   if coalesce(settings->>'country','NZ')<>'NZ' then raise exception 'GST-bearing general receipts currently require NZ tax configuration';end if;
   settings:=public.v61105_effective_tax_status(d);
   if not coalesce((settings->>'gst_registered')::boolean,false) then raise exception 'Business is not GST registered on this date';end if;
   rate:=coalesce((settings->>'effective_rate_percent')::numeric,0);if tax='GST' and rate<=0 then raise exception 'GST rate is unavailable';end if;
   gst:=case when tax='GST' then round(amt*rate/(100+rate),2) else 0 end;
  end if;
 end if;
 insert into public.cash_transactions(id,business_id,request_id,request_payload,kind,purpose,description,reference,note,party,tax_year,taxpayer,owner_id,account_id,amount,gst_amount,gst_treatment,interest_amount,withheld_amount,created_by)
 values(v_id,b,p_request,p,kind,purpose,label,nullif(btrim(p->>'reference'),''),nullif(btrim(p->>'note'),''),nullif(btrim(p->>'party'),''),yr,taxpayer,owner,a,amt,gst,tax,interest,withheld,auth.uid()) returning * into c;
 j:=public.v6192_create_posted_journal(b,d,'bank',case when kind='transfer' then 'cash_transfer' else 'cash_transaction' end,v_id,c.reference,label,frindly_cash.lines(c,bank,case when kind='in' then amt else -amt end));
 insert into public.cash_transaction_legs(business_id,transaction_id,bank_account_id,original_date,transaction_date,amount,accounting_journal_id) values(b,v_id,bank,d,d,case when kind='in' then amt else -amt end,j);
 if kind='transfer' then
  j:=public.v6192_create_posted_journal(b,d2,'bank','cash_transfer',v_id,c.reference,label,frindly_cash.lines(c,dest,amt));
  insert into public.cash_transaction_legs(business_id,transaction_id,bank_account_id,original_date,transaction_date,amount,accounting_journal_id) values(b,v_id,dest,d2,d2,amt,j);
 end if;
 if owner is not null and purpose in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment') then
  insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,description,created_by)
  values(b,owner,d,case when kind='in' then 'funds_introduced' else 'reimbursement' end,case when kind='in' then amt else -amt end,'cash_transaction',v_id,c.reference,j,label,auth.uid());
 end if;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'cash_transaction',v_id,'recorded',p,auth.uid());return v_id;
end $$;

create function frindly_cash.reverse_at(b uuid,j uuid,reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare old public.accounting_journals%rowtype;lines jsonb;r uuid;
begin
 select * into old from public.accounting_journals where business_id=b and id=j and status='posted' for update;
 if old.id is null then raise exception 'Original posted journal not available';end if;
 perform frindly_cash.check_date(b,old.journal_date);
 select jsonb_agg(jsonb_build_object('account_id',account_id,'description',reason,'debit',credit,'credit',debit,'tax_code',tax_code,'tax_rate',tax_rate,'tax_amount',-tax_amount)) into lines from public.accounting_journal_lines where business_id=b and journal_id=j;
 r:=public.v6192_create_posted_journal(b,old.journal_date,old.journal_type,'cash_correction',gen_random_uuid(),old.source_reference,reason,lines);
 update public.accounting_journals set status='reversed',reversed_by_journal_id=r where id=j and business_id=b;
 update public.accounting_journals set reversal_of_journal_id=j where id=r and business_id=b;
 return r;
end $$;

create function frindly_cash.match(p_bank_transaction uuid,p_leg uuid,p_request uuid default null,p_payload jsonb default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare b uuid:=frindly_cash.access(true,true);tx public.bank_transactions%rowtype;l public.cash_transaction_legs%rowtype;c public.cash_transactions%rowtype;pid uuid;j uuid;old_date date;rid uuid;newlines jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into tx from public.bank_transactions where id=p_bank_transaction and business_id=b for update;
 if tx.id is null then raise exception 'Bank transaction not found';end if;
 if tx.status<>'unreconciled' or exists(select 1 from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id) then
  if p_leg is not null and exists(select 1 from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id and cash_leg_id=p_leg) then return p_leg;end if;
  if p_request is not null and exists(select 1 from public.bank_reconciliation_allocations a join public.cash_transaction_legs cl on cl.id=a.cash_leg_id join public.cash_transactions ct on ct.id=cl.transaction_id where a.business_id=b and a.bank_transaction_id=tx.id and ct.request_id=p_request and ct.request_payload=p_payload) then select cash_leg_id into rid from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id;return rid;end if;
  raise exception 'Bank transaction already reconciled or allocated';
 end if;
 perform frindly_cash.check_date(b,tx.transaction_date);
 if p_leg is null then
  if p_payload is null or (p_payload->>'amount')::numeric is distinct from abs(tx.amount) then raise exception 'New transaction must agree with the bank statement';end if;
  if p_payload->>'kind'='transfer' and tx.amount>0 then
   if (p_payload->>'to_bank_id')::uuid is distinct from tx.bank_account_id or coalesce(nullif(p_payload->>'received_date','')::date,(p_payload->>'date')::date) is distinct from tx.transaction_date then raise exception 'Transfer destination/date must agree with the statement';end if;
  elsif (p_payload->>'bank_id')::uuid is distinct from tx.bank_account_id or (p_payload->>'date')::date is distinct from tx.transaction_date or ((p_payload->>'kind'='in')<>(tx.amount>0)) then raise exception 'Transaction bank/date/direction must agree with the statement';end if;
  pid:=frindly_cash.record(p_request,p_payload);
  select * into l from public.cash_transaction_legs where business_id=b and transaction_id=pid and bank_account_id=tx.bank_account_id;
 else select * into l from public.cash_transaction_legs where business_id=b and id=p_leg for update;end if;
 if l.id is null or l.bank_account_id<>tx.bank_account_id or l.amount<>tx.amount then raise exception 'Transaction bank, amount or direction differs from the statement';end if;
 if exists(select 1 from public.bank_reconciliation_allocations where cash_leg_id=l.id) then raise exception 'Transaction already matched';end if;
 select * into c from public.cash_transactions where business_id=b and id=l.transaction_id and status='recorded';
 if c.id is null then raise exception 'Recorded transaction unavailable';end if;
 if not exists(select 1 from public.accounting_journals where business_id=b and id=l.accounting_journal_id and status='posted') then raise exception 'Transaction journal unavailable';end if;
 if exists(select 1 from public.bank_accounts where business_id=b and id=l.bank_account_id and opening_balance_journal_id is not null and tx.transaction_date<opening_balance_date) then raise exception 'Statement date predates the bank opening balance';end if;
 if l.transaction_date<>tx.transaction_date then
  perform frindly_cash.check_date(b,l.transaction_date,c.gst_treatment<>'NO_GST');perform frindly_cash.check_date(b,tx.transaction_date,c.gst_treatment<>'NO_GST');
  if c.gst_treatment<>'NO_GST' then
   if (public.v61105_effective_tax_status(l.transaction_date)->>'effective_rate_percent') is distinct from (public.v61105_effective_tax_status(tx.transaction_date)->>'effective_rate_percent') or not coalesce((public.v61105_effective_tax_status(tx.transaction_date)->>'gst_registered')::boolean,false) then raise exception 'Date change crosses a GST status/rate boundary; review the transaction first';end if;
  end if;
  old_date:=l.transaction_date;
  -- Preserve the exact original allocations even if account mappings later change.
  select jsonb_agg(jsonb_build_object('account_id',account_id,'description',description,'debit',debit,'credit',credit,'tax_code',tax_code,'tax_rate',tax_rate,'tax_amount',tax_amount)) into newlines from public.accounting_journal_lines where business_id=b and journal_id=l.accounting_journal_id;
  rid:=frindly_cash.reverse_at(b,l.accounting_journal_id,'Bank statement date correction');
  j:=public.v6192_create_posted_journal(b,tx.transaction_date,'bank',case when c.kind='transfer' then 'cash_transfer' else 'cash_transaction' end,c.id,c.reference,c.description,newlines);
  update public.cash_transaction_legs set transaction_date=tx.transaction_date,accounting_journal_id=j where id=l.id;
  -- Owner amounts stay unchanged; date/journal provenance is retained in the accounting audit.
  update public.owner_current_account_entries set entry_date=tx.transaction_date,accounting_journal_id=j where business_id=b and source_type='cash_transaction' and source_id=c.id;
  insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'cash_transaction',c.id,'statement_date_corrected',jsonb_build_object('old_date',old_date,'statement_date',tx.transaction_date,'original_journal',l.accounting_journal_id,'reversal_journal',rid,'replacement_journal',j),auth.uid());
  l.accounting_journal_id:=j;
 end if;
 insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,accounting_journal_id,cash_leg_id,created_by) values(b,tx.id,case when c.kind='transfer' then 'transfer' else 'cash_transaction' end,abs(l.amount),l.accounting_journal_id,l.id,auth.uid());
 update public.bank_transactions set status='reconciled',reconciliation_type=case when c.kind='transfer' then 'transfer' else 'cash_transaction' end,reconciled_at=now(),reconciled_by=auth.uid(),updated_at=now(),updated_by=auth.uid() where id=tx.id and business_id=b;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(b,tx.id,'cash_transaction_matched',jsonb_build_object('transaction_id',c.id,'leg_id',l.id,'journal_id',l.accounting_journal_id),auth.uid());return l.id;
end $$;

create function frindly_cash.unmatch(p_bank_transaction uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare b uuid:=frindly_cash.access(true,true);tx public.bank_transactions%rowtype;
begin
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into tx from public.bank_transactions where business_id=b and id=p_bank_transaction for update;
 if tx.id is null then raise exception 'Bank transaction not found';end if;perform frindly_cash.check_date(b,tx.transaction_date);
 if not exists(select 1 from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id and cash_leg_id is not null) then raise exception 'Cash transaction match not found';end if;
 delete from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id and cash_leg_id is not null;
 update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,updated_at=now(),updated_by=auth.uid() where business_id=b and id=tx.id;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(b,tx.id,'cash_transaction_unmatched',jsonb_build_object('reason',p_reason,'payment_preserved',true),auth.uid());
end $$;

create function frindly_cash.void(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare b uuid:=frindly_cash.access(true);c public.cash_transactions%rowtype;legrow record;r uuid;entry record;
begin
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into c from public.cash_transactions where business_id=b and id=p_id and status='recorded' for update;
 if c.id is null or nullif(btrim(p_reason),'') is null then raise exception 'Select a recorded transaction and enter a reason';end if;
 if exists(select 1 from public.bank_reconciliation_allocations a join public.cash_transaction_legs cl on cl.id=a.cash_leg_id where cl.transaction_id=c.id) then raise exception 'Unmatch the bank statement before reversing this transaction';end if;
 if c.purpose in ('owner_funds_introduced','director_loan_received') and c.owner_id is not null and (select coalesce(sum(amount),0) from public.owner_current_account_entries where business_id=b and owner_id=c.owner_id)<c.amount then raise exception 'Owner funds have already been repaid. Review linked repayments before reversing this receipt';end if;
 if c.purpose in ('loan_received','deposit_paid') and (select coalesce(sum(case when c.purpose='loan_received' then l.credit-l.debit else l.debit-l.credit end),0) from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=c.account_id and j.status in ('posted','reversed'))<c.amount then raise exception 'This balance has already been settled. Review linked repayments or deposit returns first';end if;
 for legrow in select * from public.cash_transaction_legs where business_id=b and transaction_id=c.id loop
  perform frindly_cash.check_date(b,legrow.transaction_date,c.gst_treatment<>'NO_GST');r:=frindly_cash.reverse_at(b,legrow.accounting_journal_id,p_reason);
 end loop;
 for entry in select * from public.owner_current_account_entries where business_id=b and source_type='cash_transaction' and source_id=c.id loop
  insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,reversal_of_entry_id,description,created_by) values(b,entry.owner_id,entry.entry_date,'reversal',-entry.amount,'cash_transaction_void',c.id,entry.source_reference,r,entry.id,p_reason,auth.uid());
 end loop;
 update public.cash_transactions set status='void' where id=c.id;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'cash_transaction',c.id,'void',jsonb_build_object('reason',p_reason),auth.uid());
end $$;

-- Controlled writes only. Legacy allocations remain untouched.
do $$declare ck record;begin
 for ck in select conname,pg_get_constraintdef(oid) def from pg_constraint where conrelid='public.bank_reconciliation_allocations'::regclass and contype='c' and pg_get_constraintdef(oid) like '%allocation_type%' loop
  execute format('alter table public.bank_reconciliation_allocations drop constraint %I',ck.conname);
  execute format('alter table public.bank_reconciliation_allocations add constraint %I %s',ck.conname,replace(ck.def,'''invoice''::text','''cash_transaction''::text, ''invoice''::text'));
 end loop;
end $$;
do $$declare ck record;begin
 for ck in select conname,pg_get_constraintdef(oid) def from pg_constraint where conrelid='public.bank_transactions'::regclass and contype='c' and pg_get_constraintdef(oid) like '%reconciliation_type%' loop
  execute format('alter table public.bank_transactions drop constraint %I',ck.conname);
  execute format('alter table public.bank_transactions add constraint %I %s',ck.conname,replace(ck.def,'''invoice''::text','''cash_transaction''::text, ''invoice''::text'));
 end loop;
end $$;
create function frindly_cash.guard_match() returns trigger language plpgsql set search_path='' as $$
begin
 if (case when tg_op='DELETE' then old.cash_leg_id is not null when tg_op='UPDATE' then old.cash_leg_id is not null or new.cash_leg_id is not null or new.allocation_type='cash_transaction' else new.cash_leg_id is not null or new.allocation_type='cash_transaction' end) then
  if current_user in ('anon','authenticated') then raise exception 'Cash matches must use the controlled transaction workflow';end if;
  if tg_op<>'DELETE' and not exists(select 1 from public.cash_transaction_legs l join public.bank_transactions t on t.id=new.bank_transaction_id and t.business_id=l.business_id where l.business_id=new.business_id and l.id=new.cash_leg_id and l.bank_account_id=t.bank_account_id and l.amount=t.amount and abs(l.amount)=new.amount and l.accounting_journal_id=new.accounting_journal_id) then raise exception 'Cash allocation does not agree with statement and ledger';end if;
 end if;
 return case when tg_op='DELETE' then old else new end;
end $$;
create trigger frindly_cash_match_guard before insert or update or delete on public.bank_reconciliation_allocations for each row execute function frindly_cash.guard_match();

create function public.frindly_record_cash_transaction(p_request_id uuid,p_transaction jsonb) returns uuid language sql security invoker set search_path='' as $$select frindly_cash.record(p_request_id,p_transaction)$$;
create function public.frindly_match_cash_transaction(p_bank_transaction_id uuid,p_leg_id uuid default null,p_request_id uuid default null,p_transaction jsonb default null) returns uuid language sql security invoker set search_path='' as $$select frindly_cash.match(p_bank_transaction_id,p_leg_id,p_request_id,p_transaction)$$;
create function public.frindly_unmatch_cash_transaction(p_bank_transaction_id uuid,p_reason text default 'Undo bank match') returns void language sql security invoker set search_path='' as $$select frindly_cash.unmatch(p_bank_transaction_id,p_reason)$$;
create function public.frindly_void_cash_transaction(p_transaction_id uuid,p_reason text) returns void language sql security invoker set search_path='' as $$select frindly_cash.void(p_transaction_id,p_reason)$$;

create function frindly_cash.snapshot() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b uuid:=frindly_cash.access();begin
 return jsonb_build_object('entity_type',(select business_entity_type from public.financial_settings where business_id=b),'transactions',coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('account_type',(select account_type from public.accounting_accounts where id=c.account_id and business_id=b),'legs',(select jsonb_agg(to_jsonb(l)||jsonb_build_object('matched',exists(select 1 from public.bank_reconciliation_allocations a where a.cash_leg_id=l.id),'bank_name',bk.name)) from public.cash_transaction_legs l join public.bank_accounts bk on bk.id=l.bank_account_id where l.transaction_id=c.id and l.business_id=b)) order by c.created_at desc) from public.cash_transactions c where c.business_id=b),'[]'::jsonb),
 'owners',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'name',o.display_name)) from public.business_owners o where o.business_id=b and o.status='active'),'[]'::jsonb),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'name',a.account_name,'type',a.account_type,'key',coalesce(a.system_key,a.system_account_key))) from public.accounting_accounts a where a.business_id=b and not coalesce(a.archived,false) and not coalesce(a.is_control,false) and coalesce(a.allow_manual_posting,false) and a.account_type in ('asset','liability','equity','revenue','other_income') and coalesce(a.system_key,a.system_account_key,'') !~ '(bank|receivable|payable|gst|payroll|tax|clearing|sales|opening_balance)' and a.account_subtype is distinct from 'bank' and a.id not in(select accounting_account_id from public.bank_accounts where business_id=b and accounting_account_id is not null)),'[]'::jsonb),
 'can_write',public.v6147_can_write_area(b,'financials'));
end $$;
create function public.frindly_cash_snapshot() returns jsonb language sql stable security invoker set search_path='' as $$select frindly_cash.snapshot()$$;

CREATE OR REPLACE FUNCTION frindly_cash.gst_base(p_from date, p_to date, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  bid uuid:=public.current_business_id(); d date; isreg boolean; prevreg boolean:=false; day_basis text; prev_basis text;
  seg_start date; seg_end date; part jsonb; cfg jsonb; basis text;
  sales_ex numeric:=0; sales_gst numeric:=0; purch_ex numeric:=0; purch_gst numeric:=0;
  debit_adj numeric:=0; credit_adj numeric:=0;
  sales_items jsonb:='[]'::jsonb; purchase_items jsonb:='[]'::jsonb;
  adjustment_items jsonb:='[]'::jsonb; review jsonb:='[]'::jsonb;
  windows jsonb:='[]'::jsonb; registered_days int:=0; total_days int;
begin
  if bid is null or not public.v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid GST period'; end if;
  total_days:=p_to-p_from+1;
  for d in select generate_series(p_from,p_to,interval '1 day')::date loop
    isreg:=coalesce((public.v6170e_gst_settings(d)->>'gst_registered')::boolean,false);
    day_basis:=coalesce(nullif(p_basis,''),(public.v6170e_gst_settings(d)->>'accounting_basis')); day_basis:=case day_basis when 'non_cash' then 'invoice' when 'cash' then 'payments' else day_basis end; if day_basis not in ('invoice','payments','hybrid') then raise exception 'Invalid GST basis'; end if;
    if isreg then
      registered_days:=registered_days+1;
      if not prevreg then seg_start:=d; end if;
    end if;
    if prevreg and (not isreg or day_basis<>prev_basis) then
      seg_end:=d-1;
      part:=public.frindly_gst_calculate_basis_v1(seg_start,seg_end,prev_basis);
      if cfg is null then cfg:=part->'settings'; basis:=part->>'basis'; end if;
      sales_ex:=sales_ex+coalesce((part->>'sales_ex_gst')::numeric,0);
      sales_gst:=sales_gst+coalesce((part->>'gst_collected')::numeric,0);
      purch_ex:=purch_ex+coalesce((part->>'purchases_ex_gst')::numeric,0);
      purch_gst:=purch_gst+coalesce((part->>'gst_paid')::numeric,0);
      debit_adj:=debit_adj+coalesce((part->>'debit_adjustments')::numeric,0);
      credit_adj:=credit_adj+coalesce((part->>'credit_adjustments')::numeric,0);
      sales_items:=sales_items||coalesce(part->'sales_items','[]'::jsonb);
      purchase_items:=purchase_items||coalesce(part->'purchase_items','[]'::jsonb);
      adjustment_items:=adjustment_items||coalesce(part->'adjustment_items','[]'::jsonb);
      review:=review||coalesce(part->'review_items','[]'::jsonb);
      windows:=windows||jsonb_build_array(jsonb_build_object('from',seg_start,'to',seg_end));
    end if;
    if isreg and (not prevreg or day_basis<>prev_basis) then seg_start:=d; end if;
    prevreg:=isreg; prev_basis:=day_basis;
  end loop;
  if prevreg then
    seg_end:=p_to;
    part:=public.frindly_gst_calculate_basis_v1(seg_start,seg_end,prev_basis);
    if cfg is null then cfg:=part->'settings'; basis:=part->>'basis'; end if;
    sales_ex:=sales_ex+coalesce((part->>'sales_ex_gst')::numeric,0);
    sales_gst:=sales_gst+coalesce((part->>'gst_collected')::numeric,0);
    purch_ex:=purch_ex+coalesce((part->>'purchases_ex_gst')::numeric,0);
    purch_gst:=purch_gst+coalesce((part->>'gst_paid')::numeric,0);
    debit_adj:=debit_adj+coalesce((part->>'debit_adjustments')::numeric,0);
    credit_adj:=credit_adj+coalesce((part->>'credit_adjustments')::numeric,0);
    sales_items:=sales_items||coalesce(part->'sales_items','[]'::jsonb);
    purchase_items:=purchase_items||coalesce(part->'purchase_items','[]'::jsonb);
    adjustment_items:=adjustment_items||coalesce(part->'adjustment_items','[]'::jsonb);
    review:=review||coalesce(part->'review_items','[]'::jsonb);
    windows:=windows||jsonb_build_array(jsonb_build_object('from',seg_start,'to',seg_end));
  end if;
  if registered_days=0 then
    cfg:=public.v6170e_gst_settings(p_to);
    return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',coalesce(nullif(p_basis,''),cfg->>'accounting_basis'),'sales_ex_gst',0,'gst_collected',0,'purchases_ex_gst',0,'gst_paid',0,'debit_adjustments',0,'credit_adjustments',0,'gst_net',0,'sales_items','[]'::jsonb,'purchase_items','[]'::jsonb,'adjustment_items','[]'::jsonb,'registered_windows','[]'::jsonb,'review_items',jsonb_build_array(jsonb_build_object('severity','blocking','code','not_registered','message','Business is not GST registered for this period.')),'calculation_version','frindly-gst-boundary-v1');
  end if;
  if registered_days<total_days then
    review:=review||jsonb_build_array(jsonb_build_object('severity','info','code','registration_boundary','message','This GST period crosses a GST registration boundary. Only dates when the business was GST registered are included.','registered_windows',windows));
  end if;
  return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',basis,'sales_ex_gst',round(sales_ex,2),'gst_collected',round(sales_gst,2),'purchases_ex_gst',round(purch_ex,2),'gst_paid',round(purch_gst,2),'debit_adjustments',round(debit_adj,2),'credit_adjustments',round(credit_adj,2),'gst_net',round(sales_gst+debit_adj-purch_gst-credit_adj,2),'sales_items',sales_items,'purchase_items',purchase_items,'adjustment_items',adjustment_items,'registered_windows',windows,'review_items',review,'calculation_version','frindly-gst-boundary-v1');
end $function$
;

create or replace function public.frindly_gst_boundary_basis_v1(p_from date,p_to date,p_basis text default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare b uuid:=public.current_business_id();result jsonb;items jsonb;ex numeric;gst numeric;
begin
 result:=frindly_cash.gst_base(p_from,p_to,p_basis);
 select coalesce(sum(c.amount-c.gst_amount),0),coalesce(sum(c.gst_amount),0),coalesce(jsonb_agg(jsonb_build_object('source_type','cash_transaction','source_id',c.id,'date',l.transaction_date,'reference',coalesce(c.reference,c.description),'party',c.party,'ex_gst',c.amount-c.gst_amount,'gst',c.gst_amount,'total',c.amount,'classification',case when c.gst_treatment='ZERO' then 'zero_rated' else 'standard' end)),'[]'::jsonb) into ex,gst,items
 from public.cash_transactions c join public.cash_transaction_legs l on l.transaction_id=c.id and l.business_id=c.business_id
 where c.business_id=b and c.status='recorded' and c.purpose='grant' and c.gst_treatment in ('GST','ZERO') and l.transaction_date between p_from and p_to;
 return result||jsonb_build_object('sales_ex_gst',coalesce((result->>'sales_ex_gst')::numeric,0)+ex,'gst_collected',coalesce((result->>'gst_collected')::numeric,0)+gst,'gst_net',coalesce((result->>'gst_net')::numeric,0)+gst,'sales_items',coalesce(result->'sales_items','[]'::jsonb)||items);
end $$;

revoke all on all functions in schema frindly_cash from public,anon,authenticated;
grant execute on function frindly_cash.record(uuid,jsonb),frindly_cash.match(uuid,uuid,uuid,jsonb),frindly_cash.unmatch(uuid,text),frindly_cash.void(uuid,text),frindly_cash.snapshot() to authenticated;
revoke all on function public.frindly_record_cash_transaction(uuid,jsonb),public.frindly_match_cash_transaction(uuid,uuid,uuid,jsonb),public.frindly_unmatch_cash_transaction(uuid,text),public.frindly_void_cash_transaction(uuid,text),public.frindly_cash_snapshot() from public,anon;
grant execute on function public.frindly_record_cash_transaction(uuid,jsonb),public.frindly_match_cash_transaction(uuid,uuid,uuid,jsonb),public.frindly_unmatch_cash_transaction(uuid,text),public.frindly_void_cash_transaction(uuid,text),public.frindly_cash_snapshot() to authenticated;
revoke all on function frindly_cash.gst_base(date,date,text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.v61114_statement_cash_flows(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with ctx as (
  select public.current_business_id() as bid, auth.uid() as uid
),
cash_accounts as (
  select a.id
  from public.accounting_accounts a
  join ctx on ctx.bid = a.business_id
  where ctx.uid is not null
    and not coalesce(a.archived, false)
    and (
      a.account_type in ('bank','cash')
      or
      a.account_subtype in ('bank','cash','cash_equivalent')
      or a.system_account_key in ('bank','bank_main','cash','cash_on_hand')
      or a.system_key in ('bank','bank_main','cash','cash_on_hand')
      or a.xero_account_type in ('BANK')
      or a.account_code in ('090','1000')
    )
),
cash_by_journal as (
  select
    j.id as journal_id,
    j.business_id,
    j.journal_date,
    j.journal_number,
    coalesce(j.source_reference, j.journal_number) as reference,
    coalesce(j.source_type, j.journal_type, 'journal') as source_type,
    round(sum(l.debit - l.credit), 2) as cash_change
  from public.accounting_journals j
  join ctx on ctx.bid = j.business_id
  join public.accounting_journal_lines l
    on l.journal_id = j.id
   and l.business_id = j.business_id
  join cash_accounts ca on ca.id = l.account_id
  where ctx.uid is not null
    and j.status in ('posted','reversed')
    and j.journal_date <= p_to
  group by j.id, j.business_id, j.journal_date, j.journal_number, j.source_reference, j.source_type, j.journal_type
),
period_cash as (
  select *
  from cash_by_journal
  where journal_date between p_from and p_to
    and source_type <> 'bank_opening_balance'
    and abs(cash_change) > 0.005
),
classified as (
  select
    pc.*,
    case
      when exists(select 1 from public.accounting_journal_lines tl join public.accounting_accounts ta on ta.id=tl.account_id and ta.business_id=tl.business_id where tl.journal_id=pc.journal_id and tl.business_id=pc.business_id and (ta.system_key='bank_transfer_clearing' or ta.system_account_key='bank_transfer_clearing')) then 'transfers'
      when exists (
        select 1
        from public.accounting_journal_lines l
        join public.accounting_accounts a
          on a.id = l.account_id
         and a.business_id = l.business_id
        where l.journal_id = pc.journal_id
          and l.business_id = pc.business_id
          and l.account_id not in (select id from cash_accounts)
          and (
            a.account_type = 'equity'
            or a.report_section = 'equity'
            or a.account_subtype in ('loan','borrowings','owner_equity','owner_current','shareholder_current')
            or coalesce(a.system_account_key,'') similar to '%(owner|shareholder|loan|borrowing|dividend|drawing|capital)%'
            or coalesce(a.system_key,'') similar to '%(owner|shareholder|loan|borrowing|dividend|drawing|capital)%'
          )
      ) then 'financing'
      when exists (
        select 1
        from public.accounting_journal_lines l
        join public.accounting_accounts a
          on a.id = l.account_id
         and a.business_id = l.business_id
        where l.journal_id = pc.journal_id
          and l.business_id = pc.business_id
          and l.account_id not in (select id from cash_accounts)
          and (
            a.account_type in ('fixed_asset','non_current_asset')
            or a.report_section in ('fixed_assets','non_current_assets')
            or a.account_subtype in ('fixed_asset','equipment','vehicle','property')
            or coalesce(a.system_account_key,'') similar to '%(fixed_asset|equipment|asset_disposal)%'
            or coalesce(a.system_key,'') similar to '%(fixed_asset|equipment|asset_disposal)%'
          )
      ) then 'investing'
      else 'operating'
    end as section
  from period_cash pc
),
labelled as (
  select
    c.*,
    case
      when section = 'transfers' then 'Transfers in transit between bank accounts'
      when section = 'operating' and cash_change >= 0 then 'Receipts from customers and operating income'
      when section = 'operating' and source_type in ('payroll','bank') and exists (
        select 1
        from public.accounting_journal_lines l
        join public.accounting_accounts a on a.id = l.account_id and a.business_id = l.business_id
        where l.journal_id = c.journal_id
          and l.business_id = c.business_id
          and (a.account_subtype = 'payroll' or coalesce(a.system_account_key,'') like 'payroll_%' or coalesce(a.system_key,'') like 'payroll_%')
      ) then 'Payroll, PAYE and employee payments'
      when section = 'operating' then 'Payments to suppliers, tax and operations'
      when section = 'investing' and cash_change >= 0 then 'Proceeds from sale of assets'
      when section = 'investing' then 'Purchase of property and equipment'
      when section = 'financing' and cash_change >= 0 then 'Owner, shareholder or loan funds received'
      else 'Owner drawings, dividends or loan repayments'
    end as line_label
  from classified c
),
line_totals as (
  select
    section,
    line_label,
    round(sum(cash_change), 2) as amount,
    count(*) as journal_count
  from labelled
  group by section, line_label
),
section_totals as (
  select section, round(sum(amount), 2) as amount
  from line_totals
  group by section
),
section_payload as (
  select jsonb_agg(
    jsonb_build_object(
      'section', s.section,
      'label', case s.section
        when 'operating' then 'Cash flows from operating activities'
        when 'investing' then 'Cash flows from investing activities'
        when 'transfers' then 'Transfers in transit between bank accounts'
        else 'Cash flows from financing activities'
      end,
      'amount', coalesce(st.amount, 0),
      'lines', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'label', lt.line_label,
            'amount', lt.amount,
            'journal_count', lt.journal_count
          )
          order by lt.line_label
        )
        from line_totals lt
        where lt.section = s.section
      ), '[]'::jsonb)
    )
    order by case s.section when 'operating' then 1 when 'investing' then 2 when 'financing' then 3 else 4 end
  ) as sections
  from (select v.section from (values ('operating'), ('investing'), ('financing'), ('transfers')) v(section) where v.section<>'transfers' or exists(select 1 from classified where section='transfers')) as s
  left join section_totals st on st.section = s.section
),
totals as (
  select
    round(coalesce((select sum(cash_change) from cash_by_journal where journal_date < p_from or (journal_date between p_from and p_to and source_type = 'bank_opening_balance')), 0), 2) as opening_cash,
    round(coalesce((select sum(cash_change) from cash_by_journal where journal_date <= p_to), 0), 2) as closing_cash,
    round(coalesce((select sum(cash_change) from labelled), 0), 2) as net_movement,
    (select count(*) from cash_accounts) as cash_account_count,
    (select count(*) from period_cash) as journal_count
)
select jsonb_build_object(
  'from', p_from,
  'to', p_to,
  'method', 'direct',
  'basis', 'posted_ledger',
  'opening_cash', opening_cash,
  'closing_cash', closing_cash,
  'net_movement', net_movement,
  'calculated_closing_cash', round(opening_cash + net_movement, 2),
  'reconciles', round(opening_cash + net_movement, 2) = round(closing_cash, 2),
  'cash_account_count', cash_account_count,
  'journal_count', journal_count,
  'sections', coalesce(section_payload.sections, '[]'::jsonb),
  'warnings', (
    case when cash_account_count = 0
      then jsonb_build_array('No posted bank or cash ledger accounts were found for this business.')
      else '[]'::jsonb
    end
    ||
    case when round(opening_cash + net_movement, 2) <> round(closing_cash, 2)
      then jsonb_build_array('Opening cash plus net movement does not equal closing cash. Review cash/bank account setup.')
      else '[]'::jsonb
    end
  )
)
from totals, section_payload;
$function$
;

-- Compatibility entry points now create/match the same durable cash transaction.
create function frindly_cash.owner_from_statement(p_tx uuid,p_type text,p_owner uuid,p_note text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b uuid:=frindly_cash.access(true,true);t public.bank_transactions%rowtype;pid uuid;lid uuid;payload jsonb;
begin
 select * into t from public.bank_transactions where business_id=b and id=p_tx for update;
 if t.id is null then raise exception 'Bank transaction not found';end if;
 payload:=jsonb_build_object('kind',case when t.amount>0 then 'in' else 'out' end,'purpose',p_type,'bank_id',t.bank_account_id,'date',t.transaction_date,'amount',abs(t.amount),'owner_id',p_owner,'description',replace(initcap(p_type),'_',' '),'reference',t.reference,'note',p_note);
 lid:=frindly_cash.match(t.id,null,gen_random_uuid(),payload);
 select transaction_id into pid from public.cash_transaction_legs where id=lid;
 return jsonb_build_object('ok',true,'transaction_id',pid,'owner_id',p_owner,'journal_id',(select accounting_journal_id from public.cash_transaction_legs where id=lid),'allocation_id',(select id from public.bank_reconciliation_allocations where cash_leg_id=lid),'owner_entry_id',(select id from public.owner_current_account_entries where business_id=b and source_type='cash_transaction' and source_id=pid limit 1));
end $$;
create or replace function public.v61106e_reconcile_owner_equity_bank_transaction(p_bank_transaction_id uuid,p_equity_type text,p_note text default null) returns jsonb
language sql security invoker set search_path='' as $$select frindly_cash.owner_from_statement(p_bank_transaction_id,p_equity_type,null,p_note)$$;
create or replace function public.v61107w_reconcile_owner_current_account(p_bank_transaction_id uuid,p_owner_id uuid,p_action text,p_note text default null) returns jsonb
language plpgsql security invoker set search_path='' as $$begin
 if p_owner_id is null or p_action not in ('funds_introduced','reimbursement') or p_action is null then raise exception 'Choose an owner and supported action';end if;
 return frindly_cash.owner_from_statement(p_bank_transaction_id,case when p_action='funds_introduced' then 'owner_funds_introduced' else 'repay_owner_loan' end,p_owner_id,p_note);
end $$;
revoke all on function frindly_cash.owner_from_statement(uuid,text,uuid,text) from public,anon;
grant execute on function frindly_cash.owner_from_statement(uuid,text,uuid,text) to authenticated;
CREATE OR REPLACE FUNCTION public.v61107w_undo_owner_current_account(p_bank_transaction_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_bid uuid:=public.current_business_id();v_uid uuid:=auth.uid();v_tx public.bank_transactions%rowtype;v_alloc public.bank_reconciliation_allocations%rowtype;v_entry public.owner_current_account_entries%rowtype;v_rev_journal uuid;
begin
 if exists(select 1 from public.bank_reconciliation_allocations where business_id=public.current_business_id() and bank_transaction_id=p_bank_transaction_id and cash_leg_id is not null) then
  perform frindly_cash.unmatch(p_bank_transaction_id,p_reason);
  return jsonb_build_object('ok',true,'payment_preserved',true);
 end if;
 if v_uid is null or v_bid is null then raise exception 'Authentication and active business required'; end if;
 if not public.v6147_can_write_area(v_bid,'bank') then raise exception 'Bank reconciliation write access denied'; end if;
 select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
 if v_tx.id is null then raise exception 'Bank transaction not found'; end if;
 select * into v_alloc from public.bank_reconciliation_allocations where business_id=v_bid and bank_transaction_id=v_tx.id and allocation_type='owner_equity' and owner_id is not null order by created_at desc limit 1 for update;
 if v_alloc.id is null then raise exception 'Individual owner/shareholder reconciliation not found'; end if;
 select * into v_entry from public.owner_current_account_entries where business_id=v_bid and source_type='bank_reconciliation_allocation' and source_id=v_alloc.id order by created_at desc limit 1 for update;
 if v_entry.id is null then raise exception 'Owner current-account entry is missing; no changes made'; end if;
 if v_alloc.accounting_journal_id is not null then v_rev_journal:=public.v6170a_reverse_journal(v_alloc.accounting_journal_id,coalesce(nullif(btrim(p_reason),''),'Bank reconciliation undone')); end if;
 insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,reversal_of_entry_id,description,created_by)
 values(v_bid,v_entry.owner_id,current_date,'reversal',-v_entry.amount,'bank_reconciliation_undo',v_alloc.id,v_entry.source_reference,v_rev_journal,v_entry.id,'Reversal: '||coalesce(nullif(btrim(p_reason),''),'Bank reconciliation undone'),v_uid);
 delete from public.bank_reconciliation_allocations where id=v_alloc.id and business_id=v_bid;
 update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,updated_at=now(),updated_by=v_uid where id=v_tx.id and business_id=v_bid;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(v_bid,v_tx.id,'owner_current_account_undo',jsonb_build_object('owner_id',v_entry.owner_id,'allocation_id',v_alloc.id,'journal_id',v_alloc.accounting_journal_id,'reversal_journal_id',v_rev_journal,'reason',p_reason),v_uid);
 return jsonb_build_object('ok',true,'bank_transaction_id',v_tx.id,'owner_id',v_entry.owner_id,'reversal_journal_id',v_rev_journal);
end $function$
;
CREATE OR REPLACE FUNCTION public.v61106e_undo_owner_equity_bank_transaction(p_bank_transaction_id uuid, p_reason text DEFAULT 'Undo owner/equity bank reconciliation'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

-- Financial recording must not depend on Banking permission or the separate Reports area.
create policy frindly_cash_bank_picker on public.bank_accounts for select to authenticated
using(business_id=public.current_business_id() and public.v6147_can_read_area(business_id,'financials'));
create function frindly_cash.ledger(p_to date) returns table(journal_id uuid,journal_date date,journal_number text,source_type text,source_id uuid,source_reference text,description text,account_code text,account_name text,debit numeric,credit numeric,status text,bank_name text)
language plpgsql stable security definer set search_path='' as $$
declare b uuid:=frindly_cash.access();begin
 return query with mappings as (
  select bk.accounting_account_id gl,bk.name,0 priority from public.bank_accounts bk where bk.business_id=b and not bk.archived
  union all
  select al.accounting_account_id,bk.name,1 from public.bank_account_ledger_links al join public.bank_accounts bk on bk.id=al.bank_account_id and bk.business_id=al.business_id and not bk.archived where al.business_id=b
 ),bank_map as (select distinct on (gl) gl,name from mappings where gl is not null order by gl,priority,name)
 select j.id,j.journal_date,j.journal_number,j.source_type,j.source_id,j.source_reference,coalesce(l.description,j.description),a.account_code,a.account_name,l.debit,l.credit,j.status,m.name
 from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
 join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id join bank_map m on m.gl=a.id
 where j.business_id=b and j.status in ('posted','reversed') and j.journal_date<=p_to order by j.journal_date,j.id,l.id;
end $$;
create function public.frindly_cash_ledger(p_to date) returns table(journal_id uuid,journal_date date,journal_number text,source_type text,source_id uuid,source_reference text,description text,account_code text,account_name text,debit numeric,credit numeric,status text,bank_name text)
language sql stable security invoker set search_path='' as $$select * from frindly_cash.ledger(p_to)$$;
revoke all on function frindly_cash.ledger(date),public.frindly_cash_ledger(date) from public,anon;
grant execute on function frindly_cash.ledger(date),public.frindly_cash_ledger(date) to authenticated;
