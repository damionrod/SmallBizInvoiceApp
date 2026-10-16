-- Frindly v62.03 follow-up hardening.
-- Keeps reconciliation state evidence-based and makes bank-created expenses atomic.

begin;

-- Compatibility for older isolated environments. Main already has this field.
alter table if exists public.bank_reconciliation_allocations
  add column if not exists invoice_payment_transaction_id uuid;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.bank_reconciliation_allocations'::regclass
      and conname='bank_reconciliation_allocations_invoice_payment_transaction_fk'
  ) then
    alter table public.bank_reconciliation_allocations
      add constraint bank_reconciliation_allocations_invoice_payment_transaction_fk
      foreign key (invoice_payment_transaction_id)
      references public.invoice_payment_transactions(id) on delete restrict;
  end if;
end$$;

create or replace function public.v6203_set_expense_payment_requirement()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.funding_source='owner_personal' then
    new.reconciliation_requirement:='not_required';
  elsif new.reconciliation_requirement is null then
    new.reconciliation_requirement:='bank_match';
  end if;
  return new;
end$$;

drop trigger if exists v6203_set_expense_payment_requirement on public.expense_payments;
create trigger v6203_set_expense_payment_requirement
before insert or update of funding_source,reconciliation_requirement
on public.expense_payments
for each row execute function public.v6203_set_expense_payment_requirement();

create or replace function public.v6203_reconciliation_statuses()
returns table(
  record_type text,
  record_id uuid,
  reconciliation_status text,
  matched_amount numeric,
  required_amount numeric,
  legacy_manual boolean
)
language sql
stable
security definer
set search_path=''
as $$
  with bid as (select public.current_business_id() id),
  expense_values as (
    select e.id,
      coalesce(sum(case when p.reconciliation_requirement='bank_match' then p.amount else 0 end),0) required,
      coalesce(sum(case when p.reconciliation_requirement='bank_match' then least(p.amount,coalesce(a.matched,0)) else 0 end),0) matched,
      coalesce(sum(case when p.reconciliation_requirement='not_required' then p.amount else 0 end),0) no_match,
      coalesce(e.reconciled,false) manual_flag
    from public.expenses e
    left join public.expense_payments p on p.expense_id=e.id and p.business_id=e.business_id
    left join lateral (
      select sum(bra.amount) matched
      from public.bank_reconciliation_allocations bra
      where bra.business_id=e.business_id and bra.expense_payment_id=p.id
    ) a on true
    where e.business_id=(select id from bid) and not coalesce(e.archived,false)
    group by e.id,e.reconciled
  ), invoice_values as (
    select i.id,
      coalesce(sum(p.amount),0) required,
      coalesce(sum(least(p.amount,coalesce(a.matched,0))),0) matched
    from public.invoices i
    left join public.customer_payments p on p.invoice_id=i.id and p.business_id=i.business_id
    left join lateral (
      select sum(bra.amount) matched
      from public.bank_reconciliation_allocations bra
      where bra.business_id=i.business_id and (
        bra.customer_payment_id=p.id
        or bra.existing_customer_payment_id=p.id
        or exists (
          select 1 from public.invoice_payment_transactions ipt
          where ipt.id=bra.invoice_payment_transaction_id
            and ipt.business_id=i.business_id
            and ipt.customer_payment_id=p.id
        )
      )
    ) a on true
    where i.business_id=(select id from bid)
    group by i.id
  )
  select 'expense',e.id,
    case
      when e.required<=0.005 and e.no_match>0.005 then 'not_required'
      when e.required<=0.005 and e.manual_flag then 'legacy_manual_review'
      when e.required<=0.005 then 'awaiting_payment'
      when e.matched<=0.005 and e.manual_flag then 'legacy_manual_review'
      when e.matched<=0.005 then 'awaiting_bank_match'
      when e.matched+0.005<e.required then 'part_reconciled'
      else 'reconciled'
    end,e.matched,e.required,(e.manual_flag and e.matched<=0.005)
  from expense_values e
  union all
  select 'invoice',i.id,
    case when i.required<=0.005 then 'awaiting_payment'
         when i.matched<=0.005 then 'awaiting_bank_match'
         when i.matched+0.005<i.required then 'part_reconciled'
         else 'reconciled' end,
    i.matched,i.required,false
  from invoice_values i
$$;

