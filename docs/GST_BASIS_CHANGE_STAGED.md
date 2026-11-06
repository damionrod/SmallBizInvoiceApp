# GST basis changes — staged build

> Historical preview-stage notes. Superseded by [GST basis change activation](GST_BASIS_CHANGE_ACTIVATION.md).

## What is available

Financials → GST Returns → **Review / change basis**.

- Compare the existing authoritative GST calculation with another basis.
- Distinguish a historical correction from a genuine IRD-approved change.
- Capture the effective date, reason/approval reference and confirmation that affected periods are unfiled, including externally through myIR.
- For an actual change, show a provisional worksheet for outstanding customer and supplier GST and the six IR546 adjustment directions.
- Save an audited, tenant-scoped request in **Pending verification** state.
- Review or cancel pending requests without changing official settings or financial transactions.
- Display the stored snapshot for a finalised GST return instead of silently recalculating it.

**This is a preview/request release, not activation of the full accounting feature.** The database deliberately has no approved/applied request status or activation RPC. Saving a request does not update `gst_settings_history` or `financial_settings`, does not create `gst_adjustments`, and does not post a journal or payment. It cannot be used as authority to file changed figures.

Affected returns are blocked from finalisation by the calculator/save path and a database trigger covering legacy save callers and direct table finalisation. Historical basis transitions already present in settings also generate a blocking review until their reconciliation is verified. Unaffected returns retain their existing calculation and filing paths. Cancelling a request removes that request's block; it does not remove independent historical-transition or pre-existing evidence blocks.

## Existing components retained

The existing boundary wrapper, `frindly_cash.gst_base`, `frindly_gst_calculate_basis_v1`, effective settings lookup, draft/save path and source payment records remain the authoritative components. Only the boundary wrapper and save function are extended with snapshot/protection checks. There is no second return calculator or operational posting workflow.

## Important limitations before activation

- Worksheet amounts are **provisional**. Credits, refunds, reversals, imported or estimated payment evidence and prior filed-return attribution require full reconciliation validation. They must not be manually copied into a filing as verified amounts.
- The simple worksheet uses recorded source GST and proportional outstanding amounts, including business-use percentages. It does not yet perform a verified transaction-level attribution to prior filings or transition adjustments.
- A correction request does not change historical settings or recalculate saved filed snapshots.
- There is no automatic creation, confirmation, deduplication or journal posting of actual transition adjustments in this release.
- An externally filed period prevents request application and saved-return overwriting. Missing external filing snapshots are not reconstructed by this feature.
- Existing official Settings changes are not replaced by this request screen. Their historical transitions are detected and blocked from filing pending verification.
- Full regression and accounting acceptance testing remains deferred at the user's request.

## Database changes

Migration: `20261106033020_gst_basis_change_preview.sql`.

One new table: `gst_basis_change_requests`, with RLS and authenticated read access restricted to the current business and Financials permission. Writes/cancellation go through authenticated, permission-checked RPCs. A partial unique index prevents duplicate pending requests for the same business/period/effective date/basis/type. Request IDs protect retries; an evidence fingerprint rejects a changed preview. Requests and finalisation share a transaction-scoped advisory lock.

New public RPCs:

- `frindly_preview_gst_basis_change_v1`
- `frindly_request_gst_basis_change_v1`
- `frindly_cancel_gst_basis_request_v1`

Private helpers: `frindly_cash.gst_basis_review` and `frindly_cash.guard_gst_basis_finalisation`. New trigger: `frindly_guard_gst_basis_finalisation` on `gst_returns`.

Existing functions extended:

- `frindly_gst_boundary_basis_v1`: stored snapshot for finalised periods; pending/historical transition review flags otherwise.
- `frindly_save_gst_basis_v1`: common transaction lock and externally filed-period protection; existing validation remains.

The migration contains no updates to genuine business transactions, basis settings, saved returns, journals or payments.

## Checks actually run

`preview-smoke.cjs` executed against an isolated PGlite database using captured live column types/functions:

1. Migration compiles.
2. All six simple IR546 worksheet directions match independently specified expected amounts: -90, +90, +60, -60, +150, -150 for debtor GST 150 and creditor GST 60. All previews report `can_apply=false`.
3. Identical request retries do not duplicate requests or alter official settings/adjustments.
4. Affected finalisation is rejected by the server.
5. Cancellation is scoped to the current business.
6. The fixture write-permission predicate is enforced.
7. Finalised calculation returns its original stored snapshot even when another preview basis is requested.
8. Recorded external filing prevents changes.

`preview-ui-smoke.cjs` executed the actual new frontend functions with mocked RPCs in Chromium at 1200px and 390px. Both passed opening/preview/confirmation, one save call, no posting calls, no horizontal page overflow, and modal close. The first harness run closed the last Chromium page and could not create the next page; keeping both pages open corrected that harness lifecycle issue. The rerun passed both sizes.

JavaScript syntax checks and `git diff --check` passed.

These are limited build checks. They do not establish full legal/accounting acceptance, production RLS coverage, real-device behavior or complete adjacent workflow regression. No invoices, expenses, payroll, bank matches, Cash Book entries or financial reporting records were created on live tenants for testing.

## Deployment and recovery

Database changes are deployed before the frontend so existing clients remain compatible. Source publication uses an expected-main-head lease to preserve concurrent work. See the delivery message for the commit and observed deployment status.

Recovery reference: `tests/gst-basis/fixtures/current-functions.sql` preserves the pre-change function definitions. To roll back the UI, revert only this feature's frontend changes. Keep request records and filing protection while outstanding requests/history are reviewed. A full backend rollback must first account for pending requests and known historical-transition risks, then remove the feature finalisation trigger and restore only the two modified public functions from the captured definitions. Do not execute all fixture SQL against production, drop request data, or restore unrelated functions.

No accounting journals require reversal because this staged feature does not post them.
