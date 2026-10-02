-- V61.106 Frindly Community
-- Additive module only: text-only community posts, public replies, private messages,
-- moderation controls, and Community-screen banner sponsorships.

create extension if not exists pgcrypto;

create or replace function public.v61106_is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select p.is_super_admin from public.profiles p where p.id = auth.uid()), false);
$$;

create table if not exists public.community_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  display_name text not null,
  show_business_name boolean not null default true,
  show_region boolean not null default true,
  show_industry boolean not null default true,
  private_messages_enabled boolean not null default true,
  region text,
  industry text,
  suspended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id,business_id),
  constraint community_profiles_display_name_len check (char_length(display_name) between 1 and 60)
);

create table if not exists public.community_posts (
  id uuid primary key default gen_random_uuid(),
  author_profile_id uuid not null references public.community_profiles(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  title text not null,
  body text not null,
  category text not null default 'general',
  region text,
  industry text,
  status text not null default 'active',
  hidden_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint community_posts_category check (category in ('need_workers','business_advice','recommendation','equipment_supplies','general')),
  constraint community_posts_status check (status in ('active','hidden','deleted')),
  constraint community_posts_text_len check (char_length(title) between 1 and 140 and char_length(body) between 1 and 2000)
);

create table if not exists public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  author_profile_id uuid not null references public.community_profiles(id) on delete cascade,
  body text not null,
  status text not null default 'active',
  hidden_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint community_comments_status check (status in ('active','hidden','deleted')),
  constraint community_comments_body_len check (char_length(body) between 1 and 1200)
);

create table if not exists public.community_conversations (
  id uuid primary key default gen_random_uuid(),
  created_by_profile_id uuid not null references public.community_profiles(id) on delete cascade,
  participant_profile_ids uuid[] not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint community_conversations_status check (status in ('active','archived','blocked')),
  constraint community_conversations_participants check (array_length(participant_profile_ids,1) >= 2)
);

create table if not exists public.community_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.community_conversations(id) on delete cascade,
  author_profile_id uuid not null references public.community_profiles(id) on delete cascade,
  body text not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint community_messages_status check (status in ('active','hidden','deleted')),
  constraint community_messages_body_len check (char_length(body) between 1 and 1200)
);

create table if not exists public.community_blocked_words (
  id uuid primary key default gen_random_uuid(),
  word text not null unique,
  severity text not null default 'block',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint community_blocked_words_severity check (severity in ('block','review'))
);

create table if not exists public.community_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_profile_id uuid not null references public.community_profiles(id) on delete cascade,
  target_type text not null,
  target_id uuid not null,
  reason text,
  status text not null default 'open',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint community_reports_target_type check (target_type in ('post','comment','message','profile','ad')),
  constraint community_reports_status check (status in ('open','reviewing','closed','dismissed'))
);

create table if not exists public.community_ad_packages (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  price numeric(12,2) not null default 0,
  currency text not null default 'NZD',
  duration_days integer not null default 30,
  placement text not null default 'top',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint community_ad_packages_price check (price >= 0 and duration_days > 0),
  constraint community_ad_packages_placement check (placement in ('top','feed','sidebar','inbox'))
);

create table if not exists public.community_ad_campaigns (
  id uuid primary key default gen_random_uuid(),
  package_id uuid references public.community_ad_packages(id) on delete set null,
  sponsor_type text not null default 'external',
  sponsor_business_id uuid references public.businesses(id) on delete set null,
  sponsor_name text not null,
  sponsor_contact_email text,
  title text not null,
  body text,
  destination_url text,
  placement text not null default 'top',
  target_region text,
  target_industry text,
  price_charged numeric(12,2) not null default 0,
  currency text not null default 'NZD',
  stripe_checkout_session_id text,
  stripe_payment_intent_id text,
  payment_status text not null default 'manual',
  status text not null default 'draft',
  priority integer not null default 0,
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null default (now() + interval '30 days'),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint community_ad_campaigns_sponsor_type check (sponsor_type in ('frindly_user','external')),
  constraint community_ad_campaigns_placement check (placement in ('top','feed','sidebar','inbox')),
  constraint community_ad_campaigns_payment_status check (payment_status in ('manual','pending','paid','failed','refunded')),
  constraint community_ad_campaigns_status check (status in ('draft','pending_payment','paid','pending_review','active','paused','rejected','expired')),
  constraint community_ad_campaigns_dates check (ends_at > starts_at),
  constraint community_ad_campaigns_len check (char_length(sponsor_name) between 1 and 120 and char_length(title) between 1 and 140)
);

