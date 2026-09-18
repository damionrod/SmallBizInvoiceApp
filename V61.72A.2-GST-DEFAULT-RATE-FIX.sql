-- Finlo V61.72A.2 — NZ GST default-rate seeding
-- Surgical change only: seed a stored NZ GST rate when onboarding confirms GST registration.
-- Existing positive/custom rates are preserved. No historical businesses are backfilled.

begin;

create or replace function public.v6171_onboarding_save(p_step smallint,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
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
   if v in ('yes','confirmed') then
     update businesses
        set settings=jsonb_set(coalesce(settings,'{}'::jsonb),'{gstRate}','15'::jsonb,true),updated_at=now()
      where id=bid
        and upper(coalesce(settings->>'country','NZ'))='NZ'
        and (not (coalesce(settings,'{}'::jsonb) ? 'gstRate') or settings->'gstRate' is null);
   end if;
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
revoke all on function public.v6171_onboarding_save(smallint,jsonb) from public,anon;

commit;
