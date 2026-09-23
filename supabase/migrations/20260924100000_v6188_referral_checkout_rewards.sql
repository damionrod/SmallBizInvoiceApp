-- Record referrals when the signup trigger creates the initial subscription.
-- The referral code is an attribution token, never an authorization claim.
create or replace function public.v6151_register_referral_signup_internal(
  p_business_id uuid, p_user_id uuid, p_email text, p_code text, p_invite_token text)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare rc public.business_referral_codes%rowtype; inv public.referral_invites%rowtype;
        camp public.referral_campaigns%rowtype; ver public.referral_campaign_versions%rowtype;
        ih text; rid uuid;
begin
  if coalesce(nullif(p_code,''),'')='' then return; end if;
  select * into rc from public.business_referral_codes
  where referral_code=upper(p_code) and active=true;
  if not found or rc.business_id=p_business_id then return; end if;
  if exists(select 1 from public.referrals where referred_business_id=p_business_id) then return; end if;
  if nullif(p_invite_token,'') is not null then
    ih:=encode(extensions.digest(p_invite_token,'sha256'),'hex');
    select * into inv from public.referral_invites
    where token_hash=ih and referring_business_id=rc.business_id
      and status in ('invited','pending_qualification')
      and lower(invited_email)=lower(p_email)
    order by created_at desc limit 1;
    if inv.id is null then return; end if;
  end if;
  if inv.id is not null then
    select * into camp from public.referral_campaigns where id=inv.campaign_id;
    select * into ver from public.referral_campaign_versions where id=inv.campaign_version_id;
  else
    select * into camp from public.referral_campaigns
    where active=true and start_date<=now() and (end_date is null or end_date>now())
    order by start_date desc limit 1;
    if not found then return; end if;
    select * into ver from public.referral_campaign_versions
    where campaign_id=camp.id and effective_from<=now()
    order by version desc limit 1;
  end if;
  if camp.id is null or ver.id is null then return; end if;
  insert into public.referrals(referring_business_id,referred_business_id,referred_user_id,
    invite_id,campaign_id,campaign_version_id,signup_at,status)
  values(rc.business_id,p_business_id,p_user_id,inv.id,camp.id,ver.id,now(),'signed_up')
  returning id into rid;
  if inv.id is not null then
    update public.referral_invites set status='signed_up',signup_at=now(),
      referred_business_id=p_business_id,updated_at=now() where id=inv.id;
  end if;
  insert into public.referral_audit_log(referral_id,action,details)
  values(rid,'signup',jsonb_build_object('email',p_email,'referral_code',rc.referral_code));
  perform public.v6151_process_referral_event_internal(p_business_id,'signup_completed');
end $$;
revoke all on function public.v6151_register_referral_signup_internal(uuid,uuid,text,text,text)
  from public,anon,authenticated;

create or replace function public.v6188_register_signup_referral()
returns trigger language plpgsql security definer set search_path = public, auth
as $$
declare signup_user auth.users%rowtype;
begin
  select u.* into signup_user from auth.users u
  join public.profiles p on p.id=u.id
  where p.business_id=new.business_id and p.role='owner'
  order by u.created_at limit 1;
  if found and nullif(signup_user.raw_user_meta_data->>'business_invite_token','') is null
     and nullif(signup_user.raw_user_meta_data->>'referral_code','') is not null then
    perform public.v6151_register_referral_signup_internal(
      new.business_id,signup_user.id,signup_user.email,
      signup_user.raw_user_meta_data->>'referral_code',
      signup_user.raw_user_meta_data->>'referral_invite_token');
  end if;
  return new;
end $$;
revoke all on function public.v6188_register_signup_referral() from public,anon,authenticated;
drop trigger if exists v6188_register_signup_referral on public.subscriptions;
create trigger v6188_register_signup_referral after insert on public.subscriptions
for each row execute function public.v6188_register_signup_referral();

-- Checkout is the source of the referee's benefit; avoid awarding it twice
-- when the referrer later qualifies on an actual paid subscription invoice.
alter table public.referrals add column if not exists referee_checkout_coupon_id text;

