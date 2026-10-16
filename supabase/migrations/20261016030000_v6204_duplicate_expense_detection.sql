-- Frindly v62.04
-- Broaden duplicate-expense detection without blocking legitimate recurring bills.
-- Read-only candidate scoring: no existing financial records are changed.

begin;

create or replace function public.v6204_expense_duplicate_candidates(
  p_supplier_id uuid,
  p_supplier_name text,
  p_reference text,
  p_invoice_date date,
  p_total numeric,
  p_content_sha256 text default null,
  p_exclude_expense_id uuid default null
) returns table(
  expense_id uuid,
  expense_number text,
  supplier_name text,
  supplier_reference text,
  invoice_date date,
  total_amount numeric,
  lifecycle_state text,
  score integer,
  reasons jsonb
)
language sql
stable
security invoker
set search_path=''
as $$
  with input as (
    select public.current_business_id() bid,
      regexp_replace(lower(trim(coalesce(p_supplier_name,''))),'[^a-z0-9]+','','g') supplier_key,
      regexp_replace(lower(trim(coalesce(p_reference,''))),'[^a-z0-9]+','','g') reference_key,
      round(coalesce(p_total,0),2) total_value
  ), candidates as (
    select e.*,
      regexp_replace(lower(trim(coalesce(e.supplier_name,''))),'[^a-z0-9]+','','g') existing_supplier_key,
      regexp_replace(lower(trim(coalesce(e.supplier_reference,''))),'[^a-z0-9]+','','g') existing_reference_key,
      exists(
        select 1 from public.expense_attachments a
        where a.expense_id=e.id and a.business_id=e.business_id
          and a.archived_at is null and p_content_sha256 is not null
          and a.content_sha256=p_content_sha256
      ) hash_match
    from public.expenses e,input i
    where e.business_id=i.bid
      and not coalesce(e.archived,false)
      and coalesce(e.lifecycle_state,'recorded')<>'voided'
      and (p_exclude_expense_id is null or e.id<>p_exclude_expense_id)
      and abs(round(e.total_amount,2)-i.total_value)<=0.01
      and (
        abs(e.invoice_date-p_invoice_date)<=365
        or exists(
          select 1 from public.expense_attachments a
          where a.expense_id=e.id and a.business_id=e.business_id
            and a.archived_at is null and p_content_sha256 is not null
            and a.content_sha256=p_content_sha256
        )
      )
  ), assessed as (
    select c.*,i.supplier_key,i.reference_key,
      (i.supplier_key<>'' and c.existing_supplier_key=i.supplier_key) exact_supplier_name,
      (i.supplier_key<>'' and c.existing_supplier_key<>''
        and least(length(i.supplier_key),length(c.existing_supplier_key))>=5
        and (c.existing_supplier_key like '%'||i.supplier_key||'%'
          or i.supplier_key like '%'||c.existing_supplier_key||'%')) related_supplier_name,
      (i.reference_key<>'' and c.existing_reference_key=i.reference_key) exact_reference
    from candidates c cross join input i
  ), scored as (
    select a.*,
      least(100,
        40
        + case when p_supplier_id is not null and a.supplier_id=p_supplier_id then 30 else 0 end
        + case when a.exact_supplier_name then 25 when a.related_supplier_name then 20 else 0 end
        + case when a.exact_reference then 35 else 0 end
        + case when a.invoice_date=p_invoice_date then 15
               when abs(a.invoice_date-p_invoice_date)<=7 then 10
               when abs(a.invoice_date-p_invoice_date)<=31 then 5 else 0 end
        + case when a.hash_match then 60 else 0 end
      )::integer calculated_score,
      jsonb_strip_nulls(jsonb_build_object(
        'same_amount',true,
        'same_supplier_id',case when p_supplier_id is not null and a.supplier_id=p_supplier_id then true end,
        'same_supplier_name',case when a.exact_supplier_name then true end,
        'related_supplier_name',case when not a.exact_supplier_name and a.related_supplier_name then true end,
        'same_reference',case when a.exact_reference then true end,
        'same_date',case when a.invoice_date=p_invoice_date then true end,
        'date_difference_days',abs(a.invoice_date-p_invoice_date),
        'same_attachment',case when a.hash_match then true end
      )) calculated_reasons
    from assessed a
  )
  select s.id,s.expense_number,s.supplier_name,s.supplier_reference,s.invoice_date,
         s.total_amount,s.lifecycle_state,s.calculated_score,s.calculated_reasons
  from scored s
  where s.calculated_score>=65
  order by s.calculated_score desc,s.created_at desc
  limit 10
$$;

revoke all on function public.v6204_expense_duplicate_candidates(uuid,text,text,date,numeric,text,uuid) from public;
revoke execute on function public.v6204_expense_duplicate_candidates(uuid,text,text,date,numeric,text,uuid) from anon;
grant execute on function public.v6204_expense_duplicate_candidates(uuid,text,text,date,numeric,text,uuid) to authenticated;

comment on function public.v6204_expense_duplicate_candidates(uuid,text,text,date,numeric,text,uuid)
is 'Advisory duplicate-expense scoring across one year using amount, supplier relation, reference, date and receipt hash.';

commit;
