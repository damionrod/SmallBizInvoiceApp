-- Frindly v61.107T Phase 1A foundation: owners/shareholders + current-account subledger.
-- Safe/additive only. Does not backfill or alter historical accounting records.
create table if not exists public.business_owners (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete restrict,
 display_name text not null check (length(trim(display_name)) between 1 and 160),
 owner_type text not null default 'shareholder' check (owner_type in ('owner','shareholder','director','partner','trustee','other')),
 is_shareholder boolean not null default false, is_director boolean not null default false,
 ownership_percent numeric(7,4) null check (ownership_percent is null or (ownership_percent>=0 and ownership_percent<=100)),
 status text not null default 'active' check (status in ('active','inactive')), notes text null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid null, updated_by uuid null
);
create index if not exists business_owners_business_idx on public.business_owners(business_id,status);
create unique index if not exists business_owners_name_active_uq on public.business_owners(business_id,lower(trim(display_name))) where status='active';
create table if not exists public.owner_current_account_entries (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete restrict,
 owner_id uuid not null references public.business_owners(id) on delete restrict, entry_date date not null,
 entry_type text not null check (entry_type in ('funds_introduced','expense_paid_personally','reimbursement','owner_withdrawal','shareholder_loan_received','shareholder_loan_repaid','capital_contribution','opening_balance','accountant_adjustment','reversal')),
 amount numeric(14,2) not null check (amount<>0), source_type text not null, source_id uuid null, source_reference text null,
 accounting_journal_id uuid null references public.accounting_journals(id) on delete restrict,
 reversal_of_entry_id uuid null references public.owner_current_account_entries(id) on delete restrict,
 description text null, created_at timestamptz not null default now(), created_by uuid null,
 constraint owner_current_entry_source_unique unique(business_id,source_type,source_id,entry_type)
);
create index if not exists owner_current_entries_owner_date_idx on public.owner_current_account_entries(business_id,owner_id,entry_date,id);
create index if not exists owner_current_entries_journal_idx on public.owner_current_account_entries(accounting_journal_id) where accounting_journal_id is not null;
create or replace function public.v61107t_owner_entry_business_guard() returns trigger language plpgsql set search_path=public as $$
begin
 if not exists(select 1 from public.business_owners o where o.id=new.owner_id and o.business_id=new.business_id) then raise exception 'Owner/shareholder does not belong to this business'; end if;
 if new.accounting_journal_id is not null and not exists(select 1 from public.accounting_journals j where j.id=new.accounting_journal_id and j.business_id=new.business_id) then raise exception 'Accounting journal does not belong to this business'; end if;
 if new.reversal_of_entry_id is not null and not exists(select 1 from public.owner_current_account_entries e where e.id=new.reversal_of_entry_id and e.business_id=new.business_id and e.owner_id=new.owner_id) then raise exception 'Reversal entry does not belong to this owner/business'; end if;
 return new;
end $$;
drop trigger if exists trg_v61107t_owner_entry_business_guard on public.owner_current_account_entries;
create trigger trg_v61107t_owner_entry_business_guard before insert or update on public.owner_current_account_entries for each row execute function public.v61107t_owner_entry_business_guard();
alter table public.business_owners enable row level security; alter table public.owner_current_account_entries enable row level security;
drop policy if exists business_owners_read on public.business_owners;
create policy business_owners_read on public.business_owners for select using (public.v6145_has_active_business_membership(business_id));
drop policy if exists business_owners_write on public.business_owners;
create policy business_owners_write on public.business_owners for all using (public.v6147_current_business_role(business_id) in ('owner','admin','bookkeeper')) with check (public.v6147_current_business_role(business_id) in ('owner','admin','bookkeeper'));
drop policy if exists owner_current_entries_read on public.owner_current_account_entries;
create policy owner_current_entries_read on public.owner_current_account_entries for select using (public.v6145_has_active_business_membership(business_id));
drop policy if exists owner_current_entries_write on public.owner_current_account_entries;
create policy owner_current_entries_write on public.owner_current_account_entries for all using (public.v6147_current_business_role(business_id) in ('owner','admin','bookkeeper')) with check (public.v6147_current_business_role(business_id) in ('owner','admin','bookkeeper'));
create or replace function public.v61107t_owner_current_balances(p_business_id uuid default public.current_business_id()) returns table(owner_id uuid,display_name text,balance numeric) language sql stable security definer set search_path=public as $$
 select o.id,o.display_name,coalesce(sum(e.amount),0)::numeric from public.business_owners o left join public.owner_current_account_entries e on e.business_id=o.business_id and e.owner_id=o.id where o.business_id=p_business_id and public.v6145_has_active_business_membership(p_business_id) group by o.id,o.display_name order by o.display_name
