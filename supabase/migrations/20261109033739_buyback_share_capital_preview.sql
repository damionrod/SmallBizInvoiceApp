-- Read the same balance that the existing capital posting validation checks.
create function public.frindly_buyback_share_capital_preview(p_as_of date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  business uuid := frindly_cash.access(true);
  capital_account uuid;
  balance numeric;
begin
  if public.v6169a_accountant_centre_access(business,true) is not true
    or not exists(select 1 from public.financial_settings where business_id=business and business_entity_type='company')
    or not exists(select 1 from public.businesses where id=business and coalesce(settings->>'country','NZ')='NZ')
  then raise exception 'Capital payments require authorised accounting access for an NZ company' using errcode='42501';
  end if;
  if p_as_of is null then raise exception 'Choose a payment date'; end if;
  capital_account := frindly_cash.owner_account(business,'capital_contribution');
  if not frindly_cash.capital_equity_account(business,capital_account) then
    raise exception 'The share capital mapping needs accountant review';
  end if;
  select round(coalesce(sum(l.credit-l.debit),0),2) into balance
  from public.accounting_journal_lines l
  join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id
  where l.business_id=business and l.account_id=capital_account
    and j.status in ('posted','reversed') and j.journal_date<=p_as_of;
  return jsonb_build_object('account_id',capital_account,'balance',balance);
end $$;
revoke all on function public.frindly_buyback_share_capital_preview(date) from public,anon;
grant execute on function public.frindly_buyback_share_capital_preview(date) to authenticated;
