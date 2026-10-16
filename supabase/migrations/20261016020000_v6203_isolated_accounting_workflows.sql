-- Frindly v62.03
-- Isolated accounting workflow improvements.
-- Additive/idempotent: no existing records are rewritten or deleted.

begin;

-- Main already has this column; the isolated Dev project does not. Keeping this
-- compatibility addition here makes the release safe to apply to either.
alter table if exists public.bank_reconciliation_allocations
  add column if not exists existing_customer_payment_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.bank_reconciliation_allocations'::regclass
      and conname='bank_reconciliation_allocations_existing_customer_payment_fk'
  ) then
    alter table public.bank_reconciliation_allocations
      add constraint bank_reconciliation_allocations_existing_customer_payment_fk
      foreign key (existing_customer_payment_id)
      references public.customer_payments(id) on delete restrict;
  end if;
end$$;

create table if not exists public.bank_reconciliation_groups (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  request_id uuid not null,
  status text not null default 'pending' check (status in ('pending','completed','undone')),
  bank_total numeric(14,2) not null default 0 check (bank_total >= 0),
  allocation_total numeric(14,2) not null default 0 check (allocation_total >= 0),
  transaction_count integer not null default 0 check (transaction_count >= 0),
  allocation_count integer not null default 0 check (allocation_count >= 0),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  completed_at timestamptz,
  undone_at timestamptz,
  undone_by uuid,
  undo_reason text,
  unique (business_id, request_id)
);

alter table public.bank_reconciliation_groups enable row level security;
grant select on public.bank_reconciliation_groups to authenticated;
revoke insert, update, delete on public.bank_reconciliation_groups from anon, authenticated;

drop policy if exists bank_reconciliation_groups_select_v6203 on public.bank_reconciliation_groups;
create policy bank_reconciliation_groups_select_v6203
on public.bank_reconciliation_groups for select to authenticated
using (business_id = public.current_business_id());

alter table if exists public.bank_reconciliation_allocations
  add column if not exists reconciliation_group_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.bank_reconciliation_allocations'::regclass
      and conname='bank_reconciliation_allocations_group_fk'
  ) then
    alter table public.bank_reconciliation_allocations
      add constraint bank_reconciliation_allocations_group_fk
      foreign key (reconciliation_group_id)
      references public.bank_reconciliation_groups(id) on delete restrict;
  end if;
end$$;

create index if not exists bank_reconciliation_allocations_group_idx
  on public.bank_reconciliation_allocations(business_id,reconciliation_group_id)
  where reconciliation_group_id is not null;

-- Explicitly distinguish payments that require a bank match from payments that
-- are intentionally outside the business bank account (for example owner paid).
alter table if exists public.expense_payments
  add column if not exists reconciliation_requirement text not null default 'bank_match';
alter table if exists public.expense_payments
  drop constraint if exists expense_payments_reconciliation_requirement_ck;
alter table if exists public.expense_payments
  add constraint expense_payments_reconciliation_requirement_ck
  check (reconciliation_requirement in ('bank_match','not_required'));

update public.expense_payments
set reconciliation_requirement='not_required'
where funding_source='owner_personal'
  and reconciliation_requirement is distinct from 'not_required';

-- Document integrity and audit-safe removal metadata. Existing attachment
-- behaviour remains unchanged.
alter table if exists public.expense_attachments
  add column if not exists content_sha256 text,
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid,
  add column if not exists archive_reason text;

create index if not exists expense_attachments_hash_idx
  on public.expense_attachments(business_id,content_sha256)
  where content_sha256 is not null and archived_at is null;

create table if not exists public.expense_duplicate_reviews (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  candidate_expense_id uuid references public.expenses(id) on delete restrict,
  existing_expense_id uuid references public.expenses(id) on delete restrict,
  score integer not null check (score between 0 and 100),
  reasons jsonb not null default '[]'::jsonb,
  decision text not null check (decision in ('use_existing','review_both','create_anyway','replace_draft','dismissed')),
  decision_reason text,
  source text not null default 'expense_form',
  decided_at timestamptz not null default now(),
  decided_by uuid not null default auth.uid()
);

alter table public.expense_duplicate_reviews enable row level security;
grant select on public.expense_duplicate_reviews to authenticated;
revoke insert, update, delete on public.expense_duplicate_reviews from anon, authenticated;

drop policy if exists expense_duplicate_reviews_select_v6203 on public.expense_duplicate_reviews;
create policy expense_duplicate_reviews_select_v6203
on public.expense_duplicate_reviews for select to authenticated
using (business_id = public.current_business_id());

