-- Reuse cash transactions, bank legs and the existing journal writer. No historical data changes.
create or replace function frindly_cash.capital_equity_account(b uuid,a uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.accounting_accounts ac where ac.business_id=b and ac.id=a
 and ac.account_type='equity' and not coalesce(ac.archived,false) and not coalesce(ac.is_control,false)
 and coalesce(ac.allow_manual_posting,false)
 and coalesce(ac.system_key,'') not in ('opening_balance_equity','owner_drawings')
 and coalesce(ac.system_account_key,'') not in ('opening_balance_equity','owner_drawings')
 and coalesce(ac.account_subtype,'') not in ('drawings','opening_balance'));
$$;
revoke all on function frindly_cash.capital_equity_account(uuid,uuid) from public,anon,authenticated;

create or replace function frindly_cash.validate_capital(b uuid,p jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare d date:=(p->>'date')::date;owner uuid:=nullif(p->>'owner_id','')::uuid;
 capital uuid;part jsonb;a uuid;n numeric;total numeric:=0;available numeric;seen uuid[]:='{}';
begin
 if b is distinct from frindly_cash.access(true) or not public.v6169a_accountant_centre_access(b,true) then raise exception 'Capital transactions require authorised accounting access' using errcode='42501';end if;
 if not exists(select 1 from public.financial_settings where business_id=b and business_entity_type='company')
 or not exists(select 1 from public.businesses where id=b and coalesce(settings->>'country','NZ')='NZ') then raise exception 'Capital payments require an NZ company configuration';end if;
 if p->>'kind'<>'out' or p->>'purpose' not in ('share_buyback','return_share_capital') then raise exception 'Capital payments must be money out';end if;
 if not exists(select 1 from public.business_owners where business_id=b and id=owner and status='active' and is_shareholder
 and (shareholding_effective_from is null or shareholding_effective_from<=d)) then raise exception 'Select an active shareholder of this company on the payment date';end if;
 if p->'capital_authorised' is distinct from 'true'::jsonb or p->'capital_solvent' is distinct from 'true'::jsonb
 or p->'capital_tax_reviewed' is distinct from 'true'::jsonb or p->'capital_not_previously_posted' is distinct from 'true'::jsonb then raise exception 'Confirm legal authorisation, solvency, tax review and that equity has not already been posted';end if;
 if length(btrim(coalesce(p->>'capital_authority_ref','')))<3 or length(btrim(coalesce(p->>'capital_reviewer','')))<3
 or length(btrim(coalesce(p->>'capital_share_details','')))<3 or length(btrim(coalesce(p->>'note','')))<5 then raise exception 'Enter the approval reference, reviewer and accounting allocation note';end if;
 if nullif(p->>'capital_authority_date','') is null or (p->>'capital_authority_date')::date>d then raise exception 'Authorisation must be dated on or before payment';end if;
 if p->>'capital_tax_status' is distinct from 'no_additional_withholding' then raise exception 'Withholding/dividend-tax settlements require the accountant workflow; this form does not calculate them';end if;
 if coalesce(p->>'gst_treatment','NO_GST')<>'NO_GST' or coalesce((p->>'interest_amount')::numeric,0)<>0
 or coalesce((p->>'withheld_amount')::numeric,0)<>0 then raise exception 'Capital payments have no GST, interest or withholding allocations in this form';end if;
 if jsonb_typeof(p->'capital_allocations') is distinct from 'array' or jsonb_array_length(p->'capital_allocations') not between 1 and 10 then raise exception 'Enter one to ten approved equity allocations';end if;
 capital:=frindly_cash.owner_account(b,'capital_contribution');
 if not frindly_cash.capital_equity_account(b,capital) then raise exception 'The share capital mapping needs accountant review';end if;
 for part in select * from jsonb_array_elements(p->'capital_allocations') loop
  a:=nullif(part->>'account_id','')::uuid;n:=(part->>'amount')::numeric;
  if a is null or n is null or n<=0 or n>999999999999.99 or n<>round(n,2) or a=any(seen)
  or not frindly_cash.capital_equity_account(b,a) then raise exception 'Choose distinct eligible equity accounts and positive two-decimal allocations';end if;
  if p->>'purpose'='return_share_capital' and a<>capital then raise exception 'Return of Share Capital must use the existing share capital account';end if;
  if a=capital then
   select coalesce(sum(l.credit-l.debit),0) into available from public.accounting_journal_lines l
   join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id
   where l.business_id=b and l.account_id=a and j.status in ('posted','reversed') and j.journal_date<=d;
   if n>round(available,2) then raise exception 'Capital allocation exceeds the posted share capital balance; review the approved allocation';end if;
  end if;
  total:=total+n;seen:=array_append(seen,a);
 end loop;
 if total is distinct from (p->>'amount')::numeric then raise exception 'Equity allocations must equal the bank payment';end if;
 return (p->'capital_allocations'->0->>'account_id')::uuid;
end $$;
revoke all on function frindly_cash.validate_capital(uuid,jsonb) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION frindly_cash.lines(p public.cash_transactions, p_bank uuid, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid;bank uuid;lines jsonb;net numeric;g uuid;part jsonb;
begin
 bank:=frindly_cash.bank_gl(p.business_id,p_bank);
 lines:=jsonb_build_array(frindly_cash.line(bank,greatest(p_amount,0),greatest(-p_amount,0),p.description));
 if p.purpose in ('share_buyback','return_share_capital') then
  for part in select * from jsonb_array_elements(p.request_payload->'capital_allocations') loop
   lines:=lines||jsonb_build_array(frindly_cash.line((part->>'account_id')::uuid,(part->>'amount')::numeric,0,p.description));
  end loop;
  return lines;
 end if;
 if p.kind='transfer' then
  a:=frindly_cash.account(p.business_id,'bank_transfer_clearing','Bank Transfer Clearing','asset');
  return lines||jsonb_build_array(frindly_cash.line(a,greatest(-p_amount,0),greatest(p_amount,0),'Transfer in transit'));
 end if;
 net:=p.amount+p.withheld_amount-p.gst_amount-p.interest_amount;
 lines:=lines||jsonb_build_array(frindly_cash.line(p.account_id,case when p_amount<0 then net else 0 end,case when p_amount>0 then net else 0 end,p.description));
 if p.gst_amount>0 then
  g:=public.v61105_account_role_id(p.business_id,'gst_output');if g is null then raise exception 'GST output account mapping is missing';end if;
  lines:=lines||jsonb_build_array(frindly_cash.line(g,0,p.gst_amount,'GST on grant receipt'));
 end if;
 if p.interest_amount>0 then
  a:=frindly_cash.account(p.business_id,'loan_interest','Loan Interest','expense');lines:=lines||jsonb_build_array(frindly_cash.line(a,p.interest_amount,0,'Loan interest'));
 end if;
 if p.withheld_amount>0 then
  a:=frindly_cash.account(p.business_id,'withholding_tax_receivable','Withholding Tax Receivable','asset');lines:=lines||jsonb_build_array(frindly_cash.line(a,p.withheld_amount,0,'Tax withheld from interest'));
 end if;
 return lines;
end $function$;


CREATE OR REPLACE FUNCTION frindly_cash.record(p_request uuid, p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=frindly_cash.access(true);c public.cash_transactions%rowtype;old public.cash_transactions%rowtype;v_id uuid:=gen_random_uuid();bank uuid:=(p->>'bank_id')::uuid;dest uuid:=nullif(p->>'to_bank_id','')::uuid;d date:=(p->>'date')::date;d2 date:=coalesce(nullif(p->>'received_date','')::date,d);kind text:=p->>'kind';purpose text:=p->>'purpose';amt numeric:=(p->>'amount')::numeric;interest numeric:=coalesce((p->>'interest_amount')::numeric,0);withheld numeric:=coalesce((p->>'withheld_amount')::numeric,0);gst numeric:=0;rate numeric;tax text:=coalesce(p->>'gst_treatment','NO_GST');a uuid;owner uuid:=nullif(p->>'owner_id','')::uuid;owner_entry uuid;balance numeric;j uuid;settings jsonb;taxpayer text:=p->>'taxpayer';yr int:=nullif(p->>'tax_year','')::int;label text:=nullif(btrim(p->>'description'),'');
begin
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 if p_request is null or p is null then raise exception 'Request ID and transaction details are required';end if;
 select * into old from public.cash_transactions where business_id=b and request_id=p_request;
 if old.id is not null then if old.request_payload<>p then raise exception 'Request ID already used for a different transaction';end if;return old.id;end if;
 if kind not in ('in','out','transfer') or kind is null or amt is null or amt<=0 or amt<>round(amt,2) or amt>999999999999.99 or interest<0 or interest<>round(interest,2) or withheld<0 or withheld<>round(withheld,2) or label is null or length(label)>500 then raise exception 'Enter a purpose, valid amount and description';end if;
 perform frindly_cash.check_date(b,d,tax in ('GST','ZERO'));
 perform frindly_cash.bank_gl(b,bank);
 if exists(select 1 from public.bank_accounts where business_id=b and id=bank and opening_balance_journal_id is not null and d<opening_balance_date) then raise exception 'This payment predates the bank opening balance. Review opening history before posting it again';end if;
 if tax not in ('NO_GST','GST','ZERO') or tax is null then raise exception 'Choose a valid GST treatment';end if;
 if tax<>'NO_GST' and purpose<>'grant' then raise exception 'Only grant receipts use GST in this workflow';end if;
 if interest>0 and purpose<>'loan_repayment' or withheld>0 and purpose<>'interest' then raise exception 'Invalid interest or withholding allocation';end if;
 if interest>=amt then raise exception 'Loan interest must be less than the payment; record ordinary interest costs in Expenses';end if;
 if kind='transfer' then
  if purpose<>'transfer' or dest is null or dest=bank or interest<>0 or withheld<>0 or owner is not null then raise exception 'Choose two different bank accounts';end if;
  perform frindly_cash.bank_gl(b,dest);perform frindly_cash.check_date(b,d2);
  if exists(select 1 from public.bank_accounts where business_id=b and id=dest and opening_balance_journal_id is not null and d2<opening_balance_date) then raise exception 'Transfer predates the destination bank opening balance';end if;
  if (select currency from public.bank_accounts where id=bank) is distinct from (select currency from public.bank_accounts where id=dest) or (select accounting_account_id from public.bank_accounts where id=bank)=(select accounting_account_id from public.bank_accounts where id=dest) then raise exception 'Transfers require separate ledgers in the same currency';end if;
 else
  if kind='in' and purpose not in ('grant','interest','loan_received','owner_funds_introduced','director_loan_received','capital_contribution','income_tax_refund','deposit_return','other_receipt') or kind='out' and purpose not in ('income_tax','loan_repayment','owner_drawings','repay_owner_loan','director_payment','dividend_distribution','deposit_paid','other_payment','share_buyback','return_share_capital') or purpose is null then raise exception 'Choose a supported non-standard transaction purpose';end if;
  if purpose in ('share_buyback','return_share_capital') then
   a:=frindly_cash.validate_capital(b,p);
  elsif purpose in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment','capital_contribution','owner_drawings','dividend_distribution') then
   a:=frindly_cash.owner_account(b,purpose);
   if owner is not null and not exists(select 1 from public.business_owners where business_id=b and id=owner and status='active') then raise exception 'Select an active owner/shareholder';end if;
   if purpose in ('repay_owner_loan','director_payment') and owner is not null then
    select coalesce(sum(amount),0) into balance from public.owner_current_account_entries where business_id=b and owner_id=owner;
    if balance<amt then raise exception 'Repayment exceeds this owner current-account balance';end if;
   end if;
  elsif purpose in ('income_tax','income_tax_refund') then
   if yr is null or yr<2000 or yr>2200 or taxpayer not in ('business','owner') or taxpayer is null then raise exception 'Select who the tax is for and the tax year';end if;
   if taxpayer='owner' then
    if owner is null or not exists(select 1 from public.business_owners where business_id=b and id=owner and status='active') then raise exception 'Select the owner whose income tax this is';end if;
    a:=frindly_cash.owner_account(b,'owner_drawings');
   else
    if exists(select 1 from public.financial_settings where business_id=b and business_entity_type in ('sole_trader','partnership')) then raise exception 'Personal income tax must be recorded for the owner, not as business income tax';end if;
    select ac.id into a from public.accounting_accounts ac where ac.business_id=b and not coalesce(ac.archived,false) and ac.account_type in ('asset','current_asset','liability','current_liability') and (ac.system_key in ('income_tax_payable','income_tax_paid','provisional_tax') or ac.system_account_key in ('income_tax_payable','income_tax_paid','provisional_tax')) order by case when ac.system_key='income_tax_payable' or ac.system_account_key='income_tax_payable' then 0 else 1 end,ac.account_code limit 1;
    if a is null then a:=frindly_cash.account(b,'income_tax_paid','Income Tax Paid','asset');end if;
   end if;
  elsif purpose in ('loan_received','loan_repayment') then a:=frindly_cash.account(b,'bank_loan','Bank Loan','liability');
  elsif purpose in ('deposit_paid','deposit_return') then a:=frindly_cash.account(b,'refundable_deposits','Refundable Deposits','asset');
  elsif purpose='grant' then
   if nullif(btrim(p->>'party'),'') is null or nullif(btrim(p->>'note'),'') is null then raise exception 'Enter the grant funder and purpose/tax treatment note';end if;
   a:=frindly_cash.account(b,'grants_received','Grants Received','other_income');
  elsif purpose='interest' then a:=frindly_cash.account(b,'bank_interest_received','Bank Interest Received','other_income');
  else
   a:=nullif(p->>'account_id','')::uuid;
   if not exists(select 1 from public.accounting_accounts where business_id=b and id=a and not coalesce(archived,false) and not coalesce(is_control,false) and coalesce(allow_manual_posting,false) and account_type in ('asset','liability','equity','revenue','other_income') and coalesce(system_key,system_account_key,'') !~ '(bank|receivable|payable|gst|payroll|tax|clearing|sales|opening_balance)' and account_subtype is distinct from 'bank' and id not in(select accounting_account_id from public.bank_accounts where business_id=b and accounting_account_id is not null)) then raise exception 'Choose an eligible non-standard category; use existing payment workflows for control accounts';end if;
  end if;
  if purpose='loan_repayment' then
   select coalesce(sum(l.credit-l.debit),0) into balance from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=a and j.status in ('posted','reversed') and j.journal_date<=d;
   if amt-interest>round(balance,2) then raise exception 'Loan principal repayment exceeds the recorded loan balance. Review the opening loan balance first';end if;
  elsif purpose='deposit_return' then
   select coalesce(sum(l.debit-l.credit),0) into balance from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=a and j.status in ('posted','reversed') and j.journal_date<=d;
   if amt>round(balance,2) then raise exception 'Deposit return exceeds the recorded refundable deposit balance';end if;
  end if;
  if owner is not null and purpose not in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment','capital_contribution','owner_drawings','dividend_distribution','income_tax','income_tax_refund','share_buyback','return_share_capital') then raise exception 'Owner is not applicable';end if;
  if tax<>'NO_GST' then
   select bs.settings into settings from public.businesses bs where id=b;
   if coalesce(settings->>'country','NZ')<>'NZ' then raise exception 'GST-bearing general receipts currently require NZ tax configuration';end if;
   settings:=public.v61105_effective_tax_status(d);
   if not coalesce((settings->>'gst_registered')::boolean,false) then raise exception 'Business is not GST registered on this date';end if;
   rate:=coalesce((settings->>'effective_rate_percent')::numeric,0);if tax='GST' and rate<=0 then raise exception 'GST rate is unavailable';end if;
   gst:=case when tax='GST' then round(amt*rate/(100+rate),2) else 0 end;
  end if;
 end if;
 insert into public.cash_transactions(id,business_id,request_id,request_payload,kind,purpose,description,reference,note,party,tax_year,taxpayer,owner_id,account_id,amount,gst_amount,gst_treatment,interest_amount,withheld_amount,created_by)
 values(v_id,b,p_request,p,kind,purpose,label,nullif(btrim(p->>'reference'),''),nullif(btrim(p->>'note'),''),nullif(btrim(p->>'party'),''),yr,taxpayer,owner,a,amt,gst,tax,interest,withheld,auth.uid()) returning * into c;
 j:=public.v6192_create_posted_journal(b,d,'bank',case when kind='transfer' then 'cash_transfer' else 'cash_transaction' end,v_id,c.reference,label,frindly_cash.lines(c,bank,case when kind='in' then amt else -amt end));
 insert into public.cash_transaction_legs(business_id,transaction_id,bank_account_id,original_date,transaction_date,amount,accounting_journal_id) values(b,v_id,bank,d,d,case when kind='in' then amt else -amt end,j);
 if kind='transfer' then
  j:=public.v6192_create_posted_journal(b,d2,'bank','cash_transfer',v_id,c.reference,label,frindly_cash.lines(c,dest,amt));
  insert into public.cash_transaction_legs(business_id,transaction_id,bank_account_id,original_date,transaction_date,amount,accounting_journal_id) values(b,v_id,dest,d2,d2,amt,j);
 end if;
 if owner is not null and purpose in ('owner_funds_introduced','director_loan_received','repay_owner_loan','director_payment') then
  insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,description,created_by)
  values(b,owner,d,case when kind='in' then 'funds_introduced' else 'reimbursement' end,case when kind='in' then amt else -amt end,'cash_transaction',v_id,c.reference,j,label,auth.uid());
 end if;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'cash_transaction',v_id,'recorded',p,auth.uid());return v_id;
end $function$;


CREATE OR REPLACE FUNCTION frindly_cash.snapshot()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=frindly_cash.access();begin
 return jsonb_build_object('entity_type',(select business_entity_type from public.financial_settings where business_id=b),'transactions',coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('account_type',(select account_type from public.accounting_accounts where id=c.account_id and business_id=b),'legs',(select jsonb_agg(to_jsonb(l)||jsonb_build_object('matched',exists(select 1 from public.bank_reconciliation_allocations a where a.cash_leg_id=l.id),'bank_name',bk.name)) from public.cash_transaction_legs l join public.bank_accounts bk on bk.id=l.bank_account_id where l.transaction_id=c.id and l.business_id=b)) order by c.created_at desc) from public.cash_transactions c where c.business_id=b),'[]'::jsonb),
 'owners',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'name',o.display_name)) from public.business_owners o where o.business_id=b and o.status='active'),'[]'::jsonb),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'name',a.account_name,'type',a.account_type,'key',coalesce(a.system_key,a.system_account_key))) from public.accounting_accounts a where a.business_id=b and not coalesce(a.archived,false) and not coalesce(a.is_control,false) and coalesce(a.allow_manual_posting,false) and a.account_type in ('asset','liability','equity','revenue','other_income') and coalesce(a.system_key,a.system_account_key,'') !~ '(bank|receivable|payable|gst|payroll|tax|clearing|sales|opening_balance)' and a.account_subtype is distinct from 'bank' and a.id not in(select accounting_account_id from public.bank_accounts where business_id=b and accounting_account_id is not null)),'[]'::jsonb),
 'capital',jsonb_build_object(
 'can_record',public.v6169a_accountant_centre_access(b,true) and exists(select 1 from public.financial_settings where business_id=b and business_entity_type='company') and exists(select 1 from public.businesses where id=b and coalesce(settings->>'country','NZ')='NZ'),
 'shareholders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'name',o.display_name)) from public.business_owners o where o.business_id=b and o.status='active' and o.is_shareholder),'[]'::jsonb),
 'accounts',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'name',a.account_code||' · '||a.account_name)) from public.accounting_accounts a where a.business_id=b and frindly_cash.capital_equity_account(b,a.id)),'[]'::jsonb)),
 'can_write',public.v6147_can_write_area(b,'financials'));
