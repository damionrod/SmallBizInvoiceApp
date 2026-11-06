-- Honour the same approved manual extension as the application access gate.
-- Existing helper entitlements remain checked separately by v6171_helper_status.
CREATE OR REPLACE FUNCTION public.v61107aax_helper_subscription_access()
 RETURNS TABLE(allowed boolean, reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bid uuid;
  v_sub public.subscriptions%rowtype;
  v_now timestamptz := now();
begin
  v_bid := public.current_business_id();
  if v_bid is null then return query select false,'no_business'::text; return; end if;

  select * into v_sub from public.subscriptions
  where business_id=v_bid
  order by created_at desc limit 1;

  if not found then return query select false,'no_subscription'::text; return; end if;

  if v_sub.manual_access_until is not null
     and v_sub.manual_access_until > v_now
     and v_sub.status <> 'suspended' then
    return query select true,'manual_access'::text; return;
  end if;

  if v_sub.status='trialing' and v_sub.trial_ends_at is not null and v_sub.trial_ends_at>v_now then
    return query select true,'trial'::text; return;
  end if;

  if v_sub.status='active' then
    if (coalesce(v_sub.cancel_at_period_end,false) or v_sub.cancel_at is not null)
       and coalesce(v_sub.cancel_at,v_sub.current_period_end) is not null
       and coalesce(v_sub.cancel_at,v_sub.current_period_end)<=v_now then
      return query select false,'ended'::text; return;
    end if;
    return query select true,'active'::text; return;
  end if;

  if v_sub.status='past_due'
     and v_sub.current_period_end is not null
     and v_now < v_sub.current_period_end + interval '7 days' then
    return query select true,'payment_grace'::text; return;
  end if;

  return query select false,
    case when v_sub.status='trialing' then 'trial_ended' else coalesce(v_sub.status,'inactive') end::text;
end $function$;
