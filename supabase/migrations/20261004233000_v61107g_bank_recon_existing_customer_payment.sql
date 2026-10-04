-- v61.107G Phase 2: preserve an explicit, non-destructive link to a customer
-- payment that existed before bank reconciliation.  This is deliberately
-- separate from customer_payment_id, which denotes a payment created by the
-- reconciliation flow and may therefore be removed by Undo.
alter table if exists public.bank_reconciliation_allocations
  add column if not exists existing_customer_payment_id uuid null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='bank_reconciliation_allocations_existing_customer_payment_fk'
      and conrelid='public.bank_reconciliation_allocations'::regclass
  ) then
    alter table public.bank_reconciliation_allocations
      add constraint bank_reconciliation_allocations_existing_customer_payment_fk
      foreign key (existing_customer_payment_id)
      references public.customer_payments(id)
      on delete restrict;
  end if;
end $$;

create index if not exists bank_reconciliation_allocations_existing_customer_payment_idx
  on public.bank_reconciliation_allocations(existing_customer_payment_id)
  where existing_customer_payment_id is not null;
