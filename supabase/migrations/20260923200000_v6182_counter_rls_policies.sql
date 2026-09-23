-- V61.82: RLS policies for internal business-scoped counters.
--
-- These counters are written only by the existing SECURITY DEFINER number
-- generation functions. Authenticated users may read only the counter for
-- their active business; no client-side write policy is granted.

begin;

alter table public.customer_refund_counters enable row level security;
alter table public.supplier_credit_counters enable row level security;
alter table public.supplier_refund_counters enable row level security;

drop policy if exists v6182_customer_refund_counters_select
  on public.customer_refund_counters;
create policy v6182_customer_refund_counters_select
  on public.customer_refund_counters
  for select to authenticated
  using (business_id = public.current_business_id());

drop policy if exists v6182_supplier_credit_counters_select
  on public.supplier_credit_counters;
create policy v6182_supplier_credit_counters_select
  on public.supplier_credit_counters
  for select to authenticated
  using (public.v6147_can_read_area(business_id, 'core'));

drop policy if exists v6182_supplier_refund_counters_select
  on public.supplier_refund_counters;
create policy v6182_supplier_refund_counters_select
  on public.supplier_refund_counters
  for select to authenticated
  using (public.v6147_can_read_area(business_id, 'core'));

commit;
