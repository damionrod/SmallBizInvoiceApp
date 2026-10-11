-- Purchase-order email reservation and completion. Apply in staging first.
create table if not exists public.purchase_order_email_attempts (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id),
 purchase_order_id uuid not null references public.purchase_orders(id),
 requested_by uuid not null,
 recipient text not null,
 state text not null check(state in ('reserved','sent','failed','uncertain')),
 provider_message_id text,
 error_summary text,
 created_at timestamptz not null default now(),
 completed_at timestamptz
);
create unique index if not exists po_email_one_unresolved_per_order
 on public.purchase_order_email_attempts(purchase_order_id)
 where state in ('reserved','uncertain');
create index if not exists po_email_attempts_business_po
 on public.purchase_order_email_attempts(business_id,purchase_order_id,created_at desc);
alter table public.purchase_order_email_attempts enable row level security;
revoke all on public.purchase_order_email_attempts from public,anon,authenticated;
grant select on public.purchase_order_email_attempts to authenticated;
drop policy if exists po_email_attempts_read on public.purchase_order_email_attempts;
create policy po_email_attempts_read on public.purchase_order_email_attempts for select to authenticated
 using (public.v6147_can_write_area(business_id,'expenses'));

create or replace function public.v61142k_reserve_po_email(p_id uuid,p_recipient text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_po public.purchase_orders%rowtype; v_attempt uuid;
begin
 select * into v_po from public.purchase_orders where id=p_id for update;
 if not found or not public.v6147_can_write_area(v_po.business_id,'expenses') then raise exception 'Purchase order unavailable or permission denied'; end if;
 if v_po.status not in ('draft','approved','sent') then raise exception 'This Purchase Order cannot be emailed'; end if;
 if nullif(trim(p_recipient),'') is null then raise exception 'Supplier email is required'; end if;
 if exists(select 1 from public.purchase_order_email_attempts where purchase_order_id=p_id and state in ('reserved','uncertain')) then
  raise exception 'An email is already processing or needs delivery confirmation. Check email history before retrying';
 end if;
 if exists(select 1 from public.purchase_order_email_attempts where purchase_order_id=p_id and state='sent' and created_at>now()-interval '60 seconds') then
  raise exception 'This Purchase Order was just emailed. Wait one minute before resending';
 end if;
 insert into public.purchase_order_email_attempts(business_id,purchase_order_id,requested_by,recipient,state)
 values(v_po.business_id,p_id,auth.uid(),p_recipient,'reserved') returning id into v_attempt;
 return v_attempt;
end $$;
revoke all on function public.v61142k_reserve_po_email(uuid,text) from public,anon;
grant execute on function public.v61142k_reserve_po_email(uuid,text) to authenticated;

-- Called only by the Edge Function using the service role after a provider result.
create or replace function public.v61142k_finish_po_email(p_attempt uuid,p_outcome text,p_provider_id text default null,p_error text default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_attempt public.purchase_order_email_attempts%rowtype; v_po public.purchase_orders%rowtype;
begin
 if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
 select * into v_attempt from public.purchase_order_email_attempts where id=p_attempt for update;
 if not found then raise exception 'Email attempt not found'; end if;
 if v_attempt.state <> 'reserved' then raise exception 'Email attempt already finalized'; end if;
 select * into v_po from public.purchase_orders where id=v_attempt.purchase_order_id for update;
 if not found then raise exception 'Purchase Order not found'; end if;
 if p_outcome not in ('sent','failed','uncertain') then raise exception 'Invalid email outcome'; end if;
 update public.purchase_order_email_attempts set state=p_outcome,provider_message_id=left(p_provider_id,200),error_summary=left(p_error,500),completed_at=now() where id=p_attempt;
 if p_outcome='sent' then
   if v_po.status not in ('draft','approved','sent') then raise exception 'Purchase Order changed status while sending'; end if;
   update public.purchase_orders set status='sent',updated_at=clock_timestamp(),updated_by=v_attempt.requested_by where id=v_po.id;
   insert into public.purchase_order_events(business_id,purchase_order_id,event_type,note,created_by)
   values(v_po.business_id,v_po.id,'emailed',left('Sent to '||v_attempt.recipient||'; provider ID '||coalesce(p_provider_id,'unavailable'),1000),v_attempt.requested_by);
 end if;
end $$;
revoke all on function public.v61142k_finish_po_email(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.v61142k_finish_po_email(uuid,text,text,text) to service_role;

-- Prevent edits, cancellation, and deletion while email delivery is unresolved.
-- Service role completion remains permitted.
create or replace function public.v61142k_block_po_changes_during_send()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 if auth.role()='service_role' then return coalesce(new,old); end if;
 v_id:=case when tg_op='DELETE' then old.id else new.id end;
 if exists(select 1 from public.purchase_order_email_attempts where purchase_order_id=v_id and state in ('reserved','uncertain')) then
  raise exception 'Purchase Order email is processing or requires delivery confirmation';
 end if;
 return coalesce(new,old);
end $$;
drop trigger if exists po_email_guard_header on public.purchase_orders;
create trigger po_email_guard_header before update or delete on public.purchase_orders
 for each row execute function public.v61142k_block_po_changes_during_send();
