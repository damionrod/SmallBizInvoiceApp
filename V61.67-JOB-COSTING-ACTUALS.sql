-- V61.67 - Job Costing actuals / profitability upgrade
-- Additive only. Keeps job_costings as the canonical job record.

alter table public.job_costings add column if not exists status text not null default 'draft';
alter table public.job_costings add column if not exists estimate_status text not null default 'not_estimated';
alter table public.job_costings add column if not exists estimate_frozen_at timestamptz;
alter table public.job_costings add column if not exists original_estimate_snapshot jsonb;
alter table public.job_costings add column if not exists current_estimate_snapshot jsonb;
alter table public.job_costings add column if not exists started_at timestamptz;
alter table public.job_costings add column if not exists completed_at timestamptz;

alter table public.invoices add column if not exists job_costing_id uuid;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='invoices_job_costing_id_fkey') then
    alter table public.invoices add constraint invoices_job_costing_id_fkey foreign key (job_costing_id) references public.job_costings(id) on delete set null;
  end if;
end $$;

create index if not exists job_costings_business_status_idx on public.job_costings(business_id,status);
create index if not exists invoices_business_job_costing_idx on public.invoices(business_id,job_costing_id);

create table if not exists public.job_actual_costs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  job_costing_id uuid not null references public.job_costings(id) on delete cascade,
  cost_date date not null default current_date,
  cost_type text not null default 'other',
  description text not null,
  quantity numeric(12,3) not null default 1,
  unit text not null default 'Item',
  unit_cost numeric(12,4) not null default 0,
  amount_ex_gst numeric(12,2) not null default 0,
  notes text,
  source_type text not null default 'manual',
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_actual_costs_source_check check (source_type in ('manual')),
  constraint job_actual_costs_amount_check check (quantity >= 0 and unit_cost >= 0 and amount_ex_gst >= 0)
);
create index if not exists job_actual_costs_business_job_idx on public.job_actual_costs(business_id,job_costing_id);
create index if not exists job_actual_costs_job_date_idx on public.job_actual_costs(job_costing_id,cost_date);

