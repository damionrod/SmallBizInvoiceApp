-- v61.92C keep accounting posting robust when older source records contain stale optional links.
-- The monetary posting stays unchanged; invalid customer/supplier/job references are omitted
-- from journal line metadata so business/account/journal foreign keys remain protected.

begin;

create or replace function public.v6192_create_posted_journal(
  p_business_id uuid,
  p_journal_date date,
  p_journal_type text,
  p_source_type text,
  p_source_id uuid,
  p_source_reference text,
  p_description text,
  p_lines jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journal_id uuid;
  v_debits numeric := 0;
  v_credits numeric := 0;
  v_line_count integer := 0;
  v_journal_number text;
begin
  if p_business_id is null or p_journal_date is null then
    raise exception 'Business and journal date are required';
  end if;

  select count(*), round(coalesce(sum((x.debit)::numeric),0),2), round(coalesce(sum((x.credit)::numeric),0),2)
    into v_line_count, v_debits, v_credits
  from jsonb_to_recordset(coalesce(p_lines,'[]'::jsonb)) as x(
    account_id uuid,
    debit numeric,
    credit numeric
  )
  where round(coalesce(x.debit,0),2) > 0 or round(coalesce(x.credit,0),2) > 0;

  if v_line_count < 2 or v_debits <= 0 or v_debits <> v_credits then
    raise exception 'Posted journal must have at least two balanced lines';
  end if;

  v_journal_number :=
    'AUTO-' || to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS') || '-' ||
    upper(left(regexp_replace(coalesce(p_source_type,p_journal_type),'[^a-zA-Z0-9]+','','g'),4)) || '-' ||
    left(replace(coalesce(p_source_id, gen_random_uuid())::text,'-',''),8);

  insert into public.accounting_journals(
    business_id, journal_number, journal_date, period_date, source_type, source_id,
    source_reference, posting_version, migration_origin, description, journal_type,
    status, created_by
  ) values (
    p_business_id, v_journal_number, p_journal_date, p_journal_date, p_source_type, p_source_id,
    p_source_reference, 1, 'v6192_posting_engine', p_description, p_journal_type,
    'draft', auth.uid()
  )
  returning id into v_journal_id;

  insert into public.accounting_journal_lines(
    business_id, journal_id, account_id, description, debit, credit, tax_code,
    tax_rate, tax_amount, customer_id, supplier_id, job_costing_id, source_line_id
  )
  select
    p_business_id,
    v_journal_id,
    x.account_id,
    nullif(x.description,''),
    round(coalesce(x.debit,0),2),
    round(coalesce(x.credit,0),2),
    nullif(x.tax_code,''),
    x.tax_rate,
    round(coalesce(x.tax_amount,0),2),
    case
      when x.customer_id is not null and exists (
        select 1 from public.customers c
        where c.business_id = p_business_id and c.id = x.customer_id
      ) then x.customer_id
      else null
    end,
    case
      when x.supplier_id is not null and exists (
        select 1 from public.suppliers s
        where s.business_id = p_business_id and s.id = x.supplier_id
      ) then x.supplier_id
      else null
    end,
    case
      when x.job_costing_id is not null and exists (
        select 1 from public.job_costings j
        where j.business_id = p_business_id and j.id = x.job_costing_id
      ) then x.job_costing_id
      else null
    end,
    x.source_line_id
  from jsonb_to_recordset(p_lines) as x(
    account_id uuid,
    description text,
    debit numeric,
    credit numeric,
    tax_code text,
    tax_rate numeric,
    tax_amount numeric,
    customer_id uuid,
    supplier_id uuid,
    job_costing_id uuid,
    source_line_id uuid
  )
  where round(coalesce(x.debit,0),2) > 0 or round(coalesce(x.credit,0),2) > 0;

  update public.accounting_journals
  set status = 'posted',
      posted_at = now(),
      posted_by = auth.uid()
  where id = v_journal_id
    and business_id = p_business_id;

  return v_journal_id;
end
$$;

revoke all on function public.v6192_create_posted_journal(uuid,date,text,text,uuid,text,text,jsonb) from public, anon, authenticated;

commit;
