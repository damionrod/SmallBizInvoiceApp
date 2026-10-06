-- V61.107AAT: separate the customer's renewal preference from Stripe's period-end stop.
-- Existing period-end stops came from the previous "Turn off auto renewal" UI, so they become manual renewal.
alter table public.subscriptions
  add column if not exists renewal_preference text not null default 'automatic';

update public.subscriptions
set renewal_preference = case
  when coalesce(cancel_at_period_end,false) or cancel_at is not null then 'manual'
  else 'automatic'
end
where renewal_preference not in ('automatic','manual','cancelled')
   or (renewal_preference='automatic' and (coalesce(cancel_at_period_end,false) or cancel_at is not null));

do $$ begin
  alter table public.subscriptions add constraint subscriptions_renewal_preference_check
    check (renewal_preference in ('automatic','manual','cancelled'));
exception when duplicate_object then null;
end $$;

create or replace function public.v61107aaq_due_subscription_notifications()
returns table(id uuid,email_to text,subject text,html_body text)
language plpgsql security definer set search_path='public'
as $$
begin
  insert into public.subscription_lifecycle_notifications
    (business_id,subscription_id,notification_key,event_type,event_at,due_at,email_to)
  select s.business_id,s.id,x.notification_key,x.event_type,x.event_at,x.due_at,p.email
  from public.subscriptions s
  join public.business_memberships bm on bm.business_id=s.business_id and bm.role='owner' and coalesce(bm.status,'active')='active'
  join public.profiles p on p.id=bm.user_id and p.email is not null
  cross join lateral (
    select 'trial_7d_'||s.trial_ends_at::text,'trial_ending',s.trial_ends_at,s.trial_ends_at-interval '7 days'
      where s.status='trialing' and s.trial_ends_at is not null and now()<s.trial_ends_at
    union all select 'trial_3d_'||s.trial_ends_at::text,'trial_ending',s.trial_ends_at,s.trial_ends_at-interval '3 days'
      where s.status='trialing' and s.trial_ends_at is not null and now()<s.trial_ends_at
    union all select 'trial_1d_'||s.trial_ends_at::text,'trial_ending',s.trial_ends_at,s.trial_ends_at-interval '1 day'
      where s.status='trialing' and s.trial_ends_at is not null and now()<s.trial_ends_at
    union all select 'trial_ended_'||s.trial_ends_at::text,'trial_ended',s.trial_ends_at,s.trial_ends_at
      where s.status='trialing' and s.trial_ends_at is not null and now()>=s.trial_ends_at
    union all select 'annual_30d_'||s.current_period_end::text,'annual_renewal',s.current_period_end,s.current_period_end-interval '30 days'
      where s.status='active' and s.billing_interval='annual' and s.renewal_preference='automatic' and coalesce(s.cancel_at_period_end,false)=false and s.cancel_at is null and s.current_period_end is not null and now()<s.current_period_end
    union all select 'annual_7d_'||s.current_period_end::text,'annual_renewal',s.current_period_end,s.current_period_end-interval '7 days'
      where s.status='active' and s.billing_interval='annual' and s.renewal_preference='automatic' and coalesce(s.cancel_at_period_end,false)=false and s.cancel_at is null and s.current_period_end is not null and now()<s.current_period_end
    union all select 'monthly_7d_'||s.current_period_end::text,'monthly_renewal',s.current_period_end,s.current_period_end-interval '7 days'
      where s.status='active' and s.billing_interval='monthly' and s.renewal_preference='automatic' and coalesce(s.cancel_at_period_end,false)=false and s.cancel_at is null and s.current_period_end is not null and now()<s.current_period_end
    union all select 'manual_30d_'||s.current_period_end::text,'manual_renewal',s.current_period_end,s.current_period_end-interval '30 days'
      where s.status='active' and s.billing_interval='annual' and s.renewal_preference='manual' and s.current_period_end is not null and now()<s.current_period_end
    union all select 'manual_7d_'||s.current_period_end::text,'manual_renewal',s.current_period_end,s.current_period_end-interval '7 days'
      where s.status='active' and s.renewal_preference='manual' and s.current_period_end is not null and now()<s.current_period_end
    union all select 'manual_1d_'||s.current_period_end::text,'manual_renewal',s.current_period_end,s.current_period_end-interval '1 day'
      where s.status='active' and s.renewal_preference='manual' and s.current_period_end is not null and now()<s.current_period_end
    union all select 'ending_7d_'||coalesce(s.cancel_at,s.current_period_end)::text,'subscription_ending',coalesce(s.cancel_at,s.current_period_end),coalesce(s.cancel_at,s.current_period_end)-interval '7 days'
      where s.status='active' and s.renewal_preference='cancelled' and coalesce(s.cancel_at,s.current_period_end) is not null and now()<coalesce(s.cancel_at,s.current_period_end)
    union all select 'ending_1d_'||coalesce(s.cancel_at,s.current_period_end)::text,'subscription_ending',coalesce(s.cancel_at,s.current_period_end),coalesce(s.cancel_at,s.current_period_end)-interval '1 day'
      where s.status='active' and s.renewal_preference='cancelled' and coalesce(s.cancel_at,s.current_period_end) is not null and now()<coalesce(s.cancel_at,s.current_period_end)
  ) x(notification_key,event_type,event_at,due_at)
  on conflict(subscription_id,notification_key) do nothing;

  return query
  select n.id,n.email_to,
    case n.event_type when 'trial_ending' then 'Your Frindly trial is ending soon' when 'trial_ended' then 'Your Frindly trial has ended'
      when 'annual_renewal' then 'Your Frindly annual subscription renews soon' when 'monthly_renewal' then 'Your Frindly subscription renews soon'
      when 'manual_renewal' then 'Your Frindly subscription is expiring soon' else 'Your Frindly subscription is ending soon' end,
    '<div style="font-family:Arial,sans-serif;max-width:600px;margin:auto;color:#172033"><h2 style="color:#171c3d">Frindly</h2><p>'||
    case n.event_type when 'trial_ending' then 'Your Frindly trial ends on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>. Choose a paid plan before then to keep uninterrupted access.'
    when 'trial_ended' then 'Your Frindly trial ended on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>. Choose a paid plan to continue using Frindly.'
    when 'annual_renewal' then 'Your annual Frindly subscription is set to renew automatically on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>.'
    when 'monthly_renewal' then 'Your Frindly subscription is set to renew automatically on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>.'
    when 'manual_renewal' then 'Auto renewal is off. Your Frindly subscription expires on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>. Open Subscription & Billing to renew or cancel.'
    else 'Your Frindly subscription is scheduled to end on <strong>'||to_char(n.event_at at time zone 'Pacific/Auckland','FMDD FMMonth YYYY')||'</strong>. You can keep the subscription from Subscription & Billing before it ends.' end
    ||'</p><p><a href="https://frindly.co.nz/#settings/subscription" style="display:inline-block;background:#171c3d;color:white;padding:11px 18px;border-radius:8px;text-decoration:none">Open Subscription & Billing</a></p><p style="font-size:12px;color:#667085">Business, Made Easy.</p></div>'
  from public.subscription_lifecycle_notifications n
  where n.sent_at is null and n.due_at<=now()
    and ((n.event_type='trial_ending' and now()<n.event_at and n.due_at>=now()-interval '36 hours')
      or (n.event_type='trial_ended' and now()>=n.event_at and n.event_at>=now()-interval '36 hours')
      or (n.event_type in ('annual_renewal','monthly_renewal','manual_renewal','subscription_ending') and now()<n.event_at and n.due_at>=now()-interval '36 hours'))
    and (n.error_message is null or n.updated_at<now()-interval '1 hour')
  order by n.due_at limit 100;
end $$;
