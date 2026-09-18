-- V61.70C3 — Customer Refunds + Bank Reconciliation
-- Coordinated production delta. No historical bootstrap, no data backfill, no bank mapping changes.

create table if not exists public.customer_refund_counters (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  last_number integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_refunds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  customer_id uuid not null,
  refund_number text not null,
  refund_date date not null default current_date,
  amount numeric not null check(amount>0),
  currency text not null default 'NZD',
  method text not null default 'bank_transfer' check(method in('bank_transfer','card','cash','other')),
  reference text,
  notes text,
  lifecycle_state text not null default 'draft' check(lifecycle_state in('draft','recorded','voided')),
  idempotency_key uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now(), created_by uuid,
  updated_at timestamptz not null default now(), updated_by uuid,
  recorded_at timestamptz, recorded_by uuid, financial_locked_at timestamptz,
  voided_at timestamptz, voided_by uuid, void_reason text,
  unique(business_id,id), unique(business_id,refund_number), unique(business_id,idempotency_key),
  foreign key(business_id,customer_id) references public.customers(business_id,id)
);
create index if not exists customer_refunds_customer_idx on public.customer_refunds(business_id,customer_id,lifecycle_state,refund_date);
alter table public.customer_refunds enable row level security;
drop policy if exists customer_refunds_select on public.customer_refunds;
create policy customer_refunds_select on public.customer_refunds for select using(business_id=current_business_id());
revoke all on public.customer_refunds from anon,authenticated;
grant select on public.customer_refunds to authenticated;
revoke all on public.customer_refund_counters from anon,authenticated;

create or replace function public.v6170c3_customer_credit(p_customer_id uuid)
returns table(gross_credit numeric,recorded_refunds numeric,available_credit numeric)
language sql stable security definer set search_path='public' as $$
with b as(select current_business_id() bid),
inv as(select i.total,
 coalesce((select sum(cp.amount) from customer_payments cp where cp.business_id=i.business_id and cp.invoice_id=i.id),0) paid,
 coalesce((select sum(cn.total_amount) from customer_credit_notes cn where cn.business_id=i.business_id and cn.original_invoice_id=i.id and cn.lifecycle_state='issued'),0) credits
 from invoices i,b where i.business_id=b.bid and i.customer_id=p_customer_id),
g as(select coalesce(sum(greatest(0,paid+credits-total)),0) gross from inv),
r as(select coalesce(sum(amount),0) refunded from customer_refunds,b where business_id=b.bid and customer_id=p_customer_id and lifecycle_state='recorded')
select round(g.gross,2),round(r.refunded,2),round(greatest(g.gross-r.refunded,0),2) from g,r$$;

create or replace function public.v6170c3_next_refund_number(p_bid uuid) returns text language plpgsql security definer set search_path='public' as $$
declare n int;begin
 if p_bid is null or p_bid<>current_business_id() or not v6147_can_write_area(p_bid,'core') then raise exception 'Refund access denied' using errcode='42501';end if;
 insert into customer_refund_counters(business_id,last_number) values(p_bid,1) on conflict(business_id) do update set last_number=customer_refund_counters.last_number+1,updated_at=now() returning last_number into n;
 return 'RF-'||lpad(n::text,4,'0');
end$$;

create or replace function public.v6170c3_guard_refund_mutation() returns trigger language plpgsql set search_path='public' as $$begin
 if tg_op='DELETE' and old.lifecycle_state<>'draft' then raise exception 'Recorded refunds cannot be deleted';end if;
 if tg_op='UPDATE' and old.lifecycle_state in('recorded','voided') and current_user in('authenticated','anon') then raise exception 'Controlled refund function required';end if;
 return case when tg_op='DELETE' then old else new end;
end$$;
drop trigger if exists v6170c3_refund_guard on public.customer_refunds;
create trigger v6170c3_refund_guard before delete or update on public.customer_refunds for each row execute function public.v6170c3_guard_refund_mutation();