create index if not exists expenses_duplicate_lookup_v6203_idx
  on public.expenses(business_id,invoice_date,total_amount)
  where archived=false;

create index if not exists expense_duplicate_reviews_business_idx
  on public.expense_duplicate_reviews(business_id,decided_at desc);

-- Strengthen the existing allocation tenant guard. This closes the historical
-- gap where existing_customer_payment_id was not explicitly checked.
create or replace function public.v6135_validate_bank_allocation()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare tx_business uuid;
begin
  select business_id into tx_business
  from public.bank_transactions where id=new.bank_transaction_id;
  if tx_business is null or tx_business<>new.business_id then
    raise exception 'Bank allocation must belong to the same business as the bank transaction';
  end if;
  if new.invoice_id is not null and not exists(select 1 from public.invoices where id=new.invoice_id and business_id=new.business_id) then
    raise exception 'Invoice does not belong to this business';
  end if;
  if new.expense_id is not null and not exists(select 1 from public.expenses where id=new.expense_id and business_id=new.business_id) then
    raise exception 'Expense does not belong to this business';
  end if;
  if new.customer_payment_id is not null and not exists(select 1 from public.customer_payments where id=new.customer_payment_id and business_id=new.business_id) then
    raise exception 'Customer payment does not belong to this business';
  end if;
  if new.existing_customer_payment_id is not null and not exists(select 1 from public.customer_payments where id=new.existing_customer_payment_id and business_id=new.business_id) then
    raise exception 'Existing customer payment does not belong to this business';
  end if;
  if new.expense_payment_id is not null and not exists(select 1 from public.expense_payments where id=new.expense_payment_id and business_id=new.business_id) then
    raise exception 'Expense payment does not belong to this business';
  end if;
  if new.reconciliation_group_id is not null and not exists(select 1 from public.bank_reconciliation_groups where id=new.reconciliation_group_id and business_id=new.business_id) then
    raise exception 'Reconciliation group does not belong to this business';
  end if;
  return new;
end$$;

-- Candidate scoring is deterministic and explainable. It deliberately remains
-- advisory: legitimate recurring bills are never blocked by a database unique
-- constraint.
create or replace function public.v6203_expense_duplicate_candidates(
  p_supplier_id uuid,
  p_supplier_name text,
  p_reference text,
  p_invoice_date date,
  p_total numeric,
  p_content_sha256 text default null,
  p_exclude_expense_id uuid default null
) returns table(
  expense_id uuid,
  expense_number text,
  supplier_name text,
  supplier_reference text,
  invoice_date date,
  total_amount numeric,
  lifecycle_state text,
  score integer,
  reasons jsonb
)
language sql
stable
security definer
set search_path=''
as $$
  with input as (
    select public.current_business_id() bid,
      regexp_replace(lower(trim(coalesce(p_supplier_name,''))),'[^a-z0-9]+','','g') supplier_key,
      regexp_replace(lower(trim(coalesce(p_reference,''))),'[^a-z0-9]+','','g') reference_key,
      round(coalesce(p_total,0),2) total_value
  ), candidates as (
    select e.*,
      regexp_replace(lower(trim(coalesce(e.supplier_name,''))),'[^a-z0-9]+','','g') existing_supplier_key,
      regexp_replace(lower(trim(coalesce(e.supplier_reference,''))),'[^a-z0-9]+','','g') existing_reference_key,
      exists(
        select 1 from public.expense_attachments a
        where a.expense_id=e.id and a.business_id=e.business_id
          and a.archived_at is null and p_content_sha256 is not null
          and a.content_sha256=p_content_sha256
      ) hash_match
    from public.expenses e,input i
    where e.business_id=i.bid and not coalesce(e.archived,false)
      and (p_exclude_expense_id is null or e.id<>p_exclude_expense_id)
      and abs(round(e.total_amount,2)-i.total_value)<=0.01
      and abs(e.invoice_date-p_invoice_date)<=7
  ), scored as (
    select c.*,
      least(100,
        45
        + case when p_supplier_id is not null and c.supplier_id=p_supplier_id then 25 else 0 end
        + case when i.supplier_key<>'' and c.existing_supplier_key=i.supplier_key then 20 else 0 end
        + case when i.reference_key<>'' and c.existing_reference_key=i.reference_key then 20 else 0 end
        + case when c.invoice_date=p_invoice_date then 10 else 0 end
        + case when c.hash_match then 35 else 0 end
      )::integer calculated_score,
      jsonb_strip_nulls(jsonb_build_object(
        'same_amount',true,
        'same_supplier_id',case when p_supplier_id is not null and c.supplier_id=p_supplier_id then true end,
        'same_supplier_name',case when i.supplier_key<>'' and c.existing_supplier_key=i.supplier_key then true end,
        'same_reference',case when i.reference_key<>'' and c.existing_reference_key=i.reference_key then true end,
        'same_date',case when c.invoice_date=p_invoice_date then true end,
        'date_difference_days',abs(c.invoice_date-p_invoice_date),
        'same_attachment',case when c.hash_match then true end
      )) calculated_reasons
    from candidates c cross join input i
  )
  select s.id,s.expense_number,s.supplier_name,s.supplier_reference,s.invoice_date,
         s.total_amount,s.lifecycle_state,s.calculated_score,s.calculated_reasons
  from scored s
  where s.calculated_score>=65
  order by s.calculated_score desc,s.created_at desc
  limit 10
