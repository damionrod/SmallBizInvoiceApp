-- GST/payroll settlements extend the existing journal engine; no source accruals are recreated.
create schema if not exists frindly_settlement;
revoke all on schema frindly_settlement from public, anon;
grant usage on schema frindly_settlement to authenticated;

create table public.liability_payments (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id),
 request_id uuid not null,
 payment_date date not null,
 bank_account_id uuid not null references public.bank_accounts(id),
 amount numeric(14,2) not null check(amount>0),
 direction text not null check(direction in ('payment','refund')),
 reference text,
 accounting_journal_id uuid not null references public.accounting_journals(id),
 created_at timestamptz not null default now(),
 created_by uuid not null references auth.users(id),
 unique(business_id,request_id), unique(business_id,id)
);
create table public.liability_payment_allocations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id),
 payment_id uuid not null,
 kind text not null check(kind in ('gst','wages','ird')),
 gst_return_id uuid references public.gst_returns(id),
 pay_run_id uuid references public.payroll_pay_runs(id),
 account_id uuid not null references public.accounting_accounts(id),
 amount numeric(14,2) not null check(amount>0),
 foreign key(business_id,payment_id) references public.liability_payments(business_id,id),
 check((kind='gst' and gst_return_id is not null and pay_run_id is null) or
       (kind in ('wages','ird') and gst_return_id is null and pay_run_id is not null))
);
create index liability_payment_allocations_source_idx on public.liability_payment_allocations(business_id,kind,pay_run_id,gst_return_id);
create index liability_payment_allocations_payment_idx on public.liability_payment_allocations(business_id,payment_id);
create index liability_payments_bank_idx on public.liability_payments(bank_account_id);
create index liability_payments_journal_idx on public.liability_payments(accounting_journal_id);
alter table public.liability_payments enable row level security;
alter table public.liability_payment_allocations enable row level security;
revoke all on public.liability_payments,public.liability_payment_allocations from public,anon,authenticated;
-- Data is exposed only through permission-checked RPCs. No client may mutate settlement rows.

alter table public.bank_reconciliation_allocations add column liability_payment_id uuid references public.liability_payments(id);
create index bank_reconciliation_liability_payment_idx on public.bank_reconciliation_allocations(liability_payment_id) where liability_payment_id is not null;
alter table public.bank_reconciliation_allocations drop constraint bank_reconciliation_allocations_allocation_type_v6212_ck;
alter table public.bank_reconciliation_allocations add constraint bank_reconciliation_allocations_allocation_type_settlement_ck check(allocation_type in ('invoice','expense','transfer','exclude','customer_refund','supplier_refund','payroll_pay_run','payroll_ird','owner_equity','expense_deposit_refund','stripe_payout','liability_settlement'));

create function frindly_settlement.assert_access(p_area text,p_write boolean default false) returns uuid
language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id();
begin
 if auth.uid() is null or b is null then raise exception 'Authentication and active business required'; end if;
 if not coalesce(case when p_write then public.v6147_can_write_area(b,p_area) else public.v6147_can_read_area(b,p_area) end,false) then raise exception 'Settlement access denied'; end if;
 return b;
end $$;
revoke all on function frindly_settlement.assert_access(text,boolean) from public,anon,authenticated;

-- Always derive payroll obligations from the ORIGINAL journal accounts, including historical 265.
-- Legacy bank-credit payroll has no wages liability to settle a second time.
create function frindly_settlement.obligations(p_bid uuid) returns table(
 kind text,source_id uuid,account_id uuid,label text,source_date date,total numeric,paid numeric,outstanding numeric,direction text,notice text)
