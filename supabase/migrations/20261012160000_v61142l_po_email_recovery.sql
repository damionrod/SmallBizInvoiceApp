-- v61.142L: controlled resolution of uncertain PO email delivery.
-- Apply after v61.142K. Never automatically retry ambiguous provider outcomes.
create or replace function public.v61142l_resolve_po_email(
 p_attempt uuid,
 p_resolution text,
 p_evidence text,
 p_provider_message_id text default null
) returns void
language plpgsql security definer set search_path=public as $$
declare a public.purchase_order_email_attempts%rowtype;
        p public.purchase_orders%rowtype;
begin
 if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
 if p_resolution not in ('sent','failed') then raise exception 'Invalid resolution'; end if;
 if length(trim(coalesce(p_evidence,''))) < 12 then raise exception 'Provider verification evidence required'; end if;
 select * into a from public.purchase_order_email_attempts where id=p_attempt for update;
 if not found then raise exception 'Email attempt not found'; end if;
 if a.state <> 'uncertain' then raise exception 'Only uncertain email attempts can be resolved'; end if;
 select * into p from public.purchase_orders where id=a.purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if p_resolution='sent' and p.status not in ('draft','approved','sent') then
   raise exception 'Purchase order status requires manual review';
 end if;
 update public.purchase_order_email_attempts
 set state=p_resolution,
     provider_message_id=left(coalesce(nullif(p_provider_message_id,''),provider_message_id),200),
     error_summary=left('Resolved after provider verification: '||trim(p_evidence),500),
     completed_at=clock_timestamp()
 where id=p_attempt;
 if p_resolution='sent' then
   update public.purchase_orders set status='sent',updated_at=clock_timestamp(),updated_by=a.requested_by where id=p.id;
 end if;
 insert into public.purchase_order_events(business_id,purchase_order_id,event_type,note,created_by)
 values(a.business_id,a.purchase_order_id,'email_delivery_resolved',
        left('Email attempt '||a.id||' verified as '||p_resolution||'. Evidence: '||trim(p_evidence),1000),a.requested_by);
end $$;
revoke all on function public.v61142l_resolve_po_email(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.v61142l_resolve_po_email(uuid,text,text,text) to service_role;
