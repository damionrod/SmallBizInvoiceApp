-- CareClean Invoice App v16: persistent email delivery status
-- Run this once in Supabase SQL Editor.
alter table public.invoices add column if not exists email_sent boolean not null default false;
alter table public.invoices add column if not exists last_sent_to text;
alter table public.invoices add column if not exists last_sent_at timestamptz;
