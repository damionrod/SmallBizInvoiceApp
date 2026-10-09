-- v61.111: backend launch hardening.
-- Adds shared rate-limit state, Stripe webhook event audit/idempotency,
-- universal deferred journal balance protection, and narrow write locks.

create table if not exists public.edge_function_rate_limits (
  scope text not null,
  identifier text not null,
  window_start timestamptz not null,
  request_count integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key(scope, identifier)
);

alter table public.edge_function_rate_limits enable row level security;
revoke all on public.edge_function_rate_limits from public, anon, authenticated;
grant select, insert, update, delete on public.edge_function_rate_limits to service_role;

create or replace function public.v61111_check_edge_rate_limit(
  p_scope text,
  p_identifier text,
  p_limit integer,
  p_window_seconds integer
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope text := left(nullif(btrim(coalesce(p_scope,'')),''), 120);
  v_identifier text := left(nullif(btrim(coalesce(p_identifier,'')),''), 160);
  v_limit integer := greatest(1, coalesce(p_limit, 1));
  v_window_seconds integer := greatest(10, coalesce(p_window_seconds, 60));
  v_now timestamptz := now();
  v_start timestamptz;
  v_count integer;
begin
  if v_scope is null or v_identifier is null then
    raise exception 'Rate limit scope and identifier are required';
  end if;

  insert into public.edge_function_rate_limits(scope, identifier, window_start, request_count, updated_at)
  values(v_scope, v_identifier, v_now, 1, v_now)
  on conflict(scope, identifier) do update set
    window_start = case
      when public.edge_function_rate_limits.window_start <= v_now - make_interval(secs => v_window_seconds)
      then v_now else public.edge_function_rate_limits.window_start end,
    request_count = case
      when public.edge_function_rate_limits.window_start <= v_now - make_interval(secs => v_window_seconds)
      then 1 else public.edge_function_rate_limits.request_count + 1 end,
    updated_at = v_now
  returning window_start, request_count into v_start, v_count;

  return jsonb_build_object(
    'allowed', v_count <= v_limit,
    'count', v_count,
    'limit', v_limit,
    'reset_at', v_start + make_interval(secs => v_window_seconds)
  );
end;
$$;

revoke execute on function public.v61111_check_edge_rate_limit(text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.v61111_check_edge_rate_limit(text,text,integer,integer) to service_role;

create table if not exists public.stripe_webhook_events (
  event_id text primary key,
  event_type text not null,
  stripe_account_id text,
  status text not null default 'processing' check(status in ('processing','completed','failed')),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  completed_at timestamptz,
  failed_at timestamptz,
  error_message text
);

alter table public.stripe_webhook_events enable row level security;
revoke all on public.stripe_webhook_events from public, anon, authenticated;
grant select, insert, update, delete on public.stripe_webhook_events to service_role;

create or replace function public.v61111_begin_stripe_webhook_event(
  p_event_id text,
  p_event_type text,
  p_stripe_account_id text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_row public.stripe_webhook_events%rowtype;
begin
  if nullif(btrim(coalesce(p_event_id,'')),'') is null then
    raise exception 'Stripe event id is required';
  end if;

  insert into public.stripe_webhook_events(event_id,event_type,stripe_account_id,status,first_seen_at,last_seen_at)
  values(p_event_id, coalesce(nullif(p_event_type,''),'unknown'), nullif(p_stripe_account_id,''), 'processing', v_now, v_now)
  on conflict(event_id) do nothing
  returning * into v_row;

  if found then
    return jsonb_build_object('process', true, 'status', v_row.status, 'last_seen_at', v_row.last_seen_at);
  end if;

  select * into v_row
    from public.stripe_webhook_events
   where event_id = p_event_id
   for update;

  if v_row.status = 'completed' then
    update public.stripe_webhook_events
       set last_seen_at = v_now
     where event_id = p_event_id;
    return jsonb_build_object('process', false, 'status', v_row.status, 'last_seen_at', v_now);
  end if;

  if v_row.status = 'processing' and v_row.last_seen_at > v_now - interval '15 minutes' then
    update public.stripe_webhook_events
       set last_seen_at = v_now
     where event_id = p_event_id;
    return jsonb_build_object('process', false, 'status', v_row.status, 'last_seen_at', v_now);
  end if;

  update public.stripe_webhook_events
     set event_type = coalesce(nullif(p_event_type,''),'unknown'),
         stripe_account_id = nullif(p_stripe_account_id,''),
         status = 'processing',
         last_seen_at = v_now,
         error_message = null
   where event_id = p_event_id
   returning * into v_row;

  return jsonb_build_object(
    'process', true,
    'status', v_row.status,
    'last_seen_at', v_row.last_seen_at
  );
end;
$$;

create or replace function public.v61111_finish_stripe_webhook_event(
  p_event_id text,
  p_status text,
  p_error_message text default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.stripe_webhook_events
     set status = case when p_status = 'completed' then 'completed' else 'failed' end,
         completed_at = case when p_status = 'completed' then now() else completed_at end,
         failed_at = case when p_status = 'completed' then failed_at else now() end,
         error_message = case when p_status = 'completed' then null else left(coalesce(p_error_message,''), 1000) end,
         last_seen_at = now()
   where event_id = p_event_id;
end;
$$;

revoke execute on function public.v61111_begin_stripe_webhook_event(text,text,text) from public, anon, authenticated;
revoke execute on function public.v61111_finish_stripe_webhook_event(text,text,text) from public, anon, authenticated;
grant execute on function public.v61111_begin_stripe_webhook_event(text,text,text) to service_role;
grant execute on function public.v61111_finish_stripe_webhook_event(text,text,text) to service_role;

create or replace function public.v61111_enforce_balanced_posted_journal()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_journal_id uuid;
  v_status text;
  v_debits numeric;
  v_credits numeric;
begin
  if TG_TABLE_NAME = 'accounting_journals' then
    v_journal_id := case when TG_OP = 'DELETE' then old.id else new.id end;
  else
    v_journal_id := case when TG_OP = 'DELETE' then old.journal_id else new.journal_id end;
  end if;
  if v_journal_id is null then
    if TG_OP = 'DELETE' then return old; else return new; end if;
  end if;

  select j.status, round(coalesce(sum(l.debit),0),2), round(coalesce(sum(l.credit),0),2)
    into v_status, v_debits, v_credits
    from public.accounting_journals j
    left join public.accounting_journal_lines l
      on l.journal_id = j.id
     and l.business_id = j.business_id
   where j.id = v_journal_id
   group by j.status;

  if v_status in ('posted','reversed') and (v_debits is null or abs(v_debits - v_credits) > 0.005) then
    raise exception 'Posted accounting journal % is not balanced: debits %, credits %', v_journal_id, coalesce(v_debits,0), coalesce(v_credits,0);
  end if;

  if TG_OP = 'DELETE' then return old; else return new; end if;
end;
$$;

drop trigger if exists accounting_journal_lines_balanced_v61111 on public.accounting_journal_lines;
create constraint trigger accounting_journal_lines_balanced_v61111
after insert or update or delete on public.accounting_journal_lines
deferrable initially deferred
for each row execute function public.v61111_enforce_balanced_posted_journal();

drop trigger if exists accounting_journals_balanced_v61111 on public.accounting_journals;
create constraint trigger accounting_journals_balanced_v61111
after insert or update of status on public.accounting_journals
deferrable initially deferred
for each row execute function public.v61111_enforce_balanced_posted_journal();

create or replace function public.v61111_lock_bank_reconciliation_allocation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.bank_transaction_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(new.bank_transaction_id::text, 61111));
    perform 1 from public.bank_transactions
     where id = new.bank_transaction_id
       and business_id = new.business_id
     for update;
  end if;
  if new.related_bank_transaction_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(new.related_bank_transaction_id::text, 61111));
    perform 1 from public.bank_transactions
     where id = new.related_bank_transaction_id
       and business_id = new.business_id
     for update;
  end if;
  return new;
end;
$$;

drop trigger if exists bank_reconciliation_allocation_lock_v61111 on public.bank_reconciliation_allocations;
create trigger bank_reconciliation_allocation_lock_v61111
before insert or update on public.bank_reconciliation_allocations
for each row execute function public.v61111_lock_bank_reconciliation_allocation();

create or replace function public.v61111_lock_stock_equipment_asset()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(new.id::text, 61112));
  return new;
end;
$$;

drop trigger if exists se_assets_write_lock_v61111 on public.se_assets;
create trigger se_assets_write_lock_v61111
before update on public.se_assets
for each row execute function public.v61111_lock_stock_equipment_asset();
