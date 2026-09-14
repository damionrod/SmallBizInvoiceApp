-- Finlo V61.55 — isolated AI expense scan telemetry.
-- No existing expense tables or columns are changed.

create table if not exists public.expense_ai_scans (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'processing' check (status in ('processing','success','failed')),
  filename text,
  mime_type text,
  model text,
  openai_response_id text,
  input_tokens integer,
  output_tokens integer,
  error_message text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists expense_ai_scans_business_created_idx on public.expense_ai_scans(business_id,created_at desc);
create index if not exists expense_ai_scans_user_created_idx on public.expense_ai_scans(user_id,created_at desc);

alter table public.expense_ai_scans enable row level security;

drop policy if exists v6155_expense_ai_scans_read on public.expense_ai_scans;
create policy v6155_expense_ai_scans_read on public.expense_ai_scans
for select to authenticated
using (business_id=public.current_business_id() or public.is_super_admin());

-- Browser clients do not insert/update/delete scan telemetry directly.
-- The authenticated Edge Function derives the current business and writes via service role.
revoke insert, update, delete on public.expense_ai_scans from anon, authenticated;
grant select on public.expense_ai_scans to authenticated;

notify pgrst, 'reload schema';
