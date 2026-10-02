-- Frindly v61.105 Phase 13D: asset disposal accounting integrity.
-- Forward-only. Existing disposals/journals are not rewritten.

alter table public.se_assets add column if not exists disposal_ex_gst numeric;
alter table public.se_assets add column if not exists disposal_gst_output numeric;
alter table public.se_assets add column if not exists disposal_gst_credit_adjustment numeric;
alter table public.se_assets add column if not exists disposal_journal_id uuid references public.accounting_journals(id) on delete restrict;
alter table public.se_assets add column if not exists disposal_reason text;
alter table public.se_assets add column if not exists disposal_accounted_at timestamptz;

create or replace function public.se_record_asset_event(
 p_business_id uuid,p_asset_id uuid,p_action text,p_event_date date,p_proceeds numeric,p_note text,p_assigned_to text
) returns uuid language plpgsql security definer set search_path='' as $$
declare
 a public.se_assets%rowtype; i public.se_items%rowtype; v_action text:=lower(trim(coalesce(p_action,'')));
 v_date date:=coalesce(p_event_date,current_date); v_proceeds numeric:=coalesce(p_proceeds,0); v_reason text:=nullif(trim(coalesce(p_note,'')),'');
 v_tax jsonb; v_registered boolean:=false; v_rate numeric:=0; v_gst_output numeric:=0; v_gst_credit numeric:=0; v_ex_gst numeric:=0;
 v_business_ratio numeric:=1; v_private_gross numeric:=0; v_business_net_proceeds numeric:=0;
 v_fixed uuid; v_accum uuid; v_bank uuid; v_gst_payable uuid; v_owner uuid; v_gain uuid; v_loss uuid;
 v_capitalised numeric:=0; v_accum_depn numeric:=0; v_nbv numeric:=0; v_gain_amt numeric:=0; v_loss_amt numeric:=0; v_journal uuid; v_lines jsonb:='[]'::jsonb;
