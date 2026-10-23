-- Allow authorised payroll managers to create and approve leave on behalf of employees.
-- This is the intended admin/bookkeeper workflow; payroll posting remains separate.
create or replace function public.frindly_leave_request_action(p_draft_id uuid,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); d public.payroll_manager_leave_drafts; a public.payroll_manager_leave_approvals_isolated;
begin
 if auth.uid() is null or b is null or not public.frindly_leave_manager_can_approve(b) then
  raise exception 'Leave manager permission required' using errcode='42501';
 end if;
 if p_draft_id is null or p_action is null or p_action not in ('submit','approve','decline') then
  raise exception 'Invalid action' using errcode='22023';
 end if;
 select * into d from public.payroll_manager_leave_drafts where id=p_draft_id and business_id=b for update;
 if not found then raise exception 'Request unavailable' using errcode='42501'; end if;
 if p_action='submit' then
  insert into public.payroll_manager_leave_approvals_isolated(business_id,draft_id,submitted_by)
  values(b,d.id,auth.uid()) returning * into a;
 else
  select * into a from public.payroll_manager_leave_approvals_isolated
   where draft_id=d.id and business_id=b and status='pending' for update;
  if not found then raise exception 'Pending request unavailable' using errcode='42501'; end if;
  update public.payroll_manager_leave_approvals_isolated
   set status=case when p_action='approve' then 'approved' else 'declined' end,
       decided_by=auth.uid(),decided_at=now() where id=a.id returning * into a;
 end if;
 insert into public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by)
 values(b,'manager_leave_approval',a.id,p_action,jsonb_build_object('draft_id',d.id,'status',a.status),auth.uid());
 return jsonb_build_object('id',a.id,'draft_id',d.id,'status',a.status);
end $$;

revoke all on function public.frindly_leave_request_action(uuid,text) from public,anon;
grant execute on function public.frindly_leave_request_action(uuid,text) to authenticated;
