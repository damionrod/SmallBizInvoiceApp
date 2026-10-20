-- Leave manager permissions: proposed isolated change; DO NOT deploy before authenticated role tests.
-- Preserves subscription, payroll write access, selected-business isolation and super-admin handling.
-- Uses the existing Accountant Centre role vocabulary, not a new permission model.
create or replace function public.frindly_leave_manager_can_approve(p_business uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null
   and p_business=public.current_business_id()
   and public.v55_payroll_access(p_business)
   and public.v6147_can_write_area(p_business,'payroll')
   and (
     public.is_super_admin()
     or exists (
       select 1 from public.business_memberships m
       where m.user_id=auth.uid()
         and m.business_id=p_business
         and m.status='active'
         and m.role in ('owner','admin','accountant','bookkeeper')
     )
   )
$$;
revoke all on function public.frindly_leave_manager_can_approve(uuid) from public,anon;
grant execute on function public.frindly_leave_manager_can_approve(uuid) to authenticated;
