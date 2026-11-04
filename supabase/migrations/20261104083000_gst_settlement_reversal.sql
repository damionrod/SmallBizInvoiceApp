-- Keep the original settlement and its allocations as an audit trail.
create function public.frindly_reverse_gst_settlement(
 p_journal_id uuid,p_reason text,p_correct_rounding boolean default false
) returns uuid
language plpgsql security definer set search_path='' as $$
declare
 b uuid:=frindly_settlement.assert_access('financials',true);
 p public.liability_payments%rowtype;
 j public.accounting_journals%rowtype;
 reversal uuid;
 allocations jsonb;
 lines jsonb;
begin
 if length(btrim(coalesce(p_reason,''))) not between 3 and 500 then
  raise exception 'Enter a reversal reason between 3 and 500 characters';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('frindly-settlement:'||b::text,0));
 select * into p from public.liability_payments where business_id=b and accounting_journal_id=p_journal_id for update;
 if p.id is null then raise exception 'GST settlement unavailable'; end if;
 select * into j from public.accounting_journals where business_id=b and id=p_journal_id
  and source_type='liability_settlement' and status='posted' and reversed_by_journal_id is null for update;
 if j.id is null then raise exception 'Original posted settlement unavailable or already reversed'; end if;
 if exists(select 1 from public.bank_reconciliation_allocations where business_id=b and
   (liability_payment_id=p.id or accounting_journal_id=j.id)) then
  raise exception 'Undo the bank match before reversing this settlement';
 end if;
 perform frindly_cash.check_date(b,j.journal_date);
 if exists(select 1 from public.liability_payment_allocations where business_id=b and payment_id=p.id and kind<>'gst') then
  raise exception 'Only GST settlements can be reversed here';
 end if;
 select jsonb_agg(jsonb_build_object('kind',kind,'source_id',gst_return_id,'account_id',account_id,
   'amount',amount,'gst_refund_rounding',0.01)) into allocations
 from public.liability_payment_allocations where business_id=b and payment_id=p.id;
 if allocations is null then raise exception 'GST allocations unavailable'; end if;
 if p_correct_rounding and (p.direction<>'refund' or jsonb_array_length(allocations)<>1
   or p.amount<>(allocations->0->>'amount')::numeric) then
  raise exception 'Only an unadjusted single-return refund can be corrected for rounding';
 end if;
 select jsonb_agg(jsonb_build_object('account_id',account_id,'description',btrim(p_reason),
   'debit',credit,'credit',debit,'tax_code',tax_code,'tax_rate',tax_rate,'tax_amount',-tax_amount))
 into lines from public.accounting_journal_lines where business_id=b and journal_id=j.id;
 reversal:=public.v6192_create_posted_journal(b,j.journal_date,j.journal_type,'liability_settlement',
   gen_random_uuid(),j.source_reference,'GST settlement reversal: '||btrim(p_reason),lines);
 update public.accounting_journals set status='reversed',reversed_by_journal_id=reversal where business_id=b and id=j.id;
 update public.accounting_journals set reversal_of_journal_id=j.id where business_id=b and id=reversal;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by)
 values(b,'liability_payment',p.id,'reverse_payment',jsonb_build_object('reason',btrim(p_reason),'reversal_journal_id',reversal),auth.uid());
 if p_correct_rounding then
  return frindly_settlement.record_payment(gen_random_uuid(),p.payment_date,p.bank_account_id,p.reference,allocations);
 end if;
 return reversal;
end $$;
revoke all on function public.frindly_reverse_gst_settlement(uuid,text,boolean) from public,anon;
grant execute on function public.frindly_reverse_gst_settlement(uuid,text,boolean) to authenticated;

-- Keep reversed entries visible in history while identifying them for the action UI.
do $patch$
declare definition text;
begin
 select pg_get_functiondef('frindly_settlement.snapshot(text,uuid)'::regprocedure) into definition;
 if strpos(definition,'select p.*,coalesce')=0 then raise exception 'GST snapshot patch guard failed'; end if;
 execute replace(definition,'select p.*,coalesce',
  'select p.*,exists(select 1 from public.accounting_journals j where j.business_id=p.business_id and j.id=p.accounting_journal_id and j.status=''reversed'') reversed,
  public.v6147_can_write_area(p.business_id,''financials'') and exists(select 1 from public.liability_payment_allocations a where a.business_id=p.business_id and a.payment_id=p.id and a.kind=''gst'')
  and not exists(select 1 from public.liability_payment_allocations a where a.business_id=p.business_id and a.payment_id=p.id and a.kind<>''gst'') can_reverse_gst,
  (select ba.name from public.bank_accounts ba where ba.business_id=p.business_id and ba.id=p.bank_account_id) bank_name,coalesce');
end $patch$;
