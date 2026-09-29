-- V61.79D Phase A advisor-hardening correction
-- Scope: RLS init-plan optimization, operation-specific Schedule write policies,
-- and leading-column indexes for V61.79 foreign keys reported unindexed by Supabase advisors.
-- Runtime/UI/OAuth changes: none.

begin;

-- 1) Supabase-recommended init-plan form for authenticated ownership checks.
drop policy if exists v6179_google_connections_own_read on public.google_calendar_connections;
create policy v6179_google_connections_own_read
on public.google_calendar_connections
for select
to authenticated
using (
  business_id = public.current_business_id()
  and user_id = (select auth.uid())
);

-- 2) Replace broad FOR ALL Schedule write policies with operation-specific policies.
drop policy if exists v6179_schedule_series_write on public.job_recurrence_series;
drop policy if exists v6179_schedule_series_insert on public.job_recurrence_series;
drop policy if exists v6179_schedule_series_update on public.job_recurrence_series;
drop policy if exists v6179_schedule_series_delete on public.job_recurrence_series;
create policy v6179_schedule_series_insert
on public.job_recurrence_series
for insert to authenticated
with check (public.v6179_schedule_role_allowed(business_id, true));
create policy v6179_schedule_series_update
on public.job_recurrence_series
for update to authenticated
using (public.v6179_schedule_role_allowed(business_id, true))
with check (public.v6179_schedule_role_allowed(business_id, true));
create policy v6179_schedule_series_delete
on public.job_recurrence_series
for delete to authenticated
using (public.v6179_schedule_role_allowed(business_id, true));

drop policy if exists v6179_schedules_write on public.job_schedules;
drop policy if exists v6179_schedules_insert on public.job_schedules;
drop policy if exists v6179_schedules_update on public.job_schedules;
drop policy if exists v6179_schedules_delete on public.job_schedules;
create policy v6179_schedules_insert
on public.job_schedules
for insert to authenticated
with check (public.v6179_schedule_role_allowed(business_id, true));
create policy v6179_schedules_update
on public.job_schedules
for update to authenticated
using (public.v6179_schedule_role_allowed(business_id, true))
with check (public.v6179_schedule_role_allowed(business_id, true));
create policy v6179_schedules_delete
on public.job_schedules
for delete to authenticated
using (public.v6179_schedule_role_allowed(business_id, true));

drop policy if exists v6179_schedule_assignments_write on public.job_schedule_assignments;
drop policy if exists v6179_schedule_assignments_insert on public.job_schedule_assignments;
drop policy if exists v6179_schedule_assignments_update on public.job_schedule_assignments;
drop policy if exists v6179_schedule_assignments_delete on public.job_schedule_assignments;
create policy v6179_schedule_assignments_insert
on public.job_schedule_assignments
for insert to authenticated
with check (public.v6179_schedule_role_allowed(business_id, true));
create policy v6179_schedule_assignments_update
on public.job_schedule_assignments
for update to authenticated
using (public.v6179_schedule_role_allowed(business_id, true))
with check (public.v6179_schedule_role_allowed(business_id, true));
create policy v6179_schedule_assignments_delete
on public.job_schedule_assignments
for delete to authenticated
using (public.v6179_schedule_role_allowed(business_id, true));

-- 3) Leading-column indexes only for V61.79 foreign keys reported unindexed.
-- Existing indexes already lead with business_id, schedule_id, or assignment employee_id where applicable.
create index if not exists job_recurrence_series_job_costing_id_idx on public.job_recurrence_series(job_costing_id);
create index if not exists job_recurrence_series_customer_id_idx on public.job_recurrence_series(customer_id);
create index if not exists job_recurrence_series_created_by_idx on public.job_recurrence_series(created_by);
create index if not exists job_recurrence_series_updated_by_idx on public.job_recurrence_series(updated_by);

create index if not exists job_schedules_job_costing_id_idx on public.job_schedules(job_costing_id);
create index if not exists job_schedules_quote_id_idx on public.job_schedules(quote_id);
create index if not exists job_schedules_customer_id_idx on public.job_schedules(customer_id);
create index if not exists job_schedules_invoice_id_idx on public.job_schedules(invoice_id);
create index if not exists job_schedules_recurrence_series_id_idx on public.job_schedules(recurrence_series_id);
create index if not exists job_schedules_created_by_idx on public.job_schedules(created_by);
create index if not exists job_schedules_updated_by_idx on public.job_schedules(updated_by);

create index if not exists job_schedule_assignments_business_id_idx on public.job_schedule_assignments(business_id);
create index if not exists job_schedule_assignments_created_by_idx on public.job_schedule_assignments(created_by);
create index if not exists job_schedule_assignments_updated_by_idx on public.job_schedule_assignments(updated_by);

create index if not exists google_calendar_connections_user_id_idx on public.google_calendar_connections(user_id);
create index if not exists google_calendar_event_links_employee_id_idx on public.google_calendar_event_links(employee_id);
create index if not exists google_calendar_event_links_user_id_idx on public.google_calendar_event_links(user_id);
create index if not exists google_calendar_sync_log_connection_id_idx on public.google_calendar_sync_log(connection_id);
create index if not exists google_calendar_sync_log_schedule_id_idx on public.google_calendar_sync_log(schedule_id);

commit;
