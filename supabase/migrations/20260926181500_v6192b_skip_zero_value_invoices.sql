-- v61.92B posting hotfix.
-- Zero-dollar invoices are valid operational records, but they do not create
-- double-entry accounting lines. Skip them during batch posting.

begin;

create or replace function public.v6192_post_operational_ledger(
  p_from date,
  p_to date,
  p_include_depreciation boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid := public.current_business_id();
  v_user uuid := auth.uid();
  v_ar uuid;
  v_ap uuid;
  v_bank uuid;
  v_sales uuid;
  v_gst_payable uuid;
  v_gst_receivable uuid;
  v_expense_fallback uuid;
  v_fixed_assets uuid;
  v_accum_depn uuid;
  v_depn_expense uuid;
  v_invoice_count integer := 0;
  v_customer_payment_count integer := 0;
  v_expense_count integer := 0;
  v_supplier_payment_count integer := 0;
  v_depreciation_count integer := 0;
  r record;
  v_lines jsonb;
  v_amount numeric;
  v_ratio numeric;
  v_posted uuid;
begin
  if v_user is null or v_business_id is null then
    raise exception 'Sign in and choose a business first';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Select a valid posting period';
  end if;
  if not public.v6169a_accountant_centre_access(v_business_id, true) then
    raise exception 'Accountant or owner access is required to post accounting journals';
  end if;

  if exists (
    select 1 from public.accounting_periods p
    where p.business_id = v_business_id
      and p.status <> 'open'
      and daterange(p.period_start, p.period_end, '[]') && daterange(p_from, p_to, '[]')
  ) then
    raise exception 'One or more accounting periods in this date range are locked';
  end if;

  v_ar := public.v6192_account_id(v_business_id,'accounts_receivable','1100');
  v_ap := public.v6192_account_id(v_business_id,'accounts_payable','2000');
  v_bank := public.v6192_account_id(v_business_id,'bank','1000');
  v_sales := coalesce(
    (select sm.account_id from public.accounting_source_mappings sm where sm.business_id=v_business_id and sm.source_type='sales_default' and sm.source_key='sales_default' and sm.purpose='income' and coalesce(sm.archived,false)=false limit 1),
    public.v6192_account_id(v_business_id,'sales','4000')
  );
  v_gst_payable := public.v6192_account_id(v_business_id,'gst_payable','2100');
  v_gst_receivable := public.v6192_account_id(v_business_id,'gst_receivable','1200');
  v_expense_fallback := public.v6192_account_id(v_business_id,'business_expenses','6000');
  v_fixed_assets := public.v6192_account_id(v_business_id,'fixed_assets','1500');
  v_accum_depn := public.v6192_account_id(v_business_id,'accumulated_depreciation','1590');
  v_depn_expense := public.v6192_account_id(v_business_id,'depreciation','6200');

  if v_ar is null or v_ap is null or v_bank is null or v_sales is null or
     v_gst_payable is null or v_gst_receivable is null or v_expense_fallback is null then
    raise exception 'Chart of accounts is incomplete. Refresh the default Frindly chart before posting.';
  end if;

  for r in
    select i.*
    from public.invoices i
    where i.business_id = v_business_id
      and i.invoice_date between p_from and p_to
      and round(coalesce(i.total,0),2) > 0
      and coalesce(i.lifecycle_state,'issued') not in ('draft','voided')
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'invoice'
          and j.source_id = i.id
          and j.status in ('posted','reversed')
      )
    order by i.invoice_date, i.invoice_number
  loop
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id',v_ar,'description','Invoice '||coalesce(r.invoice_number,''),'debit',round(coalesce(r.total,0),2),'credit',0,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id),
      jsonb_build_object('account_id',v_sales,'description','Sales revenue','debit',0,'credit',round(coalesce(r.total,0)-coalesce(r.gst,0),2),'tax_amount',round(coalesce(r.gst,0),2),'customer_id',r.customer_id,'job_costing_id',r.job_costing_id)
    );
    if round(coalesce(r.gst,0),2) > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id',v_gst_payable,'description','GST collected','debit',0,'credit',round(coalesce(r.gst,0),2),'tax_amount',round(coalesce(r.gst,0),2),'customer_id',r.customer_id,'job_costing_id',r.job_costing_id));
    end if;
    v_posted := public.v6192_create_posted_journal(v_business_id,r.invoice_date,'invoice','invoice',r.id,r.invoice_number,'Invoice '||coalesce(r.invoice_number,''),v_lines);
    v_invoice_count := v_invoice_count + 1;
  end loop;

  for r in
    select p.*, i.invoice_number, i.customer_id, i.job_costing_id
    from public.customer_payments p
    join public.invoices i on i.id = p.invoice_id and i.business_id = p.business_id
    where p.business_id = v_business_id
      and p.payment_date between p_from and p_to
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'customer_payment'
          and j.source_id = p.id
          and j.status in ('posted','reversed')
      )
    order by p.payment_date, p.created_at
  loop
    v_amount := round(coalesce(r.amount,0),2);
    if v_amount > 0 then
      v_posted := public.v6192_create_posted_journal(
        v_business_id,r.payment_date,'customer_payment','customer_payment',r.id,coalesce(r.reference,r.invoice_number),'Customer payment for '||coalesce(r.invoice_number,'invoice'),
        jsonb_build_array(
          jsonb_build_object('account_id',v_bank,'description','Customer payment','debit',v_amount,'credit',0,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id),
          jsonb_build_object('account_id',v_ar,'description','Clear receivable','debit',0,'credit',v_amount,'customer_id',r.customer_id,'job_costing_id',r.job_costing_id)
        )
      );
      v_customer_payment_count := v_customer_payment_count + 1;
    end if;
  end loop;

  for r in
    select e.*
    from public.expenses e
    where e.business_id = v_business_id
      and e.invoice_date between p_from and p_to
      and coalesce(e.archived,false) = false
      and coalesce(e.payment_status,'') <> 'draft'
      and coalesce(e.lifecycle_state,'recorded') not in ('draft','voided')
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'expense'
          and j.source_id = e.id
          and j.status in ('posted','reversed')
      )
    order by e.invoice_date, e.expense_number
  loop
    v_ratio := greatest(0, least(1, coalesce(r.business_use_percent,100) / 100));

    with source_lines as (
      select
        l.id as source_line_id,
        coalesce(l.description,r.description,'Supplier bill') as description,
        l.category_id,
        l.job_costing_id,
        round(coalesce(l.ex_gst,0) * v_ratio, 2) as ex_gst,
        round(coalesce(l.gst_amount,0) * v_ratio, 2) as gst_amount,
        l.gst_rate
      from public.expense_lines l
      where l.business_id = v_business_id
        and l.expense_id = r.id
        and coalesce(r.is_split,false) = true
      union all
      select
        null::uuid,
        coalesce(r.description,'Supplier bill'),
        r.category_id,
        r.job_costing_id,
        round(coalesce(r.business_ex_gst, r.ex_gst * v_ratio), 2),
        round(coalesce(r.business_gst_amount, r.gst_amount * v_ratio), 2),
        r.gst_rate
      where not exists (
        select 1 from public.expense_lines l
        where l.business_id = v_business_id
          and l.expense_id = r.id
          and coalesce(r.is_split,false) = true
      )
    ), mapped as (
      select
        sl.*,
        coalesce(sm.account_id, v_expense_fallback) as account_id
      from source_lines sl
      left join public.accounting_source_mappings sm
        on sm.business_id = v_business_id
       and sm.source_type = 'expense_category'
       and sm.source_id = sl.category_id
       and sm.purpose = 'expense'
       and coalesce(sm.archived,false) = false
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'account_id', account_id,
      'description', description,
      'debit', ex_gst,
      'credit', 0,
      'tax_amount', gst_amount,
      'tax_rate', gst_rate,
      'supplier_id', r.supplier_id,
      'job_costing_id', job_costing_id,
      'source_line_id', source_line_id
    )) filter (where ex_gst > 0), '[]'::jsonb)
    into v_lines
    from mapped;

    if round(coalesce(r.business_gst_amount, r.gst_amount * v_ratio),2) > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id',v_gst_receivable,
        'description','GST claimable',
        'debit',round(coalesce(r.business_gst_amount, r.gst_amount * v_ratio),2),
        'credit',0,
        'tax_amount',round(coalesce(r.business_gst_amount, r.gst_amount * v_ratio),2),
        'supplier_id',r.supplier_id,
        'job_costing_id',r.job_costing_id
      ));
    end if;

    select round(coalesce(sum((x.debit)::numeric),0),2)
      into v_amount
    from jsonb_to_recordset(v_lines) as x(debit numeric);
    if v_amount > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id',v_ap,
        'description','Supplier bill payable',
        'debit',0,
        'credit',v_amount,
        'supplier_id',r.supplier_id,
        'job_costing_id',r.job_costing_id
      ));
      v_posted := public.v6192_create_posted_journal(v_business_id,r.invoice_date,'expense','expense',r.id,r.expense_number,'Supplier bill '||coalesce(r.expense_number,''),v_lines);
      v_expense_count := v_expense_count + 1;
    end if;
  end loop;

  for r in
    select p.*, e.expense_number, e.supplier_id, e.job_costing_id
    from public.expense_payments p
    join public.expenses e on e.id = p.expense_id and e.business_id = p.business_id
    where p.business_id = v_business_id
      and p.payment_date between p_from and p_to
      and not exists (
        select 1 from public.accounting_journals j
        where j.business_id = v_business_id
          and j.source_type = 'supplier_payment'
          and j.source_id = p.id
          and j.status in ('posted','reversed')
      )
    order by p.payment_date, p.created_at
  loop
    v_amount := round(coalesce(r.amount,0),2);
    if v_amount > 0 then
      v_posted := public.v6192_create_posted_journal(
        v_business_id,r.payment_date,'supplier_payment','supplier_payment',r.id,coalesce(r.reference,r.expense_number),'Supplier payment for '||coalesce(r.expense_number,'bill'),
        jsonb_build_array(
          jsonb_build_object('account_id',v_ap,'description','Clear payable','debit',v_amount,'credit',0,'supplier_id',r.supplier_id,'job_costing_id',r.job_costing_id),
          jsonb_build_object('account_id',v_bank,'description','Supplier payment','debit',0,'credit',v_amount,'supplier_id',r.supplier_id,'job_costing_id',r.job_costing_id)
        )
      );
      v_supplier_payment_count := v_supplier_payment_count + 1;
    end if;
  end loop;

  if p_include_depreciation and v_fixed_assets is not null and v_accum_depn is not null and v_depn_expense is not null then
    for r in
      with months as (
        select (date_trunc('month', gs)::date + interval '1 month - 1 day')::date as month_end
        from generate_series(date_trunc('month', p_from)::date, date_trunc('month', p_to)::date, interval '1 month') gs
      )
      select a.id, a.available_on, a.original_cost, a.book_opening_value, a.business_use_percent, a.accounting_rate, m.month_end
      from public.se_assets a
      join months m on m.month_end between greatest(coalesce(a.available_on,a.purchased_on,m.month_end), p_from) and p_to
      where a.business_id = v_business_id
        and a.voided_at is null
        and a.disposed_on is null
        and coalesce(a.accounting_rate,0) > 0
        and not exists (
          select 1 from public.accounting_journals j
          where j.business_id = v_business_id
            and j.source_type = 'depreciation'
            and j.source_id = a.id
            and j.journal_date = m.month_end
            and j.status in ('posted','reversed')
        )
      order by m.month_end, a.id
    loop
      v_amount := round(coalesce(r.book_opening_value,r.original_cost,0) * coalesce(r.business_use_percent,100) / 100 * coalesce(r.accounting_rate,0) / 100 / 12, 2);
      if v_amount > 0 then
        v_posted := public.v6192_create_posted_journal(
          v_business_id,r.month_end,'depreciation','depreciation',r.id,'DEP-'||to_char(r.month_end,'YYYY-MM'),'Monthly depreciation',
          jsonb_build_array(
            jsonb_build_object('account_id',v_depn_expense,'description','Monthly depreciation','debit',v_amount,'credit',0),
            jsonb_build_object('account_id',v_accum_depn,'description','Accumulated depreciation','debit',0,'credit',v_amount)
          )
        );
        v_depreciation_count := v_depreciation_count + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'posted', v_invoice_count + v_customer_payment_count + v_expense_count + v_supplier_payment_count + v_depreciation_count,
    'invoices', v_invoice_count,
    'customer_payments', v_customer_payment_count,
    'supplier_bills', v_expense_count,
    'supplier_payments', v_supplier_payment_count,
    'depreciation', v_depreciation_count,
    'period_start', p_from,
    'period_end', p_to
  );
end
$$;

revoke all on function public.v6192_post_operational_ledger(date,date,boolean) from public, anon;
grant execute on function public.v6192_post_operational_ledger(date,date,boolean) to authenticated;

notify pgrst, 'reload schema';

commit;