create or replace function public.v6170c3_create_refund(p_customer_id uuid,p_amount numeric,p_refund_date date default current_date,p_method text default 'bank_transfer',p_reference text default null,p_notes text default null,p_idempotency_key uuid default gen_random_uuid()) returns customer_refunds language plpgsql security definer set search_path='public' as $$
declare bid uuid:=current_business_id();r customer_refunds;n text;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Refund access denied' using errcode='42501';end if;
 if not exists(select 1 from customers where id=p_customer_id and business_id=bid) then raise exception 'Customer not found for active business';end if;
 if coalesce(p_amount,0)<=0 or p_method not in('bank_transfer','card','cash','other') then raise exception 'Invalid refund';end if;
 select * into r from customer_refunds where business_id=bid and idempotency_key=p_idempotency_key;if found then return r;end if;
 n:=v6170c3_next_refund_number(bid);
 insert into customer_refunds(business_id,customer_id,refund_number,refund_date,amount,method,reference,notes,idempotency_key,created_by,updated_by) values(bid,p_customer_id,n,coalesce(p_refund_date,current_date),round(p_amount,2),p_method,nullif(btrim(p_reference),''),nullif(btrim(p_notes),''),p_idempotency_key,auth.uid(),auth.uid()) returning * into r;return r;
end$$;

create or replace function public.v6170c3_update_refund(p_refund_id uuid,p_amount numeric,p_refund_date date,p_method text,p_reference text default null,p_notes text default null) returns customer_refunds language plpgsql security definer set search_path='public' as $$declare bid uuid:=current_business_id();r customer_refunds;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Refund access denied' using errcode='42501';end if;
 select * into r from customer_refunds where id=p_refund_id and business_id=bid for update;if not found or r.lifecycle_state<>'draft' then raise exception 'Only draft refunds can be edited';end if;
 if coalesce(p_amount,0)<=0 or p_method not in('bank_transfer','card','cash','other') then raise exception 'Invalid refund';end if;
 update customer_refunds set amount=round(p_amount,2),refund_date=coalesce(p_refund_date,refund_date),method=p_method,reference=nullif(btrim(p_reference),''),notes=nullif(btrim(p_notes),''),updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;return r;
end$$;

create or replace function public.v6170c3_delete_draft_refund(p_refund_id uuid) returns boolean language plpgsql security definer set search_path='public' as $$declare bid uuid:=current_business_id();n int;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Refund access denied' using errcode='42501';end if;
 delete from customer_refunds where id=p_refund_id and business_id=bid and lifecycle_state='draft';get diagnostics n=row_count;if n=0 then raise exception 'Only draft can delete';end if;return true;
end$$;

create or replace function public.v6170c3_record_refund(p_refund_id uuid) returns customer_refunds language plpgsql security definer set search_path='public' as $$
declare bid uuid:=current_business_id();r customer_refunds;s record;backed_gross numeric;backed_used numeric;lines jsonb;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Refund access denied' using errcode='42501';end if;
 select * into r from customer_refunds where id=p_refund_id and business_id=bid for update;if not found then raise exception 'Refund not found';end if;if r.lifecycle_state='recorded' then return r;end if;if r.lifecycle_state<>'draft' then raise exception 'Only draft can record';end if;
 perform pg_advisory_xact_lock(hashtextextended(bid::text||':'||r.customer_id::text,0));select * into s from v6170c3_customer_credit(r.customer_id);if r.amount>s.available_credit+0.005 then raise exception 'Refund exceeds available customer credit';end if;
 select coalesce(sum(greatest(0,least(cn.total_amount,coalesce((select sum(cp.amount) from customer_payments cp where cp.business_id=i.business_id and cp.invoice_id=i.id),0)+cn.total_amount-i.total))),0) into backed_gross from customer_credit_notes cn join invoices i on i.id=cn.original_invoice_id and i.business_id=cn.business_id where cn.business_id=bid and cn.customer_id=r.customer_id and cn.lifecycle_state='issued' and exists(select 1 from accounting_journals j where j.business_id=bid and j.source_type='customer_credit_note' and j.source_id=cn.id and j.status in('posted','reversed'));
 select coalesce(sum(cr.amount),0) into backed_used from customer_refunds cr where cr.business_id=bid and cr.customer_id=r.customer_id and cr.lifecycle_state='recorded' and exists(select 1 from accounting_journals j where j.business_id=bid and j.source_type='customer_refund' and j.source_id=cr.id and j.status='posted');
 update customer_refunds set lifecycle_state='recorded',recorded_at=now(),recorded_by=auth.uid(),financial_locked_at=now(),updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 if greatest(backed_gross-backed_used,0)>=r.amount-0.005 then lines:=jsonb_build_array(jsonb_build_object('account_id',v6170b_account(bid,'accounts_receivable'),'debit',r.amount,'credit',0),jsonb_build_object('account_id',v6170b_account(bid,'payment_clearing'),'debit',0,'credit',r.amount));perform v6170a_post_journal(r.refund_date,'customer_refund',r.id,r.refund_number,'Customer refund','customer_refund',lines,1,'v61.70c3');end if;return r;
