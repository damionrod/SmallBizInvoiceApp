-- v61.105 Phase 8: additive NZ GST transition review persistence only.
create table if not exists public.gst_transition_reviews (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  jurisdiction text not null default 'NZ' check (jurisdiction in ('NZ')),
  effective_from date not null,
  previous_registered boolean not null,
  new_registered boolean not null,
  window_end date null,
  affected_invoice_ids uuid[] not null default '{}',
  affected_expense_ids uuid[] not null default '{}',
  invoice_count integer not null default 0 check (invoice_count >= 0),
  expense_count integer not null default 0 check (expense_count >= 0),
  status text not null default 'open' check (status in ('open','resolved')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  resolved_by uuid null references auth.users(id),
  resolved_at timestamptz null,
  notes text null
);

create index if not exists gst_transition_reviews_business_effective_idx
  on public.gst_transition_reviews (business_id, effective_from desc, created_at desc);

alter table public.gst_transition_reviews enable row level security;

revoke all on table public.gst_transition_reviews from anon;
grant select, insert on table public.gst_transition_reviews to authenticated;
grant update (status, resolved_by, resolved_at, notes) on table public.gst_transition_reviews to authenticated;

-- Current-business isolation. This table is review metadata only; it never mutates accounting records.
drop policy if exists "gst_transition_reviews_select_current_business" on public.gst_transition_reviews;
create policy "gst_transition_reviews_select_current_business"
on public.gst_transition_reviews for select to authenticated
using (business_id = public.current_business_id());

drop policy if exists "gst_transition_reviews_insert_current_business" on public.gst_transition_reviews;
create policy "gst_transition_reviews_insert_current_business"
on public.gst_transition_reviews for insert to authenticated
with check (
  business_id = public.current_business_id()
  and created_by = (select auth.uid())
  and previous_registered is distinct from new_registered
);

drop policy if exists "gst_transition_reviews_update_current_business" on public.gst_transition_reviews;
create policy "gst_transition_reviews_update_current_business"
on public.gst_transition_reviews for update to authenticated
using (business_id = public.current_business_id())
with check (business_id = public.current_business_id());
