-- Finlo V61.70C45 — corrections, supplier credits/refunds and accounting report integration
-- Extends existing supplier_credits. Does not bootstrap historical businesses or create historical journals.

-- Existing supplier credit architecture: extend in place.
alter table public.supplier_credits add column if not exists original_expense_id uuid references public.expenses(id) on delete restrict;
alter table public.supplier_credits add column if not exists credit_type text;
alter table public.supplier_credits add column if not exists supplier_reference text;
alter table public.supplier_credits add column if not exists reason text;
alter table public.supplier_credits add column if not exists lifecycle_state text;
alter table public.supplier_credits add column if not exists lifecycle_version smallint;
alter table public.supplier_credits add column if not exists idempotency_key uuid;
alter table public.supplier_credits add column if not exists recorded_at timestamptz;
alter table public.supplier_credits add column if not exists recorded_by uuid;
alter table public.supplier_credits add column if not exists financial_locked_at timestamptz;
alter table public.supplier_credits add column if not exists voided_at timestamptz;
alter table public.supplier_credits add column if not exists voided_by uuid;
alter table public.supplier_credits add column if not exists void_reason text;
create unique index if not exists supplier_credits_business_idempotency_uq on public.supplier_credits(business_id,idempotency_key) where idempotency_key is not null;
create index if not exists supplier_credits_original_expense_idx on public.supplier_credits(business_id,original_expense_id);

create table if not exists public.supplier_credit_counters(
 business_id uuid primary key references public.businesses(id) on delete cascade,
 next_number bigint not null default 1 check(next_number>0)
);
alter table public.supplier_credit_counters enable row level security;
revoke all on public.supplier_credit_counters from anon,authenticated;

-- Minimum protected supplier refund architecture, mirroring C3 settlement/evidence separation.
create table if not exists public.supplier_refunds(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 supplier_id uuid references public.suppliers(id) on delete restrict,
 refund_number text not null,
 refund_date date not null default current_date,
 amount numeric(14,2) not null check(amount>0),
 currency text not null default 'NZD',
 method text not null default 'bank_transfer' check(method in('bank_transfer','card','cash','other')),
 reference text,
 notes text,
 lifecycle_state text not null default 'draft' check(lifecycle_state in('draft','recorded','voided')),
 idempotency_key uuid not null default gen_random_uuid(),
 created_at timestamptz not null default now(), created_by uuid default auth.uid(),
 updated_at timestamptz not null default now(), updated_by uuid default auth.uid(),
 recorded_at timestamptz, recorded_by uuid, financial_locked_at timestamptz,
 voided_at timestamptz, voided_by uuid, void_reason text,
 unique(business_id,refund_number), unique(business_id,idempotency_key)
);
create index if not exists supplier_refunds_supplier_idx on public.supplier_refunds(business_id,supplier_id,lifecycle_state);
alter table public.supplier_refunds enable row level security;
drop policy if exists c45_supplier_refunds_select on public.supplier_refunds;
create policy c45_supplier_refunds_select on public.supplier_refunds for select to authenticated using(public.v6147_can_read_area(business_id,'core'));
revoke all on public.supplier_refunds from anon;
revoke insert,update,delete,truncate on public.supplier_refunds from authenticated;
grant select on public.supplier_refunds to authenticated;

create table if not exists public.supplier_refund_counters(
 business_id uuid primary key references public.businesses(id) on delete cascade,
 next_number bigint not null default 1 check(next_number>0)
);
alter table public.supplier_refund_counters enable row level security;
revoke all on public.supplier_refund_counters from anon,authenticated;

alter table public.bank_reconciliation_allocations add column if not exists supplier_refund_id uuid references public.supplier_refunds(id) on delete set null;
create unique index if not exists bank_alloc_supplier_refund_uq on public.bank_reconciliation_allocations(business_id,supplier_refund_id) where supplier_refund_id is not null;

alter table public.bank_transactions drop constraint if exists bank_recon_type_c3;
alter table public.bank_transactions drop constraint if exists bank_recon_type_c45;
alter table public.bank_transactions add constraint bank_recon_type_c45 check(reconciliation_type is null or reconciliation_type in('invoice','expense','created_expense','split','transfer','excluded','customer_refund','supplier_refund'));