create or replace function public.v6151_issue_referral_rewards_internal(p_referral_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.referrals%rowtype; v public.referral_campaign_versions%rowtype;
        c public.referral_campaigns%rowtype; a numeric; b numeric;
        exp_at timestamptz; snap jsonb;
begin
  select * into r from public.referrals where id=p_referral_id for update;
  if not found or r.status in ('reward_issued','rejected','cancelled') then return; end if;
  select * into v from public.referral_campaign_versions where id=r.campaign_version_id;
  select * into c from public.referral_campaigns where id=r.campaign_id;
  a:=public.v6151_reward_amount(r.referring_business_id,v.referrer_reward_type,v.referrer_reward_value);
  b:=case when v.referee_reward_enabled and r.referee_checkout_coupon_id is null
          then public.v6151_reward_amount(r.referred_business_id,v.referee_reward_type,v.referee_reward_value) else 0 end;
  exp_at:=case when c.credit_expiry_days is null then null else now()+(c.credit_expiry_days||' days')::interval end;
  snap:=jsonb_build_object('campaign_id',r.campaign_id,'campaign_version_id',r.campaign_version_id,
    'campaign_name',c.name,'version',v.version,'referrer_reward_type',v.referrer_reward_type,
    'referrer_reward_value',v.referrer_reward_value,'referee_reward_enabled',v.referee_reward_enabled,
    'referee_reward_type',v.referee_reward_type,'referee_reward_value',v.referee_reward_value,
    'referee_checkout_coupon_id',r.referee_checkout_coupon_id,'qualified_at',now());
  if a>0 then
    insert into public.business_credits(business_id,referral_id,campaign_id,campaign_version_id,credit_type,beneficiary,amount,status,expires_at,notes,reward_snapshot)
    values(r.referring_business_id,r.id,r.campaign_id,r.campaign_version_id,'referral_reward','referrer',a,'available',exp_at,'Referral reward',snap)
    on conflict do nothing;
  end if;
  if b>0 then
    insert into public.business_credits(business_id,referral_id,campaign_id,campaign_version_id,credit_type,beneficiary,amount,status,expires_at,notes,reward_snapshot)
    values(r.referred_business_id,r.id,r.campaign_id,r.campaign_version_id,'referral_reward','referee',b,'available',exp_at,'Referred business reward',snap)
    on conflict do nothing;
  end if;
  update public.referrals set status='reward_issued',reward_issued_at=coalesce(reward_issued_at,now()),
    reward_snapshot=coalesce(reward_snapshot,snap),updated_at=now() where id=r.id;
  update public.referral_invites set status='reward_issued',updated_at=now() where id=r.invite_id;
  insert into public.referral_audit_log(referral_id,action,details)
  values(r.id,'reward_issued',jsonb_build_object('referrer_credit',a,'referee_credit',b,'snapshot',snap));
end $$;
revoke all on function public.v6151_issue_referral_rewards_internal(uuid) from public,anon,authenticated;

-- Bring the untouched launch campaign into line with the two-sided offer.
-- Never overwrite later Super Admin choices or change earlier reward versions.
insert into public.referral_campaign_versions
  (campaign_id,version,referrer_reward_type,referrer_reward_value,referee_reward_enabled,referee_reward_type,referee_reward_value)
select c.id,2,'free_months',1,true,'free_months',1
from public.referral_campaigns c join public.referral_campaign_versions v on v.campaign_id=c.id and v.version=1
where c.name='Launch Referral Campaign' and c.active=true
  and v.referrer_reward_type='month_equivalent' and v.referrer_reward_value=1
  and v.referee_reward_enabled=false
  and not exists (select 1 from public.referral_campaign_versions x where x.campaign_id=c.id and x.version>1)
on conflict (campaign_id,version) do nothing;

-- Invitations still waiting for signup follow the updated two-sided offer.
update public.referral_invites i set campaign_version_id=v.id,updated_at=now()
from public.referral_campaigns c join public.referral_campaign_versions v
  on v.campaign_id=c.id and v.version=2 and v.referee_reward_enabled=true
  and v.referrer_reward_type='free_months' and v.referrer_reward_value=1
  and v.referee_reward_type='free_months' and v.referee_reward_value=1
where i.campaign_id=c.id and c.name='Launch Referral Campaign' and i.status='invited'
  and i.referred_business_id is null and i.campaign_version_id<>v.id;
