-- Ownership events link existing payments; they never create accounting journals.
create table frindly_cash.share_changes(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id),
 request_id uuid not null,request_payload jsonb not null,owner_id uuid not null references public.business_owners(id),
 change_type text not null check(change_type in ('cancellation','capital_only')),effective_date date not null,
 share_class text,shares_acquired numeric(18,4) not null check(shares_acquired>=0),authority_ref text not null,
 before_data jsonb not null,after_data jsonb not null,note text not null,created_by uuid not null,created_at timestamptz not null default now(),
 payment_review_required boolean not null default false,unique(business_id,request_id),unique(business_id,owner_id,authority_ref,effective_date)
);
create table frindly_cash.share_change_payments(
 transaction_id uuid primary key references public.cash_transactions(id),change_id uuid not null references frindly_cash.share_changes(id),
 business_id uuid not null references public.businesses(id),created_by uuid not null,created_at timestamptz not null default now()
);
create index share_changes_business_idx on frindly_cash.share_changes(business_id,owner_id);
create index share_change_payments_event_idx on frindly_cash.share_change_payments(change_id);
alter table frindly_cash.share_changes enable row level security;
alter table frindly_cash.share_change_payments enable row level security;
revoke all on frindly_cash.share_changes,frindly_cash.share_change_payments from public,anon,authenticated;

create function public.frindly_share_change_snapshot(p_transaction_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare b uuid:=frindly_cash.access();c public.cash_transactions%rowtype;
begin
 if not exists(select 1 from public.financial_settings where business_id=b and business_entity_type='company')
 or not exists(select 1 from public.businesses where id=b and coalesce(settings->>'country','NZ')='NZ') then raise exception 'Shareholding changes are available only for NZ companies, not sole traders or proprietors';end if;
 select * into c from public.cash_transactions where id=p_transaction_id and business_id=b and purpose in ('share_buyback','return_share_capital');
 if c.id is null then raise exception 'Capital payment unavailable in this company';end if;
 return jsonb_build_object('can_confirm',public.v6147_can_write_area(b,'financials') and public.v6169a_accountant_centre_access(b,true) and public.v6147_current_business_role(b) in ('owner','admin','bookkeeper'),
 'owners',coalesce((select jsonb_agg(to_jsonb(o) order by o.id) from public.business_owners o where o.business_id=b and (o.is_shareholder or coalesce(o.shares_held,0)>0)),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(e)-'request_payload'||jsonb_build_object('payments',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'description',t.description,'status',t.status,'amount',t.amount)) from frindly_cash.share_change_payments l join public.cash_transactions t on t.id=l.transaction_id and t.business_id=b where l.change_id=e.id and l.business_id=b),'[]'::jsonb)) order by e.created_at desc) from frindly_cash.share_changes e where e.business_id=b and e.owner_id=c.owner_id),'[]'::jsonb),
 'linked_event_id',(select change_id from frindly_cash.share_change_payments where business_id=b and transaction_id=c.id));
end $$;
revoke all on function public.frindly_share_change_snapshot(uuid) from public,anon;
grant execute on function public.frindly_share_change_snapshot(uuid) to authenticated;

