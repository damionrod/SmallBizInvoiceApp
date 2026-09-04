-- v30 quotation upgrade
-- Adds optional advance-payment fields to quotations.
-- Safe to run after the existing v23/v24 migrations.

alter table public.quotes add column if not exists advance_enabled boolean not null default false;
alter table public.quotes add column if not exists advance_percent numeric(7,3) not null default 0;
alter table public.quotes add column if not exists advance_amount numeric(12,2) not null default 0;

-- Keep existing quotations unchanged: no advance is assumed for historical quotes.
update public.quotes
set advance_enabled = false,
    advance_percent = coalesce(advance_percent,0),
    advance_amount = coalesce(advance_amount,0)
where advance_enabled is null
   or advance_percent is null
   or advance_amount is null;
