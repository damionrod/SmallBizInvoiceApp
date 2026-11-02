-- Historical bank-ledger links consolidate presentation without rewriting posted journals.
create table public.bank_account_ledger_links(
 business_id uuid not null references public.businesses(id),
 bank_account_id uuid not null references public.bank_accounts(id),
 accounting_account_id uuid not null references public.accounting_accounts(id),
 reason text not null check(length(btrim(reason))>0),
 created_at timestamptz not null default now(),
 created_by uuid references auth.users(id),
 primary key(business_id,accounting_account_id)
);
create index bank_account_ledger_links_bank_idx on public.bank_account_ledger_links(bank_account_id);
create index bank_account_ledger_links_account_idx on public.bank_account_ledger_links(accounting_account_id);
alter table public.bank_account_ledger_links enable row level security;
revoke all on public.bank_account_ledger_links from public,anon,authenticated;
grant select on public.bank_account_ledger_links to authenticated;
create policy bank_ledger_links_read on public.bank_account_ledger_links for select to authenticated
 using(business_id=(select public.current_business_id()) and
 (public.v6147_can_read_area(business_id,'financials') or public.v6147_can_read_area(business_id,'bank') or public.v6147_can_read_area(business_id,'business_settings')));

create function public.frindly_bank_ledger_aliases_v1()
returns table(bank_account_id uuid,accounting_account_id uuid)
language sql stable security invoker set search_path='' as $$
 select l.bank_account_id,l.accounting_account_id from public.bank_account_ledger_links l
 join public.bank_accounts b on b.business_id=l.business_id and b.id=l.bank_account_id and not b.archived
 join public.accounting_accounts a on a.business_id=l.business_id and a.id=l.accounting_account_id
 where auth.uid() is not null and l.business_id=public.current_business_id();
$$;
revoke all on function public.frindly_bank_ledger_aliases_v1() from public,anon;
grant execute on function public.frindly_bank_ledger_aliases_v1() to authenticated;

-- Validate tenant boundaries independently of RLS for maintenance/service writes too.
create function public.frindly_validate_bank_ledger_link() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.bank_accounts b join public.accounting_accounts a on a.business_id=b.business_id where b.business_id=new.business_id and b.id=new.bank_account_id and a.id=new.accounting_account_id) then
 raise exception 'Bank ledger link must remain in the same business'; end if;
 return new;
end $$;
revoke all on function public.frindly_validate_bank_ledger_link() from public,anon,authenticated;
create trigger frindly_validate_bank_ledger_link before insert or update on public.bank_account_ledger_links for each row execute function public.frindly_validate_bank_ledger_link();

-- Keep the existing authorised bank diagnostics consistent with Dashboard and Cash Book.
do $patch$ declare d text;begin
 select pg_get_functiondef('public.frindly_bank_ledger_status_v1(date)'::regprocedure) into d;
 if strpos(d,'and l.account_id=a.id')=0 then raise exception 'Bank status patch guard failed';end if;
 d:=replace(d,'and l.account_id=a.id','and (l.account_id=a.id or exists(select 1 from public.bank_account_ledger_links bl where bl.business_id=b.business_id and bl.bank_account_id=b.id and bl.accounting_account_id=l.account_id))');
 execute d;
end $patch$;