create function public.frindly_confirm_share_change(p_request_id uuid,p_change jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare b uuid:=frindly_cash.access(true);c public.cash_transactions%rowtype;e frindly_cash.share_changes%rowtype;
 o public.business_owners%rowtype;h public.business_owners%rowtype;owners jsonb;after_rows jsonb:='[]';
 eid uuid:=nullif(p_change->>'event_id','')::uuid;d date:=(p_change->>'effective_date')::date;
 qty numeric:=(p_change->>'shares_acquired')::numeric;total numeric;remaining numeric;pct numeric;
 typ text:=p_change->>'change_type';ref text:=btrim(p_change->>'authority_ref');note text:=btrim(p_change->>'note');
begin
 if public.v6169a_accountant_centre_access(b,true) is not true or coalesce(public.v6147_current_business_role(b),'') not in ('owner','admin','bookkeeper') then raise exception 'Authorised company accounting access is required' using errcode='42501';end if;
 if not exists(select 1 from public.financial_settings where business_id=b and business_entity_type='company')
 or not exists(select 1 from public.businesses where id=b and coalesce(settings->>'country','NZ')='NZ') then raise exception 'Shareholding changes require an NZ company; sole traders and proprietors are excluded';end if;
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into e from frindly_cash.share_changes where business_id=b and request_id=p_request_id;
 if found then if e.request_payload is distinct from p_change then raise exception 'Request already used for another change';end if;return e.id;end if;
 select * into c from public.cash_transactions where business_id=b and id=(p_change->>'transaction_id')::uuid for update;
 if c.id is null or c.status<>'recorded' or c.purpose not in ('share_buyback','return_share_capital') then raise exception 'Select a recorded capital payment in this company';end if;
 if exists(select 1 from frindly_cash.share_change_payments where transaction_id=c.id) then
  select change_id into eid from frindly_cash.share_change_payments where transaction_id=c.id and business_id=b;
  if eid is not null and eid=nullif(p_change->>'event_id','')::uuid then return eid;end if;
  raise exception 'This payment already has a confirmed shareholding change. Open its linked record';
 end if;
 if p_change->'authorised' is distinct from 'true'::jsonb then raise exception 'Confirm the approved legal completion and supporting records';end if;
 if eid is not null then
  select * into e from frindly_cash.share_changes where id=eid and business_id=b and owner_id=c.owner_id for update;
  if e.id is null or e.payment_review_required or (e.change_type='cancellation' and c.purpose<>'share_buyback') or (e.change_type='capital_only' and c.purpose<>'return_share_capital') then raise exception 'Select a compatible confirmed change for this shareholder without a payment review warning';end if;
 else
  if typ is null or typ not in ('cancellation','capital_only') or (typ='cancellation' and c.purpose<>'share_buyback') or (typ='capital_only' and c.purpose<>'return_share_capital') then raise exception 'Select an appropriate shareholding change';end if;
  if d is null or d>(now() at time zone 'Pacific/Auckland')::date or length(coalesce(ref,''))<3 or length(ref)>200 or length(coalesce(note,''))<5 or length(note)>1000 then raise exception 'Enter the completed acquisition/effective date, approval reference and supporting document note';end if;
  if d<nullif(c.request_payload->>'capital_authority_date','')::date then raise exception 'Legal completion cannot predate the recorded capital authorisation';end if;
  perform 1 from public.business_owners where business_id=b order by id for update;
  select * into o from public.business_owners where business_id=b and id=c.owner_id;
  if o.id is null or not o.is_shareholder or o.status<>'active' then raise exception 'The recipient must be a current shareholder; review the existing shareholder record';end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) into owners from public.business_owners x where x.business_id=b and (x.is_shareholder or coalesce(x.shares_held,0)>0);
  if p_change->'expected_owners' is distinct from owners then raise exception 'Shareholder details changed. Reload and review the preview again';end if;
  if exists(select 1 from public.business_owners where business_id=b and (is_shareholder or coalesce(shares_held,0)>0) and shareholding_effective_from>d)
   or exists(select 1 from public.business_owner_history where business_id=b and change_type='shareholding_changed' and effective_date>d)
   or exists(select 1 from frindly_cash.share_changes where business_id=b and effective_date>d) then raise exception 'An ownership change is already recorded after this date. Ask your accountant to review the dated history';end if;
  if typ='cancellation' then
   if p_change->'register_complete' is distinct from 'true'::jsonb or qty is null or qty<=0 or qty<>round(qty,4) or qty>coalesce(o.shares_held,0) then raise exception 'Confirm a complete share register and a valid number of shares acquired';end if;
   if nullif(btrim(o.share_class),'') is null or exists(select 1 from public.business_owners where business_id=b and (is_shareholder or coalesce(shares_held,0)>0) and (shares_held is null or shares_held<0 or share_class is distinct from o.share_class or (shares_held>0 and (status<>'active' or not is_shareholder)))) then raise exception 'Complete all share quantities and the single share class in Settings first. Multiple classes and treasury shares require the accountant workflow';end if;
   select sum(shares_held) into total from public.business_owners where business_id=b and (is_shareholder or coalesce(shares_held,0)>0);
   if total-qty<=0 then raise exception 'Cancellation of all issued shares requires the accountant workflow';end if;
  else
   qty:=0;
   if coalesce((p_change->>'shares_acquired')::numeric,0)<>0 then raise exception 'A capital-only return must not reduce shares';end if;
  end if;
  insert into frindly_cash.share_changes(business_id,request_id,request_payload,owner_id,change_type,effective_date,share_class,shares_acquired,authority_ref,before_data,after_data,note,created_by)
   values(b,p_request_id,p_change,o.id,typ,d,o.share_class,qty,ref,owners,owners,note,auth.uid()) returning * into e;
  if typ='cancellation' then
   for h in select * from public.business_owners where business_id=b and (is_shareholder or coalesce(shares_held,0)>0) order by id loop
    remaining:=h.shares_held-case when h.id=o.id then qty else 0 end;pct:=round(remaining/(total-qty)*100,2);
    -- Reuse the existing owner/history writer and preserve director appointments/resignations.
    perform public.v61107v_update_business_owner(h.id,h.display_name,h.owner_type,remaining>0,h.is_director,pct,h.share_class,remaining,
     case when remaining=0 and not h.is_director and h.owner_type='shareholder' then 'inactive' else h.status end,
     h.director_appointed_on,h.director_resigned_on,d,'Share buyback '||ref||' — '||note);
   end loop;
  else
   insert into public.business_owner_history(business_id,owner_id,effective_date,change_type,before_data,after_data,note,created_by)
    values(b,o.id,d,'details_corrected',to_jsonb(o),to_jsonb(o),'Return of capital '||ref||' — shares unchanged. '||note,auth.uid());
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) into after_rows from public.business_owners x where x.business_id=b and x.id in(select (v->>'id')::uuid from jsonb_array_elements(owners) v);
  update frindly_cash.share_changes set after_data=after_rows where id=e.id;
 end if;
 insert into frindly_cash.share_change_payments(transaction_id,change_id,business_id,created_by) values(c.id,e.id,b,auth.uid());
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'cash_transaction',c.id,'shareholding_link',jsonb_build_object('share_change_id',e.id,'no_journal_posted',true),auth.uid());
 return e.id;