-- Extend allocation type without changing existing rows.
do $$ begin
 alter table public.bank_reconciliation_allocations drop constraint if exists bank_alloc_type_c3;
 alter table public.bank_reconciliation_allocations drop constraint if exists bank_reconciliation_allocations_allocation_type_check;
 alter table public.bank_reconciliation_allocations add constraint bank_reconciliation_allocations_allocation_type_check check(allocation_type in('invoice','expense','transfer','exclude','customer_refund','supplier_refund'));
end $$;

-- Narrow existing supplier-credit browser mutation: C45 financial lifecycle goes through RPCs.
alter table public.supplier_credits enable row level security;
revoke truncate on public.supplier_credits from anon,authenticated;
revoke insert,update,delete on public.supplier_credits from authenticated;
grant select on public.supplier_credits to authenticated;

create or replace function public.v6170c45_next_supplier_credit_number(p_bid uuid) returns text language plpgsql security definer set search_path=public as $$
declare n bigint;begin
 insert into supplier_credit_counters(business_id,next_number) values(p_bid,2)
 on conflict(business_id) do update set next_number=supplier_credit_counters.next_number+1
 returning next_number-1 into n;
 return 'SC-'||lpad(n::text,4,'0');
end$$;

create or replace function public.v6170c45_next_supplier_refund_number(p_bid uuid) returns text language plpgsql security definer set search_path=public as $$
declare n bigint;begin
 insert into supplier_refund_counters(business_id,next_number) values(p_bid,2)
 on conflict(business_id) do update set next_number=supplier_refund_counters.next_number+1
 returning next_number-1 into n;
 return 'SR-'||lpad(n::text,4,'0');
end$$;

-- Source ownership: preserve A1 and add already-existing C3 refund + C45 sources.
create or replace function public.v6170a_validate_source_owner(p_business_id uuid,p_source_type text,p_source_id uuid) returns boolean language plpgsql stable security definer set search_path=public as $$
begin
 if p_source_id is null then return p_source_type in('manual','opening_balance','year_end','tax_adjustment','depreciation');end if;
 case p_source_type
 when 'invoice' then return exists(select 1 from invoices x where x.id=p_source_id and x.business_id=p_business_id);
 when 'customer_payment' then return exists(select 1 from customer_payments x where x.id=p_source_id and x.business_id=p_business_id);
 when 'expense' then return exists(select 1 from expenses x where x.id=p_source_id and x.business_id=p_business_id);
 when 'supplier_payment' then return exists(select 1 from expense_payments x where x.id=p_source_id and x.business_id=p_business_id);
 when 'payroll' then return exists(select 1 from payroll_pay_runs x where x.id=p_source_id and x.business_id=p_business_id and x.status='finalised');
 when 'bank' then return exists(select 1 from bank_transactions x where x.id=p_source_id and x.business_id=p_business_id);
 when 'supplier_credit' then return exists(select 1 from supplier_credits x where x.id=p_source_id and x.business_id=p_business_id and x.lifecycle_state='recorded');
 when 'supplier_refund' then return exists(select 1 from supplier_refunds x where x.id=p_source_id and x.business_id=p_business_id and x.lifecycle_state='recorded');
 when 'customer_credit_note' then return exists(select 1 from customer_credit_notes x where x.id=p_source_id and x.business_id=p_business_id and x.lifecycle_state='issued');
 when 'customer_refund' then return exists(select 1 from customer_refunds x where x.id=p_source_id and x.business_id=p_business_id and x.lifecycle_state='recorded');
 else return false;end case;
end$$;