$$;

create or replace function public.v6203_record_duplicate_decision(
  p_candidate_expense_id uuid,
  p_existing_expense_id uuid,
  p_score integer,
  p_reasons jsonb,
  p_decision text,
  p_decision_reason text default null,
  p_source text default 'expense_form'
) returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare v_bid uuid:=public.current_business_id(); v_id uuid;
begin
  if auth.uid() is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'core'),false) then
    raise exception 'Expense write permission denied' using errcode='42501';
  end if;
  if p_existing_expense_id is null or not exists(select 1 from public.expenses where id=p_existing_expense_id and business_id=v_bid) then
    raise exception 'Existing expense was not found in this business';
  end if;
  if p_candidate_expense_id is not null and not exists(select 1 from public.expenses where id=p_candidate_expense_id and business_id=v_bid) then
    raise exception 'Candidate expense was not found in this business';
  end if;
  insert into public.expense_duplicate_reviews(
    business_id,candidate_expense_id,existing_expense_id,score,reasons,decision,decision_reason,source,decided_by
  ) values (
    v_bid,p_candidate_expense_id,p_existing_expense_id,least(100,greatest(0,coalesce(p_score,0))),
    coalesce(p_reasons,'{}'::jsonb),p_decision,nullif(trim(coalesce(p_decision_reason,'')),''),
    coalesce(nullif(trim(p_source),''),'expense_form'),auth.uid()
  ) returning id into v_id;
  return v_id;
end$$;

-- Minimal server draft used by photo-first capture. It carries no accounting
-- value and therefore cannot affect reports, GST or bank reconciliation.
create or replace function public.v6203_create_expense_draft(
  p_currency text default 'NZD'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_bid uuid:=public.current_business_id(); v_id uuid; v_number text;
begin
  if auth.uid() is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'core'),false) then
    raise exception 'Expense write permission denied' using errcode='42501';
  end if;
  v_number:=public.v51_next_expense_number();
  insert into public.expenses(
    business_id,expense_number,invoice_date,amount_type,gst_treatment,gst_rate,
    ex_gst,gst_amount,total_amount,payment_status,currency,is_split,created_by,updated_by
  ) values (
    v_bid,v_number,current_date,'inclusive','no_gst',0,0,0,0,'draft',
    upper(left(coalesce(nullif(trim(p_currency),''),'NZD'),3)),false,auth.uid(),auth.uid()
  ) returning id into v_id;
  return jsonb_build_object('id',v_id,'expense_number',v_number,'status','draft');
end$$;