language sql stable security definer set search_path='' as $$
 with payroll as (
 select r.id,r.pay_run_number,r.pay_date,r.net_pay,j.id journal_id,a.id account_id,
 case when coalesce(a.system_account_key,a.system_key)='payroll_net_payable' then 'wages' else 'ird' end kind,
 sum(l.credit-l.debit) total
 from public.payroll_pay_runs r
 join public.accounting_journals j on j.business_id=r.business_id and j.source_id=r.id and j.source_type='payroll' and j.status='posted'
 join public.accounting_journal_lines l on l.business_id=j.business_id and l.journal_id=j.id
 join public.accounting_accounts a on a.business_id=l.business_id and a.id=l.account_id
 where r.business_id=p_bid and r.status='finalised' and a.account_type in ('liability','current_liability','non_current_liability')
 and (a.system_key in ('payroll_net_payable','payroll_liability') or a.system_account_key in ('payroll_net_payable','payroll_liability'))
 group by r.id,j.id,a.id
 ), prior as (
 select x.kind,x.pay_run_id,x.gst_return_id,x.account_id,sum(x.amount) amount
 from public.liability_payment_allocations x join public.liability_payments p on p.business_id=x.business_id and p.id=x.payment_id
 join public.accounting_journals j on j.id=p.accounting_journal_id and j.business_id=p.business_id and j.status='posted'
 where x.business_id=p_bid group by 1,2,3,4
 ), bank_prior as (
 select a.pay_run_id,sum(a.amount) amount from public.bank_reconciliation_allocations a
 join public.accounting_journals j on j.id=a.accounting_journal_id and j.business_id=a.business_id and j.status='posted'
 where a.business_id=p_bid and a.allocation_type='payroll_pay_run' and a.liability_payment_id is null group by 1
 ), gst as (
 select g.*,case when g.gst_net<0 then 'gst_receivable' else 'gst_payable' end account_key
 from public.gst_returns g where g.business_id=p_bid
 )
 select p.kind,p.id,p.account_id,p.pay_run_number,p.pay_date,p.total,
 coalesce(pr.amount,0)+case when p.kind='wages' then coalesce(bp.amount,0) else 0 end,
 greatest(0,p.total-coalesce(pr.amount,0)-case when p.kind='wages' then coalesce(bp.amount,0) else 0 end),
 'payment',null::text
 from payroll p left join prior pr on pr.kind=p.kind and pr.pay_run_id=p.id and pr.account_id=p.account_id
 left join bank_prior bp on bp.pay_run_id=p.id
 union all
 select 'wages',r.id,null::uuid,r.pay_run_number,r.pay_date,r.net_pay,r.net_pay,0,'payment',
 'Legacy payroll already credited bank; no further wages posting is permitted. Bank matches remain separate evidence.'
 from public.payroll_pay_runs r where r.business_id=p_bid and r.status='finalised'
 and not exists(select 1 from payroll p where p.id=r.id and p.kind='wages')
 and exists(select 1 from public.accounting_journals j join public.accounting_journal_lines l on l.business_id=j.business_id and l.journal_id=j.id
 join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id
 where j.business_id=p_bid and j.source_id=r.id and j.source_type='payroll' and j.status='posted'
 and (a.account_subtype='bank' or a.system_key in ('bank','bank_main'))
 group by j.id having sum(l.credit-l.debit)=r.net_pay)
 union all
 select 'gst',g.id,a.id,g.period_start::text||' to '||g.period_end::text,g.period_end,abs(g.gst_net),coalesce(pr.amount,0),
 greatest(0,abs(g.gst_net)-coalesce(pr.amount,0)),case when g.gst_net<0 then 'refund' else 'payment' end,
 case when g.status<>'finalised' then 'Finalise this saved return before settlement.' end
 from gst g left join public.accounting_accounts a on a.business_id=p_bid and not a.archived and (a.system_key=g.account_key or a.system_account_key=g.account_key)
 left join prior pr on pr.kind='gst' and pr.gst_return_id=g.id and pr.account_id=a.id
 $$;
revoke all on function frindly_settlement.obligations(uuid) from public,anon,authenticated;

