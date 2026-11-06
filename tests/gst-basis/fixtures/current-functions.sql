CREATE OR REPLACE FUNCTION public.frindly_gst_boundary_basis_v1(p_from date, p_to date, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=public.current_business_id();result jsonb;items jsonb;ex numeric;gst numeric;
begin
 result:=frindly_cash.gst_base(p_from,p_to,p_basis);
 select coalesce(sum(c.amount-c.gst_amount),0),coalesce(sum(c.gst_amount),0),coalesce(jsonb_agg(jsonb_build_object('source_type','cash_transaction','source_id',c.id,'date',l.transaction_date,'reference',coalesce(c.reference,c.description),'party',c.party,'ex_gst',c.amount-c.gst_amount,'gst',c.gst_amount,'total',c.amount,'classification',case when c.gst_treatment='ZERO' then 'zero_rated' else 'standard' end)),'[]'::jsonb) into ex,gst,items
 from public.cash_transactions c join public.cash_transaction_legs l on l.transaction_id=c.id and l.business_id=c.business_id
 where c.business_id=b and c.status='recorded' and c.purpose='grant' and c.gst_treatment in ('GST','ZERO') and l.transaction_date between p_from and p_to;
 return result||jsonb_build_object('sales_ex_gst',coalesce((result->>'sales_ex_gst')::numeric,0)+ex,'gst_collected',coalesce((result->>'gst_collected')::numeric,0)+gst,'gst_net',coalesce((result->>'gst_net')::numeric,0)+gst,'sales_items',coalesce(result->'sales_items','[]'::jsonb)||items);
end $function$
;
CREATE OR REPLACE FUNCTION public.frindly_gst_calculate_basis_v1(p_from date, p_to date, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare bid uuid:=current_business_id(); cfg jsonb; basis text; registered boolean; sales_ex numeric:=0; sales_gst numeric:=0; purch_ex numeric:=0; purch_gst numeric:=0; debit_adj numeric:=0; credit_adj numeric:=0; legacy_count int:=0; missing_count int:=0; sales_items jsonb:='[]'; purchase_items jsonb:='[]'; adjustment_items jsonb:='[]'; review jsonb:='[]'; conflict_items jsonb:='[]';
begin
 if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid GST period';end if;
 cfg:=v6170e_gst_settings(p_to); basis:=coalesce(nullif(p_basis,''),cfg->>'accounting_basis'); basis:=case basis when 'non_cash' then 'invoice' when 'cash' then 'payments' else basis end; if basis not in ('invoice','payments','hybrid') then raise exception 'Invalid GST basis'; end if; registered:=coalesce((cfg->>'gst_registered')::boolean,false);
 if not registered then return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'sales_ex_gst',0,'gst_collected',0,'purchases_ex_gst',0,'gst_paid',0,'debit_adjustments',0,'credit_adjustments',0,'gst_net',0,'sales_items','[]'::jsonb,'purchase_items','[]'::jsonb,'adjustment_items','[]'::jsonb,'review_items',jsonb_build_array(jsonb_build_object('severity','blocking','code','not_registered','message','Business is not GST registered for this period.')));end if;
 if basis in('invoice','hybrid') then
  select coalesce(sum(greatest(i.total-i.gst,0)),0),coalesce(sum(i.gst),0),coalesce(jsonb_agg(jsonb_build_object('source_type','invoice','source_id',i.id,'date',i.invoice_date,'reference',i.invoice_number,'party',c.name,'party_id',i.customer_id,'ex_gst',greatest(i.total-i.gst,0),'gst',i.gst,'total',i.total) order by i.invoice_date,i.invoice_number),'[]') into sales_ex,sales_gst,sales_items from invoices i left join customers c on c.id=i.customer_id and c.business_id=i.business_id where i.business_id=bid and i.invoice_date between p_from and p_to and coalesce(i.lifecycle_state,'issued') not in('draft','voided');
 else
  select coalesce(sum(greatest(cp.amount-coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),0)),0),coalesce(sum(coalesce(i.gst,0)*(cp.amount/nullif(i.total,0))),0),coalesce(jsonb_agg(jsonb_build_object('source_type','customer_payment','source_id',cp.id,'date',cp.payment_date,'reference',i.invoice_number,'party',c.name,'party_id',i.customer_id,'ex_gst',greatest(cp.amount-coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),0),'gst',coalesce(i.gst,0)*(cp.amount/nullif(i.total,0)),'total',cp.amount) order by cp.payment_date),'[]') into sales_ex,sales_gst,sales_items from customer_payments cp join invoices i on i.id=cp.invoice_id and i.business_id=cp.business_id left join customers c on c.id=i.customer_id and c.business_id=i.business_id where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=false and i.total>0 and coalesce(i.lifecycle_state,'issued')='issued';
  select count(*) into legacy_count from customer_payments cp where cp.business_id=bid and cp.payment_date between p_from and p_to and coalesce(cp.is_legacy_estimate,false)=true;
  if legacy_count>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','legacy_estimated_payments','count',legacy_count,'message','Legacy estimated customer payment dates cannot be used as precise payments-basis GST evidence. Review required.'));end if;
 end if;
 if basis='invoice' then
  select coalesce(sum(e.ex_gst*coalesce(e.business_use_percent,100)/100),0),coalesce(sum(e.gst_amount*coalesce(e.business_use_percent,100)/100),0),coalesce(jsonb_agg(jsonb_build_object('source_type','expense','source_id',e.id,'date',e.invoice_date,'reference',e.expense_number,'party',e.supplier_name,'party_id',e.supplier_id,'ex_gst',e.ex_gst*coalesce(e.business_use_percent,100)/100,'gst',e.gst_amount*coalesce(e.business_use_percent,100)/100,'total',e.total_amount*coalesce(e.business_use_percent,100)/100,'business_use_percent',coalesce(e.business_use_percent,100)) order by e.invoice_date,e.expense_number),'[]') into purch_ex,purch_gst,purchase_items from expenses e where e.business_id=bid and e.invoice_date between p_from and p_to and coalesce(e.lifecycle_state,'recorded')='recorded';
 else
  select coalesce(sum(greatest(ep.amount-(e.gst_amount*(ep.amount/nullif(e.total_amount,0))),0)*coalesce(e.business_use_percent,100)/100),0),coalesce(sum(e.gst_amount*(ep.amount/nullif(e.total_amount,0))*coalesce(e.business_use_percent,100)/100),0),coalesce(jsonb_agg(jsonb_build_object('source_type','expense_payment','source_id',ep.id,'date',ep.payment_date,'reference',e.expense_number,'party',e.supplier_name,'party_id',e.supplier_id,'ex_gst',greatest(ep.amount-(e.gst_amount*(ep.amount/nullif(e.total_amount,0))),0)*coalesce(e.business_use_percent,100)/100,'gst',e.gst_amount*(ep.amount/nullif(e.total_amount,0))*coalesce(e.business_use_percent,100)/100,'total',ep.amount*coalesce(e.business_use_percent,100)/100,'business_use_percent',coalesce(e.business_use_percent,100)) order by ep.payment_date),'[]') into purch_ex,purch_gst,purchase_items from expense_payments ep join expenses e on e.id=ep.expense_id and e.business_id=ep.business_id where ep.business_id=bid and ep.payment_date between p_from and p_to and e.total_amount>0 and coalesce(e.lifecycle_state,'recorded')='recorded';
 end if;
 if basis='payments' and exists(select 1 from customer_credit_notes where business_id=bid and lifecycle_state='issued' and credit_date between p_from and p_to) then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','cash_customer_credit_timing','message','Cash-basis credit note refund timing needs review before filing.')); end if;
 select sales_ex-coalesce(sum(c.ex_gst),0),sales_gst-coalesce(sum(c.gst_amount),0) into sales_ex,sales_gst from customer_credit_notes c where c.business_id=bid and c.lifecycle_state='issued' and c.credit_date between p_from and p_to;
 select sales_items || coalesce(jsonb_agg(jsonb_build_object('source_type','customer_credit_note','source_id',c.id,'date',c.credit_date,'reference',c.credit_note_number,'party',cu.name,'party_id',c.customer_id,'ex_gst',-c.ex_gst,'gst',-c.gst_amount,'total',-c.total_amount,'original_reference',i.invoice_number) order by c.credit_date,c.credit_note_number),'[]'::jsonb) into sales_items from customer_credit_notes c left join customers cu on cu.id=c.customer_id and cu.business_id=c.business_id left join invoices i on i.id=c.original_invoice_id and i.business_id=c.business_id where c.business_id=bid and c.lifecycle_state='issued' and c.credit_date between p_from and p_to;
 
 if basis='payments' and exists(select 1 from public.se_assets where business_id=bid and disposed_on between p_from and p_to and disposal_accounted_at is not null) then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','cash_asset_disposal_timing','message','Cash-basis asset disposal receipt timing needs review before filing.')); end if;
 select sales_ex+coalesce(sum(a.disposal_ex_gst),0),sales_gst+coalesce(sum(a.disposal_gst_output),0) into sales_ex,sales_gst from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;
 select sales_items || coalesce(jsonb_agg(jsonb_build_object('source_type','asset_disposal','source_id',a.id,'date',a.disposed_on,'reference','ASSET-'||left(a.id::text,8),'party','Asset disposal','ex_gst',a.disposal_ex_gst,'gst',a.disposal_gst_output,'total',a.disposal_proceeds) order by a.disposed_on),'[]'::jsonb) into sales_items from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;
 if basis<>'invoice' and exists(select 1 from supplier_credits where business_id=bid and lifecycle_state='recorded' and credit_date between p_from and p_to) then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','cash_supplier_credit_timing','message','Supplier credit refund timing needs review before filing.')); end if;
 select purch_ex-coalesce(sum(c.ex_gst*coalesce(e.business_use_percent,100)/100),0),purch_gst-coalesce(sum(c.gst_amount*coalesce(e.business_use_percent,100)/100),0) into purch_ex,purch_gst from supplier_credits c join expenses e on e.id=c.original_expense_id and e.business_id=c.business_id where c.business_id=bid and c.lifecycle_state='recorded' and c.credit_date between p_from and p_to;
 select purchase_items || coalesce(jsonb_agg(jsonb_build_object('source_type','supplier_credit','source_id',c.id,'date',c.credit_date,'reference',c.credit_note_number,'party',e.supplier_name,'party_id',c.supplier_id,'ex_gst',-(c.ex_gst*coalesce(e.business_use_percent,100)/100),'gst',-(c.gst_amount*coalesce(e.business_use_percent,100)/100),'total',-(c.total_amount*coalesce(e.business_use_percent,100)/100),'business_use_percent',coalesce(e.business_use_percent,100),'original_reference',e.expense_number) order by c.credit_date,c.credit_note_number),'[]'::jsonb) into purchase_items from supplier_credits c join expenses e on e.id=c.original_expense_id and e.business_id=c.business_id where c.business_id=bid and c.lifecycle_state='recorded' and c.credit_date between p_from and p_to;
 select coalesce(sum(case when direction='debit' then gst_amount else 0 end),0),coalesce(sum(case when direction='credit' then gst_amount else 0 end),0),coalesce(jsonb_agg(jsonb_build_object('id',id,'date',adjustment_date,'type',adjustment_type,'direction',direction,'gst_amount',gst_amount,'reason',reason,'reference',reference) order by adjustment_date),'[]') into debit_adj,credit_adj,adjustment_items from gst_adjustments where business_id=bid and status='active' and adjustment_date between p_from and p_to;
 
 select credit_adj+coalesce(sum(a.disposal_gst_credit_adjustment),0), adjustment_items || coalesce(jsonb_agg(jsonb_build_object('source_type','asset_disposal','source_id',a.id,'date',a.disposed_on,'type','asset_disposal_private_use','direction','credit','gst_amount',a.disposal_gst_credit_adjustment,'reason','Final/decreasing GST adjustment on mixed-use asset disposal') order by a.disposed_on) filter (where coalesce(a.disposal_gst_credit_adjustment,0)>0),'[]'::jsonb) into credit_adj,adjustment_items from public.se_assets a where a.business_id=bid and a.disposed_on between p_from and p_to and a.disposal_accounted_at is not null;
 select count(*) into missing_count from expenses e where e.business_id=bid and e.invoice_date between p_from and p_to and coalesce(e.lifecycle_state,'recorded')='recorded' and e.total_amount>0 and e.gst_amount is null;
 if missing_count>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','missing_gst','count',missing_count,'message','Recorded expenses are missing GST information.'));end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'period_start',r.period_start,'period_end',r.period_end,'status',r.status,'calculation_version',r.calculation_version) order by r.period_start),'[]') into conflict_items from gst_returns r where r.business_id=bid and r.status='finalised' and daterange(r.period_start,r.period_end,'[]') && daterange(p_from,p_to,'[]') and not(r.period_start=p_from and r.period_end=p_to);
 if jsonb_array_length(conflict_items)>0 then review:=review||jsonb_build_array(jsonb_build_object('severity','blocking','code','finalised_period_overlap','message','GST period conflict — an existing finalised return overlaps this period.','returns',conflict_items));end if;
 return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',basis,'sales_ex_gst',round(sales_ex,2),'gst_collected',round(sales_gst,2),'purchases_ex_gst',round(purch_ex,2),'gst_paid',round(purch_gst,2),'debit_adjustments',round(debit_adj,2),'credit_adjustments',round(credit_adj,2),'gst_net',round(sales_gst+debit_adj-purch_gst-credit_adj,2),'sales_items',sales_items,'purchase_items',purchase_items,'adjustment_items',adjustment_items,'review_items',review,'calculation_version','frindly-gst-basis-v1');