create or replace function public.v6203_create_expense_from_bank(
  p_bank_transaction_id uuid,
  p_category_id uuid,
  p_description text,
  p_gst_treatment text,
  p_gst_rate numeric,
  p_ex_gst numeric,
  p_gst_amount numeric,
  p_total numeric,
  p_create_anyway boolean,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid();
  v_tx public.bank_transactions%rowtype; v_expense public.expenses%rowtype;
  v_payment_id uuid; v_number text; v_duplicate record;
begin
  if v_uid is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'bank'),false) then
    raise exception 'Bank reconciliation write access denied' using errcode='42501';
  end if;
  if p_request_id is null then raise exception 'Request ID is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_bank_transaction_id::text,6203));
  select * into v_tx from public.bank_transactions
  where id=p_bank_transaction_id and business_id=v_bid for update;
  if not found then raise exception 'Bank transaction not found'; end if;
  if coalesce(v_tx.status,'unreconciled')<>'unreconciled' then raise exception 'Bank transaction is already reconciled'; end if;
  if v_tx.amount>=0 then raise exception 'An expense can only be created from money going out'; end if;
  if not exists(select 1 from public.expense_categories where id=p_category_id and business_id=v_bid and not coalesce(archived,false)) then
    raise exception 'Expense category is not available for this business';
  end if;
  if p_total<=0 or abs(round(abs(v_tx.amount),2)-round(p_total,2))>0.005
     or abs(round(coalesce(p_ex_gst,0)+coalesce(p_gst_amount,0),2)-round(p_total,2))>0.005 then
    raise exception 'Expense values must equal the bank transaction amount';
  end if;
  select e.id,e.expense_number,e.supplier_name,e.supplier_reference,e.invoice_date,e.total_amount
  into v_duplicate
  from public.expenses e
  where e.business_id=v_bid and not coalesce(e.archived,false) and e.payment_status<>'draft'
    and abs(e.total_amount-p_total)<=0.005
    and abs(e.invoice_date-v_tx.transaction_date)<=7
    and (
      (nullif(trim(coalesce(v_tx.reference,'')),'') is not null and lower(trim(coalesce(e.supplier_reference,'')))=lower(trim(v_tx.reference)))
      or (nullif(trim(coalesce(v_tx.payee,'')),'') is not null and lower(regexp_replace(coalesce(e.supplier_name,''),'[^a-zA-Z0-9]','','g'))=lower(regexp_replace(v_tx.payee,'[^a-zA-Z0-9]','','g')))
    )
  order by case when e.invoice_date=v_tx.transaction_date then 0 else 1 end,e.created_at desc
  limit 1;
  if found and not coalesce(p_create_anyway,false) then
    return jsonb_build_object('status','possible_duplicate','duplicate',jsonb_build_object(
      'expense_id',v_duplicate.id,'expense_number',v_duplicate.expense_number,
      'supplier_name',v_duplicate.supplier_name,'supplier_reference',v_duplicate.supplier_reference,
      'invoice_date',v_duplicate.invoice_date,'total_amount',v_duplicate.total_amount,'score',90
    ));
  end if;
  v_number:=public.v51_next_expense_number();
  insert into public.expenses(
    business_id,expense_number,supplier_name,supplier_reference,invoice_date,due_date,description,
    category_id,amount_type,gst_treatment,gst_rate,gst_override,ex_gst,gst_amount,total_amount,
    payment_status,currency,is_split,created_by,updated_by
  ) values (
    v_bid,v_number,nullif(trim(v_tx.payee),''),nullif(trim(v_tx.reference),''),v_tx.transaction_date,v_tx.transaction_date,
    nullif(trim(p_description),''),p_category_id,'inclusive',p_gst_treatment,p_gst_rate,false,p_ex_gst,p_gst_amount,p_total,
    'unpaid',(select upper(coalesce(settings->>'currency','NZD')) from public.businesses where id=v_bid),false,v_uid,v_uid
  ) returning * into v_expense;
  insert into public.expense_payments(
    business_id,expense_id,payment_date,amount,payment_method,reference,notes,reconciled,reconciled_at,
    reconciled_by,bank_transaction_reference,reconciliation_requirement,created_by
  ) values (
    v_bid,v_expense.id,v_tx.transaction_date,p_total,'Bank reconciliation',v_tx.reference,
    'Created from bank transaction',true,now(),v_uid,coalesce(v_tx.bank_transaction_id,v_tx.reference),'bank_match',v_uid
  ) returning id into v_payment_id;
  insert into public.bank_reconciliation_allocations(
    business_id,bank_transaction_id,allocation_type,amount,expense_id,expense_payment_id,created_expense,note,created_by
  ) values (v_bid,v_tx.id,'expense',p_total,v_expense.id,v_payment_id,true,'v6203:atomic_bank_expense',v_uid);
  update public.bank_transactions set status='reconciled',reconciliation_type='created_expense',
    reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
  where id=v_tx.id and business_id=v_bid;
  if v_duplicate.id is not null then
    insert into public.expense_duplicate_reviews(
      business_id,candidate_expense_id,existing_expense_id,score,reasons,decision,decision_reason,source,decided_by
    ) values (
      v_bid,v_expense.id,v_duplicate.id,90,jsonb_build_array('same amount','near date','matching supplier or reference'),
      'create_anyway','Confirmed while creating expense from bank reconciliation','bank_reconciliation',v_uid
    );
  end if;
  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  values(v_bid,v_tx.id,'created_expense',jsonb_build_object('request_id',p_request_id,'expense_id',v_expense.id,'payment_id',v_payment_id,'amount',p_total),v_uid);
  return jsonb_build_object('status','completed','expense_id',v_expense.id,'expense_number',v_expense.expense_number,'payment_id',v_payment_id);
end$$;

revoke execute on function public.v6203_set_expense_payment_requirement() from public,anon;
revoke execute on function public.v6203_reconciliation_statuses() from public,anon;
revoke execute on function public.v6203_create_expense_from_bank(uuid,uuid,text,text,numeric,numeric,numeric,numeric,boolean,uuid) from public,anon;
grant execute on function public.v6203_reconciliation_statuses() to authenticated;
grant execute on function public.v6203_create_expense_from_bank(uuid,uuid,text,text,numeric,numeric,numeric,numeric,boolean,uuid) to authenticated;

commit;
