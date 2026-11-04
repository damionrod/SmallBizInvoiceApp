-- Loan metadata only. Posted journals remain the source of principal balances.
create table frindly_cash.loans (
 id uuid primary key,
 business_id uuid not null references public.businesses(id),
 account_id uuid not null unique references public.accounting_accounts(id),
 bank_id uuid not null references public.bank_accounts(id),
 name text not null,
 lender text not null,
 loan_type text not null check (loan_type in ('business','vehicle','machinery','equipment','property','other')),
 original_amount numeric(14,2) not null check(original_amount>0),
 start_date date not null,
 terms jsonb not null,
 creation_details jsonb not null,
 closed boolean not null default false,
 created_at timestamptz not null default now(),
 unique(business_id,name)
);
alter table frindly_cash.loans enable row level security;
create policy loans_rpc_only on frindly_cash.loans for all to authenticated using(false) with check(false);
revoke all on frindly_cash.loans from public,anon,authenticated;
create index loans_bank_idx on frindly_cash.loans(bank_id);

create function frindly_cash.loan_balance(p_business uuid,p_account uuid,p_date date default 'infinity') returns numeric
language sql stable set search_path='' as $$
 select coalesce(sum(l.credit-l.debit),0)
 from public.accounting_journal_lines l
 join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id
 where l.business_id=p_business and l.account_id=p_account
 and j.status in ('posted','reversed') and j.journal_date<=p_date
$$;
revoke all on function frindly_cash.loan_balance(uuid,uuid,date) from public,anon,authenticated;

create function public.frindly_loan_register(p_as_of date default current_date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare b uuid:=frindly_cash.access();
begin
 return jsonb_build_object('can_write',public.v6147_can_write_area(b,'financials'),'loans',coalesce((
 select jsonb_agg((to_jsonb(l)-'creation_details')||jsonb_build_object('owing',frindly_cash.loan_balance(b,l.account_id,p_as_of)) order by l.name)
 from frindly_cash.loans l where l.business_id=b),'[]'::jsonb));
end $$;

create function public.frindly_save_loan(p_id uuid,p_details jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare
 b uuid:=frindly_cash.access(true);
 old frindly_cash.loans%rowtype;
 bank uuid:=(p_details->>'bank_id')::uuid;
 a uuid;
 amount numeric:=(p_details->>'original_amount')::numeric;
 opening numeric:=coalesce((p_details->>'opening_amount')::numeric,0);
 start_on date:=(p_details->>'start_date')::date;
 opening_on date:=(p_details->>'opening_date')::date;
 loan_name text:=btrim(p_details->>'name');
 lender_name text:=btrim(p_details->>'lender');
 loan_terms jsonb:=p_details->'terms';
 equity uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into old from frindly_cash.loans where id=p_id and business_id=b for update;
 if found then
  if p_details->>'action'='close' then
   if frindly_cash.loan_balance(b,old.account_id)<>0 then raise exception 'Record the final payment before closing this loan';end if;
   update frindly_cash.loans set closed=true where id=p_id;
  elsif p_details->>'action'='reopen' and old.closed then
   update frindly_cash.loans set closed=false where id=p_id;
  elsif p_details->>'action'='terms' and not old.closed then
   if loan_terms is null or jsonb_typeof(loan_terms)<>'object' then raise exception 'Enter the revised lender terms';end if;
   update frindly_cash.loans set terms=loan_terms where id=p_id;
  elsif p_details->>'action'='create' and old.creation_details=p_details then
   return p_id;
  else raise exception 'Loan already exists or is closed';
  end if;
  insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by)
   values(b,'loan',p_id,'loan_'||(p_details->>'action'),jsonb_build_object('previous_terms',old.terms,'details',p_details),auth.uid());
  return p_id;
 end if;
 if p_details->>'action' is distinct from 'create' then raise exception 'Loan unavailable';end if;
 if p_id is null or nullif(loan_name,'') is null or length(loan_name)>100 or nullif(lender_name,'') is null or length(lender_name)>100
 or start_on is null or amount is null or amount<=0 or amount>999999999999.99 or round(amount,2)<>amount
 or opening<0 or opening>999999999999.99 or round(opening,2)<>opening or loan_terms is null or jsonb_typeof(loan_terms)<>'object'
 then raise exception 'Enter valid loan details';end if;
 if not exists(select 1 from public.bank_accounts where business_id=b and id=bank and not coalesce(archived,false) and accounting_account_id is not null) then
  raise exception 'Choose a bank account with a ledger link';
 end if;
 a:=frindly_cash.account(b,'registered_loan_'||p_id::text,'Loan: '||loan_name||' ['||p_id::text||']','liability');
 insert into frindly_cash.loans(id,business_id,account_id,bank_id,name,lender,loan_type,original_amount,start_date,terms,creation_details)
 values(p_id,b,a,bank,loan_name,lender_name,p_details->>'loan_type',amount,start_on,loan_terms,p_details);
 if opening>0 then
  if opening_on is null or opening_on<start_on or opening_on>current_date then raise exception 'Enter a valid opening balance date';end if;
  perform frindly_cash.check_date(b,opening_on);
  select id into equity from public.accounting_accounts where business_id=b and account_type='equity' and not coalesce(archived,false)
   and (system_key in ('opening_balance_equity','opening_balances') or system_account_key in ('opening_balance_equity','opening_balances') or lower(account_name) in ('opening balance equity','opening balances'))
   order by id limit 1;
  if equity is null then raise exception 'Set up the opening balances account with your accountant first';end if;
  perform public.v6192_create_posted_journal(b,opening_on,'opening_balance','loan_opening_balance',p_id,'LOAN-OPEN-'||p_id::text,
   'Opening loan balance: '||loan_name,jsonb_build_array(frindly_cash.line(equity,opening,0,loan_name),frindly_cash.line(a,0,opening,loan_name)));
 end if;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by)
 values(b,'loan',p_id,'loan_created',p_details,auth.uid());
 return p_id;
