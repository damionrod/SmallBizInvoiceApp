# Bank account consolidation

The owner authorised consolidating a single business to its two configured banks. The existing default bank record was retained, renamed to the corresponding configured bank, and kept its original ID and primary ledger. The other configured bank and its opening balance were preserved.

Obsolete bank records were archived, not deleted. Their bank-transaction, import-batch and feed routing references were reassigned to the retained default, with before/after identifiers in the existing accounting audit log. Counterparty bank details, payment amounts, dates, payroll calculations and GST records were not changed.

Historical bank ledgers are associated through `bank_account_ledger_links`. Dashboard, Cash Book and the existing bank-ledger diagnostics aggregate these links into the retained bank. Original journal accounts remain available in the General Ledger for audit: no posted journal or journal line was rewritten, deleted or duplicated. Historical free-text/blank payment metadata remains preserved; the posted movements are grouped using their original ledger account links.

## Files and database changes

- `supabase/migrations/20261102024934_bank_ledger_consolidation_links.sql`: new read-only, tenant-scoped historical ledger link table and invoker RPC; extends existing bank status aggregation.
- `scripts/admin/consolidate-owner-bank-records.sql`: parameterised, idempotent administrator-only cleanup. Requires an explicitly supplied owner email in a transaction-local setting. Resolves IDs from current records, refuses conflicting real-bank numbers/import identifiers, and records a before snapshot and completion audit.
- `public/bank-ledger-view.js`: shared bank grouping for Dashboard and Cash Book.
- `public/dashboard.js`, `public/financials.js`: use the shared grouping and preserve every original posted movement.
- `public/app.js`: restore canonical banks without reintroducing an empty unsaved placeholder.
- `public/saas.js`, `public/index.html`: module loading/cache versions.
- `tests/bank-consolidation/view.test.cjs`, `tests/settlements/bank-consolidation-ui.test.cjs`: synthetic-fixture coverage.

The migration was created by the Supabase CLI and its filename aligned with the authoritative applied migration version. Business identifiers and financial amounts are intentionally excluded from this repository report.

## Checks performed

- Production rollback trial of the complete migration and cleanup before committing changes.
- Exactly two active configured banks and one default after cleanup.
- Imported transaction count, amounts, dates, references, fingerprints and reconciliation statuses unchanged; only obsolete bank routing identifiers reassigned.
- Cryptographic before/after equality of all posted journal rows and journal lines in the business.
- Other businesses' bank records unchanged.
- RLS enabled, no anonymous/client writes granted, tenant validation trigger for historical links.
- Authenticated owner read of the existing bank-status RPC returns the two consolidated bank balances; historical link RPC returns the intended links.
- Node tests: grouping, unchanged total, unaffected businesses without links, invalid alias rejection and Settings placeholder cleanup.
- Chromium tests: actual Dashboard calculation and Cash Book expansion show the same two banks; historical transaction rows are retained.
- Existing settlement UI tests pass after the change.

The data repair adds no financial journal and changes no financial total. Old bank records and original General Ledger account codes are retained for audit, rather than being erased to make the screen look simpler.
