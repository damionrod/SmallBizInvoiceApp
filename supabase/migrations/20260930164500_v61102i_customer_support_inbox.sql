-- Frindly v61.102I — customer support inbox + human chat foundation.
-- Additive only. Existing support/health tables and application modules are unchanged.
create table if not exists public.support_threads(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  created_by_user_id uuid not null references auth.users(id) on delete cascade,
  category text not null default 'other',
  subject text not null,
  status text not null default 'open' check(status in ('open','waiting','resolved')),
  channel text not null default 'ticket' check(channel in ('ticket','live_chat')),
  current_module text,
  browser text,
  app_version text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);
create index if not exists support_threads_creator_idx on public.support_threads(created_by_user_id,last_message_at desc);
create index if not exists support_threads_business_idx on public.support_threads(business_id,last_message_at desc);
create index if not exists support_threads_status_idx on public.support_threads(status,last_message_at desc);

create table if not exists public.support_messages(
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.support_threads(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  sender_user_id uuid not null references auth.users(id) on delete cascade,
  sender_role text not null check(sender_role in ('customer','support')),
  body text not null default '',
  attachment_path text,
  attachment_name text,
  created_at timestamptz not null default now(),
  check(length(trim(body))>0 or attachment_path is not null)
);
create index if not exists support_messages_thread_idx on public.support_messages(thread_id,created_at);

create table if not exists public.support_presence(
  admin_user_id uuid primary key references auth.users(id) on delete cascade,
  is_online boolean not null default false,
  last_seen_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.support_threads enable row level security;
alter table public.support_messages enable row level security;
alter table public.support_presence enable row level security;

drop policy if exists support_threads_customer_select on public.support_threads;
create policy support_threads_customer_select on public.support_threads for select to authenticated
using(created_by_user_id=auth.uid() or public.is_super_admin());
drop policy if exists support_threads_customer_insert on public.support_threads;
create policy support_threads_customer_insert on public.support_threads for insert to authenticated
with check(created_by_user_id=auth.uid() and business_id=public.current_business_id());
drop policy if exists support_threads_admin_update on public.support_threads;
create policy support_threads_admin_update on public.support_threads for update to authenticated
using(public.is_super_admin()) with check(public.is_super_admin());

drop policy if exists support_messages_select on public.support_messages;
create policy support_messages_select on public.support_messages for select to authenticated
using(public.is_super_admin() or exists(select 1 from public.support_threads t where t.id=thread_id and t.created_by_user_id=auth.uid()));
drop policy if exists support_messages_insert_customer on public.support_messages;
create policy support_messages_insert_customer on public.support_messages for insert to authenticated
with check(sender_user_id=auth.uid() and sender_role='customer' and exists(select 1 from public.support_threads t where t.id=thread_id and t.business_id=business_id and t.created_by_user_id=auth.uid() and t.status<>'resolved'));
drop policy if exists support_messages_insert_admin on public.support_messages;
create policy support_messages_insert_admin on public.support_messages for insert to authenticated
with check(sender_user_id=auth.uid() and sender_role='support' and public.is_super_admin() and exists(select 1 from public.support_threads t where t.id=thread_id and t.business_id=business_id));

drop policy if exists support_presence_read on public.support_presence;
create policy support_presence_read on public.support_presence for select to authenticated using(true);
drop policy if exists support_presence_admin_insert on public.support_presence;
create policy support_presence_admin_insert on public.support_presence for insert to authenticated with check(admin_user_id=auth.uid() and public.is_super_admin());
drop policy if exists support_presence_admin_update on public.support_presence;
create policy support_presence_admin_update on public.support_presence for update to authenticated using(admin_user_id=auth.uid() and public.is_super_admin()) with check(admin_user_id=auth.uid() and public.is_super_admin());

create or replace function public.support_touch_thread() returns trigger language plpgsql security definer set search_path=public as $$
begin update public.support_threads set updated_at=now(),last_message_at=now(),status=case when new.sender_role='support' then 'waiting' else 'open' end where id=new.thread_id; return new; end;$$;
drop trigger if exists support_message_touch_thread on public.support_messages;
create trigger support_message_touch_thread after insert on public.support_messages for each row execute function public.support_touch_thread();

-- Private optional support attachments. Path begins with the uploader's user id.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('support-attachments','support-attachments',false,5242880,array['image/png','image/jpeg','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists support_attachment_customer_insert on storage.objects;
create policy support_attachment_customer_insert on storage.objects for insert to authenticated
with check(bucket_id='support-attachments' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists support_attachment_customer_read on storage.objects;
create policy support_attachment_customer_read on storage.objects for select to authenticated
using(bucket_id='support-attachments' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_super_admin()));

-- Realtime is used only for support messages/presence; no polling is introduced.
do $$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='support_messages') then alter publication supabase_realtime add table public.support_messages; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='support_presence') then alter publication supabase_realtime add table public.support_presence; end if;
end $$;
