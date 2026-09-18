-- V61.70F-P2 — Australian Expense GST Classification & BAS 1B Fix
-- Forward-only. Does not backfill or rewrite existing expenses.

alter table public.expenses add column if not exists au_tax_snapshot jsonb;
alter table public.expense_lines add column if not exists au_tax_snapshot jsonb;

create or replace function public.v6170f_expense_tax_config(p_on date default current_date)
returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  return public.v6170f_invoice_tax_config(coalesce(p_on,current_date));
end$$;
revoke all on function public.v6170f_expense_tax_config(date) from public,anon;
grant execute on function public.v6170f_expense_tax_config(date) to authenticated;

create or replace function public.v6170f_guard_au_expense_tax()
returns trigger
language plpgsql security definer set search_path=public as $$
declare
  c text; h public.gst_settings_history; registered boolean:=false; rate numeric;
  expected_gst numeric; expected_ex numeric; expected_business_gst numeric; pct numeric;
  authoritative boolean;
begin
  select upper(coalesce(b.settings->>'country','NZ')) into c from public.businesses b where b.id=new.business_id;
  if c is distinct from 'AU' then return new; end if;

  -- Preserve already-recorded AU history: tax classification/snapshot cannot be retrofitted through normal updates.
  if tg_op='UPDATE' and old.lifecycle_state in ('recorded','voided') and
     (new.au_tax_classification is distinct from old.au_tax_classification or new.au_tax_snapshot is distinct from old.au_tax_snapshot) then
    raise exception 'Recorded Australian expense tax treatment is immutable. Use a controlled correction rather than rewriting history.' using errcode='23514';
  end if;

  authoritative:=coalesce(new.lifecycle_state,'')='recorded' or coalesce(new.payment_status,'')<>'draft';
  if not authoritative then return new; end if;

  if new.au_tax_classification is null or new.au_tax_classification not in('gst_taxable','gst_free','input_taxed','out_of_scope') then
    raise exception 'Choose an Australian GST treatment before recording this expense.' using errcode='23514';
  end if;
  select * into h from public.gst_settings_history
   where business_id=new.business_id and jurisdiction='AU' and effective_from<=new.invoice_date
   order by effective_from desc limit 1;
  if not found then raise exception 'Australian GST settings are unavailable for expense date %',new.invoice_date using errcode='23514'; end if;
  registered:=coalesce(h.gst_registered,false);
  select r.numeric_value into rate from public.country_business_tax_rules r
   where r.country_code='AU' and r.rule_type='gst' and r.rule_key='standard_rate_percent' and r.active=true
     and r.effective_from<=new.invoice_date and (r.effective_to is null or r.effective_to>=new.invoice_date)
   order by r.effective_from desc limit 1;
  if rate is null or rate<=0 then raise exception 'Authoritative Australian GST rate is unavailable for expense date %',new.invoice_date using errcode='23514'; end if;

  if new.au_tax_classification='gst_taxable' then
    if not registered then raise exception 'GST taxable cannot be used because the business is not GST registered for the expense date.' using errcode='23514'; end if;
    expected_gst:=round(coalesce(new.total_amount,0)*rate/(100+rate),2);
    expected_ex:=round(coalesce(new.total_amount,0)-expected_gst,2);
  else
    expected_gst:=0; expected_ex:=round(coalesce(new.total_amount,0),2);
  end if;
  if abs(round(coalesce(new.gst_amount,0),2)-expected_gst)>0.005 or abs(round(coalesce(new.ex_gst,0),2)-expected_ex)>0.005 then
    raise exception 'Expense tax amounts do not match the authoritative Australian GST treatment. Expected ex GST % and GST %, received % and %.',expected_ex,expected_gst,round(coalesce(new.ex_gst,0),2),round(coalesce(new.gst_amount,0),2) using errcode='23514';
  end if;
  if abs(round(coalesce(new.ex_gst,0)+coalesce(new.gst_amount,0),2)-round(coalesce(new.total_amount,0),2))>0.005 then
    raise exception 'Expense ex-GST plus GST does not equal total.' using errcode='23514';
  end if;
  pct:=greatest(0,least(100,coalesce(new.business_use_percent,100)));
  if new.business_use_percent is null or new.business_use_percent<0 or new.business_use_percent>100 then
    raise exception 'Business use must be between 0 and 100 percent.' using errcode='23514';
  end if;
  expected_business_gst:=round(expected_gst*pct/100,2);
  if abs(round(coalesce(new.business_gst_amount,0),2)-expected_business_gst)>0.005 then
    raise exception 'Business GST does not match the business-use allocation. Expected %, received %.',expected_business_gst,round(coalesce(new.business_gst_amount,0),2) using errcode='23514';
  end if;
  new.au_tax_snapshot:=jsonb_build_object('jurisdiction','AU','gstRegistered',registered,'gstRate',rate,'classification',new.au_tax_classification,'effectiveFrom',h.effective_from,'businessUsePercent',pct,'source','v6170f_guard_au_expense_tax');
  return new;
end$$;

drop trigger if exists v6170f_p2_au_expense_tax_guard on public.expenses;
create trigger v6170f_p2_au_expense_tax_guard
before insert or update of invoice_date,payment_status,lifecycle_state,gst_treatment,gst_rate,ex_gst,gst_amount,total_amount,business_use_percent,business_gst_amount,au_tax_classification,au_tax_snapshot
on public.expenses for each row execute function public.v6170f_guard_au_expense_tax();

-- Split-line tax metadata is sealed from the parent controlled AU classification and rate.
create or replace function public.v6170f_guard_au_expense_line_tax()
returns trigger
language plpgsql security definer set search_path=public as $$
declare e public.expenses; cls text; rate numeric; expected_gst numeric; expected_ex numeric;
begin
  select * into e from public.expenses where id=new.expense_id;
  if not found then return new; end if;
  if upper(coalesce((select settings->>'country' from public.businesses where id=e.business_id),'NZ'))<>'AU' then return new; end if;
  if e.lifecycle_state in ('recorded','voided') and tg_op='UPDATE' and (new.au_tax_classification is distinct from old.au_tax_classification or new.au_tax_snapshot is distinct from old.au_tax_snapshot) then
    raise exception 'Recorded Australian expense line tax treatment is immutable.' using errcode='23514';
  end if;
  cls:=case when new.gst_treatment='gst' then 'gst_taxable' else coalesce(nullif(e.au_tax_classification,'gst_taxable'),'out_of_scope') end;
  rate:=coalesce((e.au_tax_snapshot->>'gstRate')::numeric,e.gst_rate);
  if cls='gst_taxable' then expected_gst:=round(new.total_amount*rate/(100+rate),2);expected_ex:=round(new.total_amount-expected_gst,2);else expected_gst:=0;expected_ex:=round(new.total_amount,2);end if;
  if abs(round(coalesce(new.gst_amount,0),2)-expected_gst)>0.005 or abs(round(coalesce(new.ex_gst,0),2)-expected_ex)>0.005 then raise exception 'Australian expense line tax amounts do not match the controlled treatment.' using errcode='23514';end if;
  new.au_tax_classification:=cls;
  new.au_tax_snapshot:=jsonb_build_object('jurisdiction','AU','gstRate',rate,'classification',cls,'effectiveFrom',e.au_tax_snapshot->>'effectiveFrom','source','v6170f_guard_au_expense_line_tax');
  return new;
end$$;
drop trigger if exists v6170f_p2_au_expense_line_tax_guard on public.expense_lines;
create trigger v6170f_p2_au_expense_line_tax_guard before insert or update on public.expense_lines for each row execute function public.v6170f_guard_au_expense_line_tax();
