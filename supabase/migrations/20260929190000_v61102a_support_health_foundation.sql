create table if not exists public.support_audit_log(
 id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), admin_user_id uuid not null,
 target_user_id uuid, target_business_id uuid, action text not null, outcome text not null, metadata jsonb not null default '{}'::jsonb);
create index if not exists support_audit_log_created_idx on public.support_audit_log(created_at desc);
create index if not exists support_audit_log_target_user_idx on public.support_audit_log(target_user_id,created_at desc);
create index if not exists support_audit_log_target_business_idx on public.support_audit_log(target_business_id,created_at desc);
alter table public.support_audit_log enable row level security;
revoke all on public.support_audit_log from anon,authenticated;
create table if not exists public.support_operational_events(
 id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), reference text not null unique,
 severity text not null check(severity in ('Info','Warning','Critical')), service text not null, business_id uuid, user_id uuid,
 summary text not null, status text not null default 'Open' check(status in ('Open','Resolved')), metadata jsonb not null default '{}'::jsonb);
create index if not exists support_operational_events_created_idx on public.support_operational_events(created_at desc);
create index if not exists support_operational_events_service_idx on public.support_operational_events(service,created_at desc);
alter table public.support_operational_events enable row level security;
revoke all on public.support_operational_events from anon,authenticated;
