-- A paid bill correction keeps the cash settlement and its bank allocations intact.
create function public.frindly_edit_paid_expense_v1(
  p_id uuid,p_expected timestamptz,p_request uuid,p_reference text,
  p_description text,p_tax text,p_reason text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  b uuid:=public.current_business_id();
  actor uuid:=auth.uid();
  bill public.expenses%rowtype;
  updated public.expenses%rowtype;
  original uuid;
  adjustment uuid;
  gst_account uuid;
  expense_account uuid;
  original_count integer;
  tax_settings jsonb;
  rate numeric;
  tax numeric;
  delta numeric;
  prior uuid;
begin
  if actor is null or b is null or not coalesce(public.v6147_can_write_area(b,'core'),false)
    or not coalesce(public.v6169a_accountant_centre_access(b,true),false)
  then raise exception 'Authorised accounting access is required to edit a posted bill'; end if;
  if p_request is null or p_expected is null or length(btrim(coalesce(p_reason,''))) not between 3 and 1000
    or p_tax is null or p_tax not in ('keep','no_gst','gst')
  then raise exception 'Choose a GST treatment and enter a correction reason'; end if;
  select * into bill from public.expenses where business_id=b and id=p_id for update;
  if not found or bill.lifecycle_state is distinct from 'recorded' or bill.voided_at is not null
    or coalesce(bill.archived,false) or bill.payment_status is distinct from 'paid'
    or bill.total_amount<=0 or bill.amount_paid is distinct from bill.total_amount
    or bill.outstanding_balance is distinct from 0::numeric
  then raise exception 'Only an active, fully paid bill can use this edit'; end if;
  select expense_id into prior from public.expense_revisions where business_id=b and request_id=p_request;
  if prior=p_id then return jsonb_build_object('status','already_applied'); end if;
  if prior is not null or bill.updated_at is distinct from p_expected then raise exception 'The bill changed. Refresh before editing.'; end if;
  if not public.v6170a_period_is_open(b,bill.invoice_date)
    or exists(select 1 from public.expense_payments p where p.business_id=b and p.expense_id=p_id
      and not public.v6170a_period_is_open(b,p.payment_date))
  then raise exception 'The accounting period is locked. Request a correction.'; end if;
  if exists(
    select 1 from public.gst_returns g where g.business_id=b and g.status in ('reviewed','finalised')
      and (bill.invoice_date between g.period_start and g.period_end or exists(
        select 1 from public.expense_payments p where p.business_id=b and p.expense_id=p_id
          and p.payment_date between g.period_start and g.period_end))
  ) or exists(
    select 1 from public.ird_filing_batches g where g.business_id=b and g.filing_type='gst_return'
      and g.status in ('filed_in_myir','submitted','accepted')
      and (bill.invoice_date between g.period_start and g.period_end or exists(
        select 1 from public.expense_payments p where p.business_id=b and p.expense_id=p_id
          and p.payment_date between g.period_start and g.period_end))
  ) then raise exception 'A related GST return is reviewed or filed. Request a correction.'; end if;

  if p_tax<>'keep' then
    if not exists(select 1 from public.businesses where id=b and upper(coalesce(settings->>'country','NZ'))='NZ')
      or coalesce(bill.is_split,false) or coalesce(bill.business_use_percent,100)<>100
      or coalesce(bill.private_use_amount,0)<>0
      or exists(select 1 from public.supplier_credits c where c.business_id=b and c.original_expense_id=p_id and c.lifecycle_state='recorded')
      or exists(select 1 from public.purchase_invoice_reviews r where r.business_id=b and r.expense_id=p_id)
    then raise exception 'Review linked credits, item reviews or allocations before correcting GST'; end if;
    rate:=0;
    if p_tax='gst' then
      tax_settings:=public.v61105_effective_tax_status(bill.invoice_date);
      if tax_settings->>'gst_registered' is distinct from 'true'
        or coalesce((tax_settings->>'effective_rate_percent')::numeric,0)<=0
      then raise exception 'GST is unavailable on this bill date'; end if;
      rate:=(tax_settings->>'effective_rate_percent')::numeric;
    end if;
    tax:=round(bill.total_amount*rate/(100+rate),2);
    delta:=coalesce(bill.gst_amount,0)-tax;
    if delta<>0 then
      select count(*),(array_agg(id))[1] into original_count,original from public.accounting_journals
        where business_id=b and source_type='expense' and source_id=p_id and status='posted' and journal_date=bill.invoice_date;
      gst_account:=public.v6192_account_id(b,'gst_receivable','1200');
      select (array_agg(account_id))[1] into expense_account from public.accounting_journal_lines
        where business_id=b and journal_id=original and debit>0 and account_id<>gst_account
        having count(*)=1;
      if original_count<>1 or gst_account is null or expense_account is null then
        raise exception 'The original bill journal needs accounting review';
      end if;
      adjustment:=public.v6192_create_posted_journal(b,bill.invoice_date,'expense','expense_correction',p_request,
        bill.expense_number,'GST correction: '||btrim(p_reason),
        jsonb_build_array(
          jsonb_build_object('account_id',expense_account,'debit',greatest(delta,0),'credit',greatest(-delta,0),'supplier_id',bill.supplier_id,'job_costing_id',bill.job_costing_id),
          jsonb_build_object('account_id',gst_account,'debit',greatest(-delta,0),'credit',greatest(delta,0),'supplier_id',bill.supplier_id,'job_costing_id',bill.job_costing_id)
        ));
    end if;
  end if;

  insert into public.frindly_expense_correction_authorizations(business_id,expense_id,actor_id,transaction_id,allowed_fields)
    values(b,p_id,actor,txid_current(),array['supplier_reference','description','gst_treatment','gst_rate','gst_override','ex_gst','gst_amount','business_ex_gst','business_gst_amount','updated_at','updated_by']);
  update public.expenses set supplier_reference=nullif(btrim(p_reference),''),
    description=nullif(btrim(p_description),''),
    gst_treatment=case when p_tax='keep' then gst_treatment else p_tax end,
    gst_rate=coalesce(rate,gst_rate),
    gst_override=case when p_tax='keep' then gst_override else false end,
    ex_gst=coalesce(total_amount-tax,ex_gst),gst_amount=coalesce(tax,gst_amount),
    business_ex_gst=coalesce(total_amount-tax,business_ex_gst),business_gst_amount=coalesce(tax,business_gst_amount),
    updated_at=clock_timestamp(),updated_by=actor
    where business_id=b and id=p_id returning * into updated;
  insert into public.expense_revisions(business_id,expense_id,request_id,changed_by,change_reason,change_class,before_snapshot,after_snapshot,metadata)
    values(b,p_id,p_request,actor,btrim(p_reason),'financial',to_jsonb(bill),to_jsonb(updated),
      jsonb_build_object('operation','paid_bill_edit','original_journal_id',original,'adjustment_journal_id',adjustment));
  delete from public.frindly_expense_correction_authorizations
    where business_id=b and expense_id=p_id and actor_id=actor and transaction_id=txid_current();
  return jsonb_build_object('status','applied','adjustment_journal_id',adjustment);
end $$;
revoke all on function public.frindly_edit_paid_expense_v1(uuid,timestamptz,uuid,text,text,text,text) from public,anon;
grant execute on function public.frindly_edit_paid_expense_v1(uuid,timestamptz,uuid,text,text,text,text) to authenticated;
