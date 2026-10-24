begin;
update public.plans
set stripe_price_id='price_1UEPjk3dnTsjw1X9v0jMvGTv', updated_at=now()
where slug='pro';
commit;