create function frindly_settlement.snapshot(p_kind text,p_source_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b uuid; area text; result jsonb;
begin
 if p_kind not in ('gst','wages','ird','all') then raise exception 'Invalid settlement kind'; end if;
 area:=case when p_kind='gst' then 'financials' when p_kind='all' then 'bank' else 'payroll' end;
 b:=frindly_settlement.assert_access(area);
 select jsonb_build_object('business_id',b,'obligations',coalesce((select jsonb_agg(o) from frindly_settlement.obligations(b) o where (p_kind='all' or o.kind=p_kind) and public.v6147_can_read_area(b,case when o.kind='gst' then 'financials' else 'payroll' end) and (p_source_id is null or o.source_id=p_source_id)),'[]'::jsonb),
 'existing_settlements',coalesce((select jsonb_agg(jsonb_build_object('payment_date',t.transaction_date,'amount',a.amount,'reference',t.reference,'matched',true,'legacy',a.accounting_journal_id is null)) from public.bank_reconciliation_allocations a join public.bank_transactions t on t.business_id=a.business_id and t.id=a.bank_transaction_id where a.business_id=b and a.allocation_type='payroll_pay_run' and a.liability_payment_id is null and (p_kind in ('wages','all')) and (p_source_id is null or a.pay_run_id=p_source_id) and public.v6147_can_read_area(b,'payroll')),'[]'::jsonb),
 'filing_status',case when p_kind='gst' and p_source_id is not null then (select case when exists(select 1 from public.ird_filing_batches f where f.business_id=b and f.filing_type='gst_return' and f.status='filed_in_myir' and (f.source_id=g.id or (f.period_start=g.period_start and f.period_end=g.period_end))) then 'Filed' else initcap(g.status) end from public.gst_returns g where g.business_id=b and g.id=p_source_id) end,
 'payments',coalesce((select jsonb_agg(q order by q.payment_date desc,q.created_at desc) from (
 select p.*,coalesce((select jsonb_agg(a) from public.liability_payment_allocations a where a.business_id=b and a.payment_id=p.id),'[]'::jsonb) allocations,
 exists(select 1 from public.bank_reconciliation_allocations ba where ba.business_id=b and ba.liability_payment_id=p.id) matched
 from public.liability_payments p where p.business_id=b and not exists(select 1 from public.liability_payment_allocations z where z.business_id=b and z.payment_id=p.id and not public.v6147_can_read_area(b,case when z.kind='gst' then 'financials' else 'payroll' end)) and exists(select 1 from public.liability_payment_allocations a where a.business_id=b and a.payment_id=p.id and (p_kind='all' or a.kind=p_kind) and public.v6147_can_read_area(b,case when a.kind='gst' then 'financials' else 'payroll' end) and (p_source_id is null or coalesce(a.gst_return_id,a.pay_run_id)=p_source_id)))q),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function frindly_settlement.snapshot(text,uuid) from public,anon;
grant execute on function frindly_settlement.snapshot(text,uuid) to authenticated;
create function public.frindly_settlement_snapshot(p_kind text,p_source_id uuid default null) returns jsonb
language sql security invoker set search_path='' as $$ select frindly_settlement.snapshot(p_kind,p_source_id) $$;
revoke all on function public.frindly_settlement_snapshot(text,uuid) from public,anon;
grant execute on function public.frindly_settlement_snapshot(text,uuid) to authenticated;

create function frindly_settlement.record_payment(p_request_id uuid,p_date date,p_bank_id uuid,p_reference text,p_allocations jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); uid uuid:=auth.uid(); item record; o record; ba public.bank_accounts%rowtype;
 payment_id uuid:=gen_random_uuid(); journal_id uuid; existing public.liability_payments%rowtype;
 total_amount numeric:=0; lines jsonb:='[]'; dir text; gst public.gst_returns%rowtype; ledger_net numeric; acct_count int;
begin
 if uid is null or b is null then raise exception 'Authentication and active business required'; end if;
 -- Serialize settlements AND reconciliation for this tenant. Balance checks happen after the lock.
 perform pg_advisory_xact_lock(hashtextextended('frindly-settlement:'||b::text,0));
 if p_request_id is null or p_date is null or p_bank_id is null then raise exception 'Payment ID, date and bank required'; end if;
 if jsonb_typeof(p_allocations)<>'array' or jsonb_array_length(p_allocations)=0 then raise exception 'Choose settlement allocations'; end if;
 for item in select * from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric) loop
  if item.kind not in ('gst','wages','ird') then raise exception 'Invalid settlement kind'; end if;
  perform frindly_settlement.assert_access(case when item.kind='gst' then 'financials' else 'payroll' end,true);
  if item.amount is null or item.amount<=0 or item.amount<>round(item.amount,2) then raise exception 'Payment amount must be positive with at most two decimals'; end if;
  total_amount:=total_amount+item.amount;
 end loop;
 if exists(select 1 from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric) group by kind,source_id,account_id having count(*)>1) then raise exception 'Duplicate allocation'; end if;
 select * into existing from public.liability_payments where business_id=b and request_id=p_request_id;
 if found then
  if existing.payment_date<>p_date or existing.bank_account_id<>p_bank_id or existing.amount<>total_amount or coalesce(existing.reference,'')<>coalesce(nullif(btrim(p_reference),''),'') then raise exception 'Request ID already used for a different payment'; end if;
  if (select jsonb_agg(jsonb_build_object('kind',a.kind,'source_id',coalesce(a.gst_return_id,a.pay_run_id),'account_id',a.account_id,'amount',a.amount) order by a.kind,coalesce(a.gst_return_id,a.pay_run_id),a.account_id) from public.liability_payment_allocations a where a.business_id=b and a.payment_id=existing.id)
   is distinct from (select jsonb_agg(jsonb_build_object('kind',x.kind,'source_id',x.source_id,'account_id',x.account_id,'amount',x.amount) order by x.kind,x.source_id,x.account_id) from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric)) then raise exception 'Request allocations changed'; end if;
  return existing.id;
 end if;
 if exists(select 1 from public.accounting_periods where business_id=b and status<>'open' and p_date between period_start and period_end) then raise exception 'Payment accounting period is locked'; end if;
 select * into ba from public.bank_accounts where business_id=b and id=p_bank_id and not archived;
 if ba.id is null or ba.accounting_account_id is null or not exists(select 1 from public.accounting_accounts where business_id=b and id=ba.accounting_account_id and not archived and account_type='asset' and account_subtype='bank') then raise exception 'Select a bank linked to an active bank ledger account'; end if;
 for item in select * from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric) loop
  select * into o from frindly_settlement.obligations(b) where kind=item.kind and source_id=item.source_id and account_id=item.account_id;
  if not found or o.notice is not null or item.amount>o.outstanding then raise exception 'Allocation exceeds outstanding liability or source needs review'; end if;
  if not exists(select 1 from public.accounting_accounts where business_id=b and id=item.account_id and not archived) then raise exception 'The original liability account is archived; review its mapping before settlement'; end if;
  if dir is not null and dir<>o.direction then raise exception 'Payments and refunds must be recorded separately'; end if; dir:=o.direction;
  if item.kind='gst' then
   select * into gst from public.gst_returns where business_id=b and id=item.source_id;
   if gst.status<>'finalised' then raise exception 'Only finalised GST returns can be settled'; end if;
   -- Reconcile the saved return to source GST ledger movements; never create another accrual.
   select round(coalesce(sum(l.credit-l.debit),0),2) into ledger_net
   from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
   join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id
   where j.business_id=b and j.status in ('posted','reversed') and j.journal_date between gst.period_start and gst.period_end
   and j.source_type<>'liability_settlement'
   and (a.system_key in ('gst_payable','gst_receivable') or a.system_account_key in ('gst_payable','gst_receivable'));
   if abs(ledger_net-gst.gst_net)>0.01 then raise exception 'Saved GST return differs from posted GST ledger. Reconcile source postings and calculation basis before settlement'; end if;
   if exists(select 1 from public.gst_returns g where g.business_id=b and g.id<>gst.id and g.status='finalised' and g.period_start<=gst.period_end and g.period_end>=gst.period_start) then raise exception 'Overlapping finalised GST returns require review'; end if;
  elsif exists(select 1 from public.accounting_journals j where j.business_id=b and j.source_type='payroll_ird_payment' and j.status='posted' and not exists(select 1 from public.bank_reconciliation_allocations a where a.business_id=b and a.accounting_journal_id=j.id and a.pay_run_id is not null)) and item.kind='ird' then
   raise exception 'Existing unallocated IRD settlements need allocation review before recording another payment';
  end if;
  -- Global liability balance is an additional guard against unallocated historical settlements.
  select coalesce(sum(l.credit-l.debit),0) into ledger_net from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=item.account_id and j.status in ('posted','reversed') and j.journal_date<=p_date;
  if (dir='payment' and ledger_net<item.amount) or (dir='refund' and -ledger_net<item.amount) then raise exception 'Payment exceeds the posted liability available on this date'; end if;
  lines:=lines||jsonb_build_array(jsonb_build_object('account_id',item.account_id,'description',o.label||' settlement','debit',case when dir='payment' then item.amount else 0 end,'credit',case when dir='refund' then item.amount else 0 end,'tax_code','NO_GST','tax_amount',0));
 end loop;
 -- Ensure allocations sharing an account cannot jointly exceed its balance.
 for item in select account_id,sum(amount) amount from jsonb_to_recordset(p_allocations) as x(account_id uuid,amount numeric) group by account_id loop
  select coalesce(sum(l.credit-l.debit),0) into ledger_net from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=item.account_id and j.status in ('posted','reversed') and j.journal_date<=p_date;
  if (dir='payment' and ledger_net<item.amount) or (dir='refund' and -ledger_net<item.amount) then raise exception 'Combined allocations exceed posted liability'; end if;
 end loop;
 lines:=lines||jsonb_build_array(jsonb_build_object('account_id',ba.accounting_account_id,'description','GST / payroll settlement','debit',case when dir='refund' then total_amount else 0 end,'credit',case when dir='payment' then total_amount else 0 end,'tax_code','NO_GST','tax_amount',0));
 journal_id:=public.v6192_create_posted_journal(b,p_date,'bank','liability_settlement',payment_id,nullif(btrim(p_reference),''),'GST / payroll settlement',lines);
 insert into public.liability_payments(id,business_id,request_id,payment_date,bank_account_id,amount,direction,reference,accounting_journal_id,created_by) values(payment_id,b,p_request_id,p_date,p_bank_id,total_amount,dir,nullif(btrim(p_reference),''),journal_id,uid);
 insert into public.liability_payment_allocations(business_id,payment_id,kind,gst_return_id,pay_run_id,account_id,amount)
 select b,payment_id,x.kind,case when x.kind='gst' then x.source_id end,case when x.kind<>'gst' then x.source_id end,x.account_id,x.amount from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric);
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'liability_payment',payment_id,'record_payment',jsonb_build_object('allocations',p_allocations,'journal_id',journal_id,'date',p_date,'bank_id',p_bank_id),uid);
 return payment_id;
