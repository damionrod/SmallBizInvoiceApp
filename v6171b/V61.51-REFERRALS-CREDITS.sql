-- Finlo V61.51 Referral, Campaign & Credit system
-- Additive only. Existing billing charges are intentionally unchanged.
create extension if not exists pgcrypto;

create table if not exists public.referral_campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  active boolean not null default false,
  start_date timestamptz not null default now(),
  end_date timestamptz,
  nav_label text not null default 'Share the love & Save',
  referral_page_title text not null default 'Refer & Save',
  promo_text text not null default 'Invite another business to Finlo and earn Finlo credit when they qualify.',
  email_heading text not null default 'You''ve been invited to Finlo',
  email_text text not null default 'Join Finlo through this invitation.',
  qualification_event text not null default 'first_successful_payment' check (qualification_event in ('signup_completed','email_verified','subscription_activated','first_successful_payment')),
  credit_expiry_days integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists referral_campaigns_one_active on public.referral_campaigns ((active)) where active=true;

create table if not exists public.referral_campaign_versions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.referral_campaigns(id) on delete cascade,
  version integer not null,
  referrer_reward_type text not null default 'month_equivalent' check (referrer_reward_type in ('month_equivalent','fixed_credit','percent_month','free_months','none')),
  referrer_reward_value numeric(12,4) not null default 1,
  referee_reward_enabled boolean not null default false,
  referee_reward_type text not null default 'month_equivalent' check (referee_reward_type in ('month_equivalent','fixed_credit','percent_month','free_months','none')),
  referee_reward_value numeric(12,4) not null default 1,
  effective_from timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(campaign_id,version)
);