-- Derived reconciliation state. Legacy manual flags are surfaced for review but
-- never treated as proof of a bank match.
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
      coalesce(sum(case when p.reconciliation_requirement='bank_match' then
        least(p.amount,coalesce(a.matched,0)) else 0 end),0) matched,
      coalesce(sum(case when p.reconciliation_requirement='not_required' then p.amount else 0 end),0) no_match,
      coalesce(e.reconciled,false) manual_flag
    from public.expenses e
    left join public.expense_payments p on p.expense_id=e.id and p.business_id=e.business_id
    left join lateral (
      select sum(bra.amount) matched from public.bank_reconciliation_allocations bra
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
      select sum(bra.amount) matched from public.bank_reconciliation_allocations bra
      where bra.business_id=i.business_id
        and (bra.customer_payment_id=p.id or bra.existing_customer_payment_id=p.id)
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

-- Group reconciliation supports many bank lines to one existing payment and
-- one bank line to many records in one database transaction.
create or replace function public.v6203_group_reconcile(
  p_bank_transaction_ids uuid[],
  p_allocations jsonb,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid();
  v_group public.bank_reconciliation_groups%rowtype;
  v_tx public.bank_transactions%rowtype; v_item jsonb;
  v_tx_total numeric; v_bank_total numeric:=0; v_alloc_total numeric:=0;
  v_payment_id uuid; v_target_id uuid; v_existing uuid; v_amount numeric;
  v_type text; v_note text; v_prior numeric; v_payment_amount numeric;
  v_count integer:=0;
begin
  if v_uid is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'bank'),false) then
    raise exception 'Bank reconciliation write access denied' using errcode='42501';
  end if;
  if p_request_id is null or coalesce(array_length(p_bank_transaction_ids,1),0)=0
     or p_allocations is null or jsonb_typeof(p_allocations)<>'array' or jsonb_array_length(p_allocations)=0 then
    raise exception 'Transactions, allocations and request ID are required';
  end if;
  select * into v_group from public.bank_reconciliation_groups
  where business_id=v_bid and request_id=p_request_id;
  if found then
    return jsonb_build_object('status',v_group.status,'group_id',v_group.id,'replayed',true);
  end if;
  if (select count(*) from unnest(p_bank_transaction_ids) x)<>(select count(distinct x) from unnest(p_bank_transaction_ids) x) then
    raise exception 'A bank transaction was selected more than once';
  end if;
  insert into public.bank_reconciliation_groups(business_id,request_id,status,created_by)
  values(v_bid,p_request_id,'pending',v_uid) returning * into v_group;

  foreach v_target_id in array p_bank_transaction_ids loop
    perform pg_advisory_xact_lock(hashtextextended(v_target_id::text,6203));
    select * into v_tx from public.bank_transactions
    where id=v_target_id and business_id=v_bid for update;
    if not found then raise exception 'A selected bank transaction was not found'; end if;
    if coalesce(v_tx.status,'unreconciled')<>'unreconciled' then raise exception 'A selected bank transaction is already reconciled'; end if;
    v_tx_total:=round(abs(v_tx.amount),2);
    select round(coalesce(sum((x->>'amount')::numeric),0),2) into v_alloc_total
    from jsonb_array_elements(p_allocations) x
    where (x->>'bank_transaction_id')::uuid=v_tx.id;
    if abs(v_tx_total-v_alloc_total)>0.005 then
      raise exception 'Allocations for bank transaction % must equal %',v_tx.id,v_tx_total;
    end if;
    v_bank_total:=v_bank_total+v_tx_total;
  end loop;

  v_alloc_total:=0;
  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_tx:=null; v_payment_id:=null; v_existing:=null; v_note:=null;
    select * into v_tx from public.bank_transactions
    where id=(v_item->>'bank_transaction_id')::uuid and business_id=v_bid for update;
    if not found or not (v_tx.id=any(p_bank_transaction_ids)) then raise exception 'Allocation references an unselected transaction'; end if;
    v_type:=v_item->>'type'; v_amount:=round((v_item->>'amount')::numeric,2);
    if v_amount<=0 then raise exception 'Allocation amounts must be positive'; end if;
    if v_type='invoice' then
      if v_tx.amount<=0 then raise exception 'Invoices require money-in transactions'; end if;
      v_target_id:=(v_item->>'invoice_id')::uuid;
      if not exists(select 1 from public.invoices where id=v_target_id and business_id=v_bid) then raise exception 'Invoice was not found in this business'; end if;
      v_existing:=nullif(v_item->>'existing_customer_payment_id','')::uuid;
      if v_existing is not null then
        select amount into v_payment_amount from public.customer_payments
        where id=v_existing and invoice_id=v_target_id and business_id=v_bid for update;
        if not found then raise exception 'Existing customer payment was not found for the selected invoice'; end if;
        select coalesce(sum(amount),0) into v_prior from public.bank_reconciliation_allocations
        where business_id=v_bid and (existing_customer_payment_id=v_existing or customer_payment_id=v_existing);
        if v_prior+v_amount>v_payment_amount+0.005 then raise exception 'Allocations exceed the existing customer payment'; end if;
        v_note:='v6203:existing_payment';
      else
        insert into public.customer_payments(business_id,invoice_id,payment_date,amount,reference,notes,created_by)
        values(v_bid,v_target_id,v_tx.transaction_date,v_amount,coalesce(v_tx.reference,v_tx.description),'Created by grouped bank reconciliation',v_uid)
        returning id into v_payment_id;
        v_note:='v6203:created_payment';
      end if;
      insert into public.bank_reconciliation_allocations(
        business_id,bank_transaction_id,allocation_type,amount,invoice_id,
        customer_payment_id,existing_customer_payment_id,reconciliation_group_id,note,created_by
      ) values(v_bid,v_tx.id,'invoice',v_amount,v_target_id,v_payment_id,v_existing,v_group.id,v_note,v_uid);
    elsif v_type='expense' then
      if v_tx.amount>=0 then raise exception 'Expenses require money-out transactions'; end if;
      v_target_id:=(v_item->>'expense_id')::uuid;
      if not exists(select 1 from public.expenses where id=v_target_id and business_id=v_bid and not coalesce(archived,false) and payment_status<>'draft') then
        raise exception 'Recorded expense was not found in this business';
      end if;
      v_existing:=nullif(v_item->>'existing_expense_payment_id','')::uuid;
      if v_existing is not null then
        select amount into v_payment_amount from public.expense_payments
        where id=v_existing and expense_id=v_target_id and business_id=v_bid for update;
        if not found then raise exception 'Existing expense payment was not found for the selected expense'; end if;
        select coalesce(sum(amount),0) into v_prior from public.bank_reconciliation_allocations
        where business_id=v_bid and expense_payment_id=v_existing;
        if v_prior+v_amount>v_payment_amount+0.005 then raise exception 'Allocations exceed the existing expense payment'; end if;
        v_payment_id:=v_existing; v_note:='v6203:existing_payment';
      else
        insert into public.expense_payments(
          business_id,expense_id,payment_date,amount,payment_method,reference,notes,
          reconciled,reconciled_at,reconciled_by,reconciliation_requirement,created_by
        ) values(
          v_bid,v_target_id,v_tx.transaction_date,v_amount,'Bank reconciliation',v_tx.reference,
          'Created by grouped bank reconciliation',true,now(),v_uid,'bank_match',v_uid
        ) returning id into v_payment_id;
        v_note:='v6203:created_payment';
      end if;
      insert into public.bank_reconciliation_allocations(
        business_id,bank_transaction_id,allocation_type,amount,expense_id,
        expense_payment_id,reconciliation_group_id,note,created_by
      ) values(v_bid,v_tx.id,'expense',v_amount,v_target_id,v_payment_id,v_group.id,v_note,v_uid);
    else
      raise exception 'Grouped reconciliation only supports invoice and expense allocations';
    end if;
    v_alloc_total:=v_alloc_total+v_amount; v_count:=v_count+1;
  end loop;

  if abs(v_bank_total-v_alloc_total)>0.005 then raise exception 'Group allocation total does not equal selected bank total'; end if;
  update public.bank_transactions set status='reconciled',reconciliation_type='group',
    reconciled_at=now(),reconciled_by=v_uid,updated_at=now(),updated_by=v_uid
  where business_id=v_bid and id=any(p_bank_transaction_ids);
  update public.bank_reconciliation_groups set status='completed',bank_total=v_bank_total,
    allocation_total=v_alloc_total,transaction_count=array_length(p_bank_transaction_ids,1),
    allocation_count=v_count,completed_at=now() where id=v_group.id;
  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  select v_bid,x,'group_reconciled',jsonb_build_object('group_id',v_group.id,'request_id',p_request_id),v_uid
  from unnest(p_bank_transaction_ids) x;
  return jsonb_build_object('status','completed','group_id',v_group.id,'bank_total',v_bank_total,
    'allocation_total',v_alloc_total,'transaction_count',array_length(p_bank_transaction_ids,1),'allocation_count',v_count,'replayed',false);
