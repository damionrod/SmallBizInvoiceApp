-- Leave Management release candidate. ADDITIVE ONLY. Do not run on live without approval.
-- No existing payroll tables/functions are altered. No leave balance or pay run posting.
create table if not exists public.payroll_manager_leave_drafts (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id),
 employee_id uuid not null references public.payroll_employees(id),
 leave_type_id uuid not null references public.payroll_leave_types(id),
 date_from date not null, date_to date not null,
 quantity numeric not null, unit text not null,
 status text not null default 'draft' check (status='draft'),
 created_by uuid not null, created_at timestamptz not null default now(),
 constraint manager_leave_dates check (date_to>=date_from and date_to-date_from<=366 and isfinite(date_from) and isfinite(date_to)),
 constraint manager_leave_quantity check (quantity>0 and quantity<=10000 and quantity::text not in ('NaN','Infinity','-Infinity')),
 constraint manager_leave_unit check (unit in ('hours','days','weeks'))
);
create table if not exists public.payroll_manager_leave_approvals_isolated (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id),
 draft_id uuid not null unique references public.payroll_manager_leave_drafts(id),
 status text not null default 'pending' check(status in ('pending','approved','declined')),
 submitted_by uuid not null, submitted_at timestamptz not null default now(),
 decided_by uuid, decided_at timestamptz,
 constraint leave_approval_decision_consistency check ((status='pending' and decided_by is null and decided_at is null) or (status in ('approved','declined') and decided_by is not null and decided_at is not null))
);
alter table public.payroll_manager_leave_drafts enable row level security;
alter table public.payroll_manager_leave_approvals_isolated enable row level security;
revoke all on public.payroll_manager_leave_drafts,public.payroll_manager_leave_approvals_isolated from anon,authenticated;
create index if not exists manager_leave_drafts_business_created_idx on public.payroll_manager_leave_drafts(business_id,created_at desc);
create index if not exists manager_leave_approvals_business_status_idx on public.payroll_manager_leave_approvals_isolated(business_id,status);
create or replace function public.frindly_leave_manager_can_approve(p_business uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and p_business=public.current_business_id()
 and public.v55_payroll_access(p_business)
 and public.v6147_can_write_area(p_business,'payroll')
 and (public.is_super_admin() or exists(
 select 1 from public.business_memberships m
 where m.user_id=auth.uid() and m.business_id=p_business and m.status='active'
 and m.role in ('owner','admin')
 ))
$$;
revoke all on function public.frindly_leave_manager_can_approve(uuid) from public,anon;
grant execute on function public.frindly_leave_manager_can_approve(uuid) to authenticated;
create or replace function public.frindly_leave_request_create(
 p_employee uuid,p_leave_type uuid,p_from date,p_to date,p_quantity numeric,p_unit text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); d public.payroll_manager_leave_drafts;
begin
 if auth.uid() is null or b is null or not public.frindly_leave_manager_can_approve(b) then
 raise exception 'Leave manager permission required' using errcode='42501';end if;
 if p_from is null or p_to is null or not isfinite(p_from) or not isfinite(p_to)
 or p_to<p_from or p_to-p_from>366 or p_quantity is null or p_quantity<=0
 or p_quantity>10000 or p_quantity::text in ('NaN','Infinity','-Infinity')
 or round(p_quantity,2)<>p_quantity or p_unit not in ('hours','days','weeks') then
 raise exception 'Invalid leave request' using errcode='22023';end if;
 perform 1 from public.payroll_employees where id=p_employee and business_id=b
 and not archived and employment_status in ('active','on_leave') for share;
 if not found then raise exception 'Employee unavailable' using errcode='42501';end if;
 perform 1 from public.payroll_leave_types where id=p_leave_type and business_id=b and not archived for share;
 if not found then raise exception 'Leave type unavailable' using errcode='42501';end if;
 insert into public.payroll_manager_leave_drafts(business_id,employee_id,leave_type_id,date_from,date_to,quantity,unit,created_by)
 values(b,p_employee,p_leave_type,p_from,p_to,p_quantity,p_unit,auth.uid()) returning * into d;
 insert into public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by)
 values(b,'manager_leave_draft',d.id,'create',jsonb_build_object('status','draft'),auth.uid());
 return jsonb_build_object('id',d.id,'status','draft');
end $$;
create or replace function public.frindly_leave_request_action(p_draft_id uuid,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); d public.payroll_manager_leave_drafts; a public.payroll_manager_leave_approvals_isolated;
begin
 if auth.uid() is null or b is null or not public.frindly_leave_manager_can_approve(b) then
 raise exception 'Leave manager permission required' using errcode='42501';end if;
 if p_draft_id is null or p_action is null or p_action not in ('submit','approve','decline') then
 raise exception 'Invalid action' using errcode='22023';end if;
 select * into d from public.payroll_manager_leave_drafts where id=p_draft_id and business_id=b for update;
 if not found then raise exception 'Request unavailable' using errcode='42501';end if;
 if p_action='submit' then
 insert into public.payroll_manager_leave_approvals_isolated(business_id,draft_id,submitted_by)
 values(b,d.id,auth.uid()) returning * into a;
 else
 select * into a from public.payroll_manager_leave_approvals_isolated
 where draft_id=d.id and business_id=b and status='pending' for update;
 if not found then raise exception 'Pending request unavailable' using errcode='42501';end if;
 if a.submitted_by=auth.uid() then raise exception 'Cannot approve or decline your own submission' using errcode='42501';end if;
 update public.payroll_manager_leave_approvals_isolated
 set status=case when p_action='approve' then 'approved' else 'declined' end,
 decided_by=auth.uid(),decided_at=now() where id=a.id returning * into a;
 end if;
 insert into public.payroll_audit_log(business_id,entity_type,entity_id,action,after_data,created_by)
 values(b,'manager_leave_approval',a.id,p_action,jsonb_build_object('draft_id',d.id,'status',a.status),auth.uid());
 return jsonb_build_object('id',a.id,'draft_id',d.id,'status',a.status);
end $$;
create or replace function public.frindly_leave_requests_read()
returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid:=public.current_business_id(); result jsonb;
begin
 if auth.uid() is null or b is null or not public.v55_payroll_access(b)
 or not public.v6147_can_read_area(b,'payroll') then
 raise exception 'Payroll read permission required' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object(
 'id',d.id,'employee_id',d.employee_id,'employee',concat_ws(' ',e.first_name,e.last_name),
 'leave_type_id',d.leave_type_id,'leave_type',lt.name,'date_from',d.date_from,'date_to',d.date_to,
 'quantity',d.quantity,'unit',d.unit,'status',coalesce(a.status,'draft'),
 'submitted_at',a.submitted_at,'decided_at',a.decided_at) order by d.created_at desc),'[]'::jsonb)
 into result from public.payroll_manager_leave_drafts d
 join public.payroll_employees e on e.id=d.employee_id and e.business_id=b
 join public.payroll_leave_types lt on lt.id=d.leave_type_id and lt.business_id=b
 left join public.payroll_manager_leave_approvals_isolated a on a.draft_id=d.id and a.business_id=b
 where d.business_id=b;
 return result;
end $$;
revoke all on function public.frindly_leave_request_create(uuid,uuid,date,date,numeric,text),public.frindly_leave_request_action(uuid,text),public.frindly_leave_requests_read() from public,anon;
grant execute on function public.frindly_leave_request_create(uuid,uuid,date,date,numeric,text),public.frindly_leave_request_action(uuid,text),public.frindly_leave_requests_read() to authenticated;
