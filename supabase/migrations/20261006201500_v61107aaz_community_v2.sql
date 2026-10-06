-- Frindly v61.107AAZ — Community V2 only.
create table if not exists public.community_settings (
  id boolean primary key default true check (id),
  auto_post boolean not null default true,
  allow_post_images boolean not null default false,
  posts_per_page integer not null default 20 check (posts_per_page between 5 and 100),
  retention_months integer not null default 12 check (retention_months between 1 and 120),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
insert into public.community_settings(id) values(true) on conflict(id) do nothing;
alter table public.community_settings enable row level security;
drop policy if exists community_settings_read on public.community_settings;
create policy community_settings_read on public.community_settings for select to authenticated using(true);
drop policy if exists community_settings_admin on public.community_settings;
create policy community_settings_admin on public.community_settings for all to authenticated using(public.v61106_is_super_admin()) with check(public.v61106_is_super_admin());

alter table public.community_posts add column if not exists image_url text;
alter table public.community_messages add column if not exists read_at timestamptz;
alter table public.community_ad_campaigns add column if not exists image_url text;
alter table public.community_ad_packages add column if not exists slot_limit integer not null default 1;
alter table public.community_ad_packages drop constraint if exists community_ad_packages_slot_limit_check;
alter table public.community_ad_packages add constraint community_ad_packages_slot_limit_check check(slot_limit between 1 and 20);

alter table public.community_posts drop constraint if exists community_posts_status;
alter table public.community_posts add constraint community_posts_status check(status in ('pending','active','hidden','archived','deleted'));

drop policy if exists community_messages_update_participant on public.community_messages;
create policy community_messages_update_participant on public.community_messages for update to authenticated
using (exists(select 1 from public.community_conversations c where c.id=conversation_id and c.participant_profile_ids @> array[public.v61106_current_community_profile_id()]))
with check (exists(select 1 from public.community_conversations c where c.id=conversation_id and c.participant_profile_ids @> array[public.v61106_current_community_profile_id()]));

drop policy if exists community_posts_delete_admin on public.community_posts;
create policy community_posts_delete_admin on public.community_posts for delete to authenticated using(public.v61106_is_super_admin());

do $$ begin
  insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  values('community-media','community-media',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
  on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp','image/gif'];
exception when undefined_table then null; end $$;

do $$ begin
  drop policy if exists community_media_insert on storage.objects;
  create policy community_media_insert on storage.objects for insert to authenticated
  with check(bucket_id='community-media' and (storage.foldername(name))[1]=auth.uid()::text);
  drop policy if exists community_media_update on storage.objects;
  create policy community_media_update on storage.objects for update to authenticated
  using(bucket_id='community-media' and ((storage.foldername(name))[1]=auth.uid()::text or public.v61106_is_super_admin()));
  drop policy if exists community_media_delete on storage.objects;
  create policy community_media_delete on storage.objects for delete to authenticated
  using(bucket_id='community-media' and ((storage.foldername(name))[1]=auth.uid()::text or public.v61106_is_super_admin()));
exception when undefined_table then null; end $$;

-- Sample editable price matrix. Existing custom packages are preserved.
insert into public.community_ad_packages(name,price,currency,duration_days,placement,slot_limit,active)
values
('Premium Top Banner — 1 month',149,'NZD',30,'top',1,true),('Premium Top Banner — 3 months',399,'NZD',90,'top',1,true),('Premium Top Banner — 6 months',699,'NZD',180,'top',1,true),('Premium Top Banner — 12 months',1199,'NZD',365,'top',1,true),
('Featured Partner — 1 month',99,'NZD',30,'sidebar',2,true),('Featured Partner — 3 months',269,'NZD',90,'sidebar',2,true),('Featured Partner — 6 months',479,'NZD',180,'sidebar',2,true),('Featured Partner — 12 months',799,'NZD',365,'sidebar',2,true),
('Sponsored Feed — 1 month',79,'NZD',30,'feed',3,true),('Sponsored Feed — 3 months',209,'NZD',90,'feed',3,true),('Sponsored Feed — 6 months',369,'NZD',180,'feed',3,true),('Sponsored Feed — 12 months',599,'NZD',365,'feed',3,true),
('Community Sponsor — 1 month',49,'NZD',30,'inbox',2,true),('Community Sponsor — 3 months',129,'NZD',90,'inbox',2,true),('Community Sponsor — 6 months',229,'NZD',180,'inbox',2,true),('Community Sponsor — 12 months',399,'NZD',365,'inbox',2,true)
on conflict do nothing;

-- Sample ads are clearly labelled and can be edited/deleted by Super Admin.
insert into public.community_ad_campaigns(sponsor_type,sponsor_name,title,body,destination_url,placement,price_charged,currency,payment_status,status,priority,starts_at,ends_at,created_at,updated_at)
select 'external','Frindly Sample','Grow your business with Frindly','Sample premium banner — replace this with a paid advertiser.','https://frindly.co.nz','top',0,'NZD','manual','active',-100,now(),now()+interval '30 days',now(),now()
where not exists(select 1 from public.community_ad_campaigns where sponsor_name='Frindly Sample' and placement='top');
insert into public.community_ad_campaigns(sponsor_type,sponsor_name,title,body,destination_url,placement,price_charged,currency,payment_status,status,priority,starts_at,ends_at,created_at,updated_at)
select 'external','Wellington Business Hub','Local businesses, stronger together','Sample Featured Partner advertisement.','https://frindly.co.nz','sidebar',0,'NZD','manual','active',-100,now(),now()+interval '30 days',now(),now()
where not exists(select 1 from public.community_ad_campaigns where sponsor_name='Wellington Business Hub');
insert into public.community_ad_campaigns(sponsor_type,sponsor_name,title,body,destination_url,placement,price_charged,currency,payment_status,status,priority,starts_at,ends_at,created_at,updated_at)
select 'external','Small Business Support','Tools for growing teams','Sample sponsored feed advertisement.','https://frindly.co.nz','feed',0,'NZD','manual','active',-100,now(),now()+interval '30 days',now(),now()
where not exists(select 1 from public.community_ad_campaigns where sponsor_name='Small Business Support');
insert into public.community_ad_campaigns(sponsor_type,sponsor_name,title,body,destination_url,placement,price_charged,currency,payment_status,status,priority,starts_at,ends_at,created_at,updated_at)
select 'external','Community Partner','Supporting Frindly businesses','Sample compact Community Sponsor.','https://frindly.co.nz','inbox',0,'NZD','manual','active',-100,now(),now()+interval '30 days',now(),now()
where not exists(select 1 from public.community_ad_campaigns where sponsor_name='Community Partner');
