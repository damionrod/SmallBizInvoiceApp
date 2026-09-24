# Stock & Equipment item review: implementation checkpoint

24 September 2026. **Offline implementation; do not deploy or enable in production yet.**

## What changed

- `supabase/functions/scan-expense-document/index.ts`: the **existing** Expenses photo scan returns item-by-item suggested use, confidence and reason together with its existing header fields. It still uses the configured expense AI model and does not calculate a tax deduction.
- `public/expenses.js`: no new controls, labels or layout. On save, the completed scan's item suggestions are stored in the background only if Stock & Equipment is available for this business. Suggestions are stored separately from `expense_lines`, so they do not add an expense. A scan response is matched to the exact uploaded photo; if unavailable, the bill still saves normally.
- `public/stock-equipment.js` and `.css`: the existing Review Purchases view opens a whole recorded invoice. It shows separate suggested items, printed prices, editable classification, quantity, ex GST and GST, inline depreciation information for equipment, manual add/remove, source document view, one-time **same AI** rescan for older invoices, and **Save whole invoice**. It reconciles the item totals against the recorded supplier bill, and corrections require a reason. Responsive item cards are limited to this module.
- `docs/STOCK-EQUIPMENT-INVOICE-ITEM-REVIEW-DRAFT.sql`: RLS-scoped item proposals, immutable whole-invoice review revisions, checked transaction-level item creation, a distinct low-value equipment tracking marker, correction of untouched stock/assets, source bill change guards and optimistic revision checks. It does not create accounting journals or modify GST returns.

## Verification

- Node syntax checks on the three JavaScript/TypeScript files and `git diff --check` passed.
- Existing Stock & Equipment focused tests passed **4/4**.
- The SQL and RPCs ran on the isolated Supabase project with the existing v61.89 schema. Rollback fixtures covered a mixed supplies/low-value bill, exact ex-GST/GST reconciliation, rejected totals with no partial save, revision conflict, auditable correction with asset void, protected source totals, another business denied access, and book-method validation. A follow-up query confirmed **zero fixture businesses and zero review rows** and the module still disabled. Isolated test schema objects remain in that test project.
- The entire `tests/*.test.js` run was **38/43** passing. Five failures are in unrelated pre-existing scheduling cache-key and Stripe subscription tests (`subscriptionCancellationPatch is not defined`); these files were not modified for this item review.

## Deployment and accounting limits

The SQL is a **draft**, not a production migration; Supabase CLI was unavailable in this environment. The production database, CareClean records, Bingo's recorded NZ Cleaning Supplies bill, Supabase Edge Function deployment, GitHub and Netlify were not changed. The full photographed invoice flow and mobile/desktop browser layouts remain unverified against a running app. Existing older invoices need their attached image rescanned in Stock & Equipment or manual item entry; item prices must not be guessed from bill descriptions.

**Financials, cost of sales, book depreciation and IRD tax schedules are not posted or recalculated by this release.** Supplier bills, payments and GST remain in Expenses. Accounting integration needs balanced journal and source-derived-report reconciliation with locked-period and tax-review rules before the item review can be production-enabled for accurate profit and loss.
