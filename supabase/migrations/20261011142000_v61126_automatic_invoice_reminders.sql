-- v61.126 — optional automatic invoice payment reminders.
-- Adds business/customer/invoice override controls and an idempotent worker queue.
-- Manual reminder sending is unchanged.

alter table public.customers
  add column if not exists auto_reminder_policy text not null default 'default'
  check (auto_reminder_policy in ('default','on','off'));

alter table public.invoices
  add column if not exists auto_reminder_policy text not null default 'default'
  check (auto_reminder_policy in ('default','on','off')),
  add column if not exists auto_reminders_paused_until date;

create table if not exists public.invoice_auto_reminder_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  reminder_key text not null,
  reminder_days integer not null,
  scheduled_for date not null,
  status text not null default 'claimed' check (status in ('claimed','sent','failed','skipped')),
  recipient text,
  subject text,
  provider_message_id text,
  error_message text,
  claimed_at timestamptz not null default now(),
  processed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  unique(invoice_id, reminder_key, scheduled_for)
);

create index if not exists invoice_auto_reminder_runs_business_idx
  on public.invoice_auto_reminder_runs(business_id, scheduled_for desc);

create index if not exists invoice_auto_reminder_runs_invoice_idx
  on public.invoice_auto_reminder_runs(invoice_id, scheduled_for desc);

alter table public.invoice_auto_reminder_runs enable row level security;

drop policy if exists invoice_auto_reminder_runs_select_business on public.invoice_auto_reminder_runs;
create policy invoice_auto_reminder_runs_select_business
on public.invoice_auto_reminder_runs
for select to authenticated
using (business_id = public.current_business_id());

revoke all on public.invoice_auto_reminder_runs from public, anon;
grant select on public.invoice_auto_reminder_runs to authenticated;
grant select, insert, update on public.invoice_auto_reminder_runs to service_role;

