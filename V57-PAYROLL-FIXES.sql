-- V57 targeted Payroll usability fixes.
-- Makes the two built-in reimbursement-style allowances tax-free by default.
-- Businesses can still change tax treatment in Settings > Payroll > Pay Items.
update public.payroll_pay_items
set taxable = false,
    updated_at = now()
where item_type = 'allowance'
  and name in ('Travel Allowance','Tool Allowance');

notify pgrst,'reload schema';