end $$;
revoke all on function frindly_settlement.record_payment(uuid,date,uuid,text,jsonb) from public,anon;
grant execute on function frindly_settlement.record_payment(uuid,date,uuid,text,jsonb) to authenticated;
create function public.frindly_record_liability_payment(p_request_id uuid,p_date date,p_bank_id uuid,p_reference text,p_allocations jsonb) returns uuid
language sql security invoker set search_path='' as $$ select frindly_settlement.record_payment(p_request_id,p_date,p_bank_id,p_reference,p_allocations) $$;
revoke all on function public.frindly_record_liability_payment(uuid,date,uuid,text,jsonb) from public,anon;
grant execute on function public.frindly_record_liability_payment(uuid,date,uuid,text,jsonb) to authenticated;

create function frindly_settlement.reconcile(p_bank_transaction_id uuid,p_payment_id uuid,p_request_id uuid,p_allocations jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare b uuid; tx public.bank_transactions%rowtype; p public.liability_payments%rowtype; pid uuid:=p_payment_id; item record;
begin
 b:=frindly_settlement.assert_access('bank',true);
 perform pg_advisory_xact_lock(hashtextextended('frindly-settlement:'||b::text,0));
 select * into tx from public.bank_transactions where business_id=b and id=p_bank_transaction_id for update;
 if tx.id is null or tx.status<>'unreconciled' then raise exception 'Bank transaction unavailable or already reconciled'; end if;
 if exists(select 1 from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id) then raise exception 'Bank transaction already allocated'; end if;
 if exists(select 1 from public.accounting_periods where business_id=b and status<>'open' and tx.transaction_date between period_start and period_end) then raise exception 'Bank transaction accounting period is locked'; end if;
 if pid is null then
  pid:=frindly_settlement.record_payment(p_request_id,tx.transaction_date,tx.bank_account_id,tx.reference,p_allocations);
 end if;
 select * into p from public.liability_payments where business_id=b and id=pid for update;
 if p.id is null or p.bank_account_id<>tx.bank_account_id or p.amount<>abs(tx.amount) or (p.direction='payment')<>(tx.amount<0) then raise exception 'Payment bank, amount or direction does not match this bank transaction'; end if;
 for item in select distinct kind from public.liability_payment_allocations where business_id=b and payment_id=pid loop
  perform frindly_settlement.assert_access(case when item.kind='gst' then 'financials' else 'payroll' end);
 end loop;
 if not exists(select 1 from public.accounting_journals where business_id=b and id=p.accounting_journal_id and status='posted') then raise exception 'Payment journal is not posted'; end if;
 if exists(select 1 from public.bank_reconciliation_allocations where business_id=b and liability_payment_id=pid) then raise exception 'Payment already matched'; end if;
 insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,accounting_journal_id,liability_payment_id,created_by) values(b,tx.id,'liability_settlement',p.amount,p.accounting_journal_id,pid,auth.uid());
 update public.bank_transactions set status='reconciled',reconciliation_type='liability_settlement',reconciled_at=now(),reconciled_by=auth.uid(),updated_at=now(),updated_by=auth.uid() where business_id=b and id=tx.id;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(b,tx.id,'liability_payment_matched',jsonb_build_object('payment_id',pid,'journal_id',p.accounting_journal_id),auth.uid());
 return pid;
