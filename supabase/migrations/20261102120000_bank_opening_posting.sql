-- Bank opening balances: atomic, once-only, tenant-scoped.
alter table public.bank_accounts
 add column if not exists opening_balance numeric(16,2),
 add column if not exists opening_balance_date date,
 add column if not exists opening_balance_journal_id uuid references public.accounting_journals(id);
create or replace function public.frindly_set_bank_opening_v1(
 p_bank_account_id uuid,p_amount numeric,p_as_of date
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_bid uuid:=public.current_business_id(); v_bank public.bank_accounts%rowtype;
 v_asset uuid; v_equity uuid; v_journal uuid; v_code text;
begin
 if auth.uid() is null or v_bid is null or not public.v6169a_accountant_centre_access(v_bid,true) then
   raise exception 'Owner or accountant permission required';
 end if;
 if p_amount is null or p_as_of is null or p_as_of>current_date or abs(p_amount)>999999999999 then
   raise exception 'Valid amount and non-future opening date required';
 end if;
 select * into v_bank from public.bank_accounts where id=p_bank_account_id and business_id=v_bid and not coalesce(archived,false) for update;
 if not found then raise exception 'Bank account not found'; end if;
 if v_bank.opening_balance_journal_id is not null then
   if v_bank.opening_balance=p_amount and v_bank.opening_balance_date=p_as_of then
     return jsonb_build_object('status','already_posted','journal_id',v_bank.opening_balance_journal_id);
   end if;
   raise exception 'Opening balance already posted; use a controlled accounting adjustment';
 end if;
 if exists(select 1 from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id
    where j.business_id=v_bid and j.status in ('posted','reversed')
    and l.account_id=v_bank.accounting_account_id) then
   raise exception 'Existing bank ledger postings require migration review before opening balance';
 end if;
 if v_bank.accounting_account_id is not null then
  select id into v_asset from public.accounting_accounts
  where id=v_bank.accounting_account_id and business_id=v_bid and not coalesce(archived,false)
   and (account_type='bank' or account_subtype='bank' or xero_account_type='BANK');
  if v_asset is null then raise exception 'Invalid bank ledger mapping'; end if;
 else
  select id into v_asset from public.accounting_accounts a where a.business_id=v_bid
   and a.account_type in ('bank','asset') and a.account_subtype='bank'
   and lower(a.account_name)=lower(v_bank.name) and not coalesce(a.archived,false)
   and not exists(select 1 from public.bank_accounts b where b.business_id=v_bid and b.id<>v_bank.id and b.accounting_account_id=a.id)
   limit 1;
  if v_asset is null then
   select gs::text into v_code from generate_series(1000,1099) gs where not exists(
    select 1 from public.accounting_accounts a where a.business_id=v_bid and a.account_code=gs::text)
    order by gs limit 1;
   if v_code is null then raise exception 'No available bank account code'; end if;
   insert into public.accounting_accounts(business_id,account_code,account_name,account_type,account_subtype,
    normal_balance,tax_default,allow_manual_posting,report_section,is_system,is_control,
    xero_account_code,xero_account_type,xero_tax_type,description,created_by,updated_by)
   values(v_bid,v_code,v_bank.name,'asset','bank','debit','NO_GST',false,'asset',true,true,
    v_code,'BANK','NONE','Bank account opening balance',auth.uid(),auth.uid()) returning id into v_asset;
  end if;
 end if;
 if exists(select 1 from public.bank_accounts b where b.business_id=v_bid and b.id<>v_bank.id and b.accounting_account_id=v_asset and not coalesce(b.archived,false)) then
  raise exception 'Bank ledger account is already assigned to another bank';
 end if;
 if exists(select 1 from public.accounting_journals j join public.accounting_journal_lines l on l.journal_id=j.id
    where j.business_id=v_bid and j.status in ('posted','reversed') and l.account_id=v_asset) then
  raise exception 'Existing ledger movements require migration review';
 end if;
 select id into v_equity from public.accounting_accounts where business_id=v_bid
  and account_type='equity' and not coalesce(archived,false)
  and (system_account_key in ('opening_balance_equity','opening_balances')
   or system_key in ('opening_balance_equity','opening_balances')
   or lower(account_name) in ('opening balance equity','opening balances'))
  order by id limit 1;
 if v_equity is null then
  select gs::text into v_code from generate_series(3900,3999) gs where not exists(
   select 1 from public.accounting_accounts a where a.business_id=v_bid and a.account_code=gs::text)
   order by gs limit 1;
  if v_code is null then raise exception 'No available opening equity account code'; end if;
  insert into public.accounting_accounts(business_id,account_code,account_name,account_type,account_subtype,
   normal_balance,tax_default,allow_manual_posting,report_section,is_system,is_control,
   description,created_by,updated_by)
  values(v_bid,v_code,'Opening Balance Equity','equity','owner_equity','credit','NO_GST',false,
   'equity',true,true,'Migration opening balances (not revenue)',auth.uid(),auth.uid())
  returning id into v_equity;
 end if;
 if p_amount<>0 then
  v_journal:=public.v6192_create_posted_journal(v_bid,p_as_of,'opening_balance',
   'bank_opening_balance',v_bank.id,'BANK-OPEN-'||v_bank.id::text,
   'Opening bank balance: '||v_bank.name,
   jsonb_build_array(
    jsonb_build_object('account_id',v_asset,'debit',greatest(p_amount,0),'credit',greatest(-p_amount,0)),
    jsonb_build_object('account_id',v_equity,'debit',greatest(-p_amount,0),'credit',greatest(p_amount,0))
   ));
 end if;
 update public.bank_accounts set accounting_account_id=v_asset,opening_balance=p_amount,
  opening_balance_date=p_as_of,opening_balance_journal_id=v_journal,updated_at=now(),updated_by=auth.uid()
 where id=v_bank.id;
 return jsonb_build_object('status','posted','journal_id',v_journal,'account_id',v_asset);
end $$;
revoke all on function public.frindly_set_bank_opening_v1(uuid,numeric,date) from public,anon;
grant execute on function public.frindly_set_bank_opening_v1(uuid,numeric,date) to authenticated,service_role;
