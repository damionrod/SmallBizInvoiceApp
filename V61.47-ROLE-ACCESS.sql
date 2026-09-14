-- Finlo V61.47 - Role-Aware Access Control
-- Additive RBAC enforcement using restrictive RLS policies.
-- Existing permissive tenant policies remain in place; these restrictions are ANDed with them.

create or replace function public.v6147_current_business_role(p_business_id uuid default public.current_business_id())
returns text
language sql
stable
security definer
set search_path=public
as $$
  select case
    when auth.uid() is null then null
    when public.is_super_admin() then 'owner'
    else (
      select bm.role
      from public.business_memberships bm
      where bm.user_id=auth.uid()
        and bm.business_id=p_business_id
        and bm.status='active'
      limit 1
    )
  end
$$;

create or replace function public.v6147_can_read_area(p_business_id uuid, p_area text)
returns boolean
language plpgsql
stable
security definer
set search_path=public
as $$
declare r text;
begin
  if auth.uid() is null then return false; end if;
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;
  r := public.v6147_current_business_role(p_business_id);
  if r is null then return false; end if;
  if r in ('owner','admin') then return true; end if;
  if p_area='core' then return r in ('accountant','bookkeeper','staff','viewer'); end if;
  if p_area in ('expenses','bank') then return r in ('accountant','bookkeeper'); end if;
  if p_area='financials' then return r in ('accountant','bookkeeper'); end if;
  if p_area='payroll' then return false; end if;
  if p_area='business_settings' then return false; end if;
  if p_area='team' then return false; end if;
  if p_area='billing' then return false; end if;
  return false;
end;
$$;

create or replace function public.v6147_can_write_area(p_business_id uuid, p_area text)
returns boolean
language plpgsql
stable
security definer
set search_path=public
as $$
declare r text;
begin
  if auth.uid() is null then return false; end if;
  if public.is_super_admin() then return true; end if;
  if p_business_id is null or p_business_id <> public.current_business_id() then return false; end if;
  r := public.v6147_current_business_role(p_business_id);
  if r='owner' then return true; end if;
  if r='admin' then return p_area <> 'billing'; end if;
  if p_area='core' then return r in ('accountant','bookkeeper','staff'); end if;
  if p_area in ('expenses','bank') then return r in ('accountant','bookkeeper'); end if;
  if p_area='financials' then return r='accountant'; end if;
  return false;
end;
$$;

-- Payroll remains module-enabled, but only Owner/Admin may enter the payroll data boundary.
create or replace function public.v55_payroll_access(p_business_id uuid)
returns boolean
language sql
stable security definer
set search_path=public
as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else public.v6147_can_read_area(p_business_id,'payroll')
      and exists(select 1 from public.modules m where m.slug='payroll' and m.is_active=true)
      and (
        exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
               where bm.business_id=p_business_id and m.slug='payroll' and bm.status in ('active','trialing'))
        or (
          not exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
                     where bm.business_id=p_business_id and m.slug='payroll')
          and exists(select 1 from public.subscriptions s join public.plans pl on pl.id=s.plan_id
                     where s.business_id=p_business_id and coalesce(s.status,'') not in ('suspended','canceled')
                       and 'payroll'=any(coalesce(pl.included_modules,'{}'::text[])))
        )
      )
  end
$$;

-- Financials supports Accountant read/write and Bookkeeper read-only via command-specific RLS below.
create or replace function public.v58_financials_access(p_business_id uuid)
returns boolean
language sql
stable security definer
set search_path=public
as $$
  select case
    when auth.uid() is null then false
    when public.is_super_admin() then true
    else public.v6147_can_read_area(p_business_id,'financials')
      and exists(select 1 from public.modules m where m.slug='financials' and m.is_active=true)
      and (
        exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
               where bm.business_id=p_business_id and m.slug='financials' and bm.status in ('active','trialing'))
        or (
          not exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
                     where bm.business_id=p_business_id and m.slug='financials')
          and exists(select 1 from public.subscriptions s join public.plans pl on pl.id=s.plan_id
                     where s.business_id=p_business_id and coalesce(s.status,'') not in ('suspended','canceled')
                       and 'financials'=any(coalesce(pl.included_modules,'{}'::text[])))
        )
      )
  end
$$;

