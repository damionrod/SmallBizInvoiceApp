-- V61.70C45-R1 forward-only correction / completion
begin;

-- Explicit supplier-credit <-> refund settlement evidence.
create table if not exists public.supplier_refund_allocations(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 supplier_refund_id uuid not null references public.supplier_refunds(id) on delete restrict,
 supplier_credit_id uuid not null references public.supplier_credits(id) on delete restrict,
 amount numeric not null check(amount>0),
 created_at timestamptz not null default now(), created_by uuid default auth.uid(),
 unique(business_id,supplier_refund_id,supplier_credit_id)
);
create index if not exists c45_supplier_refund_alloc_credit on public.supplier_refund_allocations(business_id,supplier_credit_id);
create index if not exists c45_supplier_refund_alloc_refund on public.supplier_refund_allocations(business_id,supplier_refund_id);
alter table public.supplier_refund_allocations enable row level security;
drop policy if exists c45_supplier_refund_alloc_select on public.supplier_refund_allocations;
create policy c45_supplier_refund_alloc_select on public.supplier_refund_allocations for select to authenticated using(public.v6147_can_read_area(business_id,'core'));
revoke all on public.supplier_refund_allocations from anon,authenticated;
grant select on public.supplier_refund_allocations to authenticated;

-- Close legacy direct supplier-credit mutation policies/grants; C45 uses RPC mutation only.
drop policy if exists v51_supplier_credits_tenant on public.supplier_credits;
drop policy if exists v6147_supplier_credits_delete on public.supplier_credits;
drop policy if exists v6147_supplier_credits_insert on public.supplier_credits;
drop policy if exists v6147_supplier_credits_update on public.supplier_credits;
revoke insert,update,delete,truncate on public.supplier_credits from anon,authenticated;
revoke insert,update,delete,truncate on public.supplier_refunds from anon,authenticated;
revoke truncate on public.supplier_refund_allocations from anon,authenticated;

-- Correct supplier-credit accounting: reverse the actual posted original expense lines pro-rata.
create or replace function public.v6170c45_record_supplier_credit(p_credit_id uuid) returns public.supplier_credits
language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); r supplier_credits; e expenses; credited numeric; ratio numeric; lines jsonb; ej uuid;
begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier credit access denied'; end if;
 select * into r from supplier_credits where id=p_credit_id and business_id=bid for update;
 if not found then raise exception 'Supplier credit not found'; end if;
 if r.lifecycle_state='recorded' then return r; end if;
 if r.lifecycle_state<>'draft' then raise exception 'Only Draft supplier credit can be recorded'; end if;
 select * into e from expenses where id=r.original_expense_id and business_id=bid for update;
 if not found or e.lifecycle_state<>'recorded' then raise exception 'Original expense is not Recorded'; end if;
 perform pg_advisory_xact_lock(hashtextextended(bid::text||':'||e.id::text,0));
 select coalesce(sum(total_amount),0) into credited from supplier_credits where business_id=bid and original_expense_id=e.id and lifecycle_state='recorded';
 if credited+r.total_amount>e.total_amount+0.005 then raise exception 'Supplier credits exceed original expense'; end if;
 update supplier_credits set lifecycle_state='recorded',status='available',recorded_at=now(),recorded_by=auth.uid(),financial_locked_at=now(),updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 select id into ej from accounting_journals where business_id=bid and source_type='expense' and source_id=e.id and status in('posted','reversed') order by posting_version desc limit 1;
 if ej is not null then
   ratio:=r.total_amount/nullif(e.total_amount,0);
   select jsonb_agg(jsonb_build_object('account_id',l.account_id,'debit',round(l.credit*ratio,2),'credit',round(l.debit*ratio,2),'tax_code',l.tax_code,'tax_rate',l.tax_rate,'tax_amount',round(coalesce(l.tax_amount,0)*ratio,2),'supplier_id',coalesce(l.supplier_id,e.supplier_id),'source_line_id',l.source_line_id))
   into lines from accounting_journal_lines l where l.journal_id=ej and l.business_id=bid and (l.debit<>0 or l.credit<>0);
   perform v6170a_post_journal(r.credit_date,'supplier_credit',r.id,r.credit_note_number,'Supplier credit '||r.credit_note_number,'supplier_credit',lines,1,'v61.70c45-r1');
 end if;
 return r;