end $$;
revoke all on function public.frindly_confirm_share_change(uuid,jsonb) from public,anon;
grant execute on function public.frindly_confirm_share_change(uuid,jsonb) to authenticated;

-- A bank reversal does not undo a legal acquisition. Flag its linked record for explicit review.
create function frindly_cash.flag_share_payment_review() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.status is distinct from new.status and new.status='void' then
  update frindly_cash.share_changes e set payment_review_required=true from frindly_cash.share_change_payments l where l.transaction_id=new.id and l.business_id=new.business_id and e.id=l.change_id and e.business_id=new.business_id;
 end if;return new;
end $$;
revoke all on function frindly_cash.flag_share_payment_review() from public,anon,authenticated;
create trigger cash_share_payment_review after update of status on public.cash_transactions for each row execute function frindly_cash.flag_share_payment_review();

-- Reuse dated owner history for report periods; preserve legacy behaviour when no linked changes exist.
create function public.frindly_shareholding_report_history() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b uuid:=public.current_business_id();begin
 if auth.uid() is null or b is null or public.v6145_has_active_business_membership(b) is not true then raise exception 'Active business membership is required' using errcode='42501';end if;
 if not exists(select 1 from public.financial_settings where business_id=b and business_entity_type='company') or not exists(select 1 from frindly_cash.share_changes where business_id=b) then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(jsonb_build_object('owner_id',owner_id,'effective_date',effective_date,'before_data',before_data,'after_data',after_data) order by effective_date,created_at,id) from public.business_owner_history where business_id=b and change_type='shareholding_changed'),'[]'::jsonb);
end $$;
revoke all on function public.frindly_shareholding_report_history() from public,anon;
grant execute on function public.frindly_shareholding_report_history() to authenticated;