end$function$
;
CREATE OR REPLACE FUNCTION public.frindly_save_gst_basis_v1(p_from date, p_to date, p_status text DEFAULT 'draft'::text, p_basis text DEFAULT NULL::text)
 RETURNS gst_returns
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare bid uuid:=current_business_id(); calc jsonb; r gst_returns; blockers int; cfg jsonb; v_existing boolean:=false; v_conflict gst_returns;
begin
 if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'GST return access denied' using errcode='42501';end if;
 if p_status not in('draft','reviewed','finalised') then raise exception 'Invalid GST return status';end if;
 select * into r from gst_returns where business_id=bid and period_start=p_from and period_end=p_to for update; v_existing:=found;
 if v_existing and r.status='finalised' then raise exception 'This GST return is finalised and locked';end if;
 if p_status='finalised' then
  select * into v_conflict from gst_returns x where x.business_id=bid and x.status='finalised' and daterange(x.period_start,x.period_end,'[]') && daterange(p_from,p_to,'[]') and (not v_existing or x.id<>r.id) order by x.period_start limit 1 for update;
  if found then raise exception 'GST period conflict: existing finalised return % to % overlaps this period',v_conflict.period_start,v_conflict.period_end using errcode='23514';end if;
 end if;
 calc:=public.frindly_gst_boundary_basis_v1(p_from,p_to,p_basis);
 if p_status='finalised' and nullif(p_basis,'') is not null and p_basis<>(case (public.v6170e_gst_settings(p_to)->>'accounting_basis') when 'non_cash' then 'invoice' when 'cash' then 'payments' else (public.v6170e_gst_settings(p_to)->>'accounting_basis') end) then raise exception 'Selected GST basis differs from business settings. Confirm the authorised basis change in Settings before finalising.'; end if; cfg:=calc->'settings'; select count(*) into blockers from jsonb_array_elements(calc->'review_items') x where x->>'severity'='blocking';
 if p_status='finalised' and blockers>0 then raise exception 'GST return has blocking review items and cannot be finalised';end if;
 if v_existing then
  update gst_returns set status=p_status,gst_rate=15,taxable_sales_ex_gst=(calc->>'sales_ex_gst')::numeric,gst_collected=(calc->>'gst_collected')::numeric,taxable_purchases_ex_gst=(calc->>'purchases_ex_gst')::numeric,gst_paid=(calc->>'gst_paid')::numeric,debit_adjustments=(calc->>'debit_adjustments')::numeric,credit_adjustments=(calc->>'credit_adjustments')::numeric,gst_net=(calc->>'gst_net')::numeric,snapshot=calc,accounting_basis=calc->>'basis',filing_frequency=cfg->>'filing_frequency',statutory_rule_snapshot=jsonb_build_object('country','NZ','standard_rate_percent',15),registration_snapshot=cfg,review_items=calc->'review_items',calculation_version='frindly-gst-boundary-v1',finalised_at=case when p_status='finalised' then now() else null end,finalised_by=case when p_status='finalised' then auth.uid() else null end,updated_at=now(),updated_by=auth.uid() where id=r.id returning * into r;
 else
  insert into gst_returns(business_id,period_start,period_end,status,gst_rate,taxable_sales_ex_gst,gst_collected,taxable_purchases_ex_gst,gst_paid,debit_adjustments,credit_adjustments,gst_net,snapshot,accounting_basis,filing_frequency,statutory_rule_snapshot,registration_snapshot,review_items,calculation_version,finalised_at,finalised_by,created_by,updated_by)
  values(bid,p_from,p_to,p_status,15,(calc->>'sales_ex_gst')::numeric,(calc->>'gst_collected')::numeric,(calc->>'purchases_ex_gst')::numeric,(calc->>'gst_paid')::numeric,(calc->>'debit_adjustments')::numeric,(calc->>'credit_adjustments')::numeric,(calc->>'gst_net')::numeric,calc,calc->>'basis',cfg->>'filing_frequency',jsonb_build_object('country','NZ','standard_rate_percent',15),cfg,calc->'review_items','frindly-gst-boundary-v1',case when p_status='finalised' then now() end,case when p_status='finalised' then auth.uid() end,auth.uid(),auth.uid()) returning * into r;
 end if;
 if p_status='finalised' then update gst_adjustments set included_return_id=r.id,updated_at=now(),updated_by=auth.uid() where business_id=bid and status='active' and adjustment_date between p_from and p_to and included_return_id is null;end if;
 return r;