end$$;

create or replace function public.v6203_undo_reconciliation_group(
  p_group_id uuid,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid();
  v_group public.bank_reconciliation_groups%rowtype; v_row record; v_ids uuid[];
begin
  if v_uid is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'bank'),false) then
    raise exception 'Bank reconciliation write access denied' using errcode='42501';
  end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'An undo reason is required'; end if;
  select * into v_group from public.bank_reconciliation_groups
  where id=p_group_id and business_id=v_bid for update;
  if not found then raise exception 'Reconciliation group not found'; end if;
  if v_group.status='undone' then return jsonb_build_object('status','undone','group_id',p_group_id,'replayed',true); end if;
  if v_group.status<>'completed' then raise exception 'Only completed reconciliation groups can be undone'; end if;
  select array_agg(distinct bank_transaction_id) into v_ids
  from public.bank_reconciliation_allocations where business_id=v_bid and reconciliation_group_id=p_group_id;
  perform 1 from public.bank_transactions where business_id=v_bid and id=any(v_ids) for update;
  for v_row in
    delete from public.bank_reconciliation_allocations
    where business_id=v_bid and reconciliation_group_id=p_group_id
    returning customer_payment_id,expense_payment_id,note
  loop
    if v_row.note='v6203:created_payment' and v_row.customer_payment_id is not null then
      delete from public.customer_payments where id=v_row.customer_payment_id and business_id=v_bid;
    end if;
    if v_row.note='v6203:created_payment' and v_row.expense_payment_id is not null then
      delete from public.expense_payments where id=v_row.expense_payment_id and business_id=v_bid;
    end if;
  end loop;
  update public.bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,
    reconciled_by=null,updated_at=now(),updated_by=v_uid where business_id=v_bid and id=any(v_ids);
  update public.bank_reconciliation_groups set status='undone',undone_at=now(),undone_by=v_uid,
    undo_reason=trim(p_reason) where id=p_group_id;
  insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by)
  select v_bid,x,'group_undo',jsonb_build_object('group_id',p_group_id,'reason',trim(p_reason)),v_uid
  from unnest(v_ids) x;
  return jsonb_build_object('status','undone','group_id',p_group_id,'transaction_count',coalesce(array_length(v_ids,1),0),'replayed',false);
