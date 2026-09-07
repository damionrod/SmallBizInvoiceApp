# Invoice Manager — v60.2

Targeted country-based Payroll tax-rule update.

- Super Admin centrally manages effective-dated statutory Payroll rules by country.
- Each business Payroll uses its configured country code.
- Pay runs use the rule version effective on the pay date.
- Finalised pay runs retain the exact rules snapshot used.
- Calculation engine no longer relies on embedded statutory PAYE/ACC/student-loan/ESCT fallback percentages.
- Existing tenant Payroll, Financials, Invoicing, Expenses, Job Costing, email and other workflows are otherwise unchanged.

See `V60.2-DEPLOYMENT-STEPS.md`.
