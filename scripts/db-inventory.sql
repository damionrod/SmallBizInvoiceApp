-- Run each SELECT separately as a database administrator. Keep raw outputs private.
-- Cron commands, function definitions and policies may contain embedded secrets.

-- PostgreSQL version and availability of the cron catalog.
select current_setting('server_version') as postgres_version,
       to_regclass('cron.job') is not null as cron_catalog_exists;

-- Run only if cron_catalog_exists is true.
select jobname, schedule, command, active, database, username
from cron.job
order by jobname, database, username, jobid;

-- All auth.users triggers and the functions they call.
-- Internal triggers are identified so platform-managed constraints can be excluded from replay.
select t.tgname as trigger_name,
       t.tgisinternal as is_internal,
       t.tgenabled as enabled_mode,
       pg_get_triggerdef(t.oid) as trigger_definition,
       format('%I.%I(%s)', n.nspname, p.proname,
              pg_get_function_identity_arguments(p.oid)) as routine_identity,
       pg_get_userbyid(p.proowner) as routine_owner,
       p.prosecdef as security_definer,
       p.proconfig as routine_settings,
       p.proacl as routine_acl,
       pg_get_functiondef(p.oid) as routine_definition
from pg_trigger as t
join pg_proc as p on p.oid = t.tgfoid
join pg_namespace as n on n.oid = p.pronamespace
where t.tgrelid = to_regclass('auth.users')
order by t.tgname;

-- Bucket configuration. Ownership identifiers and timestamps are omitted.
-- JSON access also works on platform versions without a bucket type column.
select id, name, public, file_size_limit, allowed_mime_types,
       to_jsonb(b) ->> 'type' as bucket_type
from storage.buckets as b
order by id;

select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'storage'
order by tablename, policyname;

select e.extname, e.extversion, n.nspname as extension_schema
from pg_extension as e
join pg_namespace as n on n.oid = e.extnamespace
order by e.extname;

-- List every non-system schema so extension-managed and custom schemas can be
-- classified without silently dropping an unfamiliar schema.
select nspname as schema_name, pg_get_userbyid(nspowner) as schema_owner,
       nspacl as schema_acl
from pg_namespace
where nspname <> 'information_schema'
  and nspname !~ '^pg_'
order by nspname;

-- Compare this inventory against repo SQL off-database. Use signatures for overloads.
select 'public' as schema_name, c.relname as object_name,
       case c.relkind
         when 'r' then 'table'
         when 'p' then 'partitioned table'
         when 'f' then 'foreign table'
         when 'v' then 'view'
         when 'm' then 'materialized view'
       end as object_type,
       null::text as identity_arguments
from pg_class as c
where c.relnamespace = 'public'::regnamespace
  and c.relkind in ('r', 'p', 'f', 'v', 'm')
union all
select 'public', p.proname,
       case p.prokind
         when 'p' then 'procedure'
         when 'a' then 'aggregate'
         when 'w' then 'window function'
         else 'function'
       end,
       pg_get_function_identity_arguments(p.oid)
from pg_proc as p
where p.pronamespace = 'public'::regnamespace
order by object_type, object_name, identity_arguments;

-- Find names for the chart of accounts and payment configuration candidates.
select n.nspname as schema_name, c.relname as table_name
from pg_class as c
join pg_namespace as n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('r', 'p')
  and c.relname ~ '(chart.*account|account.*template|payment.*(provider|config)|provider.*config)'
order by c.relname;

-- Count only allowlisted base tables. Missing names return NULL. After reviewing
-- the discovery result, add the exact reference-table names to VALUES and rerun.
with candidates(table_name) as (
  values ('plans'), ('modules'), ('country_payroll_rules'),
         ('country_business_tax_rules'), ('payroll_public_holidays'),
         ('finlo_helper_settings')
),
located as (
  select candidates.table_name, relations.oid
  from candidates
  left join pg_class as relations
    on relations.relname = candidates.table_name
   and relations.relnamespace = 'public'::regnamespace
   and relations.relkind in ('r', 'p')
)
select table_name, oid is not null as table_exists,
       case when oid is not null then
         ((xpath('/table/row/total/text()', query_to_xml(
           format('select count(*) as total from %I.%I', 'public', table_name),
           false, false, ''
         )))[1]::text)::bigint
       end as row_count
from located
order by table_name;