end$$;

-- Recorded-expense preflight. Financial edits are enabled only for unposted,
-- dependency-free expenses in open periods. Anything riskier stays unchanged and
-- is routed to the existing correction workflow.
create or replace function public.v6203_expense_edit_preflight(
  p_expense_id uuid,
  p_new_invoice_date date default null
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare v_bid uuid:=public.current_business_id(); v_e public.expenses%rowtype; v_new_date date;
begin
  if auth.uid() is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'core'),false) then
    return jsonb_build_object('mode','locked','reason','access_denied');
  end if;
  select * into v_e from public.expenses where id=p_expense_id and business_id=v_bid;
  if not found then return jsonb_build_object('mode','locked','reason','not_found'); end if;
  if v_e.lifecycle_state='draft' then return jsonb_build_object('mode','draft_full_edit'); end if;
  if v_e.lifecycle_state<>'recorded' or v_e.voided_at is not null or coalesce(v_e.archived,false) then
    return jsonb_build_object('mode','locked','reason','not_active_recorded');
  end if;
  v_new_date:=coalesce(p_new_invoice_date,v_e.invoice_date);
  if not public.v6170a_period_is_open(v_bid,v_e.invoice_date) or not public.v6170a_period_is_open(v_bid,v_new_date) then
    return jsonb_build_object('mode','correction_required','reason','accounting_period_closed');
  end if;
  if exists(select 1 from public.gst_returns where business_id=v_bid and status in ('reviewed','finalised') and (v_e.invoice_date between period_start and period_end or v_new_date between period_start and period_end))
     or exists(select 1 from public.bas_returns where business_id=v_bid and status in ('reviewed','finalised') and (v_e.invoice_date between period_start and period_end or v_new_date between period_start and period_end)) then
    return jsonb_build_object('mode','correction_required','reason','tax_return_locked');
  end if;
  if exists(select 1 from public.accounting_journals where business_id=v_bid and source_type='expense' and source_id=v_e.id and status in ('posted','reversed')) then
    return jsonb_build_object('mode','reversal_repost_required','reason','posted_journal');
  end if;
  if exists(select 1 from public.expense_payments where business_id=v_bid and expense_id=v_e.id)
     or exists(select 1 from public.supplier_credits where business_id=v_bid and original_expense_id=v_e.id and lifecycle_state='recorded')
     or exists(select 1 from public.bank_reconciliation_allocations where business_id=v_bid and expense_id=v_e.id)
     or exists(select 1 from public.purchase_invoice_reviews where business_id=v_bid and expense_id=v_e.id) then
    return jsonb_build_object('mode','correction_required','reason','financial_dependencies');
  end if;
  return jsonb_build_object('mode','recorded_direct_edit','reason','safe_unposted_dependency_free');
end$$;

-- Permit the controlled RPC below to replace split lines while retaining the
-- existing default block for every browser/direct-table update.
create or replace function public.v6170c1_expense_line_guard()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare eid uuid; st text; ver smallint; split boolean; sealed boolean; authorised boolean:=false;
begin
  eid:=case when tg_op='DELETE' then old.expense_id else new.expense_id end;
  select lifecycle_state,lifecycle_version,is_split,coalesce(financial_lines_sealed,false)
    into st,ver,split,sealed from public.expenses where id=eid;
  select exists(
    select 1 from public.frindly_expense_correction_authorizations a
    where a.expense_id=eid and a.business_id=public.current_business_id()
      and a.actor_id=auth.uid() and a.transaction_id=txid_current()
      and 'expense_lines'=any(a.allowed_fields)
  ) into authorised;
  if ver is not null and st in ('recorded','voided') then
    if authorised then return case when tg_op='DELETE' then old else new end; end if;
    if tg_op='INSERT' and st='recorded' and split and not sealed then return new; end if;
    raise exception using errcode='P0001',message='This expense is already part of your financial records. Its financial lines cannot be changed.';
  end if;
  return case when tg_op='DELETE' then old else new end;