-- Utility to add restrictive policies without replacing the application's existing tenant policies.
create or replace function public.v6147_add_restrictive_policies(p_table text, p_area text)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  execute format('drop policy if exists v6147_%I_select on public.%I',p_table,p_table);
  execute format('drop policy if exists v6147_%I_insert on public.%I',p_table,p_table);
  execute format('drop policy if exists v6147_%I_update on public.%I',p_table,p_table);
  execute format('drop policy if exists v6147_%I_delete on public.%I',p_table,p_table);
  execute format('create policy v6147_%I_select on public.%I as restrictive for select to authenticated using (public.v6147_can_read_area(business_id,%L))',p_table,p_table,p_area);
  execute format('create policy v6147_%I_insert on public.%I as restrictive for insert to authenticated with check (public.v6147_can_write_area(business_id,%L))',p_table,p_table,p_area);
  execute format('create policy v6147_%I_update on public.%I as restrictive for update to authenticated using (public.v6147_can_write_area(business_id,%L)) with check (public.v6147_can_write_area(business_id,%L))',p_table,p_table,p_area,p_area);
  execute format('create policy v6147_%I_delete on public.%I as restrictive for delete to authenticated using (public.v6147_can_write_area(business_id,%L))',p_table,p_table,p_area);
end;
$$;

-- Core operational data.
do $$
declare t text;
begin
  foreach t in array array['customers','invoices','quotes','job_costings','recurring_rules','customer_payments'] loop
    perform public.v6147_add_restrictive_policies(t,'core');
  end loop;
end $$;

-- Expense / supplier data.
do $$
declare t text;
begin
  foreach t in array array['expenses','expense_lines','expense_attachments','expense_categories','expense_payments','expense_reconciliations','recurring_expense_rules','suppliers','supplier_credits','batch_payments','batch_payment_items'] loop
    perform public.v6147_add_restrictive_policies(t,'expenses');
  end loop;
end $$;

-- Bank reconciliation data.
do $$
declare t text;
begin
  foreach t in array array['bank_accounts','bank_import_batches','bank_transactions','bank_rules','bank_reconciliation_allocations','bank_reconciliation_audit','bank_reconciliation_settings'] loop
    perform public.v6147_add_restrictive_policies(t,'bank');
  end loop;
end $$;

-- Financials data. Bookkeeper may read but only Accountant/Owner/Admin may write.
do $$
declare t text;
begin
  foreach t in array array['financial_budgets','financial_budget_lines','financial_budget_month_values','financial_category_mappings','financial_settings','gst_returns'] loop
    perform public.v6147_add_restrictive_policies(t,'financials');
  end loop;
end $$;

-- Payroll table that does not already use v55_payroll_access.
drop policy if exists v6147_payroll_timesheet_expenses_select on public.payroll_timesheet_expenses;
drop policy if exists v6147_payroll_timesheet_expenses_insert on public.payroll_timesheet_expenses;
drop policy if exists v6147_payroll_timesheet_expenses_update on public.payroll_timesheet_expenses;
drop policy if exists v6147_payroll_timesheet_expenses_delete on public.payroll_timesheet_expenses;
create policy v6147_payroll_timesheet_expenses_select on public.payroll_timesheet_expenses as restrictive for select to authenticated using (public.v6147_can_read_area(business_id,'payroll'));
create policy v6147_payroll_timesheet_expenses_insert on public.payroll_timesheet_expenses as restrictive for insert to authenticated with check (public.v6147_can_write_area(business_id,'payroll'));
create policy v6147_payroll_timesheet_expenses_update on public.payroll_timesheet_expenses as restrictive for update to authenticated using (public.v6147_can_write_area(business_id,'payroll')) with check (public.v6147_can_write_area(business_id,'payroll'));
create policy v6147_payroll_timesheet_expenses_delete on public.payroll_timesheet_expenses as restrictive for delete to authenticated using (public.v6147_can_write_area(business_id,'payroll'));

-- Business details/settings may only be changed by Owner/Admin (Super Admin remains allowed).
drop policy if exists v6147_businesses_update on public.businesses;
create policy v6147_businesses_update on public.businesses as restrictive for update to authenticated
using (public.v6147_can_write_area(id,'business_settings'))
with check (public.v6147_can_write_area(id,'business_settings'));

-- Keep helper internal to schema maintenance.
revoke all on function public.v6147_add_restrictive_policies(text,text) from public,anon,authenticated;
revoke all on function public.v6147_current_business_role(uuid) from public,anon;
revoke all on function public.v6147_can_read_area(uuid,text) from public,anon;
revoke all on function public.v6147_can_write_area(uuid,text) from public,anon;
grant execute on function public.v6147_current_business_role(uuid) to authenticated;
grant execute on function public.v6147_can_read_area(uuid,text) to authenticated;
grant execute on function public.v6147_can_write_area(uuid,text) to authenticated;

notify pgrst,'reload schema';