end $function$;


CREATE OR REPLACE FUNCTION frindly_cash.match(p_bank_transaction uuid, p_leg uuid, p_request uuid DEFAULT NULL::uuid, p_payload jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=frindly_cash.access(true,true);tx public.bank_transactions%rowtype;l public.cash_transaction_legs%rowtype;c public.cash_transactions%rowtype;pid uuid;j uuid;old_date date;rid uuid;newlines jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into tx from public.bank_transactions where id=p_bank_transaction and business_id=b for update;
 if tx.id is null then raise exception 'Bank transaction not found';end if;
 if tx.status<>'unreconciled' or exists(select 1 from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id) then
  if p_leg is not null and exists(select 1 from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id and cash_leg_id=p_leg) then return p_leg;end if;
  if p_request is not null and exists(select 1 from public.bank_reconciliation_allocations a join public.cash_transaction_legs cl on cl.id=a.cash_leg_id join public.cash_transactions ct on ct.id=cl.transaction_id where a.business_id=b and a.bank_transaction_id=tx.id and ct.request_id=p_request and ct.request_payload=p_payload) then select cash_leg_id into rid from public.bank_reconciliation_allocations where business_id=b and bank_transaction_id=tx.id;return rid;end if;
  raise exception 'Bank transaction already reconciled or allocated';
 end if;
 perform frindly_cash.check_date(b,tx.transaction_date);
 if p_leg is null then
  if p_payload is null or (p_payload->>'amount')::numeric is distinct from abs(tx.amount) then raise exception 'New transaction must agree with the bank statement';end if;
  if p_payload->>'kind'='transfer' and tx.amount>0 then
   if (p_payload->>'to_bank_id')::uuid is distinct from tx.bank_account_id or coalesce(nullif(p_payload->>'received_date','')::date,(p_payload->>'date')::date) is distinct from tx.transaction_date then raise exception 'Transfer destination/date must agree with the statement';end if;
  elsif (p_payload->>'bank_id')::uuid is distinct from tx.bank_account_id or (p_payload->>'date')::date is distinct from tx.transaction_date or ((p_payload->>'kind'='in')<>(tx.amount>0)) then raise exception 'Transaction bank/date/direction must agree with the statement';end if;
  pid:=frindly_cash.record(p_request,p_payload);
  select * into l from public.cash_transaction_legs where business_id=b and transaction_id=pid and bank_account_id=tx.bank_account_id;
 else select * into l from public.cash_transaction_legs where business_id=b and id=p_leg for update;end if;
 if l.id is null or l.bank_account_id<>tx.bank_account_id or l.amount<>tx.amount then raise exception 'Transaction bank, amount or direction differs from the statement';end if;
 if exists(select 1 from public.bank_reconciliation_allocations where cash_leg_id=l.id) then raise exception 'Transaction already matched';end if;
 select * into c from public.cash_transactions where business_id=b and id=l.transaction_id and status='recorded';
 if c.id is null then raise exception 'Recorded transaction unavailable';end if;
 if not exists(select 1 from public.accounting_journals where business_id=b and id=l.accounting_journal_id and status='posted') then raise exception 'Transaction journal unavailable';end if;
 if exists(select 1 from public.bank_accounts where business_id=b and id=l.bank_account_id and opening_balance_journal_id is not null and tx.transaction_date<opening_balance_date) then raise exception 'Statement date predates the bank opening balance';end if;
 if c.purpose in ('share_buyback','return_share_capital') and l.transaction_date<>tx.transaction_date then raise exception 'Capital payment date differs from the statement. Ask your accountant to correct the approved transaction before matching';end if;
 if l.transaction_date<>tx.transaction_date then
  perform frindly_cash.check_date(b,l.transaction_date,c.gst_treatment<>'NO_GST');perform frindly_cash.check_date(b,tx.transaction_date,c.gst_treatment<>'NO_GST');
  if c.gst_treatment<>'NO_GST' then
   if (public.v61105_effective_tax_status(l.transaction_date)->>'effective_rate_percent') is distinct from (public.v61105_effective_tax_status(tx.transaction_date)->>'effective_rate_percent') or not coalesce((public.v61105_effective_tax_status(tx.transaction_date)->>'gst_registered')::boolean,false) then raise exception 'Date change crosses a GST status/rate boundary; review the transaction first';end if;
  end if;
  old_date:=l.transaction_date;
  -- Preserve the exact original allocations even if account mappings later change.
  select jsonb_agg(jsonb_build_object('account_id',account_id,'description',description,'debit',debit,'credit',credit,'tax_code',tax_code,'tax_rate',tax_rate,'tax_amount',tax_amount)) into newlines from public.accounting_journal_lines where business_id=b and journal_id=l.accounting_journal_id;
  rid:=frindly_cash.reverse_at(b,l.accounting_journal_id,'Bank statement date correction');
  j:=public.v6192_create_posted_journal(b,tx.transaction_date,'bank',case when c.kind='transfer' then 'cash_transfer' else 'cash_transaction' end,c.id,c.reference,c.description,newlines);
  update public.cash_transaction_legs set transaction_date=tx.transaction_date,accounting_journal_id=j where id=l.id;
  -- Owner amounts stay unchanged; date/journal provenance is retained in the accounting audit.
  update public.owner_current_account_entries set entry_date=tx.transaction_date,accounting_journal_id=j where business_id=b and source_type='cash_transaction' and source_id=c.id;
  insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'cash_transaction',c.id,'statement_date_corrected',jsonb_build_object('old_date',old_date,'statement_date',tx.transaction_date,'original_journal',l.accounting_journal_id,'reversal_journal',rid,'replacement_journal',j),auth.uid());
  l.accounting_journal_id:=j;
 end if;
 insert into public.bank_reconciliation_allocations(business_id,bank_transaction_id,allocation_type,amount,accounting_journal_id,cash_leg_id,created_by) values(b,tx.id,case when c.kind='transfer' then 'transfer' else 'cash_transaction' end,abs(l.amount),l.accounting_journal_id,l.id,auth.uid());
 update public.bank_transactions set status='reconciled',reconciliation_type=case when c.kind='transfer' then 'transfer' else 'cash_transaction' end,reconciled_at=now(),reconciled_by=auth.uid(),updated_at=now(),updated_by=auth.uid() where id=tx.id and business_id=b;
 insert into public.bank_reconciliation_audit(business_id,bank_transaction_id,action,details,created_by) values(b,tx.id,'cash_transaction_matched',jsonb_build_object('transaction_id',c.id,'leg_id',l.id,'journal_id',l.accounting_journal_id),auth.uid());return l.id;
