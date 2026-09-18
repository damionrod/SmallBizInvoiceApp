create or replace function public.v6173p6b_validate_refs()
returns trigger language plpgsql security invoker set search_path=public as $$
begin
  if not exists (select 1 from public.payroll_employees e where e.id=new.employee_id and e.business_id=new.business_id) then
    raise exception 'Employee does not belong to this business';
  end if;
  if tg_table_name = 'payroll_final_pay_components' then
    if not exists (select 1 from public.payroll_final_pay_calculations c where c.id=new.final_pay_calculation_id and c.business_id=new.business_id and c.employee_id=new.employee_id) then
      raise exception 'Final-pay calculation does not belong to this employee/business';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.v6173p6b_validate_refs() from public, anon;
grant execute on function public.v6173p6b_validate_refs() to authenticated;