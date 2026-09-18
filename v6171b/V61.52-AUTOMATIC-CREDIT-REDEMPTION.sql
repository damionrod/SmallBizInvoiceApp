-- Finlo V61.52 - Automatic Finlo Credit Redemption through Stripe Billing
-- Additive only. Existing subscription charging remains unchanged.

create table if not exists public.finlo_credit_redemptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  stripe_invoice_id text not null unique,
  stripe_customer_id text not null,
  currency text not null default 'NZD',
  amount numeric(14,2) not null check (amount > 0),
  credit_ids uuid[] not null default '{}'::uuid[],
  status text not null default 'reserved' check (status in ('reserved','credited','failed')),
  stripe_balance_transaction_id text unique,
  ledger_entry_id uuid references public.business_credits(id) on delete set null,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  credited_at timestamptz
);

create index if not exists finlo_credit_redemptions_business_idx
  on public.finlo_credit_redemptions(business_id, created_at desc);

alter table public.finlo_credit_redemptions enable row level security;
revoke all on public.finlo_credit_redemptions from anon, authenticated;
grant select on public.finlo_credit_redemptions to authenticated;

drop policy if exists v6152_credit_redemptions_read on public.finlo_credit_redemptions;
create policy v6152_credit_redemptions_read
on public.finlo_credit_redemptions
for select to authenticated
using (
  (business_id = public.current_business_id() and public.has_active_business_membership(business_id))
  or public.is_super_admin()
);