end $$;

revoke all on function public.frindly_loan_register(date),public.frindly_save_loan(uuid,jsonb) from public,anon;
grant execute on function public.frindly_loan_register(date),public.frindly_save_loan(uuid,jsonb) to authenticated;

-- Keep the existing shared journal, statement matching and reversal paths.
do $migration$
declare
 definition text:=pg_get_functiondef('frindly_cash.record(uuid,jsonb)'::regprocedure);
 original text:='elsif purpose in (''loan_received'',''loan_repayment'') then a:=frindly_cash.account(b,''bank_loan'',''Bank Loan'',''liability'');';
begin
 if strpos(definition,original)=0 then raise exception 'Shared loan cash branch has changed';end if;
 execute replace(definition,original,$branch$
 elsif purpose in ('loan_received','loan_repayment') then
  if nullif(p->>'loan_id','') is null then
   a:=frindly_cash.account(b,'bank_loan','Bank Loan','liability');
  else
   select l.account_id into a from frindly_cash.loans l where l.business_id=b and l.id=(p->>'loan_id')::uuid and not l.closed and l.start_date<=d;
   if a is null then raise exception 'Choose an active loan for this business and date';end if;
   if purpose='loan_repayment' and exists(
    select 1 from (select j.journal_date,sum(l.credit-l.debit) as movement from public.accounting_journal_lines l
    join public.accounting_journals j on j.business_id=l.business_id and j.id=l.journal_id
    where l.business_id=b and l.account_id=a and j.status in ('posted','reversed') group by j.journal_date) daily
    where journal_date>d and frindly_cash.loan_balance(b,a,journal_date)<amt-interest
   ) then raise exception 'This backdated repayment would overpay the loan after later transactions';end if;
  end if;
 $branch$);
end $migration$;

-- Expense components are separate from principal and from each other.
do $migration$
declare
 definition text:=pg_get_functiondef('frindly_cash.record(uuid,jsonb)'::regprocedure);
 line_definition text:=pg_get_functiondef('frindly_cash.lines(public.cash_transactions,uuid,numeric)'::regprocedure);
 interest_guard text:='if interest>=amt then';
 net_line text:='net:=p.amount+p.withheld_amount-p.gst_amount-p.interest_amount;';
 principal_line text:='lines:=lines||jsonb_build_array(frindly_cash.line(p.account_id,case when p_amount<0 then net else 0 end,case when p_amount>0 then net else 0 end,p.description));';
