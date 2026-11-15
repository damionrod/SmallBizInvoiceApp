# Frindly database baseline runbook

This phase collects backups and records what exists in production. Run it from the
repository root on the `db-baseline` branch. The production project ref is
`oxsbzytwbphagcbilxud`. Confirm it in the Supabase Dashboard before proceeding.
Use the existing database credentials to connect.

## 1. Record the recovery point and make private backups

1. In the production Supabase Dashboard, open **Database → Backups**. Record the
   latest successful backup and its timestamp. Check whether PITR is enabled and
   record its available recovery window. If the Dashboard offers an on-demand
   backup, start it and verify completion. Otherwise use the manual logical backup
   below. Do not select **Restore**.
2. Run these commands in Bash, Git Bash or WSL. Docker must be running. Use the
   Supabase CLI v3 syntax below and record the exact version printed. Verify the
   `--remote` and dump flags against `supabase db dump --help` before proceeding.
   The timestamped directory keeps prior attempts intact. Use a private,
   encrypted disk.

   ```bash
   (
     set -eu
     umask 077
     supabase --version
     supabase link --project-ref oxsbzytwbphagcbilxud

     backup_dir="backup/$(date -u +%Y%m%dT%H%M%SZ)"
     mkdir -p backup
     mkdir "$backup_dir"
     git check-ignore -q "$backup_dir/schema.sql"

     supabase db dump --remote --role-only -f "$backup_dir/roles.sql"
     supabase db dump --remote -f "$backup_dir/schema.sql"
     supabase db dump --remote --data-only --use-copy -f "$backup_dir/data.sql"
     supabase db dump --remote --data-only --use-copy --schema supabase_migrations \
       -f "$backup_dir/migration-history.sql"

     ls -lh "$backup_dir"
   )
   ```

3. In the production SQL Editor, run the following SELECT. Save the full result
   under the same private backup directory and retain the exact list of versions.
   The statements column can contain credentials or operational details. If the
   table is absent, record that and leave migration history untouched.

   ```sql
   select * from supabase_migrations.schema_migrations order by version;
   ```

Record the UTC start and finish times and any failure or intentional exclusion.
Each dump is a separate operation. Use the Dashboard backup or PITR for a
point-in-time database recovery. The standard schema dump does not capture
all Supabase-managed schemas and the database backup does not contain the actual
receipt and PDF files in Storage. For disaster recovery, retain those files through
a separate private Storage backup. See [Supabase database backups](https://supabase.com/docs/guides/platform/backups)
and [CLI backup and restore](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore).

Keep raw backups, credentials, customer records and payroll records private.
Even schema and migration history can contain embedded credentials. If a
CLI command fails, retain its error privately, check the target and CLI version,
and rerun into a new directory. Record any exclusions explicitly.

## 2. Collect the read-only inventory

Open [the inventory script](../scripts/db-inventory.sql). In the production SQL
Editor, run each SELECT separately and save each result privately under the backup
directory. Confirm the UI did not truncate results. The first result reports
whether the cron catalog exists. If it is absent, skip the cron SELECT and record
that fact. If a section fails or a candidate table is missing, record the result
and continue with the other sections. The counts include no table row contents.

Catalog output may contain hard-coded secrets in cron commands, trigger bodies,
policies or schema definitions. Before sharing, redact tokens, authorization
headers, credentials, private endpoints and personal or tenant identifiers. Keep
object names and signatures, privileges, schedule, job enabled state, and the
structure of configuration references wherever safe. Share the sanitized
inventory, the migration version list alone, and a reviewed schema-only copy
after removing sensitive literals. Keep the full data, roles and migration
history dumps private. Review reference row contents separately once the actual
reference tables and their environment-specific values are identified.

The SQL inventory lists production objects. Compare those against the repository
by qualified name, object type and routine signature. A name match does not
prove that the definition is equivalent.

Pause after Steps 1 and 2 for review. Production migration history repair is a
separate, owner-run step after an isolated rebuild, schema and privilege
comparison, reference-data verification and smoke tests have passed. Leave
production cron, payment and email integrations disconnected from the isolated
rebuild.
