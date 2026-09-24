# Frindly v61.90C — complete compact GitHub replacement

24 September 2026. This package has fewer than 100 files. Extract it and preserve its `public/`, `supabase/`, `docs/` and `tests/` paths at the repository root. It builds on the supplied reviewed v61.89 compact package and carries forward the existing modules. It is **not** a clone of any files added to GitHub after that package: compare your current repository before replacing or deleting anything. Saving to GitHub alone does not run database SQL or deploy the updated Supabase function. If your GitHub branch is connected to Netlify, pushing it may automatically deploy the frontend.

## v61.90C scanner correction

- Expenses accepts multiple ordered bill photos or files, or a multipage PDF. The existing AI scanner reads all pages together. The saved bill remains the source of its original totals and GST.
- **Review items** lives beside recorded bills in Expenses and works when Stock & Equipment is off. The user can correct suggested Uses, categories and tax figures on compact rows and confirm the entire invoice to the cent. Earlier Stock reviews are copied into the shared review history by the migration.
- When the optional module is enabled, confirming also updates its operational register. The estimated Financials Summary uses confirmed ordinary expense rows, while the posted accounting reports and original GST and payment records remain intact. The Accountant Pack includes an item review schedule.

## Deployment status and next step

The purchase-review SQL migration **was applied to the main Supabase project** on 24 September 2026 after checking its prerequisites. The main `scan-expense-document` Edge Function was upgraded to version 12 and verified to accept an ordered `documents` array. Those main backend steps are complete; do **not** run the migration again on main. No Netlify frontend deployment or module entitlement change was performed here.

Deploy the updated frontend when you want the automatic two-photo scan, readable failure messages, null-safe amounts and automatic saved-bill rescan. If GitHub main automatically deploys to Netlify, uploading the extracted package may consume a deploy. Refresh the browser after deploying. See `docs/V61.90C-TWO-PAGE-SCANNER-FORENSICS.md` for the root causes, verification and practical limits.

**Accounting scope:** The review does not post inventory balances, cost of sales, depreciation, low-value deductions or journal reclassifications. The Financials Summary is an estimate and must not be used as a filed tax calculation. The posted Profit & Loss and Balance Sheet still use their posted ledger. Further accountant-reviewed posting integration is required for complete NZ accounting treatment.
