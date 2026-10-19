-- Isolated historical-paid invoice bank matching. Never creates customer payments or reposts GST.
create or replace function public.v6219l_paid_migration_candidates()
returns table(invoice_id uuid, unmatched_amount numeric)
language sql stable security definer set search_path=public
as $$
 select i.id,round(greatest(0,least(i.total,coalesce(i.amount_paid,0))-coalesce(a.allocated,0)),2)
 from public.migration_invoice_links l
 join public.invoices i on i.id=l.invoice_id and i.business_id=l.business_id
 left join lateral (
   select sum(bra.amount) allocated from public.bank_reconciliation_allocations bra
   where bra.business_id=l.business_id and bra.invoice_id=l.invoice_id
 ) a on true
 where l.business_id=public.current_business_id()
   and public.v6147_can_read_area(l.business_id,'bank')
   and i.lifecycle_state='issued' and coalesce(i.amount_paid,0)>0
   and not exists(select 1 from public.customer_payments cp where cp.business_id=l.business_id and cp.invoice_id=l.invoice_id)
   and least(i.total,coalesce(i.amount_paid,0))>coalesce(a.allocated,0)+0.005;
$$;
revoke all on function public.v6219l_paid_migration_candidates() from public,anon;
grant execute on function public.v6219l_paid_migration_candidates() to authenticated;

create or replace function public.v6219l_match_paid_migration(p_bank_transaction_id uuid,p_invoice_id uuid,p_amount numeric)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_bid uuid:=public.current_business_id(); v_tx public.bank_transactions%rowtype;
 v_inv public.invoices%rowtype; v_prior numeric; v_currency text; v_bank_currency text;
begin
 if auth.uid() is null or v_bid is null or not public.v6147_can_write_area(v_bid,'bank') then
   raise exception 'Bank reconciliation access denied' using errcode='42501';
 end if;
 if p_bank_transaction_id is null or p_invoice_id is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then
   raise exception 'A valid bank transaction, invoice and cents amount are required';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_bank_transaction_id::text,6203));
 select * into v_tx from public.bank_transactions where id=p_bank_transaction_id and business_id=v_bid for update;
 if not found or v_tx.status<>'unreconciled' or v_tx.amount<=0 then raise exception 'Bank deposit is no longer available for matching';end if;
 if abs(v_tx.amount-p_amount)>0.005 then raise exception 'Bank deposit must match the allocation amount';end if;
 select * into v_inv from public.invoices where id=p_invoice_id and business_id=v_bid for update;
 if not found or v_inv.lifecycle_state<>'issued' then raise exception 'Invoice is not an issued invoice';end if;
 if not exists(select 1 from public.migration_invoice_links where invoice_id=p_invoice_id and business_id=v_bid) then
   raise exception 'This route is only for migrated historical invoices';end if;
 if exists(select 1 from public.customer_payments where business_id=v_bid and invoice_id=p_invoice_id) then
   raise exception 'Invoice already has recorded payments; use the standard payment matching route';end if;
 select upper(coalesce(nullif(trim(b.settings->>'currency'),''),'NZD')) into v_currency
 from public.businesses b where b.id=v_bid;
 select upper(trim(a.currency)) into v_bank_currency from public.bank_accounts a where a.id=v_tx.bank_account_id and a.business_id=v_bid;
 if v_bank_currency is null or v_bank_currency<>coalesce(v_currency,'NZD') then raise exception 'Bank and invoice currencies do not match';end if;
 select coalesce(sum(amount),0) into v_prior from public.bank_reconciliation_allocations
 where business_id=v_bid and invoice_id=p_invoice_id;
 if v_prior+p_amount>least(v_inv.total,coalesce(v_inv.amount_paid,0))+0.005 then
   raise exception 'Matching would exceed the imported paid amount';end if;
 insert into public.bank_reconciliation_allocations
 (business_id,bank_transaction_id,allocation_type,amount,invoice_id,note,created_by)
 values(v_bid,v_tx.id,'invoice',p_amount,p_invoice_id,'Historical paid invoice: bank evidence only; no additional customer payment',auth.uid());
 update public.bank_transactions set status='reconciled',reconciliation_type='invoice',reconciled_at=now(),
 reconciled_by=auth.uid(),updated_by=auth.uid(),updated_at=now()
 where id=v_tx.id and business_id=v_bid and status='unreconciled';
 if not found then raise exception 'Bank transaction changed during reconciliation';end if;
 return jsonb_build_object('status','reconciled','invoice_id',p_invoice_id,'bank_transaction_id',v_tx.id,'amount',p_amount,'new_payment_created',false);
end;
$$;
revoke all on function public.v6219l_match_paid_migration(uuid,uuid,numeric) from public,anon;
grant execute on function public.v6219l_match_paid_migration(uuid,uuid,numeric) to authenticated;
