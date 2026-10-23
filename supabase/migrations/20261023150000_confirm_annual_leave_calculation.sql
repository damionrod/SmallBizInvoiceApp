-- Controlled manager confirmation of annual-holiday OWP/AWE evidence.
create or replace function public.frindly_leave_confirm_annual_calculation_v1(
  p_request_id uuid,
  p_owp_amount numeric,
  p_awe_amount numeric,
  p_selected_method text,
  p_selected_amount numeric,
  p_notes text default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); r record; c uuid;
begin
 if auth.uid() is null or b is null or not public.frindly_leave_manager_can_approve(b) then raise exception 'Payroll manager permission required' using errcode='42501'; end if;
 if p_owp_amount is null or p_owp_amount<0 or p_awe_amount is null or p_awe_amount<0 or p_selected_amount is null or p_selected_amount<0 or p_selected_method not in ('owp','awe') then raise exception 'Enter valid non-negative OWP/AWE amounts and method' using errcode='22023'; end if;
 select d.*,a.status into r from public.payroll_manager_leave_drafts d join public.payroll_manager_leave_approvals_isolated a on a.draft_id=d.id and a.business_id=d.business_id where d.id=p_request_id and d.business_id=b and a.status='approved';
 if not found then raise exception 'Approved leave request unavailable' using errcode='42501'; end if;
 insert into public.payroll_statutory_leave_calculations(business_id,employee_id,leave_type_id,statutory_leave_code,calculation_type,relevant_from,relevant_to,rule_version,input_snapshot,owp_amount,awe_amount,selected_method,selected_amount,confirmation_state,explanation_snapshot,created_by,updated_by)
 values(b,r.employee_id,r.leave_type_id,'annual_holiday','annual_holiday',r.date_from,r.date_to,'manager-confirmed-v1',jsonb_build_object('leave_request_id',p_request_id,'manager_confirmed',true,'notes',left(coalesce(p_notes,''),1000)),p_owp_amount,p_awe_amount,p_selected_method,p_selected_amount,'confirmed',jsonb_build_object('basis','Manager-confirmed OWP/AWE evidence','notes',left(coalesce(p_notes,''),1000)),auth.uid(),auth.uid())
 returning id into c;
 return jsonb_build_object('id',c,'confirmation_state','confirmed','selected_amount',p_selected_amount);
end $$;
revoke all on function public.frindly_leave_confirm_annual_calculation_v1(uuid,numeric,numeric,text,numeric,text) from public,anon;
grant execute on function public.frindly_leave_confirm_annual_calculation_v1(uuid,numeric,numeric,text,numeric,text) to authenticated;