end$function$
;
CREATE OR REPLACE FUNCTION public.v6170e_gst_settings(p_on date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare bid uuid:=current_business_id(); h record; f record;begin if bid is null or not v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501'; end if; select * into h from gst_settings_history where business_id=bid and effective_from<=p_on order by effective_from desc limit 1; if found then return jsonb_build_object('effective_from',h.effective_from,'gst_registered',h.gst_registered,'gst_number',h.gst_number,'accounting_basis',h.accounting_basis,'filing_frequency',h.filing_frequency,'balance_date_month',h.balance_date_month,'balance_date_day',h.balance_date_day); end if; select * into f from financial_settings where business_id=bid limit 1; return jsonb_build_object('effective_from',null,'gst_registered',coalesce(f.gst_registered,true),'gst_number',f.gst_number,'accounting_basis',coalesce(f.gst_accounting_basis,'invoice'),'filing_frequency',coalesce(f.gst_filing_frequency,'two_monthly'),'balance_date_month',coalesce(f.balance_date_month,3),'balance_date_day',coalesce(f.balance_date_day,31)); end$function$
;
CREATE OR REPLACE FUNCTION public.v6170e_create_gst_adjustment(p_date date, p_type text, p_direction text, p_gst_amount numeric, p_reason text, p_reference text DEFAULT NULL::text, p_evidence text DEFAULT NULL::text, p_source_type text DEFAULT NULL::text, p_source_id uuid DEFAULT NULL::uuid)
 RETURNS gst_adjustments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare bid uuid:=current_business_id();r gst_adjustments;begin if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'GST adjustment access denied' using errcode='42501';end if;if coalesce(btrim(p_reason),'')='' or p_gst_amount<0 then raise exception 'Adjustment reason and valid amount are required';end if;if exists(select 1 from gst_returns where business_id=bid and status='finalised' and p_date between period_start and period_end) then raise exception 'This GST period is finalised. Create a correction/amendment review item instead.';end if;insert into gst_adjustments(business_id,adjustment_date,adjustment_type,direction,gst_amount,reason,reference,evidence,source_type,source_id) values(bid,p_date,p_type,p_direction,p_gst_amount,p_reason,p_reference,p_evidence,p_source_type,p_source_id) returning * into r;return r;end$function$
;
CREATE OR REPLACE FUNCTION frindly_cash.gst_base(p_from date, p_to date, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  bid uuid:=public.current_business_id(); d date; isreg boolean; prevreg boolean:=false; day_basis text; prev_basis text;
  seg_start date; seg_end date; part jsonb; cfg jsonb; basis text;
  sales_ex numeric:=0; sales_gst numeric:=0; purch_ex numeric:=0; purch_gst numeric:=0;
  debit_adj numeric:=0; credit_adj numeric:=0;
  sales_items jsonb:='[]'::jsonb; purchase_items jsonb:='[]'::jsonb;
  adjustment_items jsonb:='[]'::jsonb; review jsonb:='[]'::jsonb;
  windows jsonb:='[]'::jsonb; registered_days int:=0; total_days int;
begin
  if bid is null or not public.v6147_can_read_area(bid,'financials') then raise exception 'Financial access denied' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid GST period'; end if;
  total_days:=p_to-p_from+1;
  for d in select generate_series(p_from,p_to,interval '1 day')::date loop
    isreg:=coalesce((public.v6170e_gst_settings(d)->>'gst_registered')::boolean,false);
    day_basis:=coalesce(nullif(p_basis,''),(public.v6170e_gst_settings(d)->>'accounting_basis')); day_basis:=case day_basis when 'non_cash' then 'invoice' when 'cash' then 'payments' else day_basis end; if day_basis not in ('invoice','payments','hybrid') then raise exception 'Invalid GST basis'; end if;
    if isreg then
      registered_days:=registered_days+1;
      if not prevreg then seg_start:=d; end if;
    end if;
    if prevreg and (not isreg or day_basis<>prev_basis) then
      seg_end:=d-1;
      part:=public.frindly_gst_calculate_basis_v1(seg_start,seg_end,prev_basis);
      if cfg is null then cfg:=part->'settings'; basis:=part->>'basis'; end if;
      sales_ex:=sales_ex+coalesce((part->>'sales_ex_gst')::numeric,0);
      sales_gst:=sales_gst+coalesce((part->>'gst_collected')::numeric,0);
      purch_ex:=purch_ex+coalesce((part->>'purchases_ex_gst')::numeric,0);
      purch_gst:=purch_gst+coalesce((part->>'gst_paid')::numeric,0);
      debit_adj:=debit_adj+coalesce((part->>'debit_adjustments')::numeric,0);
      credit_adj:=credit_adj+coalesce((part->>'credit_adjustments')::numeric,0);
      sales_items:=sales_items||coalesce(part->'sales_items','[]'::jsonb);
      purchase_items:=purchase_items||coalesce(part->'purchase_items','[]'::jsonb);
      adjustment_items:=adjustment_items||coalesce(part->'adjustment_items','[]'::jsonb);
      review:=review||coalesce(part->'review_items','[]'::jsonb);
      windows:=windows||jsonb_build_array(jsonb_build_object('from',seg_start,'to',seg_end));
    end if;
    if isreg and (not prevreg or day_basis<>prev_basis) then seg_start:=d; end if;
    prevreg:=isreg; prev_basis:=day_basis;
  end loop;
  if prevreg then
    seg_end:=p_to;
    part:=public.frindly_gst_calculate_basis_v1(seg_start,seg_end,prev_basis);
    if cfg is null then cfg:=part->'settings'; basis:=part->>'basis'; end if;
    sales_ex:=sales_ex+coalesce((part->>'sales_ex_gst')::numeric,0);
    sales_gst:=sales_gst+coalesce((part->>'gst_collected')::numeric,0);
    purch_ex:=purch_ex+coalesce((part->>'purchases_ex_gst')::numeric,0);
    purch_gst:=purch_gst+coalesce((part->>'gst_paid')::numeric,0);
    debit_adj:=debit_adj+coalesce((part->>'debit_adjustments')::numeric,0);
    credit_adj:=credit_adj+coalesce((part->>'credit_adjustments')::numeric,0);
    sales_items:=sales_items||coalesce(part->'sales_items','[]'::jsonb);
    purchase_items:=purchase_items||coalesce(part->'purchase_items','[]'::jsonb);
    adjustment_items:=adjustment_items||coalesce(part->'adjustment_items','[]'::jsonb);
    review:=review||coalesce(part->'review_items','[]'::jsonb);
    windows:=windows||jsonb_build_array(jsonb_build_object('from',seg_start,'to',seg_end));
  end if;
  if registered_days=0 then
    cfg:=public.v6170e_gst_settings(p_to);
    return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',coalesce(nullif(p_basis,''),cfg->>'accounting_basis'),'sales_ex_gst',0,'gst_collected',0,'purchases_ex_gst',0,'gst_paid',0,'debit_adjustments',0,'credit_adjustments',0,'gst_net',0,'sales_items','[]'::jsonb,'purchase_items','[]'::jsonb,'adjustment_items','[]'::jsonb,'registered_windows','[]'::jsonb,'review_items',jsonb_build_array(jsonb_build_object('severity','blocking','code','not_registered','message','Business is not GST registered for this period.')),'calculation_version','frindly-gst-boundary-v1');
  end if;
  if registered_days<total_days then
    review:=review||jsonb_build_array(jsonb_build_object('severity','info','code','registration_boundary','message','This GST period crosses a GST registration boundary. Only dates when the business was GST registered are included.','registered_windows',windows));
  end if;
  return jsonb_build_object('period_start',p_from,'period_end',p_to,'settings',cfg,'basis',basis,'sales_ex_gst',round(sales_ex,2),'gst_collected',round(sales_gst,2),'purchases_ex_gst',round(purch_ex,2),'gst_paid',round(purch_gst,2),'debit_adjustments',round(debit_adj,2),'credit_adjustments',round(credit_adj,2),'gst_net',round(sales_gst+debit_adj-purch_gst-credit_adj,2),'sales_items',sales_items,'purchase_items',purchase_items,'adjustment_items',adjustment_items,'registered_windows',windows,'review_items',review,'calculation_version','frindly-gst-boundary-v1');
end $function$
;
CREATE OR REPLACE FUNCTION public.v6170e_set_gst_settings(p_registered boolean, p_gst_number text, p_basis text, p_frequency text, p_balance_month smallint, p_balance_day smallint, p_effective_from date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare bid uuid:=current_business_id();begin if bid is null or not v6147_can_write_area(bid,'financials') then raise exception 'Financial settings access denied' using errcode='42501';end if;if p_basis not in('payments','invoice','hybrid') or p_frequency not in('monthly','two_monthly','six_monthly') then raise exception 'Invalid NZ GST configuration';end if;if p_balance_month not between 1 and 12 or p_balance_day not between 1 and 31 then raise exception 'Invalid balance date';end if;insert into gst_settings_history(business_id,effective_from,gst_registered,gst_number,accounting_basis,filing_frequency,balance_date_month,balance_date_day) values(bid,p_effective_from,p_registered,nullif(btrim(p_gst_number),''),p_basis,p_frequency,p_balance_month,p_balance_day) on conflict(business_id,effective_from) do update set gst_registered=excluded.gst_registered,gst_number=excluded.gst_number,accounting_basis=excluded.accounting_basis,filing_frequency=excluded.filing_frequency,balance_date_month=excluded.balance_date_month,balance_date_day=excluded.balance_date_day;update financial_settings set gst_registered=p_registered,gst_number=nullif(btrim(p_gst_number),''),gst_accounting_basis=p_basis,gst_filing_frequency=p_frequency,balance_date_month=p_balance_month,balance_date_day=p_balance_day,updated_at=now(),updated_by=auth.uid() where business_id=bid;return v6170e_gst_settings(p_effective_from);end$function$
;