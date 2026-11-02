-- Current production profit/loss engine, used unchanged in isolated verification.
CREATE OR REPLACE FUNCTION public.v6170b_profit_loss(p_from date, p_to date)
 RETURNS TABLE(revenue numeric, cost_of_sales numeric, expenses numeric, net_profit numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$with b as(select public.current_business_id()id),x as(select a.account_type,sum(l.credit-l.debit)amt from accounting_journals j join b on b.id=j.business_id join accounting_journal_lines l on l.journal_id=j.id join accounting_accounts a on a.id=l.account_id where j.status in('posted','reversed')and j.journal_date between p_from and p_to group by a.account_type),t as(select coalesce(sum(amt)filter(where account_type in('revenue','other_income')),0)revenue,coalesce(-sum(amt)filter(where account_type='cost_of_sales'),0)cost_of_sales,coalesce(-sum(amt)filter(where account_type in('expense','other_expense')),0)expenses from x)select revenue,cost_of_sales,expenses,revenue-cost_of_sales-expenses from t$function$
;
