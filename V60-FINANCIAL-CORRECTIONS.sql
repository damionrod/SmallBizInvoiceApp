-- v60 targeted financial corrections: dated customer payments for Cash Flow and payments-basis GST.
-- Safe to run once after v58/v58.1. Does not replace existing invoice/expense/payroll tables.

create table if not exists public.customer_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  payment_date date not null default current_date,
  amount numeric(14,2) not null check (amount > 0),
  reference text,
  notes text,
  is_legacy_estimate boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create index if not exists customer_payments_business_date_idx on public.customer_payments(business_id,payment_date);
create index if not exists customer_payments_invoice_idx on public.customer_payments(invoice_id);
alter table public.customer_payments enable row level security;
drop policy if exists v60_customer_payments_select on public.customer_payments;
drop policy if exists v60_customer_payments_insert on public.customer_payments;
drop policy if exists v60_customer_payments_update on public.customer_payments;
drop policy if exists v60_customer_payments_delete on public.customer_payments;
create policy v60_customer_payments_select on public.customer_payments for select to authenticated using (business_id=public.current_business_id() or public.is_super_admin());
create policy v60_customer_payments_insert on public.customer_payments for insert to authenticated with check (business_id=public.current_business_id() or public.is_super_admin());
create policy v60_customer_payments_update on public.customer_payments for update to authenticated using (business_id=public.current_business_id() or public.is_super_admin()) with check (business_id=public.current_business_id() or public.is_super_admin());
create policy v60_customer_payments_delete on public.customer_payments for delete to authenticated using (business_id=public.current_business_id() or public.is_super_admin());

-- Preserve pre-v60 paid balances. The old app did not store the real payment date, so these
-- opening records are explicitly marked as estimates rather than pretending the date is known.
insert into public.customer_payments (business_id,invoice_id,payment_date,amount,reference,notes,is_legacy_estimate,created_by)
select i.business_id,i.id,i.invoice_date,i.amount_paid,'Legacy opening payment','Payment existed before dated customer-payment tracking was introduced. Payment date estimated from invoice date.',true,null
from public.invoices i
where coalesce(i.amount_paid,0)>0
  and not exists (select 1 from public.customer_payments p where p.invoice_id=i.id);

create or replace function public.v60_customer_payment_guard()
returns trigger language plpgsql security definer set search_path=public as $$
declare inv_business uuid; inv_total numeric(14,2); existing_paid numeric(14,2);
begin
  select business_id,total into inv_business,inv_total from public.invoices where id=new.invoice_id;
  if inv_business is null then raise exception 'Invoice not found'; end if;
  if new.business_id<>inv_business then raise exception 'Customer payment must belong to the same business as the invoice'; end if;
  select coalesce(sum(amount),0) into existing_paid from public.customer_payments where invoice_id=new.invoice_id and id<>coalesce(new.id,gen_random_uuid());
  if existing_paid+new.amount>inv_total+0.005 then raise exception 'Payment exceeds invoice outstanding balance'; end if;
  return new;
end $$;

create or replace function public.v60_refresh_invoice_paid()
returns trigger language plpgsql security definer set search_path=public as $$
declare iid uuid; paid numeric(14,2); tot numeric(14,2);
begin
  if tg_op='DELETE' then iid=old.invoice_id; else iid=new.invoice_id; end if;
  select total into tot from public.invoices where id=iid;
  if tot is null then if tg_op='DELETE' then return old; else return new; end if; end if;
  select coalesce(sum(amount),0) into paid from public.customer_payments where invoice_id=iid;
  update public.invoices set amount_paid=least(tot,paid), balance_due=greatest(0,tot-paid), updated_at=now() where id=iid;
  if tg_op='DELETE' then return old; else return new; end if;
end $$;

drop trigger if exists v60_customer_payment_guard_trg on public.customer_payments;
create trigger v60_customer_payment_guard_trg before insert or update on public.customer_payments for each row execute function public.v60_customer_payment_guard();
drop trigger if exists v60_customer_payment_refresh_trg on public.customer_payments;
create trigger v60_customer_payment_refresh_trg after insert or update or delete on public.customer_payments for each row execute function public.v60_refresh_invoice_paid();
