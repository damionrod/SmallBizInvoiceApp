begin;
update public.plans
set stripe_price_id='price_1UEPjk3dnTsjw1X9v0jMvGTv', updated_at=now()
  ,stripe_annual_price_id='price_1UNInJ3dnTsjw1X9XfttQxai'
where slug='pro';
commit;