begin
 perform public.se_require_access(p_business_id,true);
 if public.current_business_id() is distinct from p_business_id then raise exception 'Choose the asset business before recording this event'; end if;
 select * into a from public.se_assets where id=p_asset_id and business_id=p_business_id for update;
 if a.id is null then raise exception 'Equipment is missing'; end if;
 select * into i from public.se_items where id=a.item_id and business_id=p_business_id;
 if v_action not in ('sold','disposed','lost','broken','note','accountant_review') then raise exception 'Unsupported equipment action'; end if;
 if v_action in ('note','accountant_review','lost','broken') then
   if v_reason is null then raise exception 'Enter a note'; end if;
   insert into public.se_activity(business_id,actor,action,item_id,detail) values
    (p_business_id,auth.uid(),case when v_action='accountant_review' then 'accountant_review_requested' when v_action in ('lost','broken') then 'tool_status_changed' else 'asset_note_added' end,a.item_id,
     jsonb_build_object('asset_id',a.id,'event',v_action,'date',v_date,'note',v_reason,'assigned_to',nullif(trim(coalesce(p_assigned_to,'')),'')));
   return a.id;
 end if;
 if a.disposed_on is not null or a.disposal_journal_id is not null then raise exception 'Equipment is already disposed'; end if;
 if v_date < coalesce(a.purchased_on,v_date) then raise exception 'Disposal precedes purchase'; end if;
 if v_proceeds < 0 then raise exception 'Proceeds cannot be negative'; end if;
 if v_action='disposed' and v_reason is null then v_reason:='Disposed'; end if;
 if v_action='sold' and v_reason is null then v_reason:='Sold'; end if;

 v_business_ratio:=greatest(0,least(1,coalesce(a.business_use_percent,100)/100));
 v_tax:=public.v61105_effective_tax_status(v_date);
 v_registered:=coalesce((v_tax->>'gst_registered')::boolean,false);
 v_rate:=case when v_registered then coalesce((v_tax->>'effective_rate_percent')::numeric,0) else 0 end;
 if v_registered and v_proceeds>0 and v_rate>0 then
   v_gst_output:=round(v_proceeds*v_rate/(100+v_rate),2);
   -- NZ final adjustment / AU decreasing adjustment: only where the asset has evidence of GST at acquisition.
   if coalesce(a.gst_amount,0)>0 then v_gst_credit:=round(v_gst_output*(1-v_business_ratio),2); end if;
 end if;
 v_ex_gst:=round(v_proceeds-v_gst_output,2);
 v_private_gross:=round(v_proceeds*(1-v_business_ratio),2);
 v_business_net_proceeds:=round(v_ex_gst*v_business_ratio,2);

 v_fixed:=coalesce(public.v6192_account_id(p_business_id,'fixed_assets_equipment','150'),public.v6192_account_id(p_business_id,'fixed_assets','1500'));
 v_accum:=coalesce(public.v6192_account_id(p_business_id,'accum_depn_equipment','155'),public.v6192_account_id(p_business_id,'accumulated_depreciation','1590'));
 v_bank:=coalesce(public.v6192_account_id(p_business_id,'bank_main','090'),public.v6192_account_id(p_business_id,'bank','1000'));
 v_gst_payable:=coalesce(public.v6192_account_id(p_business_id,'gst_collected','260'),public.v6192_account_id(p_business_id,'gst_payable','2100'));
 v_owner:=coalesce(public.v6192_account_id(p_business_id,'owner_drawings','800'),public.v6192_account_id(p_business_id,'owner_funds','3000'));
 insert into public.accounting_accounts(business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by)
 values
  (p_business_id,'206','Gain on Disposal of Assets','other_income','credit','income','asset_disposal_gain','4900','OTHERINCOME','Book gain on disposal of business assets.',true,false,auth.uid(),auth.uid()),
  (p_business_id,'430','Loss on Disposal of Assets','other_expense','debit','operating_expenses','asset_disposal_loss','6900','EXPENSE','Book loss on disposal of business assets.',true,false,auth.uid(),auth.uid())
 on conflict (business_id,account_code) do nothing;
 v_gain:=public.v6192_account_id(p_business_id,'asset_disposal_gain','206');
 v_loss:=public.v6192_account_id(p_business_id,'asset_disposal_loss','430');
 if v_bank is null or v_gst_payable is null or v_owner is null or v_gain is null or v_loss is null then raise exception 'Asset disposal accounting accounts are incomplete'; end if;

 if coalesce(a.tracking_treatment,'depreciable')='low_value' then
   v_capitalised:=0; v_accum_depn:=0; v_nbv:=0;
 else
   if i.origin_expense_id is null then raise exception 'Opening equipment has no posted opening-balance asset journal yet. Leave it unchanged until opening balances are posted.'; end if;
   if v_fixed is null or v_accum is null then raise exception 'Fixed-asset accounts are incomplete'; end if;
   select round(coalesce(sum(l.debit-l.credit),0),2) into v_capitalised
   from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
   where j.business_id=p_business_id and j.source_type='expense' and j.source_id=i.origin_expense_id and j.status='posted' and l.account_id=v_fixed;
   if v_capitalised<=0 then raise exception 'This equipment is not yet capitalised in the formal ledger. Post/review its supplier bill before disposal.'; end if;
   select round(coalesce(sum(l.credit-l.debit),0),2) into v_accum_depn
   from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
   where j.business_id=p_business_id and j.source_type='depreciation' and j.source_id=a.id and j.status='posted' and j.journal_date<=v_date and l.account_id=v_accum;
   v_accum_depn:=least(v_capitalised,greatest(0,v_accum_depn));
   v_nbv:=round(v_capitalised-v_accum_depn,2);
 end if;

 v_gain_amt:=greatest(round(v_business_net_proceeds-v_nbv,2),0);
 v_loss_amt:=greatest(round(v_nbv-v_business_net_proceeds,2),0);
 v_lines:=jsonb_build_array(jsonb_build_object('account_id',v_bank,'description','Asset disposal proceeds','debit',round(v_proceeds,2),'credit',0,'tax_code',case when v_registered then 'GST' else 'NO_GST' end,'tax_rate',v_rate,'tax_amount',0));
 if v_accum_depn>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_accum,'description','Clear accumulated depreciation','debit',v_accum_depn,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
 if v_loss_amt>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_loss,'description','Loss on asset disposal','debit',v_loss_amt,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
 if v_capitalised>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_fixed,'description','Remove disposed asset','debit',0,'credit',v_capitalised,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
 if round(v_gst_output-v_gst_credit,2)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_gst_payable,'description','Net GST on asset disposal','debit',0,'credit',round(v_gst_output-v_gst_credit,2),'tax_code','GST','tax_rate',v_rate,'tax_amount',round(v_gst_output-v_gst_credit,2))); end if;
 if v_private_gross>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_owner,'description','Private share of disposal proceeds','debit',0,'credit',v_private_gross,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;
 if v_gain_amt>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_gain,'description','Gain on asset disposal','debit',0,'credit',v_gain_amt,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)); end if;

 v_journal:=public.v6192_create_posted_journal(p_business_id,v_date,'manual','asset_disposal',a.id,'ASSET-'||left(a.id::text,8),'Asset disposal',v_lines);
 update public.se_assets set disposed_on=v_date,disposal_proceeds=v_proceeds,disposal_ex_gst=v_ex_gst,disposal_gst_output=v_gst_output,
   disposal_gst_credit_adjustment=v_gst_credit,disposal_journal_id=v_journal,disposal_reason=v_reason,disposal_accounted_at=now() where id=a.id and business_id=p_business_id;
 insert into public.se_activity(business_id,actor,action,item_id,detail) values
  (p_business_id,auth.uid(),case when v_action='sold' then 'equipment_sold' else 'equipment_disposed' end,a.item_id,
   jsonb_build_object('asset_id',a.id,'proceeds',v_proceeds,'date',v_date,'reason',v_reason,'journal_id',v_journal,'gst_output',v_gst_output,'gst_credit_adjustment',v_gst_credit,'business_use_percent',a.business_use_percent));
 return a.id;