end$$;

create or replace function public.v6170c45_supplier_credit_available(p_supplier_id uuid) returns numeric
language sql stable security definer set search_path=public as $$
 with b as(select current_business_id() id), c as(
 select coalesce(sum(sc.total_amount),0) total from supplier_credits sc,b where sc.business_id=b.id and sc.supplier_id=p_supplier_id and sc.lifecycle_state='recorded'),
 r as(select coalesce(sum(sr.amount),0) total from supplier_refunds sr,b where sr.business_id=b.id and sr.supplier_id=p_supplier_id and sr.lifecycle_state='recorded')
 select greatest(c.total-r.total,0) from c,r
$$;

create or replace function public.v6170c45_create_supplier_refund(p_supplier_id uuid,p_amount numeric,p_refund_date date,p_method text,p_reference text,p_notes text,p_idempotency_key uuid default gen_random_uuid()) returns public.supplier_refunds
language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); r supplier_refunds; n bigint; num text;
begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier refund access denied'; end if;
 if p_amount<=0 then raise exception 'Refund amount must be positive'; end if;
 if p_method not in('bank_transfer','card','cash','other') then raise exception 'Invalid refund method'; end if;
 if not exists(select 1 from suppliers where id=p_supplier_id and business_id=bid) then raise exception 'Supplier not found'; end if;
 select * into r from supplier_refunds where business_id=bid and idempotency_key=p_idempotency_key; if found then return r; end if;
 insert into supplier_refund_counters(business_id,next_number) values(bid,2) on conflict(business_id) do update set next_number=supplier_refund_counters.next_number+1 returning next_number-1 into n;
 num:='SR-'||lpad(n::text,4,'0');
 insert into supplier_refunds(business_id,supplier_id,refund_number,refund_date,amount,method,reference,notes,lifecycle_state,idempotency_key,created_by,updated_by)
 values(bid,p_supplier_id,num,coalesce(p_refund_date,current_date),p_amount,p_method,p_reference,p_notes,'draft',p_idempotency_key,auth.uid(),auth.uid()) returning * into r; return r;
end$$;

create or replace function public.v6170c45_record_supplier_refund(p_refund_id uuid) returns public.supplier_refunds
language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); r supplier_refunds; avail numeric; left_amt numeric; c record; take numeric; backed numeric; lines jsonb;
begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier refund access denied'; end if;
 select * into r from supplier_refunds where id=p_refund_id and business_id=bid for update; if not found then raise exception 'Supplier refund not found'; end if;
 if r.lifecycle_state='recorded' then return r; end if; if r.lifecycle_state<>'draft' then raise exception 'Only Draft supplier refund can be recorded'; end if;
 perform pg_advisory_xact_lock(hashtextextended(bid::text||':'||r.supplier_id::text,0));
 avail:=v6170c45_supplier_credit_available(r.supplier_id); if r.amount>avail+0.005 then raise exception 'Refund exceeds available supplier credit'; end if;
 update supplier_refunds set lifecycle_state='recorded',recorded_at=now(),recorded_by=auth.uid(),financial_locked_at=now(),updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 left_amt:=r.amount;
 for c in select sc.id,sc.total_amount-coalesce((select sum(a.amount) from supplier_refund_allocations a where a.business_id=bid and a.supplier_credit_id=sc.id),0) remaining from supplier_credits sc where sc.business_id=bid and sc.supplier_id=r.supplier_id and sc.lifecycle_state='recorded' order by sc.credit_date,sc.created_at for update loop
   exit when left_amt<=0.005; take:=least(left_amt,c.remaining); if take>0.005 then insert into supplier_refund_allocations(business_id,supplier_refund_id,supplier_credit_id,amount) values(bid,r.id,c.id,take); left_amt:=left_amt-take; end if;
 end loop;
 select coalesce(sum(a.amount),0) into backed from supplier_refund_allocations a join accounting_journals j on j.business_id=a.business_id and j.source_type='supplier_credit' and j.source_id=a.supplier_credit_id and j.status in('posted','reversed') where a.business_id=bid and a.supplier_refund_id=r.id;
 if backed>=r.amount-0.005 then
   lines:=jsonb_build_array(jsonb_build_object('account_id',v6170b_account(bid,'payment_clearing'),'debit',r.amount,'credit',0),jsonb_build_object('account_id',v6170b_account(bid,'accounts_payable'),'debit',0,'credit',r.amount,'supplier_id',r.supplier_id));
   perform v6170a_post_journal(r.refund_date,'supplier_refund',r.id,r.refund_number,'Supplier refund '||r.refund_number,'supplier_refund',lines,1,'v61.70c45-r1');
 end if; return r;