create or replace function public.v6170c45_create_supplier_credit(p_expense_id uuid,p_credit_type text,p_total numeric,p_credit_date date,p_supplier_reference text,p_reason text,p_idempotency_key uuid default gen_random_uuid()) returns public.supplier_credits language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();e expenses;r supplier_credits;credited numeric;ratio numeric;gst numeric;ex numeric;num text;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier credit access denied' using errcode='42501';end if;
 select * into e from expenses where id=p_expense_id and business_id=bid for update;if not found then raise exception 'Expense not found';end if;
 if e.lifecycle_version is null or e.lifecycle_state<>'recorded' then raise exception 'Supplier credits require a C1 Recorded expense';end if;
 if p_total<=0 then raise exception 'Credit amount must be positive';end if;if p_credit_type not in('full','partial') then raise exception 'Credit type must be full or partial';end if;
 perform pg_advisory_xact_lock(hashtextextended(bid::text||':'||e.id::text,0));
 select coalesce(sum(total_amount),0) into credited from supplier_credits where business_id=bid and original_expense_id=e.id and lifecycle_state='recorded';
 if credited+p_total>e.total_amount+0.005 then raise exception 'Supplier credits exceed the original expense';end if;
 if p_credit_type='full' and abs(p_total-(e.total_amount-credited))>0.005 then raise exception 'Full credit must equal the remaining expense amount';end if;
 select * into r from supplier_credits where business_id=bid and idempotency_key=p_idempotency_key limit 1;if found then return r;end if;
 ratio:=case when e.total_amount=0 then 0 else p_total/e.total_amount end;gst:=round(e.gst_amount*ratio,2);ex:=round(p_total-gst,2);num:=v6170c45_next_supplier_credit_number(bid);
 insert into supplier_credits(business_id,supplier_id,credit_note_number,credit_date,category_id,ex_gst,gst_amount,total_amount,status,applied_expense_id,notes,original_expense_id,credit_type,supplier_reference,reason,lifecycle_state,lifecycle_version,idempotency_key,created_by,updated_by)
 values(bid,e.supplier_id,num,coalesce(p_credit_date,current_date),e.category_id,ex,gst,p_total,'draft',e.id,p_reason,e.id,p_credit_type,p_supplier_reference,p_reason,'draft',1,p_idempotency_key,auth.uid(),auth.uid()) returning * into r;return r;
end$$;

create or replace function public.v6170c45_update_supplier_credit(p_credit_id uuid,p_total numeric,p_credit_date date,p_supplier_reference text,p_reason text,p_credit_type text) returns public.supplier_credits language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r supplier_credits;e expenses;credited numeric;ratio numeric;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier credit access denied' using errcode='42501';end if;
 select * into r from supplier_credits where id=p_credit_id and business_id=bid for update;if not found or r.lifecycle_state<>'draft' then raise exception 'Only a draft supplier credit can be edited';end if;
 select * into e from expenses where id=r.original_expense_id and business_id=bid;if not found then raise exception 'Original expense not found';end if;
 perform pg_advisory_xact_lock(hashtextextended(bid::text||':'||e.id::text,0));select coalesce(sum(total_amount),0) into credited from supplier_credits where business_id=bid and original_expense_id=e.id and lifecycle_state='recorded';if p_total<=0 or credited+p_total>e.total_amount+0.005 then raise exception 'Supplier credit exceeds remaining expense amount';end if;
 ratio:=p_total/e.total_amount;update supplier_credits set total_amount=p_total,gst_amount=round(e.gst_amount*ratio,2),ex_gst=round(p_total-round(e.gst_amount*ratio,2),2),credit_date=coalesce(p_credit_date,credit_date),supplier_reference=p_supplier_reference,reason=p_reason,notes=p_reason,credit_type=p_credit_type,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;return r;
end$$;