-- Internal reservation function. It atomically reserves all eligible positive Finlo credits
-- in the same currency so duplicate Stripe webhook deliveries cannot double-credit a customer.
create or replace function public.v6152_reserve_credits_internal(
  p_business_id uuid,
  p_stripe_invoice_id text,
  p_stripe_customer_id text,
  p_currency text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  app public.finlo_credit_redemptions%rowtype;
  ids uuid[];
  total numeric(14,2);
  cur text := upper(coalesce(nullif(trim(p_currency),''),'NZD'));
begin
  if p_business_id is null or coalesce(trim(p_stripe_invoice_id),'')='' or coalesce(trim(p_stripe_customer_id),'')='' then
    raise exception 'Missing credit redemption context';
  end if;

  select * into app
  from public.finlo_credit_redemptions
  where stripe_invoice_id=p_stripe_invoice_id
  for update;

  if found then
    if app.status='credited' then
      return jsonb_build_object('applicationId',app.id,'amount',0,'currency',app.currency,'creditIds',app.credit_ids,'alreadyCredited',true);
    elsif app.status='reserved' then
      return jsonb_build_object('applicationId',app.id,'amount',app.amount,'currency',app.currency,'creditIds',app.credit_ids,'alreadyCredited',false);
    end if;
  end if;

  select array_agg(id order by issued_at,id), round(coalesce(sum(amount),0),2)
  into ids,total
  from (
    select id,amount,issued_at
    from public.business_credits
    where business_id=p_business_id
      and amount>0
      and upper(currency)=cur
      and status='available'
      and (expires_at is null or expires_at>now())
    order by issued_at,id
    for update
  ) q;

  if total is null or total<=0 or ids is null then
    if found then
      update public.finlo_credit_redemptions
      set status='failed', error_message='No eligible Finlo credit available', updated_at=now()
      where id=app.id;
    end if;
    return jsonb_build_object('amount',0,'currency',cur,'creditIds','[]'::jsonb,'alreadyCredited',false);
  end if;

  update public.business_credits
  set status='pending'
  where id=any(ids) and status='available';

  if app.id is null then
    insert into public.finlo_credit_redemptions(
      business_id,stripe_invoice_id,stripe_customer_id,currency,amount,credit_ids,status
    ) values (
      p_business_id,p_stripe_invoice_id,p_stripe_customer_id,cur,total,ids,'reserved'
    ) returning * into app;
  else
    update public.finlo_credit_redemptions
    set business_id=p_business_id,
        stripe_customer_id=p_stripe_customer_id,
        currency=cur,
        amount=total,
        credit_ids=ids,
        status='reserved',
        stripe_balance_transaction_id=null,
        ledger_entry_id=null,
        error_message=null,
        credited_at=null,
        updated_at=now()
    where id=app.id
    returning * into app;
  end if;

  insert into public.referral_audit_log(action,details)
  values('credit_redemption_reserved',jsonb_build_object(
    'application_id',app.id,
    'business_id',p_business_id,
    'stripe_invoice_id',p_stripe_invoice_id,
    'amount',total,
    'currency',cur,
    'credit_ids',to_jsonb(ids)
  ));

  return jsonb_build_object('applicationId',app.id,'amount',total,'currency',cur,'creditIds',to_jsonb(ids),'alreadyCredited',false);
end $$;
revoke all on function public.v6152_reserve_credits_internal(uuid,text,text,text) from public,anon,authenticated;

create or replace function public.v6152_complete_credit_redemption_internal(
  p_application_id uuid,
  p_stripe_balance_transaction_id text
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  app public.finlo_credit_redemptions%rowtype;
  ledger_id uuid;
begin
  select * into app
  from public.finlo_credit_redemptions
  where id=p_application_id
  for update;

  if not found then raise exception 'Credit redemption not found'; end if;
  if app.status='credited' then return true; end if;
  if app.status<>'reserved' then raise exception 'Credit redemption is not reserved'; end if;
  if coalesce(trim(p_stripe_balance_transaction_id),'')='' then raise exception 'Stripe balance transaction is required'; end if;

  update public.business_credits
  set status='redeemed', applied_at=coalesce(applied_at,now())
  where id=any(app.credit_ids) and status='pending';

  insert into public.business_credits(
    business_id,credit_type,amount,currency,status,applied_at,notes,reward_snapshot
  ) values (
    app.business_id,
    'subscription_redemption',
    -app.amount,
    app.currency,
    'redeemed',
    now(),
    'Automatically transferred to Stripe subscription credit balance',
    jsonb_build_object(
      'redemption_application_id',app.id,
      'stripe_invoice_id',app.stripe_invoice_id,
      'stripe_customer_id',app.stripe_customer_id,
      'stripe_balance_transaction_id',p_stripe_balance_transaction_id
    )
  ) returning id into ledger_id;

  update public.finlo_credit_redemptions
  set status='credited',
      stripe_balance_transaction_id=p_stripe_balance_transaction_id,
      ledger_entry_id=ledger_id,
      credited_at=now(),
      error_message=null,
      updated_at=now()
  where id=app.id;

  insert into public.referral_audit_log(credit_id,action,details)
  values(ledger_id,'credit_redeemed_to_stripe',jsonb_build_object(
    'application_id',app.id,
    'business_id',app.business_id,
    'stripe_invoice_id',app.stripe_invoice_id,
    'stripe_balance_transaction_id',p_stripe_balance_transaction_id,
    'amount',app.amount,
    'currency',app.currency
  ));

  return true;
end $$;
revoke all on function public.v6152_complete_credit_redemption_internal(uuid,text) from public,anon,authenticated;

create or replace function public.v6152_release_credit_redemption_internal(
  p_application_id uuid,
  p_error text
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  app public.finlo_credit_redemptions%rowtype;
begin
  select * into app
  from public.finlo_credit_redemptions
  where id=p_application_id
  for update;

  if not found then return false; end if;
  if app.status='credited' then return true; end if;

  update public.business_credits
  set status='available'
  where id=any(app.credit_ids) and status='pending';

  update public.finlo_credit_redemptions
  set status='failed', error_message=left(coalesce(p_error,'Stripe credit sync failed'),1000), updated_at=now()
  where id=app.id;

  insert into public.referral_audit_log(action,details)
  values('credit_redemption_failed',jsonb_build_object(
    'application_id',app.id,
    'business_id',app.business_id,
    'stripe_invoice_id',app.stripe_invoice_id,
    'error',left(coalesce(p_error,'Stripe credit sync failed'),1000)
  ));
  return true;
end $$;
revoke all on function public.v6152_release_credit_redemption_internal(uuid,text) from public,anon,authenticated;

-- Service-role wrappers used only by the signed Stripe webhook backend.
create or replace function public.v6152_reserve_credits(
  p_business_id uuid,
  p_stripe_invoice_id text,
  p_stripe_customer_id text,
  p_currency text
)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Service role required'; end if;
  return public.v6152_reserve_credits_internal(p_business_id,p_stripe_invoice_id,p_stripe_customer_id,p_currency);
end $$;
revoke all on function public.v6152_reserve_credits(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.v6152_reserve_credits(uuid,text,text,text) to service_role;

create or replace function public.v6152_complete_credit_redemption(
  p_application_id uuid,
  p_stripe_balance_transaction_id text
)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Service role required'; end if;
  return public.v6152_complete_credit_redemption_internal(p_application_id,p_stripe_balance_transaction_id);
end $$;
revoke all on function public.v6152_complete_credit_redemption(uuid,text) from public,anon,authenticated;
grant execute on function public.v6152_complete_credit_redemption(uuid,text) to service_role;

create or replace function public.v6152_release_credit_redemption(
  p_application_id uuid,
  p_error text
)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Service role required'; end if;
  return public.v6152_release_credit_redemption_internal(p_application_id,p_error);
end $$;
revoke all on function public.v6152_release_credit_redemption(uuid,text) from public,anon,authenticated;
grant execute on function public.v6152_release_credit_redemption(uuid,text) to service_role;

-- Ensure balances ignore temporarily reserved credits and continue to show only usable Finlo-side credit.
-- Existing V61.51 portal/admin functions already calculate status='available', so no frontend change is required.

notify pgrst, 'reload schema';
