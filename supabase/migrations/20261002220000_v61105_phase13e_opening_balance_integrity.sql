-- Frindly v61.105 Phase 13E: opening balances and balance-sheet integrity.
-- Forward-only: existing unposted opening assets are not auto-posted or rewritten.

create or replace function public.se_create_opening_asset_v61105(
  p_business_id uuid,p_name text,p_original_cost numeric,p_gst_amount numeric,
  p_purchased_on date,p_available_on date,p_business_use numeric,p_condition text,
  p_category text,p_book_opening numeric,p_tax_opening numeric,p_opening_date date
) returns uuid
language plpgsql security definer set search_path='' as $$
declare
  v_item uuid; v_asset uuid; v_fixed uuid; v_opening_equity uuid; v_journal uuid;
  v_book_business numeric; v_lines jsonb;
begin
  perform public.se_require_access(p_business_id,true);
  if auth.uid() is null or public.current_business_id() is distinct from p_business_id then
    raise exception 'Choose the equipment business before adding an opening balance';
  end if;
  if nullif(trim(coalesce(p_name,'')),'') is null or p_book_opening is null or p_tax_opening is null or p_opening_date is null then
    raise exception 'Opening equipment needs a name, opening date and both opening values';
  end if;
  if p_original_cost is null or p_original_cost<0 or coalesce(p_gst_amount,0)<0 or p_gst_amount>p_original_cost
     or p_available_on<p_purchased_on or p_business_use not between 0 and 100
     or p_book_opening<0 or p_tax_opening<0 then raise exception 'Check equipment values'; end if;
  if p_opening_date < p_available_on then raise exception 'Opening balance date cannot be before the equipment was ready to use'; end if;
  if not public.v6170a_period_is_open(p_business_id,p_opening_date) then raise exception 'Opening balance date must be in an open accounting period'; end if;

  insert into public.accounting_accounts(
    business_id,account_code,account_name,account_type,normal_balance,report_section,system_key,
    xero_account_code,xero_account_type,description,is_system,is_control,created_by,updated_by
  ) values
    (p_business_id,'150','Fixed Assets - Equipment','fixed_asset','debit','asset','fixed_assets_equipment','150','FIXED','Equipment kept by the business.',true,false,auth.uid(),auth.uid()),
    (p_business_id,'859','Opening Balance Equity','equity','credit','equity','opening_balance_equity','859','EQUITY','Balancing equity for reviewed opening balances.',true,true,auth.uid(),auth.uid())
  on conflict (business_id,account_code) do nothing;

  v_fixed:=coalesce(public.v6192_account_id(p_business_id,'fixed_assets_equipment','150'),public.v6192_account_id(p_business_id,'fixed_assets','1500'));
  v_opening_equity:=public.v6192_account_id(p_business_id,'opening_balance_equity','859');
  if v_fixed is null or v_opening_equity is null then raise exception 'Opening-balance accounts are incomplete'; end if;

  v_item:=public.se_create_item(p_business_id,'equipment',p_name,null,'each',null);
  v_asset:=public.se_create_asset(p_business_id,v_item,p_original_cost,p_gst_amount,p_purchased_on,p_available_on,p_business_use,p_condition,p_category,p_book_opening,p_tax_opening);
  v_book_business:=round(p_book_opening*greatest(0,least(100,p_business_use))/100,2);
  if v_book_business<=0 then raise exception 'Business opening book value must be greater than zero'; end if;
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',v_fixed,'description','Opening equipment book value','debit',v_book_business,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
    jsonb_build_object('account_id',v_opening_equity,'description','Opening balance equity','debit',0,'credit',v_book_business,'tax_code','NO_GST','tax_rate',0,'tax_amount',0)
  );
  v_journal:=public.v6192_create_posted_journal(p_business_id,p_opening_date,'opening_balance','opening_asset',v_asset,'OPEN-ASSET-'||left(v_asset::text,8),'Opening equipment balance',v_lines);
  insert into public.se_activity(business_id,actor,action,item_id,detail)
  values(p_business_id,auth.uid(),'opening_balance_posted',v_item,jsonb_build_object('asset_id',v_asset,'journal_id',v_journal,'opening_date',p_opening_date,'book_value_business',v_book_business));
  return v_asset;
