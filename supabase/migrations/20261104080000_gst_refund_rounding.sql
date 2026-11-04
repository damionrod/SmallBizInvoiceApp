create or replace function frindly_settlement.record_payment(p_request_id uuid,p_date date,p_bank_id uuid,p_reference text,p_allocations jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); uid uuid:=auth.uid(); item record; o record; ba public.bank_accounts%rowtype;
 payment_id uuid:=gen_random_uuid(); journal_id uuid; existing public.liability_payments%rowtype;
 total_amount numeric:=0; lines jsonb:='[]'; dir text; gst public.gst_returns%rowtype; ledger_net numeric; acct_count int; rounding_amount numeric:=0; rounding_account uuid;
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
 -- An explicitly confirmed one-cent GST refund excess is separate from the return allocation.
 if exists(
   select 1 from jsonb_array_elements(p_allocations) a where a ? 'gst_refund_rounding'
 ) then
  if jsonb_array_length(p_allocations)<>1 or p_allocations->0->>'kind' is distinct from 'gst'
    or p_allocations->0->'gst_refund_rounding' is distinct from '0.01'::jsonb then
   raise exception 'Only a confirmed one-cent GST refund rounding adjustment is supported';
  end if;
  rounding_amount:=0.01;
  total_amount:=total_amount+rounding_amount;
 end if;
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
  if rounding_amount>0 and (o.direction is distinct from 'refund' or item.amount<>o.outstanding) then
   raise exception 'GST refund rounding requires settling the full outstanding refund';
  end if;
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
 if rounding_amount>0 then
  rounding_account:=frindly_cash.account(b,'gst_refund_rounding','GST Refund Rounding','other_income');
  lines:=lines||jsonb_build_array(jsonb_build_object('account_id',rounding_account,'description','Confirmed IRD GST refund rounding','debit',0,'credit',rounding_amount,'tax_code','NO_GST','tax_amount',0));
 end if;
 lines:=lines||jsonb_build_array(jsonb_build_object('account_id',ba.accounting_account_id,'description','GST / payroll settlement','debit',case when dir='refund' then total_amount else 0 end,'credit',case when dir='payment' then total_amount else 0 end,'tax_code','NO_GST','tax_amount',0));
 journal_id:=public.v6192_create_posted_journal(b,p_date,'bank','liability_settlement',payment_id,nullif(btrim(p_reference),''),'GST / payroll settlement',lines);
 insert into public.liability_payments(id,business_id,request_id,payment_date,bank_account_id,amount,direction,reference,accounting_journal_id,created_by) values(payment_id,b,p_request_id,p_date,p_bank_id,total_amount,dir,nullif(btrim(p_reference),''),journal_id,uid);
 insert into public.liability_payment_allocations(business_id,payment_id,kind,gst_return_id,pay_run_id,account_id,amount)
 select b,payment_id,x.kind,case when x.kind='gst' then x.source_id end,case when x.kind<>'gst' then x.source_id end,x.account_id,x.amount from jsonb_to_recordset(p_allocations) as x(kind text,source_id uuid,account_id uuid,amount numeric);
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'liability_payment',payment_id,'record_payment',jsonb_build_object('allocations',p_allocations,'journal_id',journal_id,'date',p_date,'bank_id',p_bank_id),uid);
 return payment_id;
end $$;
