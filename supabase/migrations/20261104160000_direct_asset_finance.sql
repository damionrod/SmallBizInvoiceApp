-- A private link lets the standard supplier-payment journal credit borrowing
-- instead of a business bank account. Existing supplier payments stay on their normal path.
create table frindly_cash.loan_supplier_payments (
 payment_id uuid primary key references public.expense_payments(id) deferrable initially deferred,
 loan_id uuid not null references frindly_cash.loans(id),
 business_id uuid not null references public.businesses(id)
);
alter table frindly_cash.loan_supplier_payments enable row level security;
revoke all on frindly_cash.loan_supplier_payments from public,anon,authenticated;
create index loan_supplier_payments_loan_idx on frindly_cash.loan_supplier_payments(loan_id);
create index loan_supplier_payments_business_idx on frindly_cash.loan_supplier_payments(business_id);

do $migration$
declare
 definition text:=pg_get_functiondef('public.v6170b_payment_account(uuid,text,uuid)'::regprocedure);
 anchor text:='elsif p_source_type=''supplier_payment'' then';
begin
 if strpos(definition,anchor)=0 then raise exception 'Supplier payment resolver has changed';end if;
 execute replace(definition,anchor,$branch$
 elsif p_source_type='supplier_payment' then
  select l.account_id into v_account
  from frindly_cash.loan_supplier_payments f join frindly_cash.loans l on l.id=f.loan_id and l.business_id=f.business_id
  where f.payment_id=p_source_id and f.business_id=p_bid;
  if found then return v_account;end if;
 $branch$);
end $migration$;

create function frindly_cash.guard_financed_supplier_payment() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from frindly_cash.loan_supplier_payments where payment_id=old.id)
 and (to_jsonb(new)-'updated_at') is distinct from (to_jsonb(old)-'updated_at') then
  raise exception 'This supplier payment is linked to a loan. Contact your accountant to correct it';
 end if;
 return new;
end $$;
revoke all on function frindly_cash.guard_financed_supplier_payment() from public,anon,authenticated;
create trigger guard_financed_supplier_payment before update on public.expense_payments
for each row execute function frindly_cash.guard_financed_supplier_payment();

create function public.frindly_record_direct_asset_finance(p_request uuid,p_loan uuid,p_expense uuid,p_date date,p_amount numeric,p_reference text)
returns uuid language plpgsql security definer set search_path='' as $$
declare
 b uuid:=frindly_cash.access(true);
 loan frindly_cash.loans%rowtype;
 bill public.expenses%rowtype;
 prior public.expense_payments%rowtype;
 posted_journal uuid;
 outstanding numeric;
 ref text:=nullif(btrim(p_reference),'');