create or replace function public.v61126_claim_invoice_auto_reminders(
  p_today date default ((now() at time zone 'Pacific/Auckland')::date),
  p_limit integer default 50
)
returns table (
  run_id uuid,
  business_id uuid,
  invoice_id uuid,
  invoice_number text,
  customer_name text,
  customer_email text,
  total numeric,
  balance_due numeric,
  due_date date,
  currency text,
  reminder_key text,
  reminder_days integer,
  scheduled_for date,
  subject_template text,
  body_template text,
  sender_template text,
  business_settings jsonb
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select
      i.id as invoice_id,
      i.business_id,
      i.invoice_number,
      i.customer_name,
      i.customer_email,
      i.total,
      coalesce(i.balance_due, i.total) as balance_due,
      i.due_date,
      coalesce(b.settings, '{}'::jsonb) as business_settings,
      coalesce(b.settings->>'currency', i.company_snapshot->>'currency', 'NZD') as currency,
      coalesce(c.auto_reminder_policy, 'default') as customer_policy,
      coalesce(i.auto_reminder_policy, 'default') as invoice_policy,
      coalesce(i.auto_reminders_paused_until, date '1900-01-01') as paused_until
    from public.invoices i
    join public.businesses b on b.id = i.business_id
    left join public.customers c on c.id = i.customer_id
    where lower(coalesce(i.lifecycle_state, '')) = 'issued'
      and i.due_date is not null
      and coalesce(i.balance_due, i.total, 0) > 0.005
      and coalesce(i.customer_email, '') ~* '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
      and coalesce(i.auto_reminders_paused_until, date '1900-01-01') < p_today
      and exists (
        select 1
        from public.email_delivery_events ede
        where ede.source_table = 'invoices'
          and ede.source_id = i.id
          and ede.message_type = 'invoice'
      )
  ),
  enabled_candidates as (
    select *
    from candidates c
    where case c.invoice_policy
      when 'off' then false
      when 'on' then true
      else case c.customer_policy
        when 'off' then false
        when 'on' then true
        else coalesce((c.business_settings->'autoPaymentReminders'->>'enabled')::boolean, false)
      end
    end
  ),
  schedule_rows as (
    select
      ec.*,
      coalesce(s.item->>'key', 'day_' || coalesce(s.item->>'days','0')) as reminder_key,
      coalesce((s.item->>'days')::integer, 0) as reminder_days,
      coalesce(s.item->>'label', 'Payment reminder') as reminder_label,
      coalesce((s.item->>'enabled')::boolean, true) as reminder_enabled
    from enabled_candidates ec
    cross join lateral jsonb_array_elements(
      coalesce(
        ec.business_settings->'autoPaymentReminders'->'schedule',
        '[{"key":"before_due","days":-3,"label":"3 days before due","enabled":true},{"key":"due_today","days":0,"label":"Due today","enabled":true},{"key":"overdue_7","days":7,"label":"7 days overdue","enabled":true},{"key":"overdue_14","days":14,"label":"14 days overdue","enabled":true}]'::jsonb
      )
    ) as s(item)
  ),
  due_rows as (
    select
      sr.*,
      (sr.due_date + sr.reminder_days) as scheduled_for
    from schedule_rows sr
    where sr.reminder_enabled
      and (sr.due_date + sr.reminder_days) <= p_today
      and (sr.due_date + sr.reminder_days) >= (p_today - 3)
      and not exists (
        select 1
        from public.invoice_reminder_history h
        where h.invoice_id = sr.invoice_id
          and (h.sent_at at time zone 'Pacific/Auckland')::date between (sr.due_date + sr.reminder_days) and p_today
      )
    order by (sr.due_date + sr.reminder_days), sr.invoice_number
    limit greatest(1, least(coalesce(p_limit, 50), 100))
  ),
  inserted as (
    insert into public.invoice_auto_reminder_runs (
      business_id,
      invoice_id,
      reminder_key,
      reminder_days,
      scheduled_for,
      status,
      recipient,
      metadata
    )
    select
      d.business_id,
      d.invoice_id,
      d.reminder_key,
      d.reminder_days,
      d.scheduled_for,
      'claimed',
      d.customer_email,
      jsonb_build_object('label', d.reminder_label, 'invoice_number', d.invoice_number)
    from due_rows d
    on conflict (invoice_id, reminder_key, scheduled_for) do nothing
    returning *
  )
  select
    r.id as run_id,
    d.business_id,
    d.invoice_id,
    d.invoice_number,
    d.customer_name,
    d.customer_email,
    d.total,
    d.balance_due,
    d.due_date,
    d.currency,
    d.reminder_key,
    d.reminder_days,
    d.scheduled_for,
    coalesce(d.business_settings->'reminderEmailSettings'->>'subject', 'Payment reminder - Invoice {invoiceNumber}') as subject_template,
    coalesce(d.business_settings->'reminderEmailSettings'->>'body', 'Hi {customerName},\n\nThis is a friendly reminder about invoice {invoiceNumber}.\n\n{statusLine}\nAmount outstanding: {amountOutstanding}\nDue date: {dueDate}\n\nIf you have already made payment, please disregard this reminder.\n\nKind regards,\n{tradingName}\n{phone}\n{email}') as body_template,
    coalesce(d.business_settings->'reminderEmailSettings'->>'senderName', '{tradingName} Accounts') as sender_template,
    d.business_settings
  from inserted r
  join due_rows d
    on d.invoice_id = r.invoice_id
   and d.reminder_key = r.reminder_key
   and d.scheduled_for = r.scheduled_for;
$$;

create or replace function public.v61126_finish_invoice_auto_reminder(
  p_run_id uuid,
  p_status text,
  p_subject text default null,
  p_provider_message_id text default null,
  p_error_message text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_status not in ('sent','failed','skipped') then
    raise exception 'Invalid reminder status: %', p_status;
  end if;

  update public.invoice_auto_reminder_runs
     set status = p_status,
         subject = coalesce(p_subject, subject),
         provider_message_id = coalesce(p_provider_message_id, provider_message_id),
         error_message = p_error_message,
         processed_at = now()
   where id = p_run_id;
end;
$$;

revoke all on function public.v61126_claim_invoice_auto_reminders(date, integer) from public, anon, authenticated;
grant execute on function public.v61126_claim_invoice_auto_reminders(date, integer) to service_role;

revoke all on function public.v61126_finish_invoice_auto_reminder(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.v61126_finish_invoice_auto_reminder(uuid, text, text, text, text) to service_role;

do $do$
begin
  if to_regnamespace('cron') is not null and to_regnamespace('net') is not null then
    if exists (select 1 from cron.job where jobname = 'frindly_auto_invoice_reminders_daily') then
      perform cron.unschedule('frindly_auto_invoice_reminders_daily');
    end if;

    perform cron.schedule(
      'frindly_auto_invoice_reminders_daily',
      '12 9 * * *',
      $job$
      select net.http_post(
        url := 'https://oxsbzytwbphagcbilxud.supabase.co/functions/v1/invoice-reminder-worker',
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := '{"source":"cron"}'::jsonb
      );
      $job$
    );
  end if;
exception
  when undefined_table or undefined_function or insufficient_privilege then
    raise notice 'Automatic invoice reminder cron was not scheduled in this environment: %', sqlerrm;
end;
$do$;
