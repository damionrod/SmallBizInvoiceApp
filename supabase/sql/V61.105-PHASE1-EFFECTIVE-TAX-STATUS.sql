-- Frindly v61.105 Phase 1: effective-dated GST registration/tax-status resolver.
-- Additive only: no existing functions/tables/triggers/calculations are modified.

create or replace function public.v61105_effective_tax_status(p_on date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  bid uuid := public.current_business_id();
  d date := coalesce(p_on, current_date);
  v_jurisdiction text;
  h public.gst_settings_history%rowtype;
  f public.financial_settings%rowtype;
  registered boolean;
  statutory_rate numeric;
  effective_rate numeric;
  effective_from date;
  tax_identifier text;
  basis text;
  frequency text;
  settings_source text;
begin
  if bid is null or not public.v6147_can_read_area(bid, 'core') then
    raise exception 'Tax status access denied' using errcode = '42501';
  end if;

  v_jurisdiction := public.v6170f_business_country();
  if v_jurisdiction not in ('NZ', 'AU') then
    raise exception 'Tax status is not configured for jurisdiction %', v_jurisdiction using errcode = '22023';
  end if;

  select * into h
  from public.gst_settings_history x
  where x.business_id = bid
    and upper(coalesce(x.jurisdiction, 'NZ')) = v_jurisdiction
    and x.effective_from <= d
  order by x.effective_from desc
  limit 1;

  if found then
    registered := h.gst_registered;
    effective_from := h.effective_from;
    tax_identifier := coalesce(h.tax_identifier, h.gst_number);
    basis := h.accounting_basis;
    frequency := h.filing_frequency;
    settings_source := 'gst_settings_history';
  else
    select * into f
    from public.financial_settings x
    where x.business_id = bid
    limit 1;

    if v_jurisdiction = 'AU' then
      registered := coalesce(f.gst_registered, false);
      tax_identifier := coalesce(
        (select b.settings->>'abn' from public.businesses b where b.id = bid),
        f.gst_number
      );
      basis := case when f.gst_accounting_basis = 'payments' then 'cash' else 'non_cash' end;
      frequency := case
        when f.gst_filing_frequency = 'monthly' then 'monthly'
        when f.gst_filing_frequency = 'annual' then 'annual'
        else 'quarterly'
      end;
    else
      -- Preserve v61.104B fallback semantics in Phase 1; onboarding/default changes are later phases.
      registered := coalesce(f.gst_registered, true);
      tax_identifier := f.gst_number;
      basis := coalesce(f.gst_accounting_basis, 'invoice');
      frequency := coalesce(f.gst_filing_frequency, 'two_monthly');
    end if;
    effective_from := null;
    settings_source := 'financial_settings_fallback';
  end if;

  select r.numeric_value into statutory_rate
  from public.country_business_tax_rules r
  where r.country_code = v_jurisdiction
    and r.rule_type = 'gst'
    and r.rule_key = 'standard_rate_percent'
    and r.active = true
    and r.effective_from <= d
    and (r.effective_to is null or r.effective_to >= d)
  order by r.effective_from desc
  limit 1;

  if statutory_rate is null or statutory_rate <= 0 then
    raise exception 'Authoritative % GST rate is unavailable for %', v_jurisdiction, d using errcode = '22023';
  end if;

  effective_rate := case when registered then statutory_rate else 0 end;

  return jsonb_build_object(
    'version', 'v61.105-phase1',
    'business_id', bid,
    'as_of_date', d,
    'jurisdiction', v_jurisdiction,
    'gst_registered', registered,
    'statutory_rate_percent', statutory_rate,
    'effective_rate_percent', effective_rate,
    'default_tax_treatment', case
      when registered then 'standard_gst'
      when v_jurisdiction = 'AU' then 'out_of_scope_unregistered'
      else 'no_gst_unregistered'
    end,
    'registration_effective_from', effective_from,
    'tax_identifier', tax_identifier,
    'accounting_basis', basis,
    'filing_frequency', frequency,
    'settings_source', settings_source,
    'rate_source', 'country_business_tax_rules'
  );
end;
$$;

comment on function public.v61105_effective_tax_status(date) is
'V61.105 Phase 1 read-only effective-dated GST status resolver. Not yet wired into transaction calculations.';

revoke execute on function public.v61105_effective_tax_status(date) from public;
revoke execute on function public.v61105_effective_tax_status(date) from anon;
grant execute on function public.v61105_effective_tax_status(date) to authenticated;
