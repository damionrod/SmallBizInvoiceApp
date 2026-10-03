-- v61.107B — invoice payment reminder communication history.
-- This does not change invoice totals, payments, journals, GST or reconciliation.
create table if not exists public.invoice_reminder_history (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  recipient text not null,
  subject text not null,
  provider_message_id text,
  sent_by uuid references auth.users(id) on delete set null,
  sent_at timestamptz not null default now()
);

create index if not exists invoice_reminder_history_invoice_sent_idx
  on public.invoice_reminder_history(invoice_id, sent_at desc);

alter table public.invoice_reminder_history enable row level security;

drop policy if exists invoice_reminder_history_select_member on public.invoice_reminder_history;
create policy invoice_reminder_history_select_member
on public.invoice_reminder_history
for select to authenticated
using (
  exists (
    select 1
    from public.business_users bu
    where bu.business_id = invoice_reminder_history.business_id
      and bu.user_id = auth.uid()
      and coalesce(bu.status,'active') = 'active'
  )
);