end$$;

create or replace function public.v6170c3_void_refund(p_refund_id uuid,p_reason text) returns customer_refunds language plpgsql security definer set search_path='public' as $$declare bid uuid:=current_business_id();r customer_refunds;j accounting_journals;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Refund access denied' using errcode='42501';end if;if nullif(btrim(p_reason),'') is null then raise exception 'Void reason required';end if;
 select * into r from customer_refunds where id=p_refund_id and business_id=bid for update;if not found or r.lifecycle_state<>'recorded' then raise exception 'Recorded refund required';end if;if exists(select 1 from bank_reconciliation_allocations where business_id=bid and customer_refund_id=r.id) then raise exception 'Undo bank reconciliation first';end if;
 select * into j from accounting_journals where business_id=bid and source_type='customer_refund' and source_id=r.id and posting_version=1 order by created_at desc limit 1;if j.id is not null and j.status='posted' then perform v6170a_reverse_journal(j.id,p_reason);end if;
 update customer_refunds set lifecycle_state='voided',voided_at=now(),voided_by=auth.uid(),void_reason=btrim(p_reason),updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;return r;
end$$;

alter table public.bank_reconciliation_allocations add column if not exists customer_refund_id uuid;
alter table public.bank_reconciliation_allocations drop constraint if exists bank_reconciliation_allocations_allocation_type_check;
alter table public.bank_reconciliation_allocations drop constraint if exists bank_alloc_type_c3;
alter table public.bank_reconciliation_allocations add constraint bank_alloc_type_c3 check(allocation_type is null or allocation_type in('invoice','expense','transfer','exclude','customer_refund'));
alter table public.bank_reconciliation_allocations drop constraint if exists bank_alloc_refund_fk;
alter table public.bank_reconciliation_allocations add constraint bank_alloc_refund_fk foreign key(business_id,customer_refund_id) references public.customer_refunds(business_id,id);

alter table public.accounting_journals drop constraint if exists accounting_journals_journal_type_check;
alter table public.accounting_journals add constraint accounting_journals_journal_type_check check(journal_type in('invoice','customer_payment','expense','supplier_payment','payroll','bank','credit_note','supplier_credit','customer_refund','depreciation','manual','opening_balance','year_end','tax_adjustment'));

