-- V61.71 — NZ Fast Onboarding + Finlo Helper foundation
-- Forward-only. No historical business/accounting backfill.

create table if not exists public.platform_industries(
  code text primary key,
  name text not null,
  is_active boolean not null default true,
  sort_order integer not null default 100
);
insert into public.platform_industries(code,name,sort_order) values
 ('professional_services','Professional services',10),('trades_construction','Trades & construction',20),('retail','Retail',30),('hospitality','Hospitality & food',40),('health_wellness','Health & wellness',50),('cleaning_property','Cleaning & property services',60),('technology','Technology',70),('creative_media','Creative & media',80),('transport_delivery','Transport & delivery',90),('other','Other',999)
on conflict(code) do update set name=excluded.name,sort_order=excluded.sort_order;
alter table public.platform_industries enable row level security;
drop policy if exists platform_industries_read on public.platform_industries;
create policy platform_industries_read on public.platform_industries for select to authenticated using(true);
revoke insert,update,delete on public.platform_industries from anon,authenticated;


create table if not exists public.business_onboarding_state(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  status text not null default 'pending' check(status in('pending','in_progress','completed','dismissed')),
  current_step smallint not null default 1 check(current_step between 1 and 5),
  gst_confirmation text not null default 'unanswered' check(gst_confirmation in('unanswered','yes','no','unsure','confirmed')),
  selected_modules text[] not null default array['invoice_manager','expenses']::text[],
  starting_mode text check(starting_mode in('fresh','existing')),
  getting_started_dismissed boolean not null default false,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.business_onboarding_state enable row level security;
drop policy if exists business_onboarding_state_read on public.business_onboarding_state;
create policy business_onboarding_state_read on public.business_onboarding_state for select to authenticated using(business_id=public.current_business_id());
revoke insert,update,delete on public.business_onboarding_state from anon,authenticated;

create table if not exists public.finlo_helper_settings(
  id boolean primary key default true check(id=true),
  global_enabled boolean not null default true,
  emergency_disabled boolean not null default false,
  provider text not null default 'openai',
  model text not null default 'gpt-5.6-luna',
  max_output_tokens integer not null default 700 check(max_output_tokens between 100 and 4000),
  contextual_awareness boolean not null default true,
  default_question_limit integer not null default 100 check(default_question_limit>=0),
  trial_question_limit integer not null default 30 check(trial_question_limit>=0),
  monthly_cost_ceiling numeric(12,4),
  monthly_price numeric(12,2) not null default 0,
  annual_price numeric(12,2),
  stripe_product_id text,
  stripe_monthly_price_id text,
  stripe_annual_price_id text,
  instruction_version text not null default 'v1',
  instruction_text text not null default 'You are Finlo Helper. Explain Finlo in plain English, concisely, for small-business owners with little accounting knowledge. Explain fields, choices and navigation. Do not make tax or accounting decisions for the customer. Do not claim an action happened when it did not. Do not invent Finlo capabilities. V1 is help and product guidance only.',
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.finlo_helper_settings(id) values(true) on conflict(id) do nothing;
alter table public.finlo_helper_settings enable row level security;
revoke all on public.finlo_helper_settings from anon,authenticated;

create table if not exists public.finlo_helper_module_controls(
  module_context text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.finlo_helper_module_controls(module_context,enabled) values
 ('onboarding',true),('dashboard',false),('invoices',false),('quotes',false),('expenses',false),('bank',false),('payroll',false),('financials',false),('gst',false),('accountant_centre',false),('settings',false)
on conflict(module_context) do nothing;
alter table public.finlo_helper_module_controls enable row level security;
revoke all on public.finlo_helper_module_controls from anon,authenticated;

insert into public.modules(slug,name,description,monthly_price,stripe_price_id,is_active)
select 'finlo_helper','Finlo Helper','Plain-English product help and guidance.',0,null,true
where not exists(select 1 from public.modules where slug='finlo_helper');

create table if not exists public.optional_addon_entitlements(
  business_id uuid not null references public.businesses(id) on delete cascade,
  module_id uuid not null references public.modules(id) on delete cascade,
  entitlement_state text not null default 'not_subscribed' check(entitlement_state in('not_subscribed','subscribed','included_with_plan','trial','complimentary','suspended')),
  allowance_override integer check(allowance_override is null or allowance_override>=0),
  starts_at timestamptz,
  ends_at timestamptz,
  stripe_subscription_item_id text,
  notes text,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key(business_id,module_id)
);
alter table public.optional_addon_entitlements enable row level security;
drop policy if exists optional_addon_entitlements_read on public.optional_addon_entitlements;
create policy optional_addon_entitlements_read on public.optional_addon_entitlements for select to authenticated using(business_id=public.current_business_id() or public.is_super_admin());
revoke insert,update,delete on public.optional_addon_entitlements from anon,authenticated;

create table if not exists public.finlo_helper_plan_config(
  plan_id uuid primary key references public.plans(id) on delete cascade,
  eligible boolean not null default true,
  included boolean not null default false,
  allowance_override integer check(allowance_override is null or allowance_override>=0),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.finlo_helper_plan_config enable row level security;
revoke all on public.finlo_helper_plan_config from anon,authenticated;
insert into public.finlo_helper_plan_config(plan_id,eligible,included)
select id,true,(slug='trial') from public.plans on conflict(plan_id) do nothing;

create table if not exists public.finlo_helper_usage(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null,
  module_context text not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  provider text,
  model text,
  input_usage integer,
  output_usage integer,
  total_usage integer,
  success boolean not null default false,
  failure_code text,
  estimated_cost numeric(12,6),
  created_at timestamptz not null default now()
);
create index if not exists finlo_helper_usage_business_period_idx on public.finlo_helper_usage(business_id,period_start,period_end,created_at);
alter table public.finlo_helper_usage enable row level security;
drop policy if exists finlo_helper_usage_read on public.finlo_helper_usage;
create policy finlo_helper_usage_read on public.finlo_helper_usage for select to authenticated using(business_id=public.current_business_id() or public.is_super_admin());
revoke insert,update,delete on public.finlo_helper_usage from anon,authenticated;

create or replace function public.v6171_onboarding_get() returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); s public.business_onboarding_state; b public.businesses; f public.financial_settings; g jsonb;
begin
 if bid is null then raise exception 'No active business' using errcode='42501'; end if;
 select * into b from businesses where id=bid; if not found then raise exception 'Business not available' using errcode='42501'; end if;
 select * into s from business_onboarding_state where business_id=bid;
 select * into f from financial_settings where business_id=bid;
 if upper(coalesce(b.settings->>'country','NZ'))='NZ' then begin g:=v6170e_gst_settings(current_date); exception when others then g:='{}'::jsonb; end; else g:='{}'::jsonb; end if;
 return jsonb_build_object('business',jsonb_build_object('id',b.id,'name',b.name,'country',coalesce(b.settings->>'country','NZ'),'currency',coalesce(b.settings->>'currency','NZD'),'industry',b.settings->>'industry','business_email',b.settings->>'businessEmail','business_type',coalesce(f.business_entity_type,b.settings->>'businessType')),'state',case when s.business_id is null then null else to_jsonb(s) end,'gst',g);
end$$;
grant execute on function public.v6171_onboarding_get() to authenticated;

create or replace function public.v6171_onboarding_save(p_step smallint,p_payload jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); st public.business_onboarding_state; v text; arr text[];
begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Business settings access denied' using errcode='42501'; end if;
 insert into business_onboarding_state(business_id,status,current_step) values(bid,'in_progress',greatest(1,least(5,p_step))) on conflict(business_id) do nothing;
 if p_step=1 then
   if nullif(btrim(p_payload->>'business_name'),'') is null then raise exception 'Business name is required'; end if;
   update businesses set name=btrim(p_payload->>'business_name'),settings=coalesce(settings,'{}'::jsonb)||jsonb_build_object('company',btrim(p_payload->>'business_name'),'trading',btrim(p_payload->>'business_name'),'country','NZ','currency','NZD','industry',nullif(p_payload->>'industry',''),'businessEmail',nullif(btrim(p_payload->>'business_email'),''),'businessType',nullif(p_payload->>'business_type','')),updated_at=now() where id=bid;
   insert into financial_settings(business_id,business_entity_type) values(bid,coalesce(nullif(p_payload->>'business_type',''),'other')) on conflict(business_id) do update set business_entity_type=excluded.business_entity_type,updated_at=now(),updated_by=auth.uid();
 elsif p_step=2 then
   v:=coalesce(p_payload->>'gst_confirmation','unanswered'); if v not in('yes','no','unsure','confirmed') then raise exception 'Invalid GST confirmation'; end if;
   update business_onboarding_state set gst_confirmation=v where business_id=bid;
 elsif p_step=3 then
   select coalesce(array_agg(x),array[]::text[]) into arr from jsonb_array_elements_text(coalesce(p_payload->'selected_modules','[]'::jsonb)) x where x in('invoice_manager','expenses','bank_reconciliation','payroll');
   update business_onboarding_state set selected_modules=arr where business_id=bid;
 elsif p_step=4 then
   v:=p_payload->>'starting_mode'; if v not in('fresh','existing') then raise exception 'Choose how you are starting'; end if;
   update business_onboarding_state set starting_mode=v where business_id=bid;
 elsif p_step=5 then
   update business_onboarding_state set status='completed',current_step=5,completed_at=now() where business_id=bid;
 end if;
 update business_onboarding_state set current_step=greatest(current_step,greatest(1,least(5,p_step))),status=case when p_step=5 then 'completed' else 'in_progress' end,updated_at=now() where business_id=bid returning * into st;
 return to_jsonb(st);
end$$;
grant execute on function public.v6171_onboarding_save(smallint,jsonb) to authenticated;

create or replace function public.v6171_onboarding_dismiss_getting_started() returns void language plpgsql security definer set search_path=public as $$declare bid uuid:=current_business_id();begin if bid is null then raise exception 'No active business';end if;update business_onboarding_state set getting_started_dismissed=true,updated_at=now() where business_id=bid;end$$;
grant execute on function public.v6171_onboarding_dismiss_getting_started() to authenticated;

create or replace function public.v6171_helper_status(p_module text default 'onboarding') returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); cfg public.finlo_helper_settings; ctl boolean:=false; sub public.subscriptions; pc public.finlo_helper_plan_config; ent public.optional_addon_entitlements; mid uuid; state text:='not_subscribed'; lim int:=0; used int:=0; ps timestamptz; pe timestamptz; included boolean:=false;
begin
 if bid is null then raise exception 'No active business' using errcode='42501';end if;
 select * into cfg from finlo_helper_settings where id=true; select enabled into ctl from finlo_helper_module_controls where module_context=p_module;
 select id into mid from modules where slug='finlo_helper'; select * into ent from optional_addon_entitlements where business_id=bid and module_id=mid;
 select * into sub from subscriptions where business_id=bid order by created_at desc limit 1; if sub.id is not null then select * into pc from finlo_helper_plan_config where plan_id=sub.plan_id; end if;
 if ent.business_id is not null then state:=ent.entitlement_state; elsif coalesce(pc.included,false) then state:='included_with_plan'; included:=true; else state:='not_subscribed'; end if;
 if state='trial' then lim:=cfg.trial_question_limit; else lim:=coalesce(ent.allowance_override,pc.allowance_override,cfg.default_question_limit); end if;
 if sub.id is not null then ps:=sub.current_period_start;pe:=sub.current_period_end;else ps:=date_trunc('month',now());pe:=date_trunc('month',now())+interval '1 month';end if;
 select count(*) into used from finlo_helper_usage where business_id=bid and success=true and created_at>=ps and created_at<pe;
 return jsonb_build_object('enabled',cfg.global_enabled and not cfg.emergency_disabled and coalesce(ctl,false),'global_enabled',cfg.global_enabled,'emergency_disabled',cfg.emergency_disabled,'module_enabled',coalesce(ctl,false),'entitlement',state,'entitled',state in('subscribed','included_with_plan','trial','complimentary'),'used',used,'limit',lim,'remaining',greatest(lim-used,0),'period_start',ps,'next_reset',pe,'contextual_awareness',cfg.contextual_awareness);
end$$;
grant execute on function public.v6171_helper_status(text) to authenticated;

create or replace function public.v6171_admin_helper_overview() returns jsonb language plpgsql security definer set search_path=public as $$
begin if not is_super_admin() then raise exception 'Super Admin required' using errcode='42501';end if;
 return jsonb_build_object('settings',(select to_jsonb(s)-'instruction_text' from finlo_helper_settings s where id=true),'instruction',(select jsonb_build_object('version',instruction_version,'text',instruction_text) from finlo_helper_settings where id=true),'modules',(select coalesce(jsonb_agg(to_jsonb(m) order by module_context),'[]') from finlo_helper_module_controls m),'plans',(select coalesce(jsonb_agg(jsonb_build_object('plan_id',p.id,'name',p.name,'slug',p.slug,'eligible',coalesce(c.eligible,true),'included',coalesce(c.included,false),'allowance_override',c.allowance_override) order by p.sort_order),'[]') from plans p left join finlo_helper_plan_config c on c.plan_id=p.id),'businesses',(select coalesce(jsonb_agg(jsonb_build_object('business_id',b.id,'business',b.name,'entitlement',coalesce(e.entitlement_state,case when pc.included then 'included_with_plan' else 'not_subscribed' end),'allowance_override',e.allowance_override,'used',(select count(*) from finlo_helper_usage u where u.business_id=b.id and u.success=true and u.created_at>=coalesce(s.current_period_start,date_trunc('month',now())) and u.created_at<coalesce(s.current_period_end,date_trunc('month',now())+interval '1 month')),'last_used',(select max(created_at) from finlo_helper_usage u where u.business_id=b.id),'estimated_cost',(select sum(estimated_cost) from finlo_helper_usage u where u.business_id=b.id and u.created_at>=date_trunc('month',now()))) order by b.name),'[]') from businesses b left join subscriptions s on s.business_id=b.id left join finlo_helper_plan_config pc on pc.plan_id=s.plan_id left join modules m on m.slug='finlo_helper' left join optional_addon_entitlements e on e.business_id=b.id and e.module_id=m.id),'kpis',jsonb_build_object('questions_this_month',(select count(*) from finlo_helper_usage where success=true and created_at>=date_trunc('month',now())),'businesses_using',(select count(distinct business_id) from finlo_helper_usage where success=true and created_at>=date_trunc('month',now())),'requests_today',(select count(*) from finlo_helper_usage where created_at>=current_date),'failed_requests',(select count(*) from finlo_helper_usage where success=false and created_at>=date_trunc('month',now())),'estimated_cost',(select coalesce(sum(estimated_cost),0) from finlo_helper_usage where created_at>=date_trunc('month',now()))));
end$$;
grant execute on function public.v6171_admin_helper_overview() to authenticated;

create or replace function public.v6171_admin_helper_save(p_settings jsonb,p_modules jsonb,p_business_id uuid default null,p_entitlement text default null,p_allowance integer default null) returns void language plpgsql security definer set search_path=public as $$
declare r record; mid uuid;begin if not is_super_admin() then raise exception 'Super Admin required' using errcode='42501';end if;
 update finlo_helper_settings set global_enabled=coalesce((p_settings->>'global_enabled')::boolean,global_enabled),emergency_disabled=coalesce((p_settings->>'emergency_disabled')::boolean,emergency_disabled),provider=coalesce(nullif(p_settings->>'provider',''),provider),model=coalesce(nullif(p_settings->>'model',''),model),max_output_tokens=coalesce((p_settings->>'max_output_tokens')::int,max_output_tokens),contextual_awareness=coalesce((p_settings->>'contextual_awareness')::boolean,contextual_awareness),default_question_limit=coalesce((p_settings->>'default_question_limit')::int,default_question_limit),trial_question_limit=coalesce((p_settings->>'trial_question_limit')::int,trial_question_limit),monthly_cost_ceiling=case when p_settings ? 'monthly_cost_ceiling' then nullif(p_settings->>'monthly_cost_ceiling','')::numeric else monthly_cost_ceiling end,monthly_price=coalesce((p_settings->>'monthly_price')::numeric,monthly_price),annual_price=case when p_settings ? 'annual_price' then nullif(p_settings->>'annual_price','')::numeric else annual_price end,stripe_product_id=case when p_settings ? 'stripe_product_id' then nullif(p_settings->>'stripe_product_id','') else stripe_product_id end,stripe_monthly_price_id=case when p_settings ? 'stripe_monthly_price_id' then nullif(p_settings->>'stripe_monthly_price_id','') else stripe_monthly_price_id end,stripe_annual_price_id=case when p_settings ? 'stripe_annual_price_id' then nullif(p_settings->>'stripe_annual_price_id','') else stripe_annual_price_id end,instruction_version=coalesce(nullif(p_settings->>'instruction_version',''),instruction_version),instruction_text=coalesce(nullif(p_settings->>'instruction_text',''),instruction_text),updated_at=now(),updated_by=auth.uid() where id=true;
 for r in select key,value from jsonb_each(coalesce(p_modules,'{}'::jsonb)) loop update finlo_helper_module_controls set enabled=(r.value::text)::boolean,updated_at=now(),updated_by=auth.uid() where module_context=r.key; end loop;
 if p_business_id is not null and p_entitlement is not null then if p_entitlement not in('not_subscribed','subscribed','included_with_plan','trial','complimentary','suspended') then raise exception 'Invalid entitlement';end if;select id into mid from modules where slug='finlo_helper';insert into optional_addon_entitlements(business_id,module_id,entitlement_state,allowance_override,updated_by) values(p_business_id,mid,p_entitlement,p_allowance,auth.uid()) on conflict(business_id,module_id) do update set entitlement_state=excluded.entitlement_state,allowance_override=excluded.allowance_override,updated_at=now(),updated_by=auth.uid();end if;
end$$;
grant execute on function public.v6171_admin_helper_save(jsonb,jsonb,uuid,text,integer) to authenticated;

-- New businesses only: create minimal resumable onboarding state. Existing businesses are untouched.
create or replace function public.v6171_seed_new_business_onboarding() returns trigger language plpgsql security definer set search_path=public as $$begin insert into business_onboarding_state(business_id) values(new.id) on conflict do nothing;return new;end$$;
drop trigger if exists v6171_new_business_onboarding on public.businesses;
create trigger v6171_new_business_onboarding after insert on public.businesses for each row execute function public.v6171_seed_new_business_onboarding();

-- Final V61.71 hardening / commercial controls applied after foundation.
create or replace function public.v6171_admin_helper_plan_save(p_plan_id uuid,p_eligible boolean,p_included boolean,p_allowance integer default null) returns void language plpgsql security definer set search_path=public as $$begin if not is_super_admin() then raise exception 'Super Admin required' using errcode='42501';end if;insert into finlo_helper_plan_config(plan_id,eligible,included,allowance_override,updated_by) values(p_plan_id,p_eligible,p_included,p_allowance,auth.uid()) on conflict(plan_id) do update set eligible=excluded.eligible,included=excluded.included,allowance_override=excluded.allowance_override,updated_at=now(),updated_by=auth.uid();end$$;
revoke all on function public.v6171_admin_helper_plan_save(uuid,boolean,boolean,integer) from public,anon;grant execute on function public.v6171_admin_helper_plan_save(uuid,boolean,boolean,integer) to authenticated;

create or replace function public.v6171_helper_status(p_module text default 'onboarding') returns jsonb language plpgsql security definer set search_path=public as $$declare bid uuid:=current_business_id();cfg public.finlo_helper_settings;ctl boolean:=false;sub public.subscriptions;pc public.finlo_helper_plan_config;ent public.optional_addon_entitlements;mid uuid;st text:='not_subscribed';lim int:=0;used int:=0;ps timestamptz;pe timestamptz;entitled boolean:=false;begin if bid is null then raise exception 'No active business' using errcode='42501';end if;select * into cfg from finlo_helper_settings where id=true;select enabled into ctl from finlo_helper_module_controls where module_context=p_module;select id into mid from modules where slug='finlo_helper';select * into ent from optional_addon_entitlements where business_id=bid and module_id=mid;select * into sub from subscriptions where business_id=bid order by created_at desc limit 1;if sub.id is not null then select * into pc from finlo_helper_plan_config where plan_id=sub.plan_id;end if;if ent.business_id is not null then st:=ent.entitlement_state;elsif coalesce(pc.included,false) then st:='included_with_plan';else st:='not_subscribed';end if;entitled:=st in('subscribed','included_with_plan','trial','complimentary');if entitled then if st='trial' or(st='included_with_plan' and sub.status='trialing') then lim:=coalesce(ent.allowance_override,pc.allowance_override,cfg.trial_question_limit);else lim:=coalesce(ent.allowance_override,pc.allowance_override,cfg.default_question_limit);end if;else lim:=0;end if;if sub.id is not null then ps:=sub.current_period_start;pe:=sub.current_period_end;else ps:=date_trunc('month',now());pe:=date_trunc('month',now())+interval '1 month';end if;select count(*) into used from finlo_helper_usage where business_id=bid and success=true and created_at>=ps and created_at<pe;return jsonb_build_object('enabled',cfg.global_enabled and not cfg.emergency_disabled and coalesce(ctl,false),'global_enabled',cfg.global_enabled,'emergency_disabled',cfg.emergency_disabled,'module_enabled',coalesce(ctl,false),'entitlement',st,'entitled',entitled,'used',used,'limit',lim,'remaining',greatest(lim-used,0),'period_start',ps,'next_reset',pe,'contextual_awareness',cfg.contextual_awareness);end$$;
revoke all on function public.v6171_helper_status(text) from public,anon;grant execute on function public.v6171_helper_status(text) to authenticated;

revoke all on function public.v6171_onboarding_get() from public,anon;grant execute on function public.v6171_onboarding_get() to authenticated;
revoke all on function public.v6171_onboarding_save(smallint,jsonb) from public,anon;grant execute on function public.v6171_onboarding_save(smallint,jsonb) to authenticated;
revoke all on function public.v6171_onboarding_dismiss_getting_started() from public,anon;grant execute on function public.v6171_onboarding_dismiss_getting_started() to authenticated;
revoke all on function public.v6171_admin_helper_overview() from public,anon;grant execute on function public.v6171_admin_helper_overview() to authenticated;
revoke all on function public.v6171_admin_helper_save(jsonb,jsonb,uuid,text,integer) from public,anon;grant execute on function public.v6171_admin_helper_save(jsonb,jsonb,uuid,text,integer) to authenticated;
revoke all on function public.v6171_seed_new_business_onboarding() from public,anon,authenticated;

create or replace function public.v6171_admin_helper_overview() returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not is_super_admin() then raise exception 'Super Admin required' using errcode='42501';end if;
 return jsonb_build_object(
 'settings',(select to_jsonb(s)-'instruction_text' from finlo_helper_settings s where id=true),
 'instruction',(select jsonb_build_object('version',instruction_version,'text',instruction_text) from finlo_helper_settings where id=true),
 'modules',(select coalesce(jsonb_agg(to_jsonb(m) order by module_context),'[]') from finlo_helper_module_controls m),
 'plans',(select coalesce(jsonb_agg(jsonb_build_object('plan_id',p.id,'name',p.name,'slug',p.slug,'eligible',coalesce(c.eligible,true),'included',coalesce(c.included,false),'allowance_override',c.allowance_override) order by p.sort_order),'[]') from plans p left join finlo_helper_plan_config c on c.plan_id=p.id),
 'businesses',(select coalesce(jsonb_agg(jsonb_build_object('business_id',b.id,'business',b.name,'entitlement',coalesce(e.entitlement_state,case when pc.included then 'included_with_plan' else 'not_subscribed' end),'allowance_override',e.allowance_override,'used',x.used,'limit',x.lim,'remaining',greatest(x.lim-x.used,0),'last_used',x.last_used,'estimated_cost',x.estimated_cost) order by b.name),'[]') from businesses b left join subscriptions s on s.business_id=b.id left join finlo_helper_plan_config pc on pc.plan_id=s.plan_id left join modules m on m.slug='finlo_helper' left join optional_addon_entitlements e on e.business_id=b.id and e.module_id=m.id cross join finlo_helper_settings cfg cross join lateral(select (select count(*) from finlo_helper_usage u where u.business_id=b.id and u.success=true and u.created_at>=coalesce(s.current_period_start,date_trunc('month',now())) and u.created_at<coalesce(s.current_period_end,date_trunc('month',now())+interval '1 month')) used,coalesce(e.allowance_override,pc.allowance_override,case when s.status='trialing' then cfg.trial_question_limit else cfg.default_question_limit end) lim,(select max(created_at) from finlo_helper_usage u where u.business_id=b.id) last_used,(select sum(estimated_cost) from finlo_helper_usage u where u.business_id=b.id and u.created_at>=date_trunc('month',now())) estimated_cost)x where cfg.id=true),
 'kpis',jsonb_build_object('questions_this_month',(select count(*) from finlo_helper_usage where success=true and created_at>=date_trunc('month',now())),'businesses_using',(select count(distinct business_id) from finlo_helper_usage where success=true and created_at>=date_trunc('month',now())),'requests_today',(select count(*) from finlo_helper_usage where created_at>=current_date),'failed_requests',(select count(*) from finlo_helper_usage where success=false and created_at>=date_trunc('month',now())),'estimated_cost',(select coalesce(sum(estimated_cost),0) from finlo_helper_usage where created_at>=date_trunc('month',now()))));
end$$;
revoke all on function public.v6171_admin_helper_overview() from public,anon;grant execute on function public.v6171_admin_helper_overview() to authenticated;