end $$;
revoke all on function frindly_settlement.reconcile(uuid,uuid,uuid,jsonb) from public,anon;
grant execute on function frindly_settlement.reconcile(uuid,uuid,uuid,jsonb) to authenticated;
create function public.frindly_reconcile_liability_payment(p_bank_transaction_id uuid,p_payment_id uuid default null,p_request_id uuid default null,p_allocations jsonb default '[]') returns uuid
language sql security invoker set search_path='' as $$ select frindly_settlement.reconcile(p_bank_transaction_id,p_payment_id,p_request_id,p_allocations) $$;
revoke all on function public.frindly_reconcile_liability_payment(uuid,uuid,uuid,jsonb) from public,anon;
grant execute on function public.frindly_reconcile_liability_payment(uuid,uuid,uuid,jsonb) to authenticated;

create function frindly_settlement.unmatch(p_bank_transaction_id uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare b uuid; tx public.bank_transactions%rowtype;
begin
 b:=frindly_settlement.assert_access('bank',true);
 perform pg_advisory_xact_lock(hashtextextended('frindly-settlement:'||b::text,0));
 select * into tx from public.bank_transactions where business_id=b and id=p_bank_transaction_id for update;
 if not exists(select 1 from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id and liability_payment_id is not null) then raise exception 'Settlement bank match not found'; end if;
 if exists(select 1 from public.accounting_periods where business_id=b and status<>'open' and tx.transaction_date between period_start and period_end) then raise exception 'Accounting period is locked'; end if;
 delete from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id and liability_payment_id is not null;
 update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,updated_at=now(),updated_by=auth.uid() where business_id=b and id=tx.id;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(b,tx.id,'liability_payment_unmatched',jsonb_build_object('reason',p_reason,'payment_preserved',true),auth.uid());
end $$;
revoke all on function frindly_settlement.unmatch(uuid,text) from public,anon;
grant execute on function frindly_settlement.unmatch(uuid,text) to authenticated;
create function public.frindly_unmatch_liability_payment(p_bank_transaction_id uuid,p_reason text default 'Undo settlement match') returns void
language sql security invoker set search_path='' as $$ select frindly_settlement.unmatch(p_bank_transaction_id,p_reason) $$;
revoke all on function public.frindly_unmatch_liability_payment(uuid,text) from public,anon;
grant execute on function public.frindly_unmatch_liability_payment(uuid,text) to authenticated;

-- Keep the legacy cash-posted payroll reconciliation branch; direct modern wages
-- through the shared settlement store so bank-first and manually recorded payments agree.
do $patch$
declare d text;
begin
 select pg_get_functiondef('public.v61109_reconcile_payroll_bank_transaction(uuid,uuid,uuid)'::regprocedure) into d;
 if strpos(d,'if not v_legacy_bank_posted then')=0 then raise exception 'Payroll reconciliation patch guard failed'; end if;
 d:=replace(d,'if not v_legacy_bank_posted then', $replacement$
 if v_legacy_bank_posted then
  perform pg_advisory_xact_lock(hashtextextended('frindly-settlement:'||v_bid::text,0));
  if v_amount+(select coalesce(sum(amount),0) from public.bank_reconciliation_allocations where business_id=v_bid and pay_run_id=v_run.id and allocation_type='payroll_pay_run')>v_run.net_pay then raise exception 'Bank allocations exceed legacy wages'; end if;
  if p_pay_run_employee_id is not null and exists(select 1 from public.bank_reconciliation_allocations where business_id=v_bid and pay_run_employee_id=p_pay_run_employee_id and allocation_type='payroll_pay_run') then raise exception 'Employee wages already matched'; end if;
 else
  if exists(select 1 from public.liability_payments lp join public.liability_payment_allocations la on la.payment_id=lp.id and la.business_id=lp.business_id where lp.business_id=v_bid and la.pay_run_id=v_run.id and la.kind='wages' and not exists(select 1 from public.bank_reconciliation_allocations a where a.business_id=v_bid and a.liability_payment_id=lp.id)) then raise exception 'Recorded wages payment is waiting for a bank match. Use GST / Payroll payment to match it'; end if;
  perform frindly_settlement.reconcile(v_tx.id,null,gen_random_uuid(),jsonb_build_array(jsonb_build_object('kind','wages','source_id',v_run.id,'account_id',v_payable,'amount',v_amount)));
  return jsonb_build_object('ok',true,'amount',v_amount,'shared_settlement',true);
 end if;
 if not v_legacy_bank_posted then
 $replacement$);
 execute d;
end $patch$;
-- The old IRD endpoint had no pay-run allocation. Require the allocation workflow.
create or replace function public.v61109_reconcile_payroll_ird_bank_transaction(p_bank_transaction_id uuid,p_note text default null) returns jsonb
language plpgsql security invoker set search_path='' as $$ begin raise exception 'Use GST / Payroll payment to allocate this IRD payment to its pay runs'; end $$;
-- Enforce tenant boundaries even for direct writes through the existing allocation table.
alter table public.bank_reconciliation_allocations add constraint bank_reconciliation_liability_payment_tenant_fk foreign key(business_id,liability_payment_id) references public.liability_payments(business_id,id);
create unique index bank_reconciliation_liability_payment_once on public.bank_reconciliation_allocations(liability_payment_id) where liability_payment_id is not null;
create function frindly_settlement.guard_bank_allocation() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if new.liability_payment_id is not null or new.allocation_type='liability_settlement' then
  if current_user in ('authenticated','anon') then raise exception 'Settlement bank matches must use the controlled payment workflow'; end if;
  if new.liability_payment_id is null or new.allocation_type<>'liability_settlement' then raise exception 'Invalid settlement bank allocation'; end if;
  if not exists(select 1 from public.liability_payments p join public.bank_transactions t on t.id=new.bank_transaction_id and t.business_id=p.business_id where p.business_id=new.business_id and p.id=new.liability_payment_id and p.accounting_journal_id=new.accounting_journal_id and p.amount=new.amount and p.amount=abs(t.amount) and p.bank_account_id=t.bank_account_id and (p.direction='payment')=(t.amount<0)) then raise exception 'Settlement allocation does not agree with payment and bank transaction'; end if;
 end if;
 return new;
end $$;
revoke all on function frindly_settlement.guard_bank_allocation() from public,anon,authenticated;
create trigger frindly_guard_settlement_bank_allocation before insert or update on public.bank_reconciliation_allocations for each row execute function frindly_settlement.guard_bank_allocation();
-- A settled accrual cannot be reversed underneath an active payment.
create function frindly_settlement.guard_payrun_reversal() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if old.status='finalised' and new.status is distinct from old.status and exists(
 select 1 from public.liability_payment_allocations a join public.liability_payments p on p.business_id=a.business_id and p.id=a.payment_id join public.accounting_journals j on j.business_id=p.business_id and j.id=p.accounting_journal_id
 where a.business_id=old.business_id and a.pay_run_id=old.id and j.status='posted') then
 raise exception 'This pay run has recorded settlements. Correct its payments through the accounting journal workflow before reversing payroll';
 end if;
 return new;
end $$;
revoke all on function frindly_settlement.guard_payrun_reversal() from public,anon,authenticated;
create trigger frindly_guard_settled_payrun_reversal before update of status on public.payroll_pay_runs for each row execute function frindly_settlement.guard_payrun_reversal();
create function frindly_settlement.guard_payroll_journal_reversal() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if old.source_type='payroll' and old.status='posted' and new.status='reversed' and exists(
 select 1 from public.liability_payment_allocations a join public.liability_payments p on p.business_id=a.business_id and p.id=a.payment_id join public.accounting_journals j on j.business_id=p.business_id and j.id=p.accounting_journal_id
 where a.business_id=old.business_id and a.pay_run_id=old.source_id and j.status='posted') then
 raise exception 'Payroll has recorded settlements. Correct the linked payment journals before reversing the payroll accrual';
 end if;
 return new;
end $$;
revoke all on function frindly_settlement.guard_payroll_journal_reversal() from public,anon,authenticated;
create trigger frindly_guard_settled_payroll_journal before update of status on public.accounting_journals for each row execute function frindly_settlement.guard_payroll_journal_reversal();

-- Extend the bank transaction discriminator as well as its allocation discriminator.
alter table public.bank_transactions drop constraint bank_transactions_reconciliation_type_v6212_ck;
alter table public.bank_transactions add constraint bank_transactions_reconciliation_type_settlement_ck CHECK (((reconciliation_type IS NULL) OR (reconciliation_type = ANY (ARRAY['liability_settlement'::text, 'invoice'::text, 'expense'::text, 'created_expense'::text, 'split'::text, 'group'::text, 'transfer'::text, 'excluded'::text, 'customer_refund'::text, 'supplier_refund'::text, 'payroll_pay_run'::text, 'owner_funds_introduced'::text, 'director_loan_received'::text, 'capital_contribution'::text, 'owner_drawings'::text, 'repay_owner_loan'::text, 'director_payment'::text, 'dividend_distribution'::text, 'expense_deposit_refund'::text]))));
