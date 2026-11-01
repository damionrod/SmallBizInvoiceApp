-- Read-only per-bank ledger diagnostics. No backfill, journal creation, or data changes.
-- Unlinked accounts are explicitly reported rather than guessed from default bank.
create or replace function public.frindly_bank_ledger_status_v1(p_as_of date default current_date)
returns table (
  bank_account_id uuid,
  bank_account_name text,
  accounting_account_id uuid,
  account_code text,
  book_balance numeric,
  mapping_status text
)
language sql stable security definer set search_path = ''
as $$
  with ctx as (
    select public.current_business_id() as bid, auth.uid() as uid
  )
  select b.id, b.name::text, a.id, a.account_code::text,
    case when a.id is null then null
      else coalesce((
        select round(sum(coalesce(l.debit,0)-coalesce(l.credit,0)),2)
        from public.accounting_journal_lines l
        join public.accounting_journals j on j.id=l.journal_id
          and j.business_id=l.business_id
        where l.business_id=b.business_id
          and l.account_id=a.id
          and j.status in ('posted','reversed')
          and j.journal_date<=p_as_of
      ),0)
    end,
    case when b.accounting_account_id is null then 'unlinked'
      when a.id is null then 'invalid_mapping'
      else 'linked' end::text
  from public.bank_accounts b
  join ctx on ctx.bid=b.business_id
  left join public.accounting_accounts a
    on a.id=b.accounting_account_id
   and a.business_id=b.business_id
   and not coalesce(a.archived,false)
   and (a.account_type='bank' or a.account_subtype='bank' or a.xero_account_type='BANK')
  where ctx.uid is not null and not coalesce(b.archived,false)
  order by b.is_default desc,b.name,b.id;
$$;
revoke execute on function public.frindly_bank_ledger_status_v1(date) from public, anon;
grant execute on function public.frindly_bank_ledger_status_v1(date) to authenticated, service_role;
