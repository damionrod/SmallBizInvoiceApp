-- Fix leave approval failure: avoid unassigned composite records in PL/pgSQL.
create or replace function public.frindly_leave_request_action(p_draft_id uuid,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 b uuid := public.current_business_id();
 draft_business uuid;
 approval_id uuid;
 approval_status text;
 submitted_by_user uuid;
begin
 if auth.uid() is null or b is null or not public.frindly_leave_manager_can_approve(b) then
  raise exception 'Leave manager permission required' using errcode='42501';
 end if;
 if p_draft_id is null or p_action is null or p_action not in ('submit','approve','decline') then
  raise exception 'Invalid action' using errcode='22023';
 end if;

 select business_id into draft_business
 from public.payroll_manager_leave_drafts
 where id=p_draft_id and business_id=b
 for update;
 if draft_business is null then raise exception 'Request unavailable' using errcode='42501'; end if;

 if p_action='submit' then
  insert into public.payroll_manager_leave_approvals_isolated(business_id,draft_id,submitted_by)
  values(b,p_draft_id,auth.uid())
  returning id,status into approval_id,approval_status;
 else
  select id,submitted_by into approval_id,submitted_by_user
  from public.payroll_manager_leave_approvals_isolated
  where draft_id=p_draft_id and business_id=b and status='pending'
  for update;
  if approval_id is null then raise exception 'Pending request unavailable' using errcode='42501'; end if;

  update public.payroll_manager_leave_approvals_isolated
  set status=case when p_action='approve' then 'approved' else 'declined' end,
      decided_by=auth.uid(), decided_at=now()
  where id=approval_id
  returning status into approval_status;
 end if;

 insert into public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by)
 values(b,'manager_leave_approval',approval_id,p_action,
        jsonb_build_object('draft_id',p_draft_id,'status',approval_status),auth.uid());
 return jsonb_build_object('id',approval_id,'draft_id',p_draft_id,'status',approval_status);
end $$;

revoke all on function public.frindly_leave_request_action(uuid,text) from public,anon;
grant execute on function public.frindly_leave_request_action(uuid,text) to authenticated;