begin
 if not coalesce(public.v6169a_accountant_centre_access(b,true),false) then raise exception 'Accounting access denied';end if;
 if p_request is null or p_date is null or p_date>current_date or p_amount is null or p_amount<=0
 or p_amount>999999999999.99 or p_amount<>round(p_amount,2) or length(coalesce(ref,''))>200 then
  raise exception 'Enter a valid payment date and amount';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into prior from public.expense_payments where id=p_request and business_id=b;
 if found then
  if prior.expense_id=p_expense and prior.amount=p_amount and prior.payment_date=p_date
   and prior.reference is not distinct from ref and exists(select 1 from frindly_cash.loan_supplier_payments where payment_id=p_request and loan_id=p_loan and business_id=b)
   then return p_request;end if;
  raise exception 'Request ID already used for a different payment';
 end if;
 select * into loan from frindly_cash.loans where id=p_loan and business_id=b and not closed for update;
 if not found or p_date<loan.start_date then raise exception 'Choose an active loan and a date on or after its start';end if;
 select * into bill from public.expenses where id=p_expense and business_id=b for update;
 if not found or coalesce(bill.archived,false) or coalesce(bill.lifecycle_state,'recorded')<>'recorded'
  or bill.payment_status='draft' or p_date<bill.invoice_date
  or coalesce(bill.business_use_percent,100)<99.995 or coalesce(bill.private_use_amount,0)>0.005 then
  raise exception 'Choose an active, wholly business-use asset bill dated on or before payment';
 end if;
 perform frindly_cash.check_date(b,p_date,coalesce(bill.gst_amount,0)>0);
 if not exists(
  select 1 from public.accounting_journals j
  join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
  join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id
  where j.business_id=b and j.source_type='expense' and j.source_id=bill.id and j.status='posted'
  and l.debit>0 and (a.account_type='fixed_asset' or a.report_section='fixed_assets')
 ) then raise exception 'Post the supplier bill as a fixed asset before recording lender payment';end if;
 -- Credit-note offsets have their own settlement workflow.
 if exists(select 1 from public.supplier_credits c where c.business_id=b and c.applied_expense_id=bill.id and c.status not in ('draft','voided','void')) then
  raise exception 'Review supplier credits before recording direct finance for this bill';
 end if;
 select round(bill.total_amount-coalesce(sum(amount),0),2) into outstanding from public.expense_payments where business_id=b and expense_id=bill.id;
 if p_amount>least(outstanding,coalesce(bill.outstanding_balance,outstanding)) then raise exception 'Payment exceeds the unpaid supplier balance';end if;
 insert into frindly_cash.loan_supplier_payments(payment_id,loan_id,business_id) values(p_request,loan.id,b);
 insert into public.expense_payments(id,business_id,expense_id,payment_date,amount,payment_method,reference,notes,funding_source,reconciliation_requirement,created_by)
 values(p_request,b,bill.id,p_date,p_amount,'Lender paid supplier',ref,'Direct asset finance: '||loan.name,'business_funds','not_required',auth.uid());
 select j.id into posted_journal from public.accounting_journals j
 where j.business_id=b and j.source_type='supplier_payment' and j.source_id=p_request and j.status='posted';
 if posted_journal is null then
  posted_journal:=public.v6170b_post_source('supplier_payment',p_request,'direct_asset_finance');
 end if;
 if posted_journal is null or not exists(
  select 1 from public.accounting_journal_lines where business_id=b and journal_id=posted_journal
  and account_id=loan.account_id and credit=p_amount
 ) then raise exception 'The payment journal did not credit the selected loan';end if;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by)
 values(b,'loan',loan.id,'supplier_financed',jsonb_build_object('payment_id',p_request,'expense_id',bill.id,'journal_id',posted_journal,'amount',p_amount),auth.uid());
 return p_request;
end $$;
revoke all on function public.frindly_record_direct_asset_finance(uuid,uuid,uuid,date,numeric,text) from public,anon;
grant execute on function public.frindly_record_direct_asset_finance(uuid,uuid,uuid,date,numeric,text) to authenticated;
notify pgrst, 'reload schema';

create function frindly_cash.guard_financed_supplier_match() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.expense_payment_id is not null and exists(
  select 1 from frindly_cash.loan_supplier_payments where payment_id=new.expense_payment_id
 ) then raise exception 'The lender paid this supplier directly. There is no business bank payment to match';end if;
 return new;
end $$;
revoke all on function frindly_cash.guard_financed_supplier_match() from public,anon,authenticated;
create trigger guard_financed_supplier_match before insert or update of expense_payment_id on public.bank_reconciliation_allocations
for each row execute function frindly_cash.guard_financed_supplier_match();

create function public.frindly_financeable_asset_bills()
returns table(id uuid,expense_number text,supplier_name text,outstanding numeric)
language plpgsql stable security definer set search_path='' as $$
declare b uuid:=frindly_cash.access(true);
begin
 if not coalesce(public.v6169a_accountant_centre_access(b,true),false) then raise exception 'Accounting access denied';end if;
 return query
 select e.id,e.expense_number::text,e.supplier_name::text,e.outstanding_balance
 from public.expenses e
 where e.business_id=b and not coalesce(e.archived,false) and coalesce(e.lifecycle_state,'recorded')='recorded'
 and e.payment_status<>'draft' and e.outstanding_balance>0
 and coalesce(e.business_use_percent,100)>=99.995 and coalesce(e.private_use_amount,0)<=0.005
 and exists(
  select 1 from public.accounting_journals j
  join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
  join public.accounting_accounts a on a.id=l.account_id and a.business_id=l.business_id
  where j.business_id=b and j.source_type='expense' and j.source_id=e.id and j.status='posted'
  and l.debit>0 and (a.account_type='fixed_asset' or a.report_section='fixed_assets')
 )
 and not exists(select 1 from public.supplier_credits c where c.business_id=b and c.applied_expense_id=e.id and c.status not in ('draft','voided','void'))
 order by e.invoice_date desc,e.id;
end $$;
revoke all on function public.frindly_financeable_asset_bills() from public,anon;
grant execute on function public.frindly_financeable_asset_bills() to authenticated;