end $$;
revoke execute on function public.se_create_opening_asset_v61105(uuid,text,numeric,numeric,date,date,numeric,text,text,numeric,numeric,date) from public,anon;
grant execute on function public.se_create_opening_asset_v61105(uuid,text,numeric,numeric,date,date,numeric,text,text,numeric,numeric,date) to authenticated;

create or replace function public.v6170b_balance_sheet(p_as_of date)
returns table(assets numeric,liabilities numeric,equity numeric,current_profit numeric,balances boolean,opening_balance_message text)
language sql stable security definer set search_path='' as $$
with b as(select public.current_business_id() id),
x as(
 select a.account_type,a.report_section,a.normal_balance,
        sum(case when a.normal_balance='debit' then l.debit-l.credit else l.credit-l.debit end) bal
 from public.accounting_journals j join b on b.id=j.business_id
 join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
 join public.accounting_accounts a on a.id=l.account_id and a.business_id=j.business_id
 where j.status in('posted','reversed') and j.journal_date<=p_as_of
 group by a.account_type,a.report_section,a.normal_balance
),t as(
 select
  coalesce(sum(bal) filter(where report_section in('asset','assets','current_assets','fixed_assets') or account_type in('asset','bank','current_asset','fixed_asset','inventory','non_current_asset')),0) assets,
  coalesce(sum(bal) filter(where report_section in('liability','liabilities','current_liabilities','non_current_liabilities') or account_type in('liability','current_liability','non_current_liability') or (account_type='tax' and normal_balance='credit')),0) liabilities,
  coalesce(sum(bal) filter(where report_section='equity' or account_type='equity'),0) equity,
  coalesce(sum(bal) filter(where account_type in('revenue','other_income','income')),0)-coalesce(sum(bal) filter(where account_type in('expense','other_expense','cost_of_sales')),0) profit
 from x
),o as(
 select exists(select 1 from public.accounting_journals j join b on b.id=j.business_id where j.journal_type='opening_balance' and j.status in('posted','reversed') and j.journal_date<=p_as_of) ok
)
select assets,liabilities,equity,profit,round(assets,2)=round(liabilities+equity+profit,2),case when o.ok then 'Opening balance established' else 'Opening balance not yet established' end from t,o
$$;
revoke execute on function public.v6170b_balance_sheet(date) from public,anon;
grant execute on function public.v6170b_balance_sheet(date) to authenticated;

-- Teach Phase 13D disposal to use a posted opening-asset balance instead of rejecting it.
do $$
declare d text; old_block text; new_block text;
begin
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='se_record_asset_event';
 old_block:=$old$if i.origin_expense_id is null then raise exception 'Opening equipment has no posted opening-balance asset journal yet. Leave it unchanged until opening balances are posted.'; end if;
  if v_fixed is null or v_accum is null then raise exception 'Fixed-asset accounts are incomplete'; end if;
  select round(coalesce(sum(l.debit-l.credit),0),2) into v_capitalised from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.business_id=p_business_id and j.source_type='expense' and j.source_id=i.origin_expense_id and j.status='posted' and l.account_id=v_fixed;$old$;
 new_block:=$new$if v_fixed is null or v_accum is null then raise exception 'Fixed-asset accounts are incomplete'; end if;
  if i.origin_expense_id is null then
   select round(coalesce(sum(l.debit-l.credit),0),2) into v_capitalised from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.business_id=p_business_id and j.source_type='opening_asset' and j.source_id=a.id and j.status='posted' and l.account_id=v_fixed;
   if v_capitalised<=0 then raise exception 'Opening equipment has no posted opening-balance asset journal yet. Review and post its opening balance before disposal.'; end if;
  else
   select round(coalesce(sum(l.debit-l.credit),0),2) into v_capitalised from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id where j.business_id=p_business_id and j.source_type='expense' and j.source_id=i.origin_expense_id and j.status='posted' and l.account_id=v_fixed;
  end if;$new$;
 if strpos(d,old_block)=0 then raise exception 'Phase 13E guard: Phase 13D opening-asset disposal block not found'; end if;
 d:=replace(d,old_block,new_block); execute d;
end $$;

-- Existing opening assets are intentionally not auto-posted. Historical values require review first.
