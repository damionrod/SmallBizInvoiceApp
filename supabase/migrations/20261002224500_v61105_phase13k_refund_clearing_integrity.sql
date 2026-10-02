-- Phase 13K: Refund Clearing & Bank Reconciliation Integrity
-- Adds only the missing Payment Clearing control account. No historical journals or refunds are rewritten.
insert into public.accounting_accounts(business_id,account_code,account_name,account_type,normal_balance,tax_default,system_account_key,allow_manual_posting,report_section,system_key,is_system,is_control,xero_account_code,xero_account_type,description)
select b.business_id,
       case when exists(select 1 from public.accounting_accounts z where z.business_id=b.business_id and length(z.account_code)=3) then '095' else '1050' end,
       'Payment Clearing',
       case when exists(select 1 from public.accounting_accounts z where z.business_id=b.business_id and length(z.account_code)=3) then 'current_asset' else 'asset' end,
       'debit','NO_GST','payment_clearing',false,'asset','payment_clearing',true,true,
       case when exists(select 1 from public.accounting_accounts z where z.business_id=b.business_id and length(z.account_code)=3) then '095' else '1050' end,
       'CURRENT','Temporary control account for recorded customer and supplier refunds awaiting the matching bank transaction.'
from (select distinct business_id from public.accounting_accounts)b
where not exists(select 1 from public.accounting_accounts a where a.business_id=b.business_id and (a.system_account_key='payment_clearing' or a.system_key='payment_clearing') and not coalesce(a.archived,false))
  and not exists(select 1 from public.accounting_accounts a where a.business_id=b.business_id and a.account_code=case when exists(select 1 from public.accounting_accounts z where z.business_id=b.business_id and length(z.account_code)=3) then '095' else '1050' end);

-- Future canonical charts receive the same semantic control account.
do $$declare d text;begin
select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='v6191_seed_default_chart';
if d is null or strpos(d,'(''090'',''Business Bank''')=0 then raise exception '13K seed guard failed';end if;
d:=replace(d,'(''090'',''Business Bank'',''bank'',''debit'',''asset'',''bank_main'',''BANK'',''Primary bank or transaction account.''),','(''090'',''Business Bank'',''bank'',''debit'',''asset'',''bank_main'',''BANK'',''Primary bank or transaction account.''),'||chr(10)||'      (''095'',''Payment Clearing'',''current_asset'',''debit'',''asset'',''payment_clearing'',''CURRENT'',''Temporary control account for refunds awaiting the matching bank transaction.''),');
execute d;end$$;
