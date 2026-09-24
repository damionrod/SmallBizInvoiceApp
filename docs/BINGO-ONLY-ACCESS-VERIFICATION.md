# Bingo-only Stock & Equipment gate — draft verification

24 September 2026. This is an **offline code draft**; no migration was applied to the main project, no account figures were changed, and no Netlify deploy was run.

## Changes prepared

- `public/saas.js`: after ordinary entitlement evaluation, queries a server-verified preview grant for Stock & Equipment. Existing modules and globally enabled access take the same paths as before. Fail closed if the RPC is absent or returns an error.
- `docs/BINGO-ONLY-STOCK-ACCESS-DRAFT.sql`: a proposed RLS-protected, client-inaccessible, expiring per-business grant; RPC checks the authenticated user, active business, active owner/admin membership and existing subscription/Expenses write access. The existing Stock & Equipment write guard accepts this grant only in addition to ordinary module eligibility. The draft grant seed checks Bingo's UUID, business name and active owner email.
- The module catalogue remains globally inactive and no other business is granted preview access. The grant has a separate expiry and ceases working when Bingo's subscription write access ends.

## Validation

- The proposed SQL was run inside a transaction against the isolated Supabase project with a temporary Bingo owner and business. The transaction ended with `ROLLBACK`; a follow-up query confirmed `se_preview_grants` was absent and the module remained globally inactive.
- Six database checks passed: Bingo owner allowed, Bingo Stock & Equipment write guard allowed, other tenant denied, member denied, expired grant denied, disabled grant denied. A separate expired-trial check denied access.
- `node --check public/saas.js` passed; six focused existing Stock & Equipment/voided-expense contract tests passed.

## Remaining before use in Bingo

1. Turn the draft SQL into a reviewed migration using the Supabase CLI. The CLI was unavailable in this workspace, so the SQL deliberately lives under `docs/`, **not** the migrations directory. Do not upload and auto-apply it as if it were already reviewed.
2. Test the access path with actual authenticated browser sessions at phone and desktop widths on a matching staging environment. The SQL checks simulated `auth.uid()` in an isolated database transaction; they are not a browser verification.
3. Review the effects of Bingo's Financials/Expenses subscription trial ending **29 September 2026 UTC**. The grant never extends subscription access. Do not silently change billing to make the fixture pass.
4. Only after review: deploy the updated frontend and apply the database migration in a coordinated sequence, check the global switch remains off and the real CareClean tenant remains inaccessible, then create the labelled test transactions using the supported app workflows. Compare Financials and stock results with `Bingo-Financials-test-scenario-2026-09-24.md`. Posting integration is still a separate implementation.

Disable the test path by setting `enabled=false` on Bingo's grant or by letting it expire; the draft sets an outer expiry of 31 October 2026 UTC. Neither action erases any resulting test documents.