end$$;

create or replace function public.v6203_edit_recorded_expense(
  p_expense_id uuid,
  p_changes jsonb,
  p_lines jsonb,
  p_expected_updated_at timestamptz,
  p_request_id uuid,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_bid uuid:=public.current_business_id(); v_uid uuid:=auth.uid();
  v_old public.expenses%rowtype; v_new public.expenses%rowtype; v_pre jsonb; v_line jsonb; v_revision uuid;
  v_allowed text[]:=array['supplier_id','supplier_name','supplier_reference','invoice_date','due_date','description','category_id','job_costing_id','amount_type','gst_treatment','gst_rate','gst_override','ex_gst','gst_amount','total_amount','outstanding_balance','currency','is_split','business_use_percent','business_use_amount','private_use_amount','business_ex_gst','business_gst_amount','allocation_method','allocation_basis','allocation_notes','financial_lines_sealed','updated_at','updated_by','expense_lines'];
begin
  if v_uid is null or v_bid is null or not coalesce(public.v6147_can_write_area(v_bid,'core'),false) then raise exception 'Expense edit permission denied' using errcode='42501'; end if;
  if p_request_id is null or p_expected_updated_at is null or length(trim(coalesce(p_reason,'')))<3 or jsonb_typeof(p_changes)<>'object' then raise exception 'Request ID, current version, changes and reason are required'; end if;
  select * into v_old from public.expenses where id=p_expense_id and business_id=v_bid for update;
  if not found then raise exception 'Expense not found'; end if;
  if exists(select 1 from public.expense_revisions where business_id=v_bid and request_id=p_request_id) then
    return jsonb_build_object('status','already_applied','expense_id',p_expense_id,'replayed',true);
  end if;
  if v_old.updated_at is distinct from p_expected_updated_at then raise exception 'Expense changed; refresh and retry' using errcode='40001'; end if;
  v_pre:=public.v6203_expense_edit_preflight(p_expense_id,coalesce((p_changes->>'invoice_date')::date,v_old.invoice_date));
  if v_pre->>'mode'<>'recorded_direct_edit' then return v_pre||jsonb_build_object('status','blocked'); end if;
  if coalesce((p_changes->>'total_amount')::numeric,v_old.total_amount)<=0 then raise exception 'Recorded expense total must be greater than zero'; end if;
  insert into public.frindly_expense_correction_authorizations(business_id,expense_id,actor_id,transaction_id,allowed_fields)
  values(v_bid,p_expense_id,v_uid,txid_current(),v_allowed);
  update public.expenses set
    supplier_id=case when p_changes?'supplier_id' then nullif(p_changes->>'supplier_id','')::uuid else supplier_id end,
    supplier_name=case when p_changes?'supplier_name' then nullif(trim(p_changes->>'supplier_name'),'') else supplier_name end,
    supplier_reference=case when p_changes?'supplier_reference' then nullif(trim(p_changes->>'supplier_reference'),'') else supplier_reference end,
    invoice_date=coalesce((p_changes->>'invoice_date')::date,invoice_date),
    due_date=case when p_changes?'due_date' then nullif(p_changes->>'due_date','')::date else due_date end,
    description=case when p_changes?'description' then nullif(trim(p_changes->>'description'),'') else description end,
    category_id=case when p_changes?'category_id' then nullif(p_changes->>'category_id','')::uuid else category_id end,
    job_costing_id=case when p_changes?'job_costing_id' then nullif(p_changes->>'job_costing_id','')::uuid else job_costing_id end,
    amount_type=coalesce(nullif(p_changes->>'amount_type',''),amount_type),
    gst_treatment=coalesce(nullif(p_changes->>'gst_treatment',''),gst_treatment),
    gst_rate=coalesce((p_changes->>'gst_rate')::numeric,gst_rate),
    gst_override=coalesce((p_changes->>'gst_override')::boolean,gst_override),
    ex_gst=coalesce((p_changes->>'ex_gst')::numeric,ex_gst),
    gst_amount=coalesce((p_changes->>'gst_amount')::numeric,gst_amount),
    total_amount=coalesce((p_changes->>'total_amount')::numeric,total_amount),
    outstanding_balance=coalesce((p_changes->>'total_amount')::numeric,total_amount),
    is_split=coalesce((p_changes->>'is_split')::boolean,is_split),
    business_use_percent=coalesce((p_changes->>'business_use_percent')::numeric,business_use_percent),
    business_use_amount=case when p_changes?'business_use_amount' then (p_changes->>'business_use_amount')::numeric else business_use_amount end,
    private_use_amount=case when p_changes?'private_use_amount' then (p_changes->>'private_use_amount')::numeric else private_use_amount end,
    business_ex_gst=case when p_changes?'business_ex_gst' then (p_changes->>'business_ex_gst')::numeric else business_ex_gst end,
    business_gst_amount=case when p_changes?'business_gst_amount' then (p_changes->>'business_gst_amount')::numeric else business_gst_amount end,
    allocation_method=coalesce(nullif(p_changes->>'allocation_method',''),allocation_method),
    allocation_basis=case when p_changes?'allocation_basis' then nullif(p_changes->>'allocation_basis','') else allocation_basis end,
    allocation_notes=case when p_changes?'allocation_notes' then nullif(p_changes->>'allocation_notes','') else allocation_notes end,
    financial_lines_sealed=false,updated_at=clock_timestamp(),updated_by=v_uid
  where id=p_expense_id and business_id=v_bid returning * into v_new;
  delete from public.expense_lines where expense_id=p_expense_id and business_id=v_bid;
  if v_new.is_split then
    if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'Split expense lines are required'; end if;
    for v_line in select value from jsonb_array_elements(p_lines) loop
      insert into public.expense_lines(expense_id,description,category_id,job_costing_id,amount_type,gst_treatment,gst_rate,ex_gst,gst_amount,total_amount,sort_order)
      values(p_expense_id,nullif(v_line->>'description',''),nullif(v_line->>'category_id','')::uuid,nullif(v_line->>'job_costing_id','')::uuid,
        'inclusive',coalesce(v_line->>'gst_treatment','no_gst'),coalesce((v_line->>'gst_rate')::numeric,0),
        (v_line->>'ex_gst')::numeric,(v_line->>'gst_amount')::numeric,(v_line->>'total_amount')::numeric,coalesce((v_line->>'sort_order')::integer,0));
    end loop;
  end if;
  insert into public.expense_revisions(business_id,expense_id,request_id,changed_by,change_reason,change_class,before_snapshot,after_snapshot,metadata)
  values(v_bid,p_expense_id,p_request_id,v_uid,trim(p_reason),'financial',to_jsonb(v_old),to_jsonb(v_new),jsonb_build_object('operation','v6203_safe_unposted_edit'))
  returning id into v_revision;
  delete from public.frindly_expense_correction_authorizations where business_id=v_bid and expense_id=p_expense_id and actor_id=v_uid and transaction_id=txid_current();
  return jsonb_build_object('status','applied','mode','recorded_direct_edit','expense_id',p_expense_id,'revision_id',v_revision,'updated_at',v_new.updated_at,'replayed',false);
end$$;

revoke execute on function public.v6203_expense_duplicate_candidates(uuid,text,text,date,numeric,text,uuid) from public,anon;
revoke execute on function public.v6203_record_duplicate_decision(uuid,uuid,integer,jsonb,text,text,text) from public,anon;
revoke execute on function public.v6203_create_expense_draft(text) from public,anon;
revoke execute on function public.v6203_reconciliation_statuses() from public,anon;
revoke execute on function public.v6203_group_reconcile(uuid[],jsonb,uuid) from public,anon;
revoke execute on function public.v6203_undo_reconciliation_group(uuid,text) from public,anon;
revoke execute on function public.v6203_expense_edit_preflight(uuid,date) from public,anon;
revoke execute on function public.v6203_edit_recorded_expense(uuid,jsonb,jsonb,timestamptz,uuid,text) from public,anon;

grant execute on function public.v6203_expense_duplicate_candidates(uuid,text,text,date,numeric,text,uuid) to authenticated;
grant execute on function public.v6203_record_duplicate_decision(uuid,uuid,integer,jsonb,text,text,text) to authenticated;
grant execute on function public.v6203_create_expense_draft(text) to authenticated;
grant execute on function public.v6203_reconciliation_statuses() to authenticated;
grant execute on function public.v6203_group_reconcile(uuid[],jsonb,uuid) to authenticated;
grant execute on function public.v6203_undo_reconciliation_group(uuid,text) to authenticated;
grant execute on function public.v6203_expense_edit_preflight(uuid,date) to authenticated;
grant execute on function public.v6203_edit_recorded_expense(uuid,jsonb,jsonb,timestamptz,uuid,text) to authenticated;

commit;
