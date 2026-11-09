-- Guided reclassification of documented opening equity. Other corrections use Manual Journals.
create function public.frindly_opening_share_capital_review(
  p_as_of date, p_amount numeric default null, p_reference text default null,
  p_confirm boolean default false, p_expected_offset uuid default null
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  business uuid := frindly_cash.access(true);
  capital uuid;
  offset_id uuid;
  capital_info jsonb;
  offset_info jsonb;
  existing public.accounting_journals%rowtype;
  posted_id uuid;
  reason text;
  ref text := btrim(coalesce(p_reference,''));
begin
  if p_confirm then
    perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||business::text,0));
  end if;
  capital_info := public.frindly_buyback_share_capital_preview(p_as_of);
  capital := (capital_info->>'account_id')::uuid;
  select capital_info || jsonb_build_object('code',account_code,'name',account_name,
    'has_entries',exists(select 1 from public.accounting_journal_lines l
      join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id
      where l.business_id=business and l.account_id=capital
        and j.status in ('posted','reversed') and j.journal_date<=p_as_of))
  into capital_info from public.accounting_accounts where business_id=business and id=capital;

  if p_amount is null and not p_confirm then return capital_info; end if;
  if p_amount is null or p_amount<=0 or p_amount>999999999999.99
    or p_amount<>round(p_amount,2) or length(ref) not between 3 and 200
  then raise exception 'Enter a positive opening amount and a source reference'; end if;

  select * into existing from public.accounting_journals
    where business_id=business and source_type='share_capital_opening' and source_id=capital
    order by created_at desc limit 1;
  if existing.id is not null and p_confirm and existing.status='posted'
    and existing.journal_date=p_as_of and existing.source_reference=ref
    and exists(select 1 from public.accounting_journal_lines
      where business_id=business and journal_id=existing.id and account_id=capital and credit=p_amount)
  then return capital_info || jsonb_build_object('journal_id',existing.id); end if;

  if existing.id is not null or exists(
    select 1 from public.accounting_journal_lines l join public.accounting_journals j
      on j.id=l.journal_id and j.business_id=l.business_id
    where l.business_id=business and l.account_id=capital and j.status in ('posted','reversed')
  ) then
    reason := 'Share capital already has ledger activity. Review the correction in Manual Journals.';
  elsif not public.v6170a_period_is_open(business,p_as_of) then
    reason := 'This accounting period is locked.';
  else
    select (array_agg(a.id))[1] into offset_id
    from public.accounting_accounts a
    where a.business_id=business and a.account_type='equity' and not coalesce(a.archived,false)
      and a.id<>capital
      and (a.system_key in ('opening_balance_equity','opening_balances')
        or a.system_account_key in ('opening_balance_equity','opening_balances')
        or lower(a.account_name) in ('opening balance equity','opening balances'))
    having count(*)=1;
    select jsonb_build_object('id',a.id,'code',a.account_code,'name',a.account_name)
      into offset_info from public.accounting_accounts a where a.id=offset_id and a.business_id=business
      and (select coalesce(sum(l.credit-l.debit),0)
        from public.accounting_journal_lines l join public.accounting_journals j
          on j.id=l.journal_id and j.business_id=l.business_id
        where l.business_id=business and l.account_id=a.id and j.journal_date<=p_as_of
          and j.status in ('posted','reversed'))>=p_amount
      and exists(select 1 from public.accounting_journal_lines l join public.accounting_journals j
          on j.id=l.journal_id and j.business_id=l.business_id
        where l.business_id=business and l.account_id=a.id and j.journal_date<=p_as_of
          and j.status='posted' and j.journal_type='opening_balance' and l.credit>0);
    if offset_info is null then
      reason := 'Frindly could not verify a sufficient Opening Balance Equity offset. Use Manual Journals with your opening records.';
    end if;
  end if;
  if not p_confirm then
    return capital_info || jsonb_build_object('offset',offset_info,'reason',reason);
  end if;
  if reason is not null then raise exception '%',reason; end if;
  if p_expected_offset is distinct from offset_id then
    raise exception 'The offset account changed. Preview the correction again.';
  end if;
  posted_id := public.v6192_create_posted_journal(
    business,p_as_of,'opening_balance','share_capital_opening',capital,ref,
    'Opening share capital reclassification',
    jsonb_build_array(
      jsonb_build_object('account_id',offset_id,'debit',p_amount,'credit',0,'tax_code','NO_GST'),
      jsonb_build_object('account_id',capital,'debit',0,'credit',p_amount,'tax_code','NO_GST')
    )
  );
  return capital_info || jsonb_build_object('journal_id',posted_id);
end $$;
revoke all on function public.frindly_opening_share_capital_review(date,numeric,text,boolean,uuid) from public,anon;
grant execute on function public.frindly_opening_share_capital_review(date,numeric,text,boolean,uuid) to authenticated;