end $$;
revoke execute on function public.se_record_asset_event(uuid,uuid,text,date,numeric,text,text) from public,anon;
grant execute on function public.se_record_asset_event(uuid,uuid,text,date,numeric,text,text) to authenticated;

-- Include accounted asset disposals in GST calculation using stored disposal tax snapshots, never current settings.
do $$
declare d text; p1 int; marker text;
begin
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='v6170e_gst_calculate';
 marker:='select purch_ex-coalesce(sum(c.ex_gst*coalesce(e.business_use_percent,100)/100),0),purch_gst-coalesce(sum(c.gst_amount*coalesce(e.business_use_percent,100)/100),0) into purch_ex,purch_gst';
 p1:=strpos(d,marker); if p1=0 then raise exception 'Phase 13D guard: GST purchase-credit marker unavailable'; end if;
 d:=substr(d,1,p1-1)||E'\n select sales_ex+coalesce(sum(a.disposal_ex_gst),0),sales_gst+coalesce(sum(a.disposal_gst_output),0) into sales_ex,sales_gst from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;\n select sales_items || coalesce(jsonb_agg(jsonb_build_object(''source_type'',''asset_disposal'',''source_id'',a.id,''date'',a.disposed_on,''reference'',''ASSET-''||left(a.id::text,8),''party'',''Asset disposal'',''ex_gst'',a.disposal_ex_gst,''gst'',a.disposal_gst_output,''total'',a.disposal_proceeds) order by a.disposed_on),''[]''::jsonb) into sales_items from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;\n '||substr(d,p1);
 marker:='select count(*) into missing_count from expenses e'; p1:=strpos(d,marker); if p1=0 then raise exception 'Phase 13D guard: GST adjustment marker unavailable'; end if;
 d:=substr(d,1,p1-1)||E'\n select credit_adj+coalesce(sum(a.disposal_gst_credit_adjustment),0), adjustment_items || coalesce(jsonb_agg(jsonb_build_object(''source_type'',''asset_disposal'',''source_id'',a.id,''date'',a.disposed_on,''type'',''asset_disposal_private_use'',''direction'',''credit'',''gst_amount'',a.disposal_gst_credit_adjustment,''reason'',''Final/decreasing GST adjustment on mixed-use asset disposal'') order by a.disposed_on) filter (where coalesce(a.disposal_gst_credit_adjustment,0)>0),''[]''::jsonb) into credit_adj,adjustment_items from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;\n '||substr(d,p1);
 execute d;
end $$;

-- Historical se_record_disposal is retained for compatibility but must not bypass the accounting-aware workflow.
revoke execute on function public.se_record_disposal(uuid,uuid,date,numeric,text) from public,anon,authenticated;
