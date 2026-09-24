# Frindly full repository replacement: item-review preview

24 September 2026. Extract this ZIP and upload the **contents** at the repository root, keeping the `public/`, `supabase/`, `docs/` and `tests/` folders. This package contains fewer than 100 files. It is built on the reviewed v61.89B 79-file package and carries forward later bill, bank, Financials and Bingo preview changes found in the current project. It does not include the many historic files that were not part of that reviewed GitHub package.

**This is an offline preview, not a production-ready accounting release.** Stock & Equipment remains off by default. The Expenses layout is unchanged; the existing photo scanner provides item suggestions in the background. Stock & Equipment presents item review and one whole-invoice save. Financials reclassification, cost of sales, book depreciation, tax schedules and GST adjustments are not posted by this preview.

## Upload and separate database/function steps

1. Back up the current GitHub repository or use a review branch. Replace repository files with the extracted contents, preserving the folder paths. If deleting old files in the GitHub UI, delete only files absent from this package after checking the current repository's newer work; this package was based on v61.89B, not a live pull of your GitHub repository.
2. GitHub upload **does not** run the SQL drafts. The new item-review SQL is `docs/STOCK-EQUIPMENT-INVOICE-ITEM-REVIEW-DRAFT.sql` and depends on the existing v61.89B Stock & Equipment foundation migration. The Bingo-only access SQL and voided bill guard are separately staged at `docs/BINGO-ONLY-STOCK-ACCESS-DRAFT.sql` and `docs/V61.89D-VOIDED-EXPENSE-PAYMENT-GUARD.sql`. Do not apply drafts to production without final accounting and staging review.
3. Uploading a Supabase Edge Function source file to GitHub **does not itself deploy** the `scan-expense-document` function to Supabase. The existing scanner must be redeployed separately after its structured item response is verified.
4. If Netlify is connected to the repository's main branch, an upload may trigger an automatic Netlify deployment and consume deploy credits. This ZIP does not change Netlify settings or deploy anything itself.

See `docs/STOCK-EQUIPMENT-ITEM-REVIEW-IMPLEMENTATION.md` for verified behavior and remaining gaps. No CareClean or Bingo account records were changed while preparing this ZIP.
