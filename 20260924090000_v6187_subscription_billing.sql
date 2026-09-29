-- V61.87: subscription cancellation and retained access to existing records.
-- No subscription is canceled or changed by this migration.
begin;

alter table public.subscriptions add column if not exists cancel_at timestamptz;

create or replace function public.v6187_subscription_read_only(p_business_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.subscriptions s where s.business_id=p_business_id and (
      s.status='canceled'
      or s.cancel_at<=now()
      or (s.cancel_at_period_end and s.current_period_end<=now())
      or (s.status='trialing' and s.trial_ends_at<=now())
    )
  ) and (p_business_id=public.current_business_id() or auth.role()='service_role' or public.is_super_admin());
$$;
revoke all on function public.v6187_subscription_read_only(uuid) from public,anon;
grant execute on function public.v6187_subscription_read_only(uuid) to authenticated,service_role;

-- Keep the existing role defaults and overrides; add only the expiry check for
-- operational writes. Billing/team access remain available to restore a plan.
create or replace function public.v6147_can_write_area(p_business_id uuid,p_area text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare r text;m_id uuid;o_write boolean;
begin
  if auth.uid() is null then return false;end if;
  if public.is_super_admin() then return true;end if;
  if p_business_id is null or p_business_id<>public.current_business_id() then return false;end if;
  select bm.id,bm.role into m_id,r from public.business_memberships bm
    where bm.user_id=auth.uid() and bm.business_id=p_business_id and bm.status='active' limit 1;
  if m_id is null then return false;end if;
  if p_area='billing' then return r='owner';end if;
  if p_area in ('team','business_settings') then return r in ('owner','admin');end if;
  if public.v6187_subscription_read_only(p_business_id) then return false;end if;
  select o.can_write into o_write from public.business_member_access_overrides o
    where o.membership_id=m_id and o.business_id=p_business_id and o.area=p_area;
  if found then return o_write;end if;
  return public.v6149_effective_role_default_write(p_business_id,r,p_area);
end;
$$;

-- A trigger also covers legacy permissive policies and SECURITY DEFINER write
-- RPCs. Verified service webhooks can still settle existing invoice payments.
create or replace function public.v6187_guard_subscription_write()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_super_admin() then
    if tg_op<>'INSERT' and public.v6187_subscription_read_only(old.business_id) then
      raise exception 'This subscription has ended. Existing records are read-only. Open Settings -> Subscription & Billing.' using errcode='42501';
    end if;
    if tg_op<>'DELETE' and public.v6187_subscription_read_only(new.business_id) then
      raise exception 'This subscription has ended. Existing records are read-only. Open Settings -> Subscription & Billing.' using errcode='42501';
    end if;
  end if;
  if tg_op='DELETE' then return old;end if;
  return new;
end;
$$;
revoke all on function public.v6187_guard_subscription_write() from public,anon,authenticated;

do $$
declare t text;
begin
  foreach t in array array[
    'customers','invoices','quotes','job_costings','recurring_rules','customer_payments',
    'credit_notes','customer_refunds','suppliers','expenses','expense_lines','expense_payments',
    'expense_attachments','expense_categories','expense_reconciliations','supplier_credits','supplier_refunds',
    'recurring_expense_rules','batch_payments','batch_payment_items','bank_accounts','bank_import_batches',
    'bank_reconciliation_allocations','bank_reconciliation_settings','bank_rules','bank_transactions',
    'financial_budgets','financial_budget_lines','financial_budget_month_values','financial_category_mappings',
    'financial_settings','gst_returns','job_schedules','job_recurrence_series','job_schedule_assignments',
    'payroll_employees','payroll_employee_documents','payroll_employee_leave','payroll_financial_transactions',
    'payroll_leave_transactions','payroll_pay_items','payroll_pay_run_employees','payroll_pay_run_lines',
    'payroll_pay_runs','payroll_payslips','payroll_settings','payroll_timesheet_expenses','payroll_timesheets',
    'accounting_accounts','accounting_journals','accounting_journal_lines','accounting_periods'
  ] loop
    if exists(select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name='business_id') then
      execute format('drop trigger if exists v6187_subscription_write on public.%I',t);
      execute format('create trigger v6187_subscription_write before insert or update or delete on public.%I for each row execute function public.v6187_guard_subscription_write()',t);
    end if;
  end loop;
end;
$$;

-- Schedule has a separate entitlement check. A former plan keeps access to its
-- historical schedule; cancellation never grants an unpurchased module.
create or replace function public.v6179_schedule_role_allowed(p_business_id uuid,p_write boolean default false)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_current uuid;v_role text;v_archive boolean:=false;
begin
  if auth.uid() is null then return false;end if;
  v_current:=public.current_business_id();
  if v_current is null or v_current<>p_business_id then return false;end if;
  if public.v6187_subscription_read_only(p_business_id) then
    if p_write then return false;end if;
    select exists(select 1 from public.subscriptions s join public.plans p on p.id=s.plan_id
      where s.business_id=p_business_id and 'schedule'=any(p.included_modules))
      and exists(select 1 from public.modules where slug='schedule' and is_active)
      and not exists(select 1 from public.business_modules bm join public.modules m on m.id=bm.module_id
        where bm.business_id=p_business_id and m.slug='schedule' and
          (bm.status in ('suspended','canceled') or (bm.status='trialing' and bm.trial_ends_at<now())))
    into v_archive;
  end if;
  if not v_archive and not public.v6179_schedule_entitled(p_business_id) then return false;end if;
  v_role:=public.v6147_current_business_role(p_business_id);
  return v_role in ('owner','admin');
end;
$$;

commit;