$$;
revoke all on function public.v61107t_owner_current_balances(uuid) from public; grant execute on function public.v61107t_owner_current_balances(uuid) to authenticated;

-- V61.107U Phase 2: owner/shareholder personally funded expenses.
-- Additive only. Existing expense-payment rows remain business-funded by default.
alter table public.expense_payments add column if not exists funding_source text not null default 'business_funds';
alter table public.expense_payments add column if not exists owner_id uuid null references public.business_owners(id) on delete restrict;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='expense_payments_funding_source_chk') then
    alter table public.expense_payments add constraint expense_payments_funding_source_chk check (funding_source in ('business_funds','owner_personal'));
  end if;
  if not exists(select 1 from pg_constraint where conname='expense_payments_owner_source_chk') then
    alter table public.expense_payments add constraint expense_payments_owner_source_chk check ((funding_source='owner_personal' and owner_id is not null) or (funding_source='business_funds' and owner_id is null));
  end if;
end $$;
create index if not exists expense_payments_owner_idx on public.expense_payments(business_id,owner_id,payment_date) where owner_id is not null;

create or replace function public.v61107u_expense_payment_owner_guard() returns trigger
language plpgsql set search_path=public as $$
begin
  if new.funding_source='owner_personal' then
    if not exists(select 1 from public.business_owners o where o.id=new.owner_id and o.business_id=new.business_id and o.status='active') then
      raise exception 'Active owner/shareholder does not belong to this business';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_v61107u_expense_payment_owner_guard on public.expense_payments;
create trigger trg_v61107u_expense_payment_owner_guard before insert or update of funding_source,owner_id,business_id on public.expense_payments for each row execute function public.v61107u_expense_payment_owner_guard();

create or replace function public.v6170b_payment_account(p_bid uuid,p_source_type text,p_source_id uuid)
returns uuid language plpgsql stable security definer set search_path=public as $$
declare v_account uuid; v_funding text;
begin
 if p_source_type='customer_payment' then
   select ba.accounting_account_id into v_account from public.bank_reconciliation_allocations ra join public.bank_transactions bt on bt.id=ra.bank_transaction_id and bt.business_id=ra.business_id join public.bank_accounts ba on ba.id=bt.bank_account_id and ba.business_id=bt.business_id where ra.business_id=p_bid and ra.customer_payment_id=p_source_id limit 1;
 elsif p_source_type='supplier_payment' then
   select ep.funding_source into v_funding from public.expense_payments ep where ep.id=p_source_id and ep.business_id=p_bid;
   if v_funding='owner_personal' then
     return public.v6170b_account(p_bid,'owner_director_loan');
   end if;
   select ba.accounting_account_id into v_account from public.bank_reconciliation_allocations ra join public.bank_transactions bt on bt.id=ra.bank_transaction_id and bt.business_id=ra.business_id join public.bank_accounts ba on ba.id=bt.bank_account_id and ba.business_id=bt.business_id where ra.business_id=p_bid and ra.expense_payment_id=p_source_id limit 1;
 end if;
 return coalesce(v_account,public.v6170b_account(p_bid,'payment_clearing'));
end $$;

create or replace function public.v61107u_record_owner_paid_expense(p_expense_id uuid,p_owner_id uuid,p_payment_date date default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_bid uuid; v_uid uuid; v_exp public.expenses%rowtype; v_owner public.business_owners%rowtype; v_remaining numeric; v_payment_id uuid; v_exp_journal uuid; v_pay_journal uuid;
begin
  v_uid:=auth.uid(); v_bid:=public.current_business_id();
  if v_uid is null or v_bid is null then raise exception 'Authentication and an active business are required'; end if;
  if public.v6147_current_business_role(v_bid) not in ('owner','admin','bookkeeper') then raise exception 'You do not have permission to record an owner-funded expense'; end if;
  select * into v_exp from public.expenses where id=p_expense_id and business_id=v_bid for update;
  if not found then raise exception 'Expense not found in active business'; end if;
  if coalesce(v_exp.archived,false) or coalesce(v_exp.lifecycle_state,'recorded')='voided' or v_exp.payment_status='draft' then raise exception 'Only an active non-draft expense can be paid personally'; end if;
  if coalesce(v_exp.business_use_percent,100)<99.995 or coalesce(v_exp.private_use_amount,0)>0.005 then raise exception 'Owner-funded payment currently requires full business use. Record mixed/private-use bills separately.'; end if;
  select * into v_owner from public.business_owners where id=p_owner_id and business_id=v_bid and status='active';
  if not found then raise exception 'Active owner/shareholder not found in this business'; end if;
  select round(v_exp.total_amount-coalesce(sum(ep.amount),0),2) into v_remaining from public.expense_payments ep where ep.business_id=v_bid and ep.expense_id=v_exp.id;
  if v_remaining<=0.005 then raise exception 'This expense is already fully paid'; end if;
  insert into public.expense_payments(business_id,expense_id,payment_date,amount,payment_method,reference,notes,funding_source,owner_id,created_by)
  values(v_bid,v_exp.id,coalesce(p_payment_date,v_exp.invoice_date,current_date),v_remaining,'Owner/shareholder personal funds',v_exp.supplier_reference,'Paid personally by '||v_owner.display_name,'owner_personal',v_owner.id,v_uid)
  returning id into v_payment_id;
  v_exp_journal:=public.v6170b_post_source('expense',v_exp.id,'v61107u_owner_personal');
  v_pay_journal:=public.v6170b_post_source('supplier_payment',v_payment_id,'v61107u_owner_personal');
  insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,description,created_by)
  values(v_bid,v_owner.id,coalesce(p_payment_date,v_exp.invoice_date,current_date),'expense_paid_personally',v_remaining,'expense_payment',v_payment_id,v_exp.expense_number,v_pay_journal,'Personally paid business expense '||v_exp.expense_number,v_uid);
  return jsonb_build_object('ok',true,'expense_id',v_exp.id,'payment_id',v_payment_id,'expense_journal_id',v_exp_journal,'payment_journal_id',v_pay_journal,'owner_id',v_owner.id,'amount',v_remaining);
end $$;
revoke all on function public.v61107u_record_owner_paid_expense(uuid,uuid,date) from public;
grant execute on function public.v61107u_record_owner_paid_expense(uuid,uuid,date) to authenticated;

-- V61.107V Phase 2B: owner/shareholder/director history + safe editing
create table if not exists public.business_owner_history(id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete restrict,owner_id uuid not null references public.business_owners(id) on delete restrict,effective_date date not null,change_type text not null check(change_type in ('created','details_corrected','role_changed','shareholding_changed','appointed_director','resigned_director','activated','deactivated')),before_data jsonb,after_data jsonb not null,note text,created_at timestamptz not null default now(),created_by uuid);
create index if not exists business_owner_history_owner_date_idx on public.business_owner_history(business_id,owner_id,effective_date desc,created_at desc);
alter table public.business_owner_history enable row level security;
drop policy if exists business_owner_history_read on public.business_owner_history; create policy business_owner_history_read on public.business_owner_history for select using(public.v6145_has_active_business_membership(business_id));
drop policy if exists business_owner_history_write on public.business_owner_history; create policy business_owner_history_write on public.business_owner_history for all using(public.v6147_current_business_role(business_id) in ('owner','admin','bookkeeper')) with check(public.v6147_current_business_role(business_id) in ('owner','admin','bookkeeper'));
alter table public.business_owners add column if not exists share_class text; alter table public.business_owners add column if not exists shares_held numeric(18,4) check(shares_held is null or shares_held>=0); alter table public.business_owners add column if not exists director_appointed_on date; alter table public.business_owners add column if not exists director_resigned_on date;
-- The production RPC v61107v_update_business_owner is deployed by migration v61107v_owner_shareholder_history_phase2b.
