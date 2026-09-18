-- V61.70F-P1 — Australian invoice GST classification & calculation fix
-- Forward-only. No historical transaction rewrite.

create or replace function public.v6170f_invoice_tax_config(p_on date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  bid uuid:=public.current_business_id();
  cfg jsonb;
  rate numeric;
begin
  if bid is null or not public.v6147_can_read_area(bid,'core') then
    raise exception 'Invoice tax configuration access denied' using errcode='42501';
  end if;
  if public.v6170f_business_country()<>'AU' then
    raise exception 'Australian invoice tax configuration requires an Australian business' using errcode='22023';
  end if;
  cfg:=public.v6170f_bas_settings(coalesce(p_on,current_date));
  select r.numeric_value into rate
  from public.country_business_tax_rules r
  where r.country_code='AU' and r.rule_type='gst' and r.rule_key='standard_rate_percent'
    and r.active=true and r.effective_from<=coalesce(p_on,current_date)
    and (r.effective_to is null or r.effective_to>=coalesce(p_on,current_date))
  order by r.effective_from desc limit 1;
  if rate is null or rate<=0 then
    raise exception 'Authoritative Australian GST rate is unavailable for %',coalesce(p_on,current_date) using errcode='22023';
  end if;
  return jsonb_build_object(
    'jurisdiction','AU',
    'gst_registered',coalesce((cfg->>'gst_registered')::boolean,false),
    'gst_rate_percent',rate,
    'effective_from',cfg->>'effective_from',
    'accounting_basis',cfg->>'accounting_basis',
    'filing_frequency',cfg->>'filing_frequency',
    'source','effective_tax_settings+country_business_tax_rules'
  );
end$$;

revoke all on function public.v6170f_invoice_tax_config(date) from public,anon;
grant execute on function public.v6170f_invoice_tax_config(date) to authenticated;

create or replace function public.v6170f_guard_au_invoice_tax()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  c text;
  h public.gst_settings_history;
  registered boolean:=false;
  rate numeric;
  expected numeric;
  base numeric;
begin
  select upper(coalesce(b.settings->>'country','NZ')) into c from public.businesses b where b.id=new.business_id;
  if c is distinct from 'AU' then return new; end if;

  if new.au_tax_classification is null or new.au_tax_classification not in ('gst_taxable','gst_free','input_taxed','out_of_scope') then
    raise exception 'Choose an Australian GST treatment before saving this invoice.' using errcode='23514';
  end if;

  select * into h from public.gst_settings_history
  where business_id=new.business_id and jurisdiction='AU' and effective_from<=new.invoice_date
  order by effective_from desc limit 1;
  if not found then
    raise exception 'Australian GST settings are unavailable for invoice date %',new.invoice_date using errcode='23514';
  end if;
  registered:=coalesce(h.gst_registered,false);

  select r.numeric_value into rate from public.country_business_tax_rules r
  where r.country_code='AU' and r.rule_type='gst' and r.rule_key='standard_rate_percent'
    and r.active=true and r.effective_from<=new.invoice_date
    and (r.effective_to is null or r.effective_to>=new.invoice_date)
  order by r.effective_from desc limit 1;
  if rate is null or rate<=0 then
    raise exception 'Authoritative Australian GST rate is unavailable for invoice date %',new.invoice_date using errcode='23514';
  end if;

  base:=round(greatest(0,coalesce(new.subtotal,0)-coalesce(new.discount_amount,0)+coalesce(new.extra_fee,0)),2);
  if new.au_tax_classification='gst_taxable' then
    if not registered then raise exception 'GST taxable cannot be used because the business is not GST registered for the invoice date.' using errcode='23514'; end if;
    expected:=round(base*rate/100,2);
  else
    expected:=0;
  end if;
  if abs(round(coalesce(new.gst,0),2)-expected)>0.005 then
    raise exception 'Invoice GST does not match the authoritative Australian GST treatment. Expected %, received %.',expected,round(coalesce(new.gst,0),2) using errcode='23514';
  end if;
  if abs(round(coalesce(new.total,0),2)-round(base+expected,2))>0.005 then
    raise exception 'Invoice total does not match the authoritative Australian tax calculation.' using errcode='23514';
  end if;

  new.company_snapshot:=jsonb_set(coalesce(new.company_snapshot,'{}'::jsonb),'{invoiceTax}',jsonb_build_object(
    'jurisdiction','AU','gstRegistered',registered,'gstRate',rate,'classification',new.au_tax_classification,
    'effectiveFrom',h.effective_from,'source','v6170f_guard_au_invoice_tax'
  ),true);
  return new;
end$$;

drop trigger if exists v6170f_au_invoice_tax_guard on public.invoices;
create trigger v6170f_au_invoice_tax_guard
before insert or update of invoice_date,subtotal,discount_amount,extra_fee,gst,total,au_tax_classification,company_snapshot
on public.invoices for each row execute function public.v6170f_guard_au_invoice_tax();

create or replace function public.v6170f_default_new_au_financial_settings()
returns trigger
language plpgsql
set search_path=public
as $$
declare c text;
begin
  select upper(coalesce(b.settings->>'country','NZ')) into c from public.businesses b where b.id=new.business_id;
  if c='AU' then
    -- New AU tenants use the standard Australian 1 July financial-year start.
    -- This trigger only runs for newly inserted settings; existing businesses are untouched.
    if new.financial_year_start_month=4 and new.financial_year_start_day=1 then
      new.financial_year_start_month:=7; new.financial_year_start_day:=1;
    end if;
    if new.balance_date_month=3 and new.balance_date_day=31 then
      new.balance_date_month:=6; new.balance_date_day:=30;
    end if;
  end if;
  return new;
end$$;

drop trigger if exists v6170f_default_new_au_financial_settings on public.financial_settings;
create trigger v6170f_default_new_au_financial_settings
before insert on public.financial_settings for each row execute function public.v6170f_default_new_au_financial_settings();
