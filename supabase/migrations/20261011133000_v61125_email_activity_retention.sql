-- v61.125 — email activity retention cleanup.
-- Keeps detailed email activity operational and bounded without changing
-- invoices, payslips, quotes, payments, journals, GST or reconciliation.

create or replace function public.v61125_cleanup_email_activity(
  p_keep_days integer default 90
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_keep_days integer := greatest(coalesce(p_keep_days, 90), 30);
  v_cutoff timestamptz := now() - make_interval(days => greatest(coalesce(p_keep_days, 90), 30));
  v_email_deleted integer := 0;
  v_reminder_deleted integer := 0;
begin
  delete from public.email_delivery_events
  where sent_at < v_cutoff;
  get diagnostics v_email_deleted = row_count;

  if to_regclass('public.invoice_reminder_history') is not null then
    delete from public.invoice_reminder_history
    where sent_at < v_cutoff;
    get diagnostics v_reminder_deleted = row_count;
  end if;

  return jsonb_build_object(
    'keep_days', v_keep_days,
    'cutoff', v_cutoff,
    'email_delivery_events_deleted', v_email_deleted,
    'invoice_reminder_history_deleted', v_reminder_deleted
  );
end;
$$;

revoke all on function public.v61125_cleanup_email_activity(integer) from public, anon, authenticated;
grant execute on function public.v61125_cleanup_email_activity(integer) to service_role;

do $do$
begin
  if to_regnamespace('cron') is not null then
    if exists (select 1 from cron.job where jobname = 'frindly_email_activity_retention_daily') then
      perform cron.unschedule('frindly_email_activity_retention_daily');
    end if;

    perform cron.schedule(
      'frindly_email_activity_retention_daily',
      '17 3 * * *',
      $job$select public.v61125_cleanup_email_activity(90);$job$
    );
  end if;
exception
  when undefined_table or undefined_function or insufficient_privilege then
    raise notice 'Email activity retention cron was not scheduled in this environment: %', sqlerrm;
end;
$do$;
