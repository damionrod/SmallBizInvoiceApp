-- Read-only dashboard projection. No returns, settlements or journals are changed.
create or replace function public.frindly_dashboard_pending_gst(p_as_of date default current_date)
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare
 b uuid:=public.current_business_id(); first_date date; cursor_date date; start_date date; end_date date;
 cfg jsonb; months integer; anchor integer; offset_months integer; next_date date;
 saved public.gst_returns%rowtype; filed boolean; calc jsonb; net numeric; settled numeric; outstanding numeric;
 payable numeric:=0; receivable numeric:=0; periods jsonb:='[]'; reviews jsonb; loops integer:=0;
begin
 if auth.uid() is null or b is null or not public.v6147_can_read_area(b,'financials') then
  raise exception 'Financial access denied' using errcode='42501';
 end if;
 if p_as_of is null then raise exception 'As-of date is required'; end if;
 -- Begin at the first recorded GST source, not at this financial year's start.
 select min(d) into first_date from (
  select min(invoice_date) d from public.invoices where business_id=b and coalesce(lifecycle_state,'issued') not in ('draft','voided')
  union all select min(invoice_date) from public.expenses where business_id=b and coalesce(lifecycle_state,'recorded')='recorded'
  union all select min(payment_date) from public.customer_payments where business_id=b
  union all select min(payment_date) from public.expense_payments where business_id=b
  union all select min(credit_date) from public.customer_credit_notes where business_id=b and lifecycle_state='issued'
  union all select min(credit_date) from public.supplier_credits where business_id=b and lifecycle_state='recorded'
  union all select min(adjustment_date) from public.gst_adjustments where business_id=b and status='active'
  union all select min(disposed_on) from public.se_assets where business_id=b and disposal_accounted_at is not null
  union all select min(l.transaction_date) from public.cash_transaction_legs l join public.cash_transactions c on c.id=l.transaction_id and c.business_id=l.business_id where l.business_id=b and c.status='recorded' and c.gst_amount<>0
  union all select min(period_start) from public.gst_returns where business_id=b
  union all select min(period_start) from public.ird_filing_batches where business_id=b and filing_type='gst_return' and status='filed_in_myir'
 ) sources where d<=p_as_of;
 cursor_date:=first_date;
 while cursor_date is not null and cursor_date<=p_as_of loop
  loops:=loops+1; if loops>1200 then raise exception 'GST history requires review: too many periods'; end if;
  select * into saved from public.gst_returns where business_id=b and period_start<=cursor_date and period_end>=cursor_date
   order by (status='finalised') desc,updated_at desc,id limit 1;
  if found then
   start_date:=saved.period_start; end_date:=saved.period_end;
  else
   cfg:=public.v6170e_gst_settings(cursor_date);
   months:=case cfg->>'filing_frequency' when 'monthly' then 1 when 'six_monthly' then 6 else 2 end;
   anchor:=coalesce((cfg->>'balance_date_month')::integer,3);
   offset_months:=mod(anchor-extract(month from cursor_date)::integer+12,months);
   end_date:=(date_trunc('month',cursor_date)+(offset_months+1)*interval '1 month'-interval '1 day')::date;
   start_date:=(date_trunc('month',end_date)-(months-1)*interval '1 month')::date;
   start_date:=greatest(start_date,coalesce((select max(period_end)+1 from public.gst_returns where business_id=b and period_end<cursor_date),start_date));
   -- A saved custom period or frequency change owns its dates; never count them twice.
   select min(d) into next_date from (
    select period_start d from public.gst_returns where business_id=b and period_start>cursor_date
    union all select effective_from from public.gst_settings_history where business_id=b and effective_from>cursor_date
     and (filing_frequency is distinct from cfg->>'filing_frequency' or balance_date_month is distinct from (cfg->>'balance_date_month')::integer)
   ) boundaries;
   if next_date is not null and next_date<=end_date then end_date:=next_date-1; end if;
   -- Do not cross an already visited boundary after a settings change.
   if loops>1 then start_date:=greatest(start_date,cursor_date); end if;
  end if;
  filed:=exists(select 1 from public.ird_filing_batches f where f.business_id=b and f.filing_type='gst_return' and f.status='filed_in_myir' and (f.source_id=saved.id or (f.period_start=start_date and f.period_end=end_date)));
  if saved.id is not null and (saved.status='finalised' or filed) then
   net:=saved.gst_net; reviews:=coalesce(saved.review_items,'[]');
  else
   calc:=public.frindly_gst_boundary_basis_v1(start_date,least(end_date,p_as_of),saved.accounting_basis);
   net:=(calc->>'gst_net')::numeric; reviews:=coalesce(calc->'review_items','[]');
  end if;
  if net is null then raise exception 'GST calculation unavailable for % to %',start_date,end_date; end if;
  select coalesce(sum(a.amount),0) into settled from public.liability_payment_allocations a
   join public.liability_payments p on p.id=a.payment_id and p.business_id=a.business_id
   join public.accounting_journals j on j.id=p.accounting_journal_id and j.business_id=p.business_id and j.status='posted'
   where a.business_id=b and a.kind='gst' and a.gst_return_id=saved.id and p.payment_date<=p_as_of
   and p.direction=case when net<0 then 'refund' else 'payment' end;
  outstanding:=greatest(0,abs(net)-settled);
  if net>=0 then payable:=payable+outstanding; else receivable:=receivable+outstanding; end if;
  if outstanding>0 or jsonb_array_length(reviews)>0 then
   periods:=periods||jsonb_build_array(jsonb_build_object('from',start_date,'to',end_date,'calculated_through',least(end_date,p_as_of),
    'return_id',saved.id,'status',case when filed then 'filed' when saved.status='finalised' then 'finalised' when saved.id is not null then 'draft' else 'unsaved' end,
    'net',net,'settled',settled,'outstanding',outstanding,'direction',case when net<0 then 'receivable' else 'payable' end,'review_items',reviews));
  end if;
  cursor_date:=end_date+1;
 end loop;
 return jsonb_build_object('as_of',p_as_of,'payable',round(payable,2),'receivable',round(receivable,2),'periods',periods);
end
$function$;
revoke all on function public.frindly_dashboard_pending_gst(date) from public,anon;
grant execute on function public.frindly_dashboard_pending_gst(date) to authenticated;