end$$;

create or replace function public.v6170c45_void_supplier_credit(p_credit_id uuid,p_reason text) returns public.supplier_credits
language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r supplier_credits;j uuid;
begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Supplier credit access denied';end if;
 if coalesce(btrim(p_reason),'')='' then raise exception 'Void reason is required';end if;
 select * into r from supplier_credits where id=p_credit_id and business_id=bid for update; if not found or r.lifecycle_state<>'recorded' then raise exception 'Only a Recorded supplier credit can be voided';end if;
 if exists(select 1 from supplier_refund_allocations a join supplier_refunds sr on sr.id=a.supplier_refund_id and sr.business_id=a.business_id where a.business_id=bid and a.supplier_credit_id=r.id and sr.lifecycle_state='recorded') then raise exception 'This supplier credit has a recorded refund settlement; resolve it first';end if;
 select id into j from accounting_journals where business_id=bid and source_type='supplier_credit' and source_id=r.id and status='posted' order by posting_version desc limit 1; if j is not null then perform v6170a_reverse_journal(j,p_reason);end if;
 update supplier_credits set lifecycle_state='voided',status='voided',voided_at=now(),voided_by=auth.uid(),void_reason=p_reason,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;return r;
end$$;

-- Correct Trial Balance join so out-of-range journal lines cannot leak into totals.
create or replace function public.v6170b_trial_balance(p_from date,p_to date) returns table(account_code text,account_name text,debits numeric,credits numeric,balance numeric)
language sql stable security definer set search_path=public as $$
 with b as(select current_business_id() id), x as(
 select l.* from accounting_journal_lines l join accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id join b on b.id=j.business_id where j.status in('posted','reversed') and j.journal_date between p_from and p_to)
 select a.account_code,a.account_name,coalesce(sum(x.debit),0),coalesce(sum(x.credit),0),case when a.normal_balance='debit' then coalesce(sum(x.debit-x.credit),0) else coalesce(sum(x.credit-x.debit),0) end
 from accounting_accounts a join b on b.id=a.business_id left join x on x.account_id=a.id where v6169a_accountant_centre_access(a.business_id,false) group by a.id order by a.account_code
$$;

-- Narrow function execution. Trigger/helper functions are not client RPCs.
do $$declare r record;begin for r in select p.oid,p.proname,pg_get_function_identity_arguments(p.oid) args from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'v6170c45%' loop execute format('revoke execute on function public.%I(%s) from public,anon,authenticated',r.proname,r.args); end loop; end$$;
grant execute on function public.v6170c45_create_supplier_credit(uuid,text,numeric,date,text,text,uuid) to authenticated;
grant execute on function public.v6170c45_update_supplier_credit(uuid,numeric,date,text,text,text) to authenticated;
grant execute on function public.v6170c45_delete_draft_supplier_credit(uuid) to authenticated;
grant execute on function public.v6170c45_record_supplier_credit(uuid) to authenticated;
grant execute on function public.v6170c45_void_supplier_credit(uuid,text) to authenticated;
grant execute on function public.v6170c45_void_expense(uuid,text) to authenticated;
grant execute on function public.v6170c45_supplier_credit_available(uuid) to authenticated;
grant execute on function public.v6170c45_create_supplier_refund(uuid,numeric,date,text,text,text,uuid) to authenticated;
grant execute on function public.v6170c45_record_supplier_refund(uuid) to authenticated;

commit;
