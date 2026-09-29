-- Set the launch offer explicitly: one month each by default. Super Admin can
-- set either side to two free months later without rewriting earned rewards.
-- Only transition the unchanged, disabled one-month defaults; respect custom offers.
with latest as (
  select c.id as campaign_id,v.version,v.id as version_id
  from public.referral_campaigns c
  join public.referral_campaign_versions v on v.campaign_id=c.id
  where c.name='Launch Referral Campaign' and c.active=true
    and v.version=(select max(x.version) from public.referral_campaign_versions x where x.campaign_id=c.id)
    and v.referrer_reward_type='month_equivalent' and v.referrer_reward_value=1
    and v.referee_reward_enabled=false
    and v.referee_reward_type='month_equivalent' and v.referee_reward_value=1
), inserted as (
  insert into public.referral_campaign_versions
    (campaign_id,version,referrer_reward_type,referrer_reward_value,referee_reward_enabled,
     referee_reward_type,referee_reward_value)
  select campaign_id,version+1,'free_months',1,true,'free_months',1 from latest
  on conflict (campaign_id,version) do nothing
  returning campaign_id,id
)
update public.referral_invites i
set campaign_version_id=inserted.id,updated_at=now()
from inserted
where i.campaign_id=inserted.campaign_id and i.status='invited'
  and i.referred_business_id is null;