end $function$;


CREATE OR REPLACE FUNCTION frindly_cash.void(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid:=frindly_cash.access(true);c public.cash_transactions%rowtype;legrow record;r uuid;entry record;
begin
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into c from public.cash_transactions where business_id=b and id=p_id and status='recorded' for update;
 if c.id is null or nullif(btrim(p_reason),'') is null then raise exception 'Select a recorded transaction and enter a reason';end if;
 if c.purpose in ('share_buyback','return_share_capital') and not public.v6169a_accountant_centre_access(b,true) then raise exception 'Capital reversal requires authorised accounting access';end if;
 if c.purpose='capital_contribution' and exists(select 1 from public.cash_transactions where business_id=b and purpose in ('share_buyback','return_share_capital') and status='recorded') and (select coalesce(sum(l.credit-l.debit),0) from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=c.account_id and j.status in ('posted','reversed'))<c.amount then raise exception 'Capital has already been returned. Review the linked capital payments before reversing this contribution';end if;
 if exists(select 1 from public.bank_reconciliation_allocations a join public.cash_transaction_legs cl on cl.id=a.cash_leg_id where cl.transaction_id=c.id) then raise exception 'Unmatch the bank statement before reversing this transaction';end if;
 if c.purpose in ('owner_funds_introduced','director_loan_received') and c.owner_id is not null and (select coalesce(sum(amount),0) from public.owner_current_account_entries where business_id=b and owner_id=c.owner_id)<c.amount then raise exception 'Owner funds have already been repaid. Review linked repayments before reversing this receipt';end if;
 if c.purpose in ('loan_received','deposit_paid') and (select coalesce(sum(case when c.purpose='loan_received' then l.credit-l.debit else l.debit-l.credit end),0) from public.accounting_journal_lines l join public.accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.business_id=b and l.account_id=c.account_id and j.status in ('posted','reversed'))<c.amount then raise exception 'This balance has already been settled. Review linked repayments or deposit returns first';end if;
 for legrow in select * from public.cash_transaction_legs where business_id=b and transaction_id=c.id loop
  perform frindly_cash.check_date(b,legrow.transaction_date,c.gst_treatment<>'NO_GST');r:=frindly_cash.reverse_at(b,legrow.accounting_journal_id,p_reason);
 end loop;
 for entry in select * from public.owner_current_account_entries where business_id=b and source_type='cash_transaction' and source_id=c.id loop
  insert into public.owner_current_account_entries(business_id,owner_id,entry_date,entry_type,amount,source_type,source_id,source_reference,accounting_journal_id,reversal_of_entry_id,description,created_by) values(b,entry.owner_id,entry.entry_date,'reversal',-entry.amount,'cash_transaction_void',c.id,entry.source_reference,r,entry.id,p_reason,auth.uid());
 end loop;
 update public.cash_transactions set status='void' where id=c.id;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'cash_transaction',c.id,'void',jsonb_build_object('reason',p_reason),auth.uid());
end $function$;

notify pgrst, 'reload schema';