create table if not exists public.community_ad_impressions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.community_ad_campaigns(id) on delete cascade,
  business_id uuid references public.businesses(id) on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.community_ad_clicks (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.community_ad_campaigns(id) on delete cascade,
  business_id uuid references public.businesses(id) on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists community_posts_feed_idx on public.community_posts(status, region, industry, category, created_at desc);
create index if not exists community_comments_post_idx on public.community_comments(post_id, status, created_at);
create index if not exists community_conversations_participants_idx on public.community_conversations using gin(participant_profile_ids);
create index if not exists community_messages_conversation_idx on public.community_messages(conversation_id, status, created_at);
create index if not exists community_ad_campaigns_active_idx on public.community_ad_campaigns(status, placement, target_region, target_industry, starts_at, ends_at);

create or replace function public.v61106_current_community_profile_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select cp.id
  from public.community_profiles cp
  where cp.user_id = auth.uid()
    and (
      public.v61106_is_super_admin()
      or exists (
        select 1 from public.business_memberships bm
        where bm.business_id = cp.business_id
          and bm.user_id = auth.uid()
          and bm.status = 'active'
      )
    )
  order by cp.updated_at desc nulls last, cp.created_at desc
  limit 1;
$$;

create or replace function public.v61106_reject_blocked_community_text()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  combined text := '';
  item record;
begin
  if tg_table_name = 'community_profiles' then
    combined := coalesce(new.display_name,'') || ' ' || coalesce(new.region,'') || ' ' || coalesce(new.industry,'');
  elsif tg_table_name = 'community_posts' then
    combined := coalesce(new.title,'') || ' ' || coalesce(new.body,'');
  elsif tg_table_name = 'community_comments' or tg_table_name = 'community_messages' then
    combined := coalesce(new.body,'');
  elsif tg_table_name = 'community_ad_campaigns' then
    combined := coalesce(new.sponsor_name,'') || ' ' || coalesce(new.title,'') || ' ' || coalesce(new.body,'');
  end if;

  for item in select word, severity from public.community_blocked_words where active = true loop
    if length(trim(item.word)) > 0 and position(lower(trim(item.word)) in lower(combined)) > 0 then
      if item.severity = 'block' then
        raise exception 'Please edit your message. Some wording may not meet Frindly Community guidelines.';
      end if;
      if tg_table_name in ('community_posts','community_comments','community_messages','community_ad_campaigns') then
        new.status := case when tg_table_name = 'community_ad_campaigns' then 'pending_review' else 'hidden' end;
      end if;
    end if;
  end loop;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists community_profiles_blocked_text on public.community_profiles;
create trigger community_profiles_blocked_text before insert or update on public.community_profiles
for each row execute function public.v61106_reject_blocked_community_text();
drop trigger if exists community_posts_blocked_text on public.community_posts;
create trigger community_posts_blocked_text before insert or update on public.community_posts
for each row execute function public.v61106_reject_blocked_community_text();
drop trigger if exists community_comments_blocked_text on public.community_comments;
create trigger community_comments_blocked_text before insert or update on public.community_comments
for each row execute function public.v61106_reject_blocked_community_text();
drop trigger if exists community_messages_blocked_text on public.community_messages;
create trigger community_messages_blocked_text before insert or update on public.community_messages
for each row execute function public.v61106_reject_blocked_community_text();
drop trigger if exists community_ad_campaigns_blocked_text on public.community_ad_campaigns;
create trigger community_ad_campaigns_blocked_text before insert or update on public.community_ad_campaigns
for each row execute function public.v61106_reject_blocked_community_text();

alter table public.community_profiles enable row level security;
alter table public.community_posts enable row level security;
alter table public.community_comments enable row level security;
alter table public.community_conversations enable row level security;
alter table public.community_messages enable row level security;
alter table public.community_blocked_words enable row level security;
alter table public.community_reports enable row level security;
alter table public.community_ad_packages enable row level security;
alter table public.community_ad_campaigns enable row level security;
alter table public.community_ad_impressions enable row level security;
alter table public.community_ad_clicks enable row level security;

drop policy if exists community_profiles_select on public.community_profiles;
create policy community_profiles_select on public.community_profiles for select to authenticated
using (public.v61106_is_super_admin() or suspended_at is null);
drop policy if exists community_profiles_insert_own on public.community_profiles;
create policy community_profiles_insert_own on public.community_profiles for insert to authenticated
with check (user_id = auth.uid() and exists (select 1 from public.business_memberships bm where bm.business_id = community_profiles.business_id and bm.user_id = auth.uid() and bm.status = 'active'));
drop policy if exists community_profiles_update_own_admin on public.community_profiles;
create policy community_profiles_update_own_admin on public.community_profiles for update to authenticated
using (public.v61106_is_super_admin() or user_id = auth.uid())
with check (public.v61106_is_super_admin() or user_id = auth.uid());

drop policy if exists community_posts_select_active on public.community_posts;
create policy community_posts_select_active on public.community_posts for select to authenticated
using (public.v61106_is_super_admin() or status = 'active');
drop policy if exists community_posts_insert_member on public.community_posts;
create policy community_posts_insert_member on public.community_posts for insert to authenticated
with check (public.v61106_is_super_admin() or exists (select 1 from public.community_profiles cp where cp.id = author_profile_id and cp.user_id = auth.uid() and cp.suspended_at is null));
drop policy if exists community_posts_update_admin on public.community_posts;
create policy community_posts_update_admin on public.community_posts for update to authenticated
using (public.v61106_is_super_admin()) with check (public.v61106_is_super_admin());

drop policy if exists community_comments_select_active on public.community_comments;
create policy community_comments_select_active on public.community_comments for select to authenticated
using (public.v61106_is_super_admin() or status = 'active');
drop policy if exists community_comments_insert_member on public.community_comments;
create policy community_comments_insert_member on public.community_comments for insert to authenticated
with check (exists (select 1 from public.community_profiles cp where cp.id = author_profile_id and cp.user_id = auth.uid() and cp.suspended_at is null));
drop policy if exists community_comments_update_admin on public.community_comments;
create policy community_comments_update_admin on public.community_comments for update to authenticated
using (public.v61106_is_super_admin()) with check (public.v61106_is_super_admin());

drop policy if exists community_conversations_select_participant on public.community_conversations;
create policy community_conversations_select_participant on public.community_conversations for select to authenticated
using (public.v61106_is_super_admin() or participant_profile_ids @> array[public.v61106_current_community_profile_id()]);
drop policy if exists community_conversations_insert_participant on public.community_conversations;
create policy community_conversations_insert_participant on public.community_conversations for insert to authenticated
with check (created_by_profile_id = public.v61106_current_community_profile_id() and participant_profile_ids @> array[public.v61106_current_community_profile_id()]);
drop policy if exists community_conversations_update_participant on public.community_conversations;
create policy community_conversations_update_participant on public.community_conversations for update to authenticated
using (public.v61106_is_super_admin() or participant_profile_ids @> array[public.v61106_current_community_profile_id()])
with check (public.v61106_is_super_admin() or participant_profile_ids @> array[public.v61106_current_community_profile_id()]);

drop policy if exists community_messages_select_participant on public.community_messages;
create policy community_messages_select_participant on public.community_messages for select to authenticated
using (public.v61106_is_super_admin() or exists (select 1 from public.community_conversations c where c.id = conversation_id and c.participant_profile_ids @> array[public.v61106_current_community_profile_id()]));
drop policy if exists community_messages_insert_participant on public.community_messages;
create policy community_messages_insert_participant on public.community_messages for insert to authenticated
with check (author_profile_id = public.v61106_current_community_profile_id() and exists (select 1 from public.community_conversations c where c.id = conversation_id and c.participant_profile_ids @> array[public.v61106_current_community_profile_id()]));
drop policy if exists community_messages_update_admin on public.community_messages;
create policy community_messages_update_admin on public.community_messages for update to authenticated
using (public.v61106_is_super_admin()) with check (public.v61106_is_super_admin());

drop policy if exists community_blocked_words_admin on public.community_blocked_words;
create policy community_blocked_words_admin on public.community_blocked_words for all to authenticated
using (public.v61106_is_super_admin()) with check (public.v61106_is_super_admin());

drop policy if exists community_reports_select_admin_own on public.community_reports;
create policy community_reports_select_admin_own on public.community_reports for select to authenticated
using (public.v61106_is_super_admin() or reporter_profile_id = public.v61106_current_community_profile_id());
drop policy if exists community_reports_insert_own on public.community_reports;
create policy community_reports_insert_own on public.community_reports for insert to authenticated
with check (reporter_profile_id = public.v61106_current_community_profile_id());
drop policy if exists community_reports_update_admin on public.community_reports;
create policy community_reports_update_admin on public.community_reports for update to authenticated
using (public.v61106_is_super_admin()) with check (public.v61106_is_super_admin());

drop policy if exists community_ad_packages_select on public.community_ad_packages;
create policy community_ad_packages_select on public.community_ad_packages for select to authenticated
using (active = true or public.v61106_is_super_admin());
drop policy if exists community_ad_packages_admin on public.community_ad_packages;
create policy community_ad_packages_admin on public.community_ad_packages for all to authenticated
using (public.v61106_is_super_admin()) with check (public.v61106_is_super_admin());

drop policy if exists community_ad_campaigns_select on public.community_ad_campaigns;
create policy community_ad_campaigns_select on public.community_ad_campaigns for select to authenticated
using (public.v61106_is_super_admin() or status = 'active');
drop policy if exists community_ad_campaigns_admin on public.community_ad_campaigns;
create policy community_ad_campaigns_admin on public.community_ad_campaigns for all to authenticated
using (public.v61106_is_super_admin()) with check (public.v61106_is_super_admin());

drop policy if exists community_ad_impressions_insert on public.community_ad_impressions;
create policy community_ad_impressions_insert on public.community_ad_impressions for insert to authenticated
with check (user_id = auth.uid() or user_id is null);
drop policy if exists community_ad_impressions_admin on public.community_ad_impressions;
create policy community_ad_impressions_admin on public.community_ad_impressions for select to authenticated
using (public.v61106_is_super_admin());
drop policy if exists community_ad_clicks_insert on public.community_ad_clicks;
create policy community_ad_clicks_insert on public.community_ad_clicks for insert to authenticated
with check (user_id = auth.uid() or user_id is null);
drop policy if exists community_ad_clicks_admin on public.community_ad_clicks;
create policy community_ad_clicks_admin on public.community_ad_clicks for select to authenticated
using (public.v61106_is_super_admin());

grant execute on function public.v61106_is_super_admin() to authenticated;
grant execute on function public.v61106_current_community_profile_id() to authenticated;

do $$
begin
  if to_regclass('public.modules') is not null then
    insert into public.modules (name, slug, description, monthly_price, stripe_price_id, is_active)
    values ('Frindly Community','community','Text-only Frindly small business community with public replies, private messages and Community-only sponsored banners.',0,null,true)
    on conflict (slug) do update set
      name = excluded.name,
      description = excluded.description,
      monthly_price = excluded.monthly_price,
      stripe_price_id = excluded.stripe_price_id,
      is_active = true;
  end if;
end $$;
