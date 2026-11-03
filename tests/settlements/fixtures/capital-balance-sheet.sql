CREATE OR REPLACE FUNCTION public.v6170b_balance_sheet(p_as_of date)
 RETURNS TABLE(assets numeric, liabilities numeric, equity numeric, current_profit numeric, balances boolean, opening_balance_message text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with b as(select public.current_business_id() id),
x as(select a.account_type,a.report_section,a.normal_balance,
sum(case when a.normal_balance='debit' then l.debit-l.credit else l.credit-l.debit end) bal
from public.accounting_journals j join b on b.id=j.business_id
join public.accounting_journal_lines l on l.journal_id=j.id and l.business_id=j.business_id
join public.accounting_accounts a on a.id=l.account_id and a.business_id=j.business_id
where j.status in('posted','reversed') and j.journal_date<=p_as_of
group by a.account_type,a.report_section,a.normal_balance),
t as(select
coalesce(sum(bal)filter(where report_section in('asset','assets','current_assets','fixed_assets') or account_type in('asset','bank','current_asset','fixed_asset','inventory','non_current_asset') or(account_type='tax' and normal_balance='debit')),0) assets,
coalesce(sum(bal)filter(where report_section in('liability','liabilities','current_liabilities','non_current_liabilities') or account_type in('liability','current_liability','non_current_liability') or(account_type='tax' and normal_balance='credit')),0) liabilities,
coalesce(sum(case when normal_balance='debit' then -bal else bal end)filter(where report_section='equity' or account_type='equity'),0) equity,
coalesce(sum(bal)filter(where account_type in('revenue','other_income','income')),0)-coalesce(sum(bal)filter(where account_type in('expense','other_expense','cost_of_sales')),0) profit from x),
o as(select exists(select 1 from public.accounting_journals j join b on b.id=j.business_id where j.journal_type='opening_balance' and j.status in('posted','reversed') and j.journal_date<=p_as_of)ok)
select assets,liabilities,equity,profit,round(assets,2)=round(liabilities+equity+profit,2),
case when o.ok then 'Opening balance established' else 'Opening balance not yet established' end from t,o
$function$;