create or replace function public.v6170c3_match_refund(p_bank_transaction_id uuid,p_refund_id uuid) returns boolean language plpgsql security definer set search_path='public' as $$declare bid uuid:=current_business_id();bt bank_transactions;r customer_refunds;j accounting_journals;ba uuid;lines jsonb;pv int;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Refund reconciliation access denied' using errcode='42501';end if;select * into bt from bank_transactions where id=p_bank_transaction_id and business_id=bid for update;if not found or bt.status<>'unreconciled' or bt.amount>=0 then raise exception 'Unreconciled outgoing bank transaction required';end if;select * into r from customer_refunds where id=p_refund_id and business_id=bid for update;if not found or r.lifecycle_state<>'recorded' then raise exception 'Recorded refund required';end if;if abs(abs(bt.amount)-r.amount)>0.005 then raise exception 'Bank amount must exactly match refund';end if;if exists(select 1 from bank_reconciliation_allocations where business_id=bid and (bank_transaction_id=bt.id or customer_refund_id=r.id)) then raise exception 'Already reconciled';end if;
 insert into bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,customer_refund_id,created_by) values(bid,bt.id,'customer_refund',r.amount,r.id,auth.uid());update bank_transactions set status='reconciled',reconciliation_type='customer_refund',reconciled_at=now(),reconciled_by=auth.uid(),updated_at=now(),updated_by=auth.uid() where id=bt.id;
 select * into j from accounting_journals where business_id=bid and source_type='customer_refund' and source_id=r.id and status='posted' limit 1;if j.id is not null then select accounting_account_id into ba from bank_accounts where id=bt.bank_account_id and business_id=bid;if ba is null then raise exception 'Actual bank ledger account is not reliably identified';end if;lines:=jsonb_build_array(jsonb_build_object('account_id',v6170b_account(bid,'payment_clearing'),'debit',r.amount,'credit',0),jsonb_build_object('account_id',ba,'debit',0,'credit',r.amount));select coalesce(max(posting_version),0)+1 into pv from accounting_journals where business_id=bid and source_type='bank' and source_id=bt.id;perform v6170a_post_journal(bt.transaction_date,'bank',bt.id,'BANK','Customer refund clearing','bank',lines,pv,'v61.70c3');end if;
 insert into bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(bid,bt.id,'customer_refund_matched',jsonb_build_object('customer_refund_id',r.id),auth.uid());return true;
end$$;

create or replace function public.v6170c3_undo_refund_match(p_bank_transaction_id uuid) returns boolean language plpgsql security definer set search_path='public' as $$declare bid uuid:=current_business_id();a bank_reconciliation_allocations;j accounting_journals;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Refund reconciliation access denied' using errcode='42501';end if;select * into a from bank_reconciliation_allocations where business_id=bid and bank_transaction_id=p_bank_transaction_id and allocation_type='customer_refund' for update;if not found then raise exception 'Refund reconciliation not found';end if;select * into j from accounting_journals where business_id=bid and source_type='bank' and source_id=p_bank_transaction_id and status='posted' order by posting_version desc,created_at desc limit 1;if j.id is not null then perform v6170a_reverse_journal(j.id,'Undo customer refund bank match');end if;delete from bank_reconciliation_allocations where id=a.id;update bank_transactions set status='unreconciled',reconciliation_type=null,reconciled_at=null,reconciled_by=null,updated_at=now(),updated_by=auth.uid() where id=p_bank_transaction_id and business_id=bid;insert into bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(bid,p_bank_transaction_id,'customer_refund_match_undone',jsonb_build_object('customer_refund_id',a.customer_refund_id),auth.uid());return true;
end$$;

revoke truncate on public.bank_transactions,public.bank_reconciliation_allocations,public.bank_reconciliation_audit,public.bank_rules from anon,authenticated;

revoke all on function public.v6170c3_customer_credit(uuid) from public,anon;
revoke all on function public.v6170c3_next_refund_number(uuid) from public,anon;
revoke all on function public.v6170c3_create_refund(uuid,numeric,date,text,text,text,uuid) from public,anon;
revoke all on function public.v6170c3_update_refund(uuid,numeric,date,text,text,text) from public,anon;
revoke all on function public.v6170c3_delete_draft_refund(uuid) from public,anon;
revoke all on function public.v6170c3_record_refund(uuid) from public,anon;
revoke all on function public.v6170c3_void_refund(uuid,text) from public,anon;
revoke all on function public.v6170c3_match_refund(uuid,uuid) from public,anon;
revoke all on function public.v6170c3_undo_refund_match(uuid) from public,anon;
grant execute on function public.v6170c3_customer_credit(uuid),public.v6170c3_create_refund(uuid,numeric,date,text,text,text,uuid),public.v6170c3_update_refund(uuid,numeric,date,text,text,text),public.v6170c3_delete_draft_refund(uuid),public.v6170c3_record_refund(uuid),public.v6170c3_void_refund(uuid,text),public.v6170c3_match_refund(uuid,uuid),public.v6170c3_undo_refund_match(uuid) to authenticated;