create table if not exists public.business_referral_codes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique references public.businesses(id) on delete cascade,
  referral_code text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.business_referral_settings (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  show_nav_shortcut boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.referral_invites (
  id uuid primary key default gen_random_uuid(),
  referring_business_id uuid not null references public.businesses(id) on delete cascade,
  invited_email text not null,
  referral_code text not null,
  campaign_id uuid not null references public.referral_campaigns(id),
  campaign_version_id uuid not null references public.referral_campaign_versions(id),
  sent_by_user_id uuid references auth.users(id) on delete set null,
  token_hash text not null unique,
  status text not null default 'invited' check (status in ('invited','signed_up','pending_qualification','qualified','reward_issued','rejected','cancelled','failed')),
  sent_at timestamptz not null default now(),
  last_sent_at timestamptz not null default now(),
  resend_count integer not null default 0,
  signup_at timestamptz,
  referred_business_id uuid references public.businesses(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists referral_invites_business_email_idx on public.referral_invites(referring_business_id,lower(invited_email),created_at desc);
create index if not exists referral_invites_sent_by_idx on public.referral_invites(sent_by_user_id,sent_at desc);

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referring_business_id uuid not null references public.businesses(id) on delete restrict,
  referred_business_id uuid not null unique references public.businesses(id) on delete restrict,
  referred_user_id uuid references auth.users(id) on delete set null,
  invite_id uuid references public.referral_invites(id) on delete set null,
  campaign_id uuid not null references public.referral_campaigns(id),
  campaign_version_id uuid not null references public.referral_campaign_versions(id),
  signup_at timestamptz not null default now(),
  qualified_at timestamptz,
  reward_issued_at timestamptz,
  status text not null default 'signed_up' check (status in ('signed_up','pending_qualification','qualified','reward_issued','rejected','cancelled')),
  fraud_flag boolean not null default false,
  fraud_note text,
  reward_snapshot jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists referrals_referring_business_idx on public.referrals(referring_business_id,created_at desc);

create table if not exists public.business_credits (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  referral_id uuid references public.referrals(id) on delete set null,
  campaign_id uuid references public.referral_campaigns(id) on delete set null,
  campaign_version_id uuid references public.referral_campaign_versions(id) on delete set null,
  credit_type text not null,
  beneficiary text,
  amount numeric(12,2) not null check (amount <> 0),
  currency text not null default 'NZD',
  status text not null default 'available' check (status in ('pending','available','redeemed','expired','revoked')),
  issued_at timestamptz not null default now(),
  applied_at timestamptz,
  expires_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  notes text,
  reward_snapshot jsonb,
  created_at timestamptz not null default now()
);
create unique index if not exists business_credits_referral_beneficiary_unique on public.business_credits(referral_id,beneficiary) where referral_id is not null and beneficiary in ('referrer','referee');
create index if not exists business_credits_business_idx on public.business_credits(business_id,created_at desc);

create table if not exists public.referral_audit_log (
  id uuid primary key default gen_random_uuid(),
  referral_id uuid references public.referrals(id) on delete cascade,
  credit_id uuid references public.business_credits(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.referral_campaigns enable row level security;
alter table public.referral_campaign_versions enable row level security;
alter table public.business_referral_codes enable row level security;
alter table public.business_referral_settings enable row level security;
alter table public.referral_invites enable row level security;
alter table public.referrals enable row level security;
alter table public.business_credits enable row level security;
alter table public.referral_audit_log enable row level security;

-- No direct browser writes. All writes go through protected RPCs/Edge Functions.
revoke all on public.referral_campaigns, public.referral_campaign_versions, public.business_referral_codes, public.business_referral_settings, public.referral_invites, public.referrals, public.business_credits, public.referral_audit_log from anon, authenticated;
grant select on public.referral_campaigns, public.referral_campaign_versions to authenticated;

create policy v6151_campaign_read on public.referral_campaigns for select to authenticated using (active=true or public.is_super_admin());
create policy v6151_campaign_version_read on public.referral_campaign_versions for select to authenticated using (exists(select 1 from public.referral_campaigns c where c.id=campaign_id and (c.active=true or public.is_super_admin())));
create policy v6151_codes_read on public.business_referral_codes for select to authenticated using (business_id=public.current_business_id() and public.has_active_business_membership(business_id) or public.is_super_admin());
create policy v6151_settings_read on public.business_referral_settings for select to authenticated using (business_id=public.current_business_id() and public.has_active_business_membership(business_id) or public.is_super_admin());
create policy v6151_invites_read on public.referral_invites for select to authenticated using (referring_business_id=public.current_business_id() and public.has_active_business_membership(referring_business_id) or public.is_super_admin());
create policy v6151_referrals_read on public.referrals for select to authenticated using ((referring_business_id=public.current_business_id() and public.has_active_business_membership(referring_business_id)) or public.is_super_admin());
create policy v6151_credits_read on public.business_credits for select to authenticated using ((business_id=public.current_business_id() and public.has_active_business_membership(business_id)) or public.is_super_admin());
create policy v6151_audit_admin_read on public.referral_audit_log for select to authenticated using (public.is_super_admin());

grant select on public.business_referral_codes, public.business_referral_settings, public.referral_invites, public.referrals, public.business_credits to authenticated;

create or replace function public.v6151_get_or_create_referral_code(p_business_id uuid)
returns text language plpgsql security definer set search_path=public,extensions as $$
declare v_code text;
begin
  select referral_code into v_code from public.business_referral_codes where business_id=p_business_id and active=true;
  if v_code is not null then return v_code; end if;
  loop
    v_code:=upper(substr(encode(extensions.gen_random_bytes(6),'hex'),1,10));
    begin
      insert into public.business_referral_codes(business_id,referral_code) values(p_business_id,v_code);
      exit;
    exception when unique_violation then
      select referral_code into v_code from public.business_referral_codes where business_id=p_business_id;
      if v_code is not null then exit; end if;
    end;
  end loop;
  return v_code;
end $$;
revoke all on function public.v6151_get_or_create_referral_code(uuid) from public,anon,authenticated;

create or replace function public.v6151_reward_amount(p_business_id uuid,p_type text,p_value numeric)
returns numeric language plpgsql stable security definer set search_path=public as $$
declare v_month numeric:=0;
begin
  select coalesce(pl.monthly_price,0) into v_month from public.subscriptions s join public.plans pl on pl.id=s.plan_id where s.business_id=p_business_id limit 1;
  return round(case p_type when 'month_equivalent' then v_month when 'fixed_credit' then p_value when 'percent_month' then v_month*(p_value/100.0) when 'free_months' then v_month*p_value else 0 end,2);
end $$;
revoke all on function public.v6151_reward_amount(uuid,text,numeric) from public,anon,authenticated;

create or replace function public.v6151_issue_referral_rewards_internal(p_referral_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.referrals%rowtype; v public.referral_campaign_versions%rowtype; c public.referral_campaigns%rowtype; a numeric; b numeric; exp_at timestamptz; snap jsonb;
begin
  select * into r from public.referrals where id=p_referral_id for update;
  if not found or r.status in ('reward_issued','rejected','cancelled') then return; end if;
  select * into v from public.referral_campaign_versions where id=r.campaign_version_id;
  select * into c from public.referral_campaigns where id=r.campaign_id;
  a:=public.v6151_reward_amount(r.referring_business_id,v.referrer_reward_type,v.referrer_reward_value);
  b:=case when v.referee_reward_enabled then public.v6151_reward_amount(r.referred_business_id,v.referee_reward_type,v.referee_reward_value) else 0 end;
  exp_at:=case when c.credit_expiry_days is null then null else now()+(c.credit_expiry_days||' days')::interval end;
  snap:=jsonb_build_object('campaign_id',r.campaign_id,'campaign_version_id',r.campaign_version_id,'campaign_name',c.name,'version',v.version,'referrer_reward_type',v.referrer_reward_type,'referrer_reward_value',v.referrer_reward_value,'referee_reward_enabled',v.referee_reward_enabled,'referee_reward_type',v.referee_reward_type,'referee_reward_value',v.referee_reward_value,'qualified_at',now());
  if a>0 then insert into public.business_credits(business_id,referral_id,campaign_id,campaign_version_id,credit_type,beneficiary,amount,status,expires_at,notes,reward_snapshot) values(r.referring_business_id,r.id,r.campaign_id,r.campaign_version_id,'referral_reward','referrer',a,'available',exp_at,'Referral reward',snap) on conflict do nothing; end if;
  if b>0 then insert into public.business_credits(business_id,referral_id,campaign_id,campaign_version_id,credit_type,beneficiary,amount,status,expires_at,notes,reward_snapshot) values(r.referred_business_id,r.id,r.campaign_id,r.campaign_version_id,'referral_reward','referee',b,'available',exp_at,'Referred business reward',snap) on conflict do nothing; end if;
  update public.referrals set status='reward_issued',reward_issued_at=coalesce(reward_issued_at,now()),reward_snapshot=coalesce(reward_snapshot,snap),updated_at=now() where id=r.id;
  update public.referral_invites set status='reward_issued',updated_at=now() where id=r.invite_id;
  insert into public.referral_audit_log(referral_id,action,details) values(r.id,'reward_issued',jsonb_build_object('referrer_credit',a,'referee_credit',b,'snapshot',snap));
end $$;
revoke all on function public.v6151_issue_referral_rewards_internal(uuid) from public,anon,authenticated;

create or replace function public.v6151_process_referral_event_internal(p_business_id uuid,p_event text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.referrals%rowtype; c public.referral_campaigns%rowtype;
begin
  select * into r from public.referrals where referred_business_id=p_business_id and status not in ('reward_issued','rejected','cancelled') for update;
  if not found then return; end if;
  select * into c from public.referral_campaigns where id=r.campaign_id;
  if c.qualification_event<>p_event then
    if r.status='signed_up' then update public.referrals set status='pending_qualification',updated_at=now() where id=r.id; end if;
    return;
  end if;
  update public.referrals set status='qualified',qualified_at=coalesce(qualified_at,now()),updated_at=now() where id=r.id;
  update public.referral_invites set status='qualified',updated_at=now() where id=r.invite_id;
  insert into public.referral_audit_log(referral_id,action,details) values(r.id,'qualified',jsonb_build_object('event',p_event));
  perform public.v6151_issue_referral_rewards_internal(r.id);
end $$;
revoke all on function public.v6151_process_referral_event_internal(uuid,text) from public,anon,authenticated;

create or replace function public.v6151_process_referral_event(p_business_id uuid,p_event text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'')<>'service_role' and not public.is_super_admin() then raise exception 'Not authorised'; end if;
  if p_event not in ('signup_completed','email_verified','subscription_activated','first_successful_payment') then raise exception 'Invalid referral event'; end if;
  perform public.v6151_process_referral_event_internal(p_business_id,p_event); return true;
end $$;
revoke all on function public.v6151_process_referral_event(uuid,text) from public,anon,authenticated;
grant execute on function public.v6151_process_referral_event(uuid,text) to service_role;

create or replace function public.v6151_register_referral_signup_internal(p_business_id uuid,p_user_id uuid,p_email text,p_code text,p_invite_token text)
returns void language plpgsql security definer set search_path=public,extensions as $$
declare rc public.business_referral_codes%rowtype; inv public.referral_invites%rowtype; camp public.referral_campaigns%rowtype; ver public.referral_campaign_versions%rowtype; ih text; rid uuid;
begin
  if coalesce(nullif(p_code,''),'')='' then return; end if;
  select * into rc from public.business_referral_codes where referral_code=upper(p_code) and active=true;
  if not found or rc.business_id=p_business_id then return; end if;
  if exists(select 1 from public.referrals where referred_business_id=p_business_id) then return; end if;
  if p_invite_token is not null and p_invite_token<>'' then
    ih:=encode(extensions.digest(p_invite_token,'sha256'),'hex');
    select * into inv from public.referral_invites where token_hash=ih and referring_business_id=rc.business_id and status in ('invited','pending_qualification') and lower(invited_email)=lower(p_email) order by created_at desc limit 1;
  end if;
  if found then
    select * into camp from public.referral_campaigns where id=inv.campaign_id;
    select * into ver from public.referral_campaign_versions where id=inv.campaign_version_id;
  else
    select * into camp from public.referral_campaigns where active=true and start_date<=now() and (end_date is null or end_date>now()) order by start_date desc limit 1;
    if not found then return; end if;
    select * into ver from public.referral_campaign_versions where campaign_id=camp.id and effective_from<=now() order by version desc limit 1;
    if not found then return; end if;
  end if;
  insert into public.referrals(referring_business_id,referred_business_id,referred_user_id,invite_id,campaign_id,campaign_version_id,signup_at,status)
  values(rc.business_id,p_business_id,p_user_id,case when inv.id is null then null else inv.id end,camp.id,ver.id,now(),'signed_up') returning id into rid;
  if inv.id is not null then update public.referral_invites set status='signed_up',signup_at=now(),referred_business_id=p_business_id,updated_at=now() where id=inv.id; end if;
  insert into public.referral_audit_log(referral_id,action,details) values(rid,'signup',jsonb_build_object('email',p_email,'referral_code',rc.referral_code));
  perform public.v6151_process_referral_event_internal(p_business_id,'signup_completed');
end $$;
revoke all on function public.v6151_register_referral_signup_internal(uuid,uuid,text,text,text) from public,anon,authenticated;

-- Preserve existing team-invite signup flow, adding referral attribution only for new businesses.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public,auth,extensions as $$
declare
  b_id uuid; trial_plan uuid; trial_modules text[]; business_name text; invite_token text; invite_hash text; inv public.business_invites%rowtype; ref_code text; ref_invite_token text;
begin
  invite_token := nullif(new.raw_user_meta_data->>'business_invite_token','');
  if invite_token is not null then
    invite_hash := encode(extensions.digest(invite_token,'sha256'),'hex');
    select * into inv from public.business_invites bi where bi.token_hash=invite_hash and bi.status='pending' and bi.expires_at>now() and lower(bi.email)=lower(new.email) for update;
    if found then
      insert into public.profiles(id,business_id,active_business_id,full_name,email,role) values(new.id,inv.business_id,inv.business_id,new.raw_user_meta_data->>'full_name',new.email,'member');
      insert into public.business_memberships(business_id,user_id,role,status,invited_by,joined_at) values(inv.business_id,new.id,inv.role,'active',inv.invited_by,now()) on conflict (business_id,user_id) do update set role=excluded.role,status='active',invited_by=excluded.invited_by,joined_at=coalesce(public.business_memberships.joined_at,now()),updated_at=now();
      update public.business_invites set status='accepted',accepted_at=now(),updated_at=now() where id=inv.id;
      return new;
    end if;
    raise exception 'This business invitation is invalid, expired, or does not match this email address.';
  end if;
  business_name := coalesce(nullif(new.raw_user_meta_data->>'business_name',''), split_part(new.email,'@',1), 'My Business');
  insert into public.businesses(name,address,phone) values (business_name,new.raw_user_meta_data->>'business_address',new.raw_user_meta_data->>'phone') returning id into b_id;
  insert into public.profiles(id,business_id,active_business_id,full_name,email,role) values (new.id,b_id,b_id,new.raw_user_meta_data->>'full_name',new.email,'owner');
  insert into public.business_memberships(business_id,user_id,role,status,joined_at) values (b_id,new.id,'owner','active',now()) on conflict (business_id,user_id) do nothing;
  select id,included_modules into trial_plan,trial_modules from public.plans where slug='trial' limit 1;
  insert into public.subscriptions(business_id,plan_id,status,trial_ends_at,current_period_start,current_period_end) values (b_id,trial_plan,'trialing',now()+interval '14 days',now(),now()+interval '14 days');
  insert into public.business_modules(business_id,module_id,status,trial_ends_at) select b_id,m.id,'trialing',now()+interval '14 days' from public.modules m where m.slug=any(coalesce(trial_modules,array['invoice_manager']::text[])) on conflict do nothing;
  ref_code:=nullif(new.raw_user_meta_data->>'referral_code',''); ref_invite_token:=nullif(new.raw_user_meta_data->>'referral_invite_token','');
  if ref_code is not null then perform public.v6151_register_referral_signup_internal(b_id,new.id,new.email,ref_code,ref_invite_token); end if;
  return new;
end $$;

create or replace function public.v6151_auth_email_verified()
returns trigger language plpgsql security definer set search_path=public,auth as $$
declare bid uuid;
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    select coalesce(active_business_id,business_id) into bid from public.profiles where id=new.id;
    if bid is not null then perform public.v6151_process_referral_event_internal(bid,'email_verified'); end if;
  end if;
  return new;
end $$;
revoke all on function public.v6151_auth_email_verified() from public,anon,authenticated;
drop trigger if exists v6151_auth_email_verified on auth.users;
create trigger v6151_auth_email_verified after insert or update of email_confirmed_at on auth.users for each row execute function public.v6151_auth_email_verified();

create or replace function public.v6151_referral_portal()
returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=public.current_business_id(); camp public.referral_campaigns%rowtype; code text; toggle boolean:=true; hist jsonb; bal numeric; success int; v_role text;
begin
  if auth.uid() is null or bid is null or not public.has_active_business_membership(bid) then raise exception 'Active business membership required'; end if;
  select bm.role into v_role from public.business_memberships bm where bm.business_id=bid and bm.user_id=auth.uid() and bm.status='active';
  select * into camp from public.referral_campaigns where active=true and start_date<=now() and (end_date is null or end_date>now()) order by start_date desc limit 1;
  if not found then return jsonb_build_object('active',false); end if;
  code:=public.v6151_get_or_create_referral_code(bid);
  select coalesce(show_nav_shortcut,true) into toggle from public.business_referral_settings where business_id=bid;
  select coalesce(sum(amount),0) into bal from public.business_credits where business_id=bid and status='available' and (expires_at is null or expires_at>now());
  select count(*) into success from public.referrals where referring_business_id=bid and status in ('qualified','reward_issued');
  select coalesce(jsonb_agg(x order by x.sent_at desc),'[]'::jsonb) into hist from (
    select i.id,i.invited_email as email,i.status,i.sent_at,i.last_sent_at,r.qualified_at,coalesce((select sum(amount) from public.business_credits bc where bc.referral_id=r.id and bc.business_id=bid and bc.beneficiary='referrer'),0) reward
    from public.referral_invites i left join public.referrals r on r.invite_id=i.id where i.referring_business_id=bid order by i.sent_at desc limit 25
  ) x;
  return jsonb_build_object('active',true,'campaignId',camp.id,'navLabel',camp.nav_label,'title',camp.referral_page_title,'promoText',camp.promo_text,'code',code,'showShortcut',toggle,'canManageToggle',v_role in ('owner','admin') or public.is_super_admin(),'successfulReferrals',success,'availableCredit',bal,'history',hist);
end $$;
revoke all on function public.v6151_referral_portal() from public,anon;
grant execute on function public.v6151_referral_portal() to authenticated;

create or replace function public.v6151_set_referral_shortcut(p_show boolean)
returns boolean language plpgsql security definer set search_path=public as $$
declare bid uuid:=public.current_business_id();
begin
  if not public.v6145_can_manage_team(bid) then raise exception 'Owner or Admin access required'; end if;
  insert into public.business_referral_settings(business_id,show_nav_shortcut,updated_by,updated_at) values(bid,p_show,auth.uid(),now()) on conflict(business_id) do update set show_nav_shortcut=excluded.show_nav_shortcut,updated_by=excluded.updated_by,updated_at=now(); return true;
end $$;
revoke all on function public.v6151_set_referral_shortcut(boolean) from public,anon;
grant execute on function public.v6151_set_referral_shortcut(boolean) to authenticated;

create or replace function public.v6151_admin_save_campaign(p_campaign_id uuid,p_name text,p_active boolean,p_start timestamptz,p_end timestamptz,p_nav_label text,p_title text,p_promo text,p_email_heading text,p_email_text text,p_qualification text,p_expiry_days int,p_ref_type text,p_ref_value numeric,p_new_enabled boolean,p_new_type text,p_new_value numeric)
returns uuid language plpgsql security definer set search_path=public as $$
declare cid uuid; ver int;
begin
  if not public.is_super_admin() then raise exception 'Super Admin required'; end if;
  if p_qualification not in ('signup_completed','email_verified','subscription_activated','first_successful_payment') then raise exception 'Invalid qualification event'; end if;
  if p_ref_type not in ('month_equivalent','fixed_credit','percent_month','free_months','none') or p_new_type not in ('month_equivalent','fixed_credit','percent_month','free_months','none') then raise exception 'Invalid reward type'; end if;
  if p_active then update public.referral_campaigns set active=false,updated_at=now() where active=true and id<>coalesce(p_campaign_id,'00000000-0000-0000-0000-000000000000'::uuid); end if;
  if p_campaign_id is null then
    insert into public.referral_campaigns(name,active,start_date,end_date,nav_label,referral_page_title,promo_text,email_heading,email_text,qualification_event,credit_expiry_days) values(p_name,p_active,coalesce(p_start,now()),p_end,p_nav_label,p_title,p_promo,p_email_heading,p_email_text,p_qualification,p_expiry_days) returning id into cid;
  else
    update public.referral_campaigns set name=p_name,active=p_active,start_date=coalesce(p_start,start_date),end_date=p_end,nav_label=p_nav_label,referral_page_title=p_title,promo_text=p_promo,email_heading=p_email_heading,email_text=p_email_text,qualification_event=p_qualification,credit_expiry_days=p_expiry_days,updated_at=now() where id=p_campaign_id returning id into cid;
  end if;
  select coalesce(max(version),0)+1 into ver from public.referral_campaign_versions where campaign_id=cid;
  insert into public.referral_campaign_versions(campaign_id,version,referrer_reward_type,referrer_reward_value,referee_reward_enabled,referee_reward_type,referee_reward_value,created_by) values(cid,ver,p_ref_type,coalesce(p_ref_value,0),p_new_enabled,p_new_type,coalesce(p_new_value,0),auth.uid());
  return cid;
end $$;
revoke all on function public.v6151_admin_save_campaign(uuid,text,boolean,timestamptz,timestamptz,text,text,text,text,text,text,int,text,numeric,boolean,text,numeric) from public,anon;
grant execute on function public.v6151_admin_save_campaign(uuid,text,boolean,timestamptz,timestamptz,text,text,text,text,text,text,int,text,numeric,boolean,text,numeric) to authenticated;

create or replace function public.v6151_admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if not public.is_super_admin() then raise exception 'Super Admin required'; end if;
 return jsonb_build_object(
  'invitations',(select count(*) from public.referral_invites),
  'signups',(select count(*) from public.referrals),
  'successful',(select count(*) from public.referrals where status in ('qualified','reward_issued')),
  'creditsIssued',(select coalesce(sum(amount),0) from public.business_credits where amount>0 and status<>'revoked'),
  'creditsRedeemed',(select abs(coalesce(sum(amount),0)) from public.business_credits where amount<0 and status<>'revoked'),
  'outstanding',(select coalesce(sum(amount),0) from public.business_credits where status='available' and (expires_at is null or expires_at>now())),
  'campaigns',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) from (select c.*,v.id version_id,v.version,v.referrer_reward_type,v.referrer_reward_value,v.referee_reward_enabled,v.referee_reward_type,v.referee_reward_value from public.referral_campaigns c left join lateral(select * from public.referral_campaign_versions vv where vv.campaign_id=c.id order by vv.version desc limit 1)v on true)x),
  'referrals',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) from (select r.id,r.status,r.signup_at,r.qualified_at,r.reward_issued_at,r.fraud_flag,rb.name referring_business,nb.name referred_business,i.invited_email,p.full_name sending_user,c.name campaign,r.reward_snapshot from public.referrals r join public.businesses rb on rb.id=r.referring_business_id join public.businesses nb on nb.id=r.referred_business_id left join public.referral_invites i on i.id=r.invite_id left join public.profiles p on p.id=i.sent_by_user_id left join public.referral_campaigns c on c.id=r.campaign_id order by r.created_at desc limit 500)x),
  'credits',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) from (select bc.*,b.name business_name from public.business_credits bc join public.businesses b on b.id=bc.business_id order by bc.created_at desc limit 500)x)
 );
end $$;
revoke all on function public.v6151_admin_dashboard() from public,anon;
grant execute on function public.v6151_admin_dashboard() to authenticated;

create or replace function public.v6151_admin_manual_credit(p_business_id uuid,p_amount numeric,p_note text)
returns uuid language plpgsql security definer set search_path=public as $$
declare cid uuid;
begin
 if not public.is_super_admin() then raise exception 'Super Admin required'; end if;
 if p_amount=0 then raise exception 'Amount cannot be zero'; end if;
 insert into public.business_credits(business_id,credit_type,amount,status,created_by,notes) values(p_business_id,'manual_adjustment',round(p_amount,2),'available',auth.uid(),nullif(p_note,'')) returning id into cid;
 insert into public.referral_audit_log(credit_id,actor_user_id,action,details) values(cid,auth.uid(),'manual_credit',jsonb_build_object('amount',round(p_amount,2),'note',p_note)); return cid;
end $$;
revoke all on function public.v6151_admin_manual_credit(uuid,numeric,text) from public,anon;
grant execute on function public.v6151_admin_manual_credit(uuid,numeric,text) to authenticated;

create or replace function public.v6151_admin_update_credit(p_credit_id uuid,p_action text,p_note text,p_expiry timestamptz)
returns boolean language plpgsql security definer set search_path=public as $$
declare old_status text; old_exp timestamptz;
begin
 if not public.is_super_admin() then raise exception 'Super Admin required'; end if;
 select status,expires_at into old_status,old_exp from public.business_credits where id=p_credit_id for update; if not found then raise exception 'Credit not found'; end if;
 if p_action='revoke' then update public.business_credits set status='revoked',notes=concat_ws(' · ',notes,p_note) where id=p_credit_id and status='available';
 elsif p_action='extend' then update public.business_credits set expires_at=p_expiry,notes=concat_ws(' · ',notes,p_note) where id=p_credit_id;
 else raise exception 'Invalid credit action'; end if;
 insert into public.referral_audit_log(credit_id,actor_user_id,action,details) values(p_credit_id,auth.uid(),p_action,jsonb_build_object('note',p_note,'previous_status',old_status,'previous_expiry',old_exp,'new_expiry',p_expiry)); return true;
end $$;
revoke all on function public.v6151_admin_update_credit(uuid,text,text,timestamptz) from public,anon;
grant execute on function public.v6151_admin_update_credit(uuid,text,text,timestamptz) to authenticated;

-- Seed a safe default campaign if none exists. This is configurable immediately in Super Admin.
do $$ declare cid uuid; begin
 if not exists(select 1 from public.referral_campaigns) then
  insert into public.referral_campaigns(name,active,nav_label,referral_page_title,promo_text,qualification_event) values('Launch Referral Campaign',true,'Share the love & Save','Refer & Save','Invite another business to Finlo and earn Finlo credit when they qualify.','first_successful_payment') returning id into cid;
  insert into public.referral_campaign_versions(campaign_id,version,referrer_reward_type,referrer_reward_value,referee_reward_enabled,referee_reward_type,referee_reward_value) values(cid,1,'month_equivalent',1,false,'month_equivalent',1);
 end if;
end $$;

notify pgrst, 'reload schema';


-- V61.51 final compatibility overrides (matches applied follow-up migrations)
create or replace function public.v6151_referral_portal()
returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=public.current_business_id(); camp public.referral_campaigns%rowtype; code text; toggle boolean:=true; hist jsonb; bal numeric; success int; v_role text; has_campaign boolean:=false;
begin
  if auth.uid() is null or bid is null or not public.has_active_business_membership(bid) then raise exception 'Active business membership required'; end if;
  select bm.role into v_role from public.business_memberships bm where bm.business_id=bid and bm.user_id=auth.uid() and bm.status='active';
  select * into camp from public.referral_campaigns where active=true and start_date<=now() and (end_date is null or end_date>now()) order by start_date desc limit 1;
  has_campaign:=found;
  code:=public.v6151_get_or_create_referral_code(bid);
  select coalesce(show_nav_shortcut,true) into toggle from public.business_referral_settings where business_id=bid;
  select coalesce(sum(amount),0) into bal from public.business_credits where business_id=bid and status='available' and (expires_at is null or expires_at>now());
  select count(*) into success from public.referrals where referring_business_id=bid and status in ('qualified','reward_issued');
  select coalesce(jsonb_agg(x order by x.sent_at desc),'[]'::jsonb) into hist from (
    select i.id,i.invited_email as email,i.status,i.sent_at,i.last_sent_at,r.qualified_at,coalesce((select sum(amount) from public.business_credits bc where bc.referral_id=r.id and bc.business_id=bid and bc.beneficiary='referrer' and bc.status<>'revoked'),0) reward
    from public.referral_invites i left join public.referrals r on r.invite_id=i.id where i.referring_business_id=bid order by i.sent_at desc limit 25
  ) x;
  return jsonb_build_object('active',has_campaign,'campaignId',case when has_campaign then camp.id else null end,'navLabel',coalesce(camp.nav_label,'Share the love & Save'),'title',coalesce(camp.referral_page_title,'Refer & Save'),'promoText',coalesce(camp.promo_text,'Referral invitations are currently paused. Your history and earned Finlo credit are preserved.'),'code',code,'showShortcut',has_campaign and toggle,'canManageToggle',v_role in ('owner','admin') or public.is_super_admin(),'successfulReferrals',success,'availableCredit',bal,'history',hist);
end $$;
revoke all on function public.v6151_referral_portal() from public,anon;
grant execute on function public.v6151_referral_portal() to authenticated;

create or replace function public.v6151_auth_email_verified()
returns trigger language plpgsql security definer set search_path=public,auth as $$
declare bid uuid; should_process boolean:=false;
begin
  should_process := (tg_op='INSERT' and new.email_confirmed_at is not null) or (tg_op='UPDATE' and old.email_confirmed_at is null and new.email_confirmed_at is not null);
  if should_process then
    select coalesce(active_business_id,business_id) into bid from public.profiles where id=new.id;
    if bid is not null then perform public.v6151_process_referral_event_internal(bid,'email_verified'); end if;
  end if;
  return new;
end $$;
revoke all on function public.v6151_auth_email_verified() from public,anon,authenticated;
drop trigger if exists v6151_auth_email_verified on auth.users;
create trigger v6151_auth_email_verified after insert or update of email_confirmed_at on auth.users for each row execute function public.v6151_auth_email_verified();

create or replace function public.v6151_admin_referral_action(p_referral_id uuid,p_action text,p_note text default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare r public.referrals%rowtype;
begin
 if not public.is_super_admin() then raise exception 'Super Admin required'; end if;
 select * into r from public.referrals where id=p_referral_id for update; if not found then raise exception 'Referral not found'; end if;
 if p_action='qualify' then
   update public.referrals set status='qualified',qualified_at=coalesce(qualified_at,now()),updated_at=now() where id=p_referral_id;
   update public.referral_invites set status='qualified',updated_at=now() where id=r.invite_id;
   insert into public.referral_audit_log(referral_id,actor_user_id,action,details) values(p_referral_id,auth.uid(),'manual_qualified',jsonb_build_object('note',p_note));
   perform public.v6151_issue_referral_rewards_internal(p_referral_id);
 elsif p_action='reject' then
   if r.status='reward_issued' then raise exception 'Issued rewards must be handled through credit revocation, not referral rejection'; end if;
   update public.referrals set status='rejected',updated_at=now() where id=p_referral_id;
   update public.referral_invites set status='rejected',updated_at=now() where id=r.invite_id;
   insert into public.referral_audit_log(referral_id,actor_user_id,action,details) values(p_referral_id,auth.uid(),'rejected',jsonb_build_object('note',p_note));
 elsif p_action='flag' then update public.referrals set fraud_flag=true,fraud_note=coalesce(nullif(p_note,''),'Flagged by Super Admin'),updated_at=now() where id=p_referral_id;
 elsif p_action='unflag' then update public.referrals set fraud_flag=false,fraud_note=null,updated_at=now() where id=p_referral_id;
 else raise exception 'Invalid referral action'; end if;
 return true;
end $$;
revoke all on function public.v6151_admin_referral_action(uuid,text,text) from public,anon;
grant execute on function public.v6151_admin_referral_action(uuid,text,text) to authenticated;

create or replace function public.v6151_admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if not public.is_super_admin() then raise exception 'Super Admin required'; end if;
 return jsonb_build_object(
  'invitations',(select count(*) from public.referral_invites),'signups',(select count(*) from public.referrals),'successful',(select count(*) from public.referrals where status in ('qualified','reward_issued')),
  'creditsIssued',(select coalesce(sum(amount),0) from public.business_credits where amount>0 and status<>'revoked'),'creditsRedeemed',(select abs(coalesce(sum(amount),0)) from public.business_credits where credit_type='subscription_redemption' and status<>'revoked'),'outstanding',(select coalesce(sum(amount),0) from public.business_credits where status='available' and (expires_at is null or expires_at>now())),
  'campaigns',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) from (select c.*,v.id version_id,v.version,v.referrer_reward_type,v.referrer_reward_value,v.referee_reward_enabled,v.referee_reward_type,v.referee_reward_value from public.referral_campaigns c left join lateral(select * from public.referral_campaign_versions vv where vv.campaign_id=c.id order by vv.version desc limit 1)v on true)x),
  'referrals',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) from (select r.id,r.status,r.signup_at,r.qualified_at,r.reward_issued_at,r.fraud_flag,r.fraud_note,r.reward_snapshot,r.created_at,rb.name referring_business,nb.name referred_business,i.invited_email,i.sent_at invitation_date,p.full_name sending_user,c.name campaign,coalesce((select sum(amount) from public.business_credits bc where bc.referral_id=r.id and bc.beneficiary='referrer' and bc.status<>'revoked'),0) referrer_credit,coalesce((select sum(amount) from public.business_credits bc where bc.referral_id=r.id and bc.beneficiary='referee' and bc.status<>'revoked'),0) new_business_credit,coalesce((select string_agg(distinct status,', ') from public.business_credits bc where bc.referral_id=r.id),'—') credit_status from public.referrals r join public.businesses rb on rb.id=r.referring_business_id join public.businesses nb on nb.id=r.referred_business_id left join public.referral_invites i on i.id=r.invite_id left join public.profiles p on p.id=i.sent_by_user_id left join public.referral_campaigns c on c.id=r.campaign_id order by r.created_at desc limit 500)x),
  'credits',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) from (select bc.*,b.name business_name from public.business_credits bc join public.businesses b on b.id=bc.business_id order by bc.created_at desc limit 500)x)
 );
end $$;
revoke all on function public.v6151_admin_dashboard() from public,anon;
grant execute on function public.v6151_admin_dashboard() to authenticated;

notify pgrst, 'reload schema';
