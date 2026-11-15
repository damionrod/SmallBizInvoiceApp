-- Match the worker's existing production authentication on fresh installs.
-- Provision the matching Edge Function and Vault secret outside migrations.
do $migration$
declare
  reminder_job record;
  legacy_headers constant text := $legacy$headers := '{"Content-Type":"application/json"}'::jsonb$legacy$;
begin
  if to_regnamespace('cron') is null or to_regnamespace('net') is null then
    return;
  end if;

  select jobid, command into reminder_job
  from cron.job
  where jobname = 'frindly_auto_invoice_reminders_daily';

  if not found or reminder_job.command like '%x-frindly-worker-secret%' then
    return;
  end if;

  if to_regclass('vault.decrypted_secrets') is null then
    raise exception 'Supabase Vault is required for the invoice reminder schedule.';
  end if;

  if strpos(reminder_job.command, legacy_headers) = 0 then
    raise exception 'Unexpected invoice reminder cron definition. Review it before replacing its headers.';
  end if;

  perform cron.alter_job(
    reminder_job.jobid,
    command := replace(
      regexp_replace(reminder_job.command, ';[[:space:]]*
      $headers$headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-frindly-worker-secret', reminder_secret.decrypted_secret
        )$headers$
    ) || $vault$
    from vault.decrypted_secrets as reminder_secret
    where reminder_secret.name = 'frindly_invoice_reminder_worker_secret'
      and length(reminder_secret.decrypted_secret) >= 32
    $vault$
  );
end;
$migration$;
, ''),
      legacy_headers,
      $headers$headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-frindly-worker-secret', reminder_secret.decrypted_secret
        )$headers$
    ) || $vault$
    from vault.decrypted_secrets as reminder_secret
    where reminder_secret.name = 'frindly_invoice_reminder_worker_secret'
      and length(reminder_secret.decrypted_secret) >= 32
    $vault$
  );
end;
$migration$;
