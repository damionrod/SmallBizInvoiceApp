alter table public.finlo_helper_settings
  add column if not exists default_helper_name text not null default 'Frindly';

update public.finlo_helper_settings
set default_helper_name='Frindly'
where id=true and nullif(btrim(default_helper_name),'') is null;

create or replace function public.v6171_helper_status(p_module text default 'onboarding'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  bid uuid:=current_business_id(); cfg public.finlo_helper_settings; ctl boolean:=false;
  sub public.subscriptions; pc public.finlo_helper_plan_config; ent public.optional_addon_entitlements; mid uuid;
  st text:='not_subscribed'; lim int:=0; used int:=0; ps timestamptz; pe timestamptz; entitled boolean:=false;
  business_settings jsonb:='{}'::jsonb; override_name text; default_name text; effective_name text;
begin
  if bid is null then raise exception 'No active business' using errcode='42501'; end if;
  select * into cfg from finlo_helper_settings where id=true;
  default_name:=left(coalesce(nullif(btrim(cfg.default_helper_name),''),'Frindly'),30);
  select coalesce(settings,'{}'::jsonb) into business_settings from businesses where id=bid;
  override_name:=left(nullif(btrim(regexp_replace(coalesce(business_settings->>'helperNameOverride',''),'\\s+',' ','g')),''),30);
  effective_name:=coalesce(override_name,default_name,'Frindly');
  select enabled into ctl from finlo_helper_module_controls where module_context=p_module;
  select id into mid from modules where slug='finlo_helper';
  select * into ent from optional_addon_entitlements where business_id=bid and module_id=mid;
  select * into sub from subscriptions where business_id=bid order by created_at desc limit 1;
  if sub.id is not null then select * into pc from finlo_helper_plan_config where plan_id=sub.plan_id; end if;
  if ent.business_id is not null then st:=ent.entitlement_state; elsif coalesce(pc.included,false) then st:='included_with_plan'; else st:='not_subscribed'; end if;
  entitled:=st in('subscribed','included_with_plan','trial','complimentary');
  if entitled then
    if st='trial' or(st='included_with_plan' and sub.status='trialing') then lim:=coalesce(ent.allowance_override,pc.allowance_override,cfg.trial_question_limit);
    else lim:=coalesce(ent.allowance_override,pc.allowance_override,cfg.default_question_limit); end if;
  else lim:=0; end if;
  if sub.id is not null then ps:=sub.current_period_start;pe:=sub.current_period_end;else ps:=date_trunc('month',now());pe:=date_trunc('month',now())+interval '1 month';end if;
  select count(*) into used from finlo_helper_usage where business_id=bid and success=true and created_at>=ps and created_at<pe;
  return jsonb_build_object('enabled',cfg.global_enabled and not cfg.emergency_disabled and coalesce(ctl,false),'global_enabled',cfg.global_enabled,'emergency_disabled',cfg.emergency_disabled,'module_enabled',coalesce(ctl,false),'entitlement',st,'entitled',entitled,'used',used,'limit',lim,'remaining',greatest(lim-used,0),'period_start',ps,'next_reset',pe,'contextual_awareness',cfg.contextual_awareness,'default_helper_name',default_name,'helper_name',effective_name,'helper_name_overridden',override_name is not null);
end$function$;

create or replace function public.v6171_admin_helper_save(p_settings jsonb, p_modules jsonb, p_business_id uuid default null::uuid, p_entitlement text default null::text, p_allowance integer default null::integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record;mid uuid;begin
if not is_super_admin() then raise exception 'Super Admin required' using errcode='42501';end if;
update finlo_helper_settings set
 default_helper_name=case when p_settings?'default_helper_name' then left(coalesce(nullif(btrim(regexp_replace(p_settings->>'default_helper_name','\\s+',' ','g')),''),'Frindly'),30) else default_helper_name end,
 global_enabled=coalesce((p_settings->>'global_enabled')::boolean,global_enabled),emergency_disabled=coalesce((p_settings->>'emergency_disabled')::boolean,emergency_disabled),provider=coalesce(nullif(p_settings->>'provider',''),provider),model=coalesce(nullif(p_settings->>'model',''),model),max_output_tokens=coalesce((p_settings->>'max_output_tokens')::int,max_output_tokens),contextual_awareness=coalesce((p_settings->>'contextual_awareness')::boolean,contextual_awareness),default_question_limit=coalesce((p_settings->>'default_question_limit')::int,default_question_limit),trial_question_limit=coalesce((p_settings->>'trial_question_limit')::int,trial_question_limit),monthly_cost_ceiling=case when p_settings?'monthly_cost_ceiling' then nullif(p_settings->>'monthly_cost_ceiling','')::numeric else monthly_cost_ceiling end,monthly_price=coalesce((p_settings->>'monthly_price')::numeric,monthly_price),annual_price=case when p_settings?'annual_price' then nullif(p_settings->>'annual_price','')::numeric else annual_price end,stripe_product_id=case when p_settings?'stripe_product_id' then nullif(p_settings->>'stripe_product_id','') else stripe_product_id end,stripe_monthly_price_id=case when p_settings?'stripe_monthly_price_id' then nullif(p_settings->>'stripe_monthly_price_id','') else stripe_monthly_price_id end,stripe_annual_price_id=case when p_settings?'stripe_annual_price_id' then nullif(p_settings->>'stripe_annual_price_id','') else stripe_annual_price_id end,instruction_version=coalesce(nullif(p_settings->>'instruction_version',''),instruction_version),instruction_text=coalesce(nullif(p_settings->>'instruction_text',''),instruction_text),updated_at=now(),updated_by=auth.uid() where id=true;
for r in select key,value from jsonb_each(coalesce(p_modules,'{}'::jsonb)) loop update finlo_helper_module_controls set enabled=(r.value::text)::boolean,updated_at=now(),updated_by=auth.uid() where module_context=r.key;end loop;
if p_business_id is not null and p_entitlement is not null then if p_entitlement not in('not_subscribed','subscribed','included_with_plan','trial','complimentary','suspended') then raise exception 'Invalid entitlement';end if;select id into mid from modules where slug='finlo_helper';insert into optional_addon_entitlements(business_id,module_id,entitlement_state,allowance_override,updated_by) values(p_business_id,mid,p_entitlement,p_allowance,auth.uid()) on conflict(business_id,module_id) do update set entitlement_state=excluded.entitlement_state,allowance_override=excluded.allowance_override,updated_at=now(),updated_by=auth.uid();end if;
end$function$;