create table if not exists public.job_activity (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.current_business_id() references public.businesses(id) on delete cascade,
  job_costing_id uuid not null references public.job_costings(id) on delete cascade,
  activity_type text not null,
  description text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists job_activity_business_job_idx on public.job_activity(business_id,job_costing_id,created_at desc);

alter table public.job_actual_costs enable row level security;
alter table public.job_activity enable row level security;

drop policy if exists v6167_job_actual_costs_tenant on public.job_actual_costs;
create policy v6167_job_actual_costs_tenant on public.job_actual_costs for all to authenticated
using (public.is_super_admin() or business_id=public.current_business_id())
with check (public.is_super_admin() or business_id=public.current_business_id());

drop policy if exists v6167_job_activity_tenant on public.job_activity;
create policy v6167_job_activity_tenant on public.job_activity for all to authenticated
using (public.is_super_admin() or business_id=public.current_business_id())
with check (public.is_super_admin() or business_id=public.current_business_id());

create or replace function public.v6167_validate_job_business()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  job_business uuid;
begin
  if new.job_costing_id is null then return new; end if;
  select business_id into job_business from public.job_costings where id=new.job_costing_id;
  if job_business is null then raise exception 'Job not found'; end if;
  if new.business_id is null then new.business_id:=job_business; end if;
  if new.business_id is distinct from job_business then raise exception 'Job belongs to a different business'; end if;
  return new;
end $$;

drop trigger if exists v6167_job_actual_costs_business_guard on public.job_actual_costs;
create trigger v6167_job_actual_costs_business_guard before insert or update of business_id,job_costing_id on public.job_actual_costs
for each row execute function public.v6167_validate_job_business();

drop trigger if exists v6167_job_activity_business_guard on public.job_activity;
create trigger v6167_job_activity_business_guard before insert or update of business_id,job_costing_id on public.job_activity
for each row execute function public.v6167_validate_job_business();

create or replace function public.v6167_invoice_job_guard()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  quote_job uuid;
  job_business uuid;
begin
  if new.job_costing_id is null and new.source_quote_id is not null then
    select job_costing_id into quote_job from public.quotes where id=new.source_quote_id;
    new.job_costing_id:=quote_job;
  end if;
  if new.job_costing_id is not null then
    select business_id into job_business from public.job_costings where id=new.job_costing_id;
    if job_business is null then raise exception 'Job not found'; end if;
    if new.business_id is null then new.business_id:=job_business; end if;
    if new.business_id is distinct from job_business then raise exception 'Invoice job belongs to a different business'; end if;
  end if;
  return new;
end $$;

drop trigger if exists v6167_invoice_job_guard on public.invoices;
create trigger v6167_invoice_job_guard before insert or update of business_id,job_costing_id,source_quote_id on public.invoices
for each row execute function public.v6167_invoice_job_guard();

create or replace function public.v6167_sync_job_from_quote()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  snap jsonb;
begin
  if new.job_costing_id is null then return new; end if;
  select coalesce(current_estimate_snapshot,costing_snapshot,'{}'::jsonb) into snap from public.job_costings where id=new.job_costing_id;
  if tg_op='INSERT' then
    update public.job_costings
      set original_estimate_snapshot=coalesce(original_estimate_snapshot,snap),
          current_estimate_snapshot=coalesce(current_estimate_snapshot,snap),
          estimate_frozen_at=coalesce(estimate_frozen_at,now()),
          estimate_status=case when estimate_status='not_estimated' then 'frozen' else 'frozen' end,
          status=case when status in ('approved_won','in_progress','completed','cancelled') then status else 'quoted' end,
          updated_at=now()
    where id=new.job_costing_id;
  end if;
  if new.status in ('approved','won') and (tg_op='INSERT' or old.status is distinct from new.status) then
    update public.job_costings set status=case when status='completed' then status else 'approved_won' end,updated_at=now() where id=new.job_costing_id;
    if tg_op='UPDATE' and old.status is distinct from new.status then
      insert into public.job_activity(business_id,job_costing_id,activity_type,description,metadata,created_by)
      values(new.business_id,new.job_costing_id,'quote_approved','Quote '||new.quote_number||' approved / won',jsonb_build_object('quote_id',new.id),auth.uid());
    end if;
  end if;
  return new;
end $$;

drop trigger if exists v6167_sync_job_from_quote on public.quotes;
create trigger v6167_sync_job_from_quote after insert or update of status on public.quotes
for each row execute function public.v6167_sync_job_from_quote();


-- Lightweight activity hooks for existing source modules. They log links/status changes only;
-- source transactions remain authoritative and are never copied into job_actual_costs.
create or replace function public.v6167_record_source_activity()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  jid uuid;
  label text;
  typ text;
begin
  jid:=new.job_costing_id;
  if jid is null then return new; end if;
  if tg_op='UPDATE' and old.job_costing_id is not distinct from new.job_costing_id then
    if tg_table_name='payroll_timesheets' and old.status is distinct from new.status and new.status='approved' then
      null;
    else
      return new;
    end if;
  end if;
  if tg_table_name='expenses' then typ:='expense_assigned'; label:='Expense '||coalesce(new.expense_number,'')||' assigned to job';
  elsif tg_table_name='expense_lines' then typ:='expense_assigned'; label:='Split expense line assigned to job';
  elsif tg_table_name='payroll_timesheets' then typ:='timesheet_assigned'; label:=case when new.status='approved' then 'Approved timesheet assigned to job' else 'Timesheet assigned to job' end;
  elsif tg_table_name='invoices' then typ:='invoice_created'; label:='Invoice '||coalesce(new.invoice_number,'')||' linked to job';
  else return new;
  end if;
  insert into public.job_activity(business_id,job_costing_id,activity_type,description,metadata,created_by)
  values(new.business_id,jid,typ,label,jsonb_build_object('source_table',tg_table_name,'source_id',new.id),auth.uid());
  return new;
end $$;

drop trigger if exists v6167_expense_job_activity on public.expenses;
create trigger v6167_expense_job_activity after insert or update of job_costing_id on public.expenses
for each row execute function public.v6167_record_source_activity();

drop trigger if exists v6167_expense_line_job_activity on public.expense_lines;
create trigger v6167_expense_line_job_activity after insert or update of job_costing_id on public.expense_lines
for each row execute function public.v6167_record_source_activity();

drop trigger if exists v6167_timesheet_job_activity on public.payroll_timesheets;
create trigger v6167_timesheet_job_activity after insert or update of job_costing_id,status on public.payroll_timesheets
for each row execute function public.v6167_record_source_activity();

drop trigger if exists v6167_invoice_job_activity on public.invoices;
create trigger v6167_invoice_job_activity after insert or update of job_costing_id on public.invoices
for each row execute function public.v6167_record_source_activity();

-- Backfill invoice job links only when the existing quote relationship is unambiguous.
update public.invoices i
set job_costing_id=q.job_costing_id
from public.quotes q
where i.job_costing_id is null
  and i.source_quote_id=q.id
  and q.job_costing_id is not null
  and (i.business_id is null or i.business_id=q.business_id);

-- Preserve current estimate data for existing records without overwriting costing_snapshot.
update public.job_costings
set current_estimate_snapshot=coalesce(current_estimate_snapshot,costing_snapshot),
    estimate_status=case
      when coalesce(total_cost_ex_gst,0)>0 or coalesce(proposed_quote_price_ex_gst,0)>0 or coalesce(costing_snapshot,'{}'::jsonb) <> '{}'::jsonb then 'estimated'
      else 'not_estimated'
    end
where current_estimate_snapshot is null;

-- Safe initial lifecycle inference. Never infer completion.
update public.job_costings j
set status=case
  when exists(select 1 from public.quotes q where q.job_costing_id=j.id and q.status in ('approved','won'))
       or exists(select 1 from public.invoices i where i.job_costing_id=j.id) then 'approved_won'
  when exists(select 1 from public.quotes q where q.job_costing_id=j.id) then 'quoted'
  when j.estimate_status in ('estimated','frozen') then 'estimated'
  else 'draft'
end
where j.status='draft';

-- Freeze the original estimate for existing quoted jobs if it was not already captured.
update public.job_costings j
set original_estimate_snapshot=coalesce(j.original_estimate_snapshot,j.current_estimate_snapshot,j.costing_snapshot),
    estimate_frozen_at=coalesce(j.estimate_frozen_at,(select min(q.created_at) from public.quotes q where q.job_costing_id=j.id)),
    estimate_status='frozen'
where exists(select 1 from public.quotes q where q.job_costing_id=j.id)
  and j.original_estimate_snapshot is null;