begin
 if strpos(definition,interest_guard)=0 or strpos(line_definition,principal_line)=0 or strpos(line_definition,net_line)=0 then raise exception 'Shared interest posting has changed';end if;
 definition:=replace(definition,';withheld numeric:=',';loan_fee numeric:=coalesce((p->>''loan_fee'')::numeric,0);withheld numeric:=');
 definition:=replace(definition,'amt-interest','amt-interest-loan_fee');
 execute replace(definition,interest_guard,$guard$
 if loan_fee<0 or loan_fee<>round(loan_fee,2) or (loan_fee<>0 and (purpose is distinct from 'loan_repayment' or nullif(p->>'loan_id','') is null)) then
  raise exception 'Enter a valid finance fee for a registered loan repayment';
 end if;
 if interest+loan_fee>amt or (interest+loan_fee=amt and (purpose<>'loan_repayment' or nullif(p->>'loan_id','') is null)) then
 $guard$);
 line_definition:=replace(line_definition,net_line,$fee$
 net:=p.amount+p.withheld_amount-p.gst_amount-p.interest_amount;
 if p.purpose='loan_repayment' and nullif(p.request_payload->>'loan_id','') is not null and coalesce((p.request_payload->>'loan_fee')::numeric,0)>0 then
  a:=frindly_cash.account(p.business_id,'finance_fees','Finance Fees','expense');
  net:=net-(p.request_payload->>'loan_fee')::numeric;
  lines:=lines||jsonb_build_array(frindly_cash.line(a,(p.request_payload->>'loan_fee')::numeric,0,'Finance fee'));
 end if;
 $fee$);
 execute replace(line_definition,principal_line,$line$if net<>0 or p.purpose<>'loan_repayment' or nullif(p.request_payload->>'loan_id','') is null then $line$||principal_line||' end if;');
end $migration$;

-- A date-changing bank match would move principal without rerunning the loan
-- balance checks. Match the recorded date, or reverse and record the correction.
do $migration$
declare
 definition text:=pg_get_functiondef('frindly_cash.match(uuid,uuid,uuid,jsonb)'::regprocedure);
 anchor text:='if l.transaction_date<>tx.transaction_date then';
begin
 if strpos(definition,anchor)=0 then raise exception 'Shared cash match date check has changed';end if;
 execute replace(definition,anchor,$guard$
 if c.request_payload ? 'loan_id' and nullif(c.request_payload->>'loan_id','') is not null and l.transaction_date<>tx.transaction_date then
  raise exception 'Loan payment date differs from the statement. Correct the recorded payment before matching';
 end if;
 if l.transaction_date<>tx.transaction_date then
 $guard$);
end $migration$;

do $migration$
declare
 definition text:=pg_get_functiondef('frindly_cash.void(uuid,text)'::regprocedure);
 anchor text:='if c.purpose in (''loan_received'',''deposit_paid'') and';
begin
 if strpos(definition,anchor)=0 then raise exception 'Shared cash reversal guard has changed';end if;
 execute replace(definition,anchor,$guard$
 if nullif(c.request_payload->>'loan_id','') is not null then
  if exists(select 1 from frindly_cash.loans where business_id=b and account_id=c.account_id and closed) then
   raise exception 'Reopen the loan before reversing a recorded transaction';
  end if;
  if c.purpose='loan_received' and exists(
   select 1 from public.accounting_journal_lines l
   join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id
   where l.business_id=b and l.account_id=c.account_id and j.status in ('posted','reversed')
   and j.journal_date >= (c.request_payload->>'date')::date
   and frindly_cash.loan_balance(b,c.account_id,j.journal_date)<c.amount
  ) then raise exception 'Review later repayments before reversing these loan funds';end if;
 end if;
 if c.purpose in ('loan_received','deposit_paid') and
 $guard$);
end $migration$;

notify pgrst, 'reload schema';
