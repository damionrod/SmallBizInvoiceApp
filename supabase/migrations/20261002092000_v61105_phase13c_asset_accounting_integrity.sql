-- Phase 13C: accounting integrity for confirmed capital equipment.
-- Reclassifies confirmed equipment out of P&L expense into Fixed Assets inside the supplier-bill journal.
-- Low-value equipment remains immediately expensed and is excluded from depreciation.
-- Existing posted journals/assets are not rewritten. Disposal accounting is intentionally not introduced here.
create or replace function public.v61105_phase13c_capitalise_expense_lines(p_business_id uuid,p_expense_id uuid,p_business_ratio numeric,p_lines jsonb,p_fixed_assets uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_result jsonb:=coalesce(p_lines,'[]'::jsonb); r record;
begin
 if p_fixed_assets is null then return v_result; end if;
 for r in
  with latest as (select pr.rows from public.purchase_invoice_reviews pr where pr.business_id=p_business_id and pr.expense_id=p_expense_id order by pr.revision desc limit 1),
  rows as (select x.value row_data from latest l cross join lateral jsonb_array_elements(l.rows) x),
  cap as (
   select nullif(row_data->>'category_id','')::uuid category_id,
    round(sum(coalesce((row_data->>'ex_gst')::numeric,0))*greatest(0,least(1,coalesce(p_business_ratio,1))),2) amount
   from rows where row_data->>'kind'='equipment' or (row_data->>'kind'='discount' and row_data->>'discount_for'='equipment')
   group by nullif(row_data->>'category_id','')::uuid)
  select c.category_id,c.amount,coalesce(sm.account_id,public.v6192_account_id(p_business_id,'business_expenses','6000')) expense_account
  from cap c left join public.accounting_source_mappings sm on sm.business_id=p_business_id and sm.source_type='expense_category' and sm.source_id=c.category_id and sm.purpose='expense' and coalesce(sm.archived,false)=false
  where c.amount>0
 loop
  if r.expense_account is null then raise exception 'Expense account mapping is unavailable for equipment capitalisation'; end if;
  v_result:=v_result||jsonb_build_array(
   jsonb_build_object('account_id',p_fixed_assets,'description','Capital equipment from reviewed supplier bill','debit',r.amount,'credit',0,'tax_code','NO_GST','tax_rate',0,'tax_amount',0),
   jsonb_build_object('account_id',r.expense_account,'description','Reclassify reviewed equipment to fixed assets','debit',0,'credit',r.amount,'tax_code','NO_GST','tax_rate',0,'tax_amount',0));
 end loop;
 return v_result;
end $$;
revoke execute on function public.v61105_phase13c_capitalise_expense_lines(uuid,uuid,numeric,jsonb,uuid) from public,anon,authenticated;

do $$
declare d text; p1 int; p2 int; marker text;
begin
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='v6192_post_operational_ledger';
 marker:='from mapped;'; p1:=strpos(d,marker); p2:=strpos(d,'if round(coalesce(r.business_gst_amount');
 if p1=0 or p2=0 or p2<=p1 then raise exception 'Phase 13C guard: supplier bill posting markers unavailable'; end if;
 d:=substr(d,1,p1+length(marker)-1)||E'\n\n    v_lines := public.v61105_phase13c_capitalise_expense_lines(v_business_id,r.id,v_ratio,v_lines,v_fixed_assets);\n\n    '||substr(d,p2);
 marker:='and a.disposed_on is null'; p1:=strpos(d,marker);
 if p1=0 then raise exception 'Phase 13C guard: depreciation marker unavailable'; end if;
 d:=substr(d,1,p1+length(marker)-1)||E'\n        and coalesce(a.tracking_treatment,'''') <> ''low_value'''||substr(d,p1+length(marker));
 execute d;
end $$;
