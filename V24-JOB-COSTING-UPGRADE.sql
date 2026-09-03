-- Invoice Manager v24 — Universal Job Costing Upgrade
-- Run once AFTER V23-JOB-COSTING-MIGRATION.sql. Existing rows are preserved.

alter table public.job_costings add column if not exists job_address text;
alter table public.job_costings add column if not exists job_duration_hours numeric(12,3) not null default 0;
alter table public.job_costings add column if not exists direct_costs jsonb not null default '[]'::jsonb;
alter table public.job_costings add column if not exists total_direct numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists allocated_overhead numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists subtotal_job_cost numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists contingency_percent numeric(7,3) not null default 0;
alter table public.job_costings add column if not exists contingency_amount numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists expected_profit numeric(12,2) not null default 0;
alter table public.job_costings add column if not exists expected_margin_percent numeric(9,4) not null default 0;
alter table public.job_costings add column if not exists costing_snapshot jsonb not null default '{}'::jsonb;

alter table public.quotes add column if not exists quote_items jsonb not null default '[]'::jsonb;

-- Preserve old v23 costing lines as historical snapshots where no v24 snapshot exists yet.
update public.job_costings
set costing_snapshot = jsonb_build_object(
  'version',23,
  'labour',coalesce(labour_items,'[]'::jsonb),
  'variables',coalesce(variable_costs,'[]'::jsonb),
  'direct','[]'::jsonb,
  'fields',coalesce(custom_fields,'[]'::jsonb),
  'totals',jsonb_build_object(
    'labourCost',coalesce(total_labour,0),
    'otherVar',coalesce(total_variable,0),
    'trueCost',coalesce(total_cost_ex_gst,0),
    'margin',coalesce(margin_percent,0),
    'recommended',coalesce(recommended_price_ex_gst,0),
    'quote',coalesce(proposed_quote_price_ex_gst,0)
  )
)
where costing_snapshot='{}'::jsonb;

-- Backfill customer-facing quote items without exposing internal costing details.
update public.quotes
set quote_items=jsonb_build_array(jsonb_build_object(
  'description',description,
  'qty',1,
  'unit_price',quoted_price_ex_gst,
  'total',quoted_price_ex_gst
))
where quote_items='[]'::jsonb;
