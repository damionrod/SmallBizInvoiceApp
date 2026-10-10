-- v61.124 — unified email activity log.
-- Records provider-accepted sends for invoices, reminders, quotes and payslips.
-- This does not change invoice totals, payroll, payments, journals, GST or reconciliation.

create table if not exists public.email_delivery_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  message_type text not null check (message_type in (
    'invoice',
    'invoice_reminder',
    'quote',
    'payslip',
    'payment_receipt',
    'referral_invite',
    'business_invite',
    'support_notification',
    'other'
  )),
  source_table text,
  source_id uuid,
  recipient text not null,
  subject text,
  provider text not null default 'resend',
  provider_message_id text,
  status text not null default 'sent' check (status in (
    'queued',
    'sent',
    'delivered',
    'bounced',
    'complained',
    'opened',
    'clicked',
    'failed',
    'delivery_unknown'
  )),
  sent_by uuid references auth.users(id) on delete set null,
  sent_at timestamptz not null default now(),
  delivered_at timestamptz,
  failed_at timestamptz,
  error_message text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists email_delivery_events_business_sent_idx
  on public.email_delivery_events(business_id, sent_at desc);

create index if not exists email_delivery_events_source_idx
  on public.email_delivery_events(source_table, source_id, sent_at desc)
  where source_id is not null;

create unique index if not exists email_delivery_events_provider_message_idx
  on public.email_delivery_events(provider, provider_message_id)
  where provider_message_id is not null;

alter table public.email_delivery_events enable row level security;

drop policy if exists email_delivery_events_select_business on public.email_delivery_events;
create policy email_delivery_events_select_business
on public.email_delivery_events
for select to authenticated
using (business_id = public.current_business_id());

revoke all on public.email_delivery_events from public, anon;
grant select on public.email_delivery_events to authenticated;
grant select, insert, update on public.email_delivery_events to service_role;