create or replace function public.v6170c45_delete_draft_supplier_credit(p_credit_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();begin if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier credit access denied' using errcode='42501';end if;delete from supplier_credits where id=p_credit_id and business_id=bid and lifecycle_state='draft';if not found then raise exception 'Only a draft supplier credit can be deleted';end if;end$$;

create or replace function public.v6170c45_record_supplier_credit(p_credit_id uuid) returns public.supplier_credits language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r supplier_credits;e expenses;credited numeric;ratio numeric;business_ex numeric;business_gst numeric;private_part numeric;lines jsonb;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier credit access denied' using errcode='42501';end if;
 select * into r from supplier_credits where id=p_credit_id and business_id=bid for update;if not found then raise exception 'Supplier credit not found';end if;if r.lifecycle_state='recorded' then return r;end if;if r.lifecycle_state<>'draft' then raise exception 'Only draft can record';end if;
 select * into e from expenses where id=r.original_expense_id and business_id=bid for update;if not found or e.lifecycle_state<>'recorded' then raise exception 'Original expense is not Recorded';end if;
 perform pg_advisory_xact_lock(hashtextextended(bid::text||':'||e.id::text,0));select coalesce(sum(total_amount),0) into credited from supplier_credits where business_id=bid and original_expense_id=e.id and lifecycle_state='recorded';if credited+r.total_amount>e.total_amount+0.005 then raise exception 'Supplier credits exceed original expense';end if;
 update supplier_credits set lifecycle_state='recorded',status='available',recorded_at=now(),recorded_by=auth.uid(),financial_locked_at=now(),updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 -- Only post when the original expense itself is accounting-backed; never manufacture history.
 if exists(select 1 from accounting_journals j where j.business_id=bid and j.source_type='expense' and j.source_id=e.id and j.status in('posted','reversed')) then
   ratio:=r.total_amount/e.total_amount;business_ex:=round(coalesce(e.business_ex_gst,e.ex_gst*coalesce(e.business_use_percent,100)/100)*ratio,2);business_gst:=round(coalesce(e.business_gst_amount,e.gst_amount*coalesce(e.business_use_percent,100)/100)*ratio,2);private_part:=round(r.total_amount-business_ex-business_gst,2);
   lines:=jsonb_build_array(jsonb_build_object('account_id',v6170b_account(bid,'accounts_payable'),'debit',r.total_amount,'credit',0),jsonb_build_object('account_id',v6170b_account(bid,'general_expense'),'debit',0,'credit',business_ex),jsonb_build_object('account_id',v6170b_account(bid,'gst_receivable'),'debit',0,'credit',business_gst),jsonb_build_object('account_id',v6170b_account(bid,'owner_drawings'),'debit',0,'credit',private_part));
   select jsonb_agg(x) into lines from jsonb_array_elements(lines)x where coalesce((x->>'debit')::numeric,0)>0 or coalesce((x->>'credit')::numeric,0)>0;
   perform v6170a_post_journal(r.credit_date,'supplier_credit',r.id,r.credit_note_number,'Supplier credit '||r.credit_note_number,'supplier_credit',lines,1,'v61.70c45');
 end if;return r;
end$$;

create or replace function public.v6170c45_void_supplier_credit(p_credit_id uuid,p_reason text) returns public.supplier_credits language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r supplier_credits;j uuid;begin if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier credit access denied' using errcode='42501';end if;if coalesce(btrim(p_reason),'')='' then raise exception 'Void reason is required';end if;select * into r from supplier_credits where id=p_credit_id and business_id=bid for update;if not found or r.lifecycle_state<>'recorded' then raise exception 'Only a Recorded supplier credit can be voided';end if;if exists(select 1 from supplier_refunds sr where sr.business_id=bid and sr.supplier_id=r.supplier_id and sr.lifecycle_state='recorded') then raise exception 'Resolve supplier refund settlement before voiding this credit';end if;select id into j from accounting_journals where business_id=bid and source_type='supplier_credit' and source_id=r.id and status='posted' order by posting_version desc limit 1;if j is not null then perform v6170a_reverse_journal(j,p_reason);end if;update supplier_credits set lifecycle_state='voided',status='voided',voided_at=now(),voided_by=auth.uid(),void_reason=p_reason,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;return r;end$$;

create or replace function public.v6170c45_supplier_credit(p_supplier_id uuid) returns table(gross_credit numeric,recorded_refunds numeric,available_credit numeric) language sql stable security definer set search_path=public as $$
with b as(select current_business_id() bid),x as(
 select e.id,e.total_amount,coalesce((select sum(p.amount) from expense_payments p where p.business_id=e.business_id and p.expense_id=e.id),0) paid,coalesce((select sum(c.total_amount) from supplier_credits c where c.business_id=e.business_id and c.original_expense_id=e.id and c.lifecycle_state='recorded'),0) credits from expenses e,b where e.business_id=b.bid and e.supplier_id=p_supplier_id and coalesce(e.lifecycle_state,'recorded')<>'voided'
),g as(select coalesce(sum(greatest(paid+credits-total_amount,0)),0) gross from x),r as(select coalesce(sum(amount),0) used from supplier_refunds,b where business_id=b.bid and supplier_id=p_supplier_id and lifecycle_state='recorded') select g.gross,r.used,greatest(g.gross-r.used,0) from g,r$$;

create or replace function public.v6170c45_create_supplier_refund(p_supplier_id uuid,p_amount numeric,p_refund_date date,p_method text,p_reference text,p_notes text,p_idempotency_key uuid default gen_random_uuid()) returns public.supplier_refunds language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r supplier_refunds;begin if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier refund access denied' using errcode='42501';end if;if not exists(select 1 from suppliers where id=p_supplier_id and business_id=bid) then raise exception 'Supplier not found';end if;if p_amount<=0 then raise exception 'Refund amount must be positive';end if;select * into r from supplier_refunds where business_id=bid and idempotency_key=p_idempotency_key;if found then return r;end if;insert into supplier_refunds(business_id,supplier_id,refund_number,refund_date,amount,method,reference,notes,idempotency_key) values(bid,p_supplier_id,v6170c45_next_supplier_refund_number(bid),coalesce(p_refund_date,current_date),p_amount,coalesce(p_method,'bank_transfer'),p_reference,p_notes,p_idempotency_key) returning * into r;return r;end$$;

create or replace function public.v6170c45_record_supplier_refund(p_refund_id uuid) returns public.supplier_refunds language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r supplier_refunds;s record;backed numeric;used numeric;lines jsonb;begin if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier refund access denied' using errcode='42501';end if;select * into r from supplier_refunds where id=p_refund_id and business_id=bid for update;if not found then raise exception 'Supplier refund not found';end if;if r.lifecycle_state='recorded' then return r;end if;if r.lifecycle_state<>'draft' then raise exception 'Only draft can record';end if;perform pg_advisory_xact_lock(hashtextextended(bid::text||':'||r.supplier_id::text,0));select * into s from v6170c45_supplier_credit(r.supplier_id);if r.amount>s.available_credit+0.005 then raise exception 'Refund exceeds available supplier credit';end if;update supplier_refunds set lifecycle_state='recorded',recorded_at=now(),recorded_by=auth.uid(),financial_locked_at=now(),updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 select coalesce(sum(sc.total_amount),0) into backed from supplier_credits sc where sc.business_id=bid and sc.supplier_id=r.supplier_id and sc.lifecycle_state='recorded' and exists(select 1 from accounting_journals j where j.business_id=bid and j.source_type='supplier_credit' and j.source_id=sc.id and j.status in('posted','reversed'));
 select coalesce(sum(sr.amount),0) into used from supplier_refunds sr where sr.business_id=bid and sr.supplier_id=r.supplier_id and sr.lifecycle_state='recorded' and sr.id<>r.id and exists(select 1 from accounting_journals j where j.business_id=bid and j.source_type='supplier_refund' and j.source_id=sr.id and j.status='posted');
 if greatest(backed-used,0)>=r.amount-0.005 then lines:=jsonb_build_array(jsonb_build_object('account_id',v6170b_account(bid,'payment_clearing'),'debit',r.amount,'credit',0),jsonb_build_object('account_id',v6170b_account(bid,'accounts_payable'),'debit',0,'credit',r.amount));perform v6170a_post_journal(r.refund_date,'supplier_refund',r.id,r.refund_number,'Supplier refund','supplier_credit',lines,1,'v61.70c45');end if;return r;end$$;

create or replace function public.v6170c45_void_supplier_refund(p_refund_id uuid,p_reason text) returns public.supplier_refunds language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r supplier_refunds;j uuid;begin if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier refund access denied' using errcode='42501';end if;if coalesce(btrim(p_reason),'')='' then raise exception 'Void reason is required';end if;select * into r from supplier_refunds where id=p_refund_id and business_id=bid for update;if not found or r.lifecycle_state<>'recorded' then raise exception 'Only a Recorded supplier refund can be voided';end if;if exists(select 1 from bank_reconciliation_allocations a where a.business_id=bid and a.supplier_refund_id=r.id) then raise exception 'Undo bank reconciliation first';end if;select id into j from accounting_journals where business_id=bid and source_type='supplier_refund' and source_id=r.id and status='posted' order by posting_version desc limit 1;if j is not null then perform v6170a_reverse_journal(j,p_reason);end if;update supplier_refunds set lifecycle_state='voided',voided_at=now(),voided_by=auth.uid(),void_reason=p_reason,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;return r;end$$;

create or replace function public.v6170c45_void_expense(p_expense_id uuid,p_reason text) returns public.expenses language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();e expenses;j uuid;begin if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Expense access denied' using errcode='42501';end if;if coalesce(btrim(p_reason),'')='' then raise exception 'Void reason is required';end if;select * into e from expenses where id=p_expense_id and business_id=bid for update;if not found or e.lifecycle_version is null or e.lifecycle_state<>'recorded' then raise exception 'Only a C1 Recorded expense can be voided';end if;if exists(select 1 from expense_payments p where p.business_id=bid and p.expense_id=e.id) or exists(select 1 from supplier_credits c where c.business_id=bid and c.original_expense_id=e.id and c.lifecycle_state in('recorded','draft')) or exists(select 1 from bank_reconciliation_allocations a where a.business_id=bid and a.expense_id=e.id) then raise exception 'Resolve payments, supplier credits or bank reconciliation before voiding this expense';end if;select id into j from accounting_journals where business_id=bid and source_type='expense' and source_id=e.id and status='posted' order by posting_version desc limit 1;if j is not null then perform v6170a_reverse_journal(j,p_reason);end if;perform set_config('finlo.c1_controlled','on',true);update expenses set lifecycle_state='voided',voided_at=now(),voided_by=auth.uid(),void_reason=p_reason,financial_locked_at=coalesce(financial_locked_at,now()),updated_at=now(),updated_by=auth.uid() where id=e.id returning * into e;return e;end$$;

create or replace function public.v6170c45_match_supplier_refund(p_bank_transaction_id uuid,p_refund_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();bt bank_transactions;r supplier_refunds;bank_account uuid;lines jsonb;ver int;begin if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Bank access denied' using errcode='42501';end if;select * into bt from bank_transactions where id=p_bank_transaction_id and business_id=bid for update;if not found or bt.status='reconciled' or bt.amount<=0 then raise exception 'Incoming unreconciled bank transaction required';end if;select * into r from supplier_refunds where id=p_refund_id and business_id=bid for update;if not found or r.lifecycle_state<>'recorded' then raise exception 'Recorded supplier refund required';end if;if abs(bt.amount-r.amount)>0.005 then raise exception 'Bank amount must exactly match supplier refund';end if;if exists(select 1 from bank_reconciliation_allocations where business_id=bid and (bank_transaction_id=bt.id or supplier_refund_id=r.id)) then raise exception 'Bank transaction or supplier refund is already matched';end if;insert into bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,supplier_refund_id,note) values(bid,bt.id,'supplier_refund',r.amount,r.id,'Supplier refund');update bank_transactions set status='reconciled',reconciliation_type='supplier_refund',reconciled_at=now(),reconciled_by=auth.uid() where id=bt.id;
 if exists(select 1 from accounting_journals j where j.business_id=bid and j.source_type='supplier_refund' and j.source_id=r.id and j.status in('posted','reversed')) then select accounting_account_id into bank_account from bank_accounts where id=bt.bank_account_id and business_id=bid;if bank_account is null then raise exception 'Map this bank account to an accounting ledger account before matching accounting-backed supplier refunds';end if;select coalesce(max(posting_version),0)+1 into ver from accounting_journals where business_id=bid and source_type='bank' and source_id=bt.id;lines:=jsonb_build_array(jsonb_build_object('account_id',bank_account,'debit',r.amount,'credit',0),jsonb_build_object('account_id',v6170b_account(bid,'payment_clearing'),'debit',0,'credit',r.amount));perform v6170a_post_journal(bt.transaction_date,'bank',bt.id,coalesce(bt.reference,r.refund_number),'Supplier refund bank match','bank',lines,ver,'v61.70c45');end if;
 insert into bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(bid,bt.id,'supplier_refund_matched',jsonb_build_object('supplier_refund_id',r.id),auth.uid());end$$;

create or replace function public.v6170c45_undo_supplier_refund_match(p_bank_transaction_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();a bank_reconciliation_allocations;j uuid;begin if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Bank access denied' using errcode='42501';end if;select * into a from bank_reconciliation_allocations where business_id=bid and bank_transaction_id=p_bank_transaction_id and allocation_type='supplier_refund' for update;if not found then raise exception 'Supplier refund match not found';end if;select id into j from accounting_journals where business_id=bid and source_type='bank' and source_id=p_bank_transaction_id and status='posted' order by posting_version desc limit 1;if j is not null then perform v6170a_reverse_journal(j,'Undo supplier refund bank reconciliation');end if;delete from bank_reconciliation_allocations where id=a.id and business_id=bid;update bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null where id=p_bank_transaction_id and business_id=bid;insert into bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(bid,p_bank_transaction_id,'supplier_refund_match_undone',jsonb_build_object('supplier_refund_id',a.supplier_refund_id),auth.uid());end$$;

-- Correct V61.70B Trial Balance range semantics: only lines from journals inside the selected period are aggregated.
create or replace function public.v6170b_trial_balance(p_from date,p_to date) returns table(account_code text,account_name text,debits numeric,credits numeric,balance numeric) language sql stable security definer set search_path=public as $$
with b as(select public.current_business_id() id),x as(select l.account_id,sum(l.debit) debits,sum(l.credit) credits from accounting_journals j join b on b.id=j.business_id join accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.status in('posted','reversed') and j.journal_date between p_from and p_to group by l.account_id) select a.account_code,a.account_name,coalesce(x.debits,0),coalesce(x.credits,0),case when a.normal_balance='debit' then coalesce(x.debits-x.credits,0) else coalesce(x.credits-x.debits,0) end from accounting_accounts a join b on b.id=a.business_id left join x on x.account_id=a.id where public.v6169a_accountant_centre_access(a.business_id,false) order by a.account_code$$;

-- Ledger-backed report wrappers with explicit business access. Existing V61.70B reports remain authoritative.
create or replace function public.v6170c45_general_ledger(p_from date,p_to date,p_account_code text default null,p_source_type text default null) returns table(journal_date date,journal_number text,source_type text,source_id uuid,source_reference text,description text,account_code text,account_name text,debit numeric,credit numeric,running_balance numeric) language sql stable security definer set search_path=public as $$
with b as(select current_business_id() id),x as(select j.journal_date,j.journal_number,j.source_type,j.source_id,j.source_reference,j.description,a.account_code,a.account_name,l.debit,l.credit,l.id,a.normal_balance from accounting_journals j join b on b.id=j.business_id join accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id join accounting_accounts a on a.id=l.account_id and a.business_id=j.business_id where j.status in('posted','reversed') and j.journal_date between p_from and p_to and v6169a_accountant_centre_access(j.business_id,false) and (p_account_code is null or a.account_code=p_account_code) and (p_source_type is null or j.source_type=p_source_type)) select journal_date,journal_number,source_type,source_id,source_reference,description,account_code,account_name,debit,credit,sum(case when normal_balance='debit' then debit-credit else credit-debit end) over(partition by account_code order by journal_date,journal_number,id) from x order by journal_date,journal_number,account_code$$;

-- Execute only by authenticated users; all functions still enforce active-business/write/read access internally.
revoke all on function public.v6170c45_next_supplier_credit_number(uuid) from public,anon,authenticated;
revoke all on function public.v6170c45_next_supplier_refund_number(uuid) from public,anon,authenticated;
grant execute on function public.v6170c45_create_supplier_credit(uuid,text,numeric,date,text,text,uuid),public.v6170c45_update_supplier_credit(uuid,numeric,date,text,text,text),public.v6170c45_delete_draft_supplier_credit(uuid),public.v6170c45_record_supplier_credit(uuid),public.v6170c45_void_supplier_credit(uuid,text),public.v6170c45_supplier_credit(uuid),public.v6170c45_create_supplier_refund(uuid,numeric,date,text,text,text,uuid),public.v6170c45_record_supplier_refund(uuid),public.v6170c45_void_supplier_refund(uuid,text),public.v6170c45_void_expense(uuid,text),public.v6170c45_match_supplier_refund(uuid,uuid),public.v6170c45_undo_supplier_refund_match(uuid),public.v6170c45_general_ledger(date,date,text,text) to authenticated;
revoke truncate on public.bank_reconciliation_allocations,public.bank_transactions,public.supplier_credits,public.supplier_refunds from anon,authenticated;