-- Additional instalments may link the same completed event, including a former shareholder.
-- Extend existing capital validation/snapshot in place; retain every accounting mapping and guard.
do $$declare def text;needle text;begin
 select pg_get_functiondef('frindly_cash.validate_capital(uuid,jsonb)'::regprocedure) into def;
 needle:='if not exists(select 1 from public.business_owners where business_id=b and id=owner and status=''active'' and is_shareholder';
 if position(needle in def)=0 then raise exception 'Capital validator changed; inspect before applying';end if;
 def:=replace(def,needle,'if nullif(p->>''capital_share_change_id'','''') is not null then
  if not exists(select 1 from frindly_cash.share_changes where id=(p->>''capital_share_change_id'')::uuid and business_id=b and owner_id=owner and not payment_review_required and effective_date<=d and change_type=case when p->>''purpose''=''share_buyback'' then ''cancellation'' else ''capital_only'' end) then raise exception ''Select a compatible confirmed share change for this recipient and payment date'';end if;
 elsif not exists(select 1 from public.business_owners where business_id=b and id=owner and status=''active'' and is_shareholder');
 execute def;
 select pg_get_functiondef('frindly_cash.snapshot()'::regprocedure) into def;
 needle:='''capital'',jsonb_build_object(';
 if position(needle in def)=0 then raise exception 'Capital snapshot changed; inspect before applying';end if;
 def:=replace(def,needle,needle||'
 ''share_changes'',coalesce((select jsonb_agg(jsonb_build_object(''id'',e.id,''owner_id'',e.owner_id,''type'',e.change_type,''reference'',e.authority_ref,''effective_date'',e.effective_date)) from frindly_cash.share_changes e where e.business_id=b and not e.payment_review_required),''[]''::jsonb),');
 needle:='where o.business_id=b and o.status=''active'' and o.is_shareholder';
 if position(needle in def)=0 then raise exception 'Capital shareholder list changed; inspect before applying';end if;
 def:=replace(def,needle,'where o.business_id=b and ((o.status=''active'' and o.is_shareholder) or exists(select 1 from frindly_cash.share_changes e where e.business_id=b and e.owner_id=o.id and not e.payment_review_required))');
 execute def;
end $$;
create function frindly_cash.link_share_instalment() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.purpose in ('share_buyback','return_share_capital') and nullif(new.request_payload->>'capital_share_change_id','') is not null then
  perform public.frindly_confirm_share_change(new.request_id,jsonb_build_object('transaction_id',new.id,'event_id',new.request_payload->>'capital_share_change_id','authorised',true));
 end if;return new;
end $$;
revoke all on function frindly_cash.link_share_instalment() from public,anon,authenticated;
create trigger cash_link_share_instalment after insert on public.cash_transactions for each row execute function frindly_cash.link_share_instalment();

alter table frindly_cash.share_changes add column payment_review_note text,add column payment_reviewed_at timestamptz,add column payment_reviewed_by uuid;
create function public.frindly_review_share_payment(p_change_id uuid,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare b uuid:=frindly_cash.access(true);e frindly_cash.share_changes%rowtype;begin
 if public.v6169a_accountant_centre_access(b,true) is not true or coalesce(public.v6147_current_business_role(b),'') not in ('owner','admin','bookkeeper') then raise exception 'Authorised company accounting access is required' using errcode='42501';end if;
 if not exists(select 1 from public.financial_settings where business_id=b and business_entity_type='company') or not exists(select 1 from public.businesses where id=b and coalesce(settings->>'country','NZ')='NZ') then raise exception 'Shareholding review is for companies only';end if;
 perform pg_advisory_xact_lock(hashtextextended('frindly-cash:'||b::text,0));
 select * into e from frindly_cash.share_changes where business_id=b and id=p_change_id for update;
 if e.id is null or not e.payment_review_required or length(btrim(coalesce(p_note,'')))<10 or length(p_note)>1000 then raise exception 'Select a flagged change and describe the accountant review and replacement payment arrangement';end if;
 update frindly_cash.share_changes set payment_review_required=false,payment_review_note=btrim(p_note),payment_reviewed_at=now(),payment_reviewed_by=auth.uid() where id=e.id;
 insert into public.accounting_audit_log(business_id,entity_type,entity_id,action,details,created_by) values(b,'share_change',e.id,'payment_review',jsonb_build_object('note',p_note,'ownership_unchanged',true),auth.uid());
end $$;
revoke all on function public.frindly_review_share_payment(uuid,text) from public,anon;
grant execute on function public.frindly_review_share_payment(uuid,text) to authenticated;
