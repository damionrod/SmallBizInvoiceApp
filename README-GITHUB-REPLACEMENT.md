# Frindly v61.90 — complete compact GitHub replacement

24 September 2026. This package has fewer than 100 files. Extract it and preserve its `public/`, `supabase/`, `docs/` and `tests/` paths at the repository root. It builds on the supplied reviewed v61.89 compact package and carries forward the existing modules. It is **not** a clone of any files added to GitHub after that package: compare your current repository before replacing or deleting anything. Saving to GitHub alone does not run database SQL or deploy the updated Supabase function. If your GitHub branch is connected to Netlify, pushing it may automatically deploy the frontend.

## v61.90 additions

- Expenses accepts multiple ordered bill photos or files, or a multipage PDF. The existing AI scanner reads all pages together. The saved bill remains the source of its original totals and GST.
- **Review items** lives beside recorded bills in Expenses and works when Stock & Equipment is off. The user can correct suggested Uses, categories and tax figures on compact rows and confirm the entire invoice to the cent. Earlier Stock reviews are copied into the shared review history by the migration.
- When the optional module is enabled, confirming also updates its operational register. The estimated Financials Summary uses confirmed ordinary expense rows, while the posted accounting reports and original GST and payment records remain intact. The Accountant Pack includes an item review schedule.

## Required deployment order

1. Read `docs/V61.90-EXPENSES-MULTIPAGE-PURCHASE-REVIEW.md` and check existing schema prerequisites. Validate the migration against a matching staging clone before main.
2. Apply `supabase/migrations/20260924130000_v6190_purchase_review_core.sql` to the chosen database. The SQL was applied to an isolated test project; it has **not** been applied to the live/main project.
3. Deploy `supabase/functions/scan-expense-document/index.ts` using the existing function settings, then deploy the frontend. This ZIP itself does not deploy either.
4. Run the bill/page/entitlement/report/accountant checks from the v61.90 document before enabling use in production. No production flag or module entitlement was changed by this package.

**Accounting scope:** The review does not post inventory balances, cost of sales, depreciation, low-value deductions or journal reclassifications. The Financials Summary is an estimate and must not be used as a filed tax calculation. The posted Profit & Loss and Balance Sheet still use their posted ledger. Further accountant-reviewed posting integration is required for complete NZ accounting treatment.
