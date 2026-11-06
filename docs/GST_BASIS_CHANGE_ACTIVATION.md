# NZ GST basis change activation

This release supersedes the preview/request-only stage in `GST_BASIS_CHANGE_STAGED.md`. It enables evidence-backed application; unresolved historical or ambiguous cases remain blocked for review.

## User workflow

Financials → GST Returns → **Review / change basis**. Choose a historical configuration correction or an actual IRD-approved change, select its effective period, preview, save the approval/reason reference and confirm affected periods are unfiled. Then **Review & apply** and explicitly confirm the freshly checked evidence. Saving a request alone does not change settings or post accounting.

Existing registered NZ businesses use this workflow for basis changes from Settings too. Initial registration and Australian settings retain their existing paths. The feature does not obtain IRD approval or amend a previously filed return.

Actual changes reconcile all six IR546 directions against source invoices/bills, dated posted payments, linked credits/refunds, business use, immutable prior filings and earlier filed transition adjustments. Settings and one active transition adjustment are applied atomically. Historical corrections produce no wash-up. Effective-dated settings preserve the original defaults before the first stored settings record.

Changed unfiled evidence must be reviewed and refreshed; replacement adjustments retain the previous evidence and reversal link. After filing, differences require amendment review rather than rewriting the snapshot. Retries do not duplicate the adjustment or posting. Tenant scope and Financials write permission are checked server-side.

## Accounting and settlement

The existing return calculator, settings, adjustment, journal, settlement and bank matching engines remain authoritative. Activation creates no replacement invoices, expenses, operational payment journals or bank movements.

When an activated business finalises a return, one non-cash `gst_return_transfer` journal reconciles the original GST controls to the filed amount, retaining reserves for unpaid pre-activation returns. Four balance-sheet-only controls are created/reused as needed: GST returns payable to IRD, GST refunds due from IRD, GST awaiting cash recognition and GST deductions awaiting payment. No operating income/expense accounts are used. Settlement and reversal reuse the existing payment engine; reconciliation matches the recorded payment without reposting it. Payroll follows its existing settlement path.

Finalisation requires verified source journals, chronological filing continuity and an open accounting period. Legacy/direct finalisation cannot bypass these checks. Filed return snapshots, their included adjustments, transfer journals and relevant historical settings are protected. Ordinary invoice/expense staff do not need Financials access to post permitted transactions.

## Deliberate review cases

Automatic application is withheld for missing or inconsistent prior filed snapshots, estimated/unposted payments, missing original GST postings, ambiguous multi-invoice refunds, incomplete supplier-refund allocations, mixed/non-proportional credit tax, foreign-currency conversion evidence, special high-value supplies, unrelated unreconciled manual adjustments, conflicting filed/external periods or eligibility restrictions. Unknown zero-rated versus exempt classification is not guessed. Review evidence must be resolved before affected filing; genuine records are never repaired by assumptions.

Rules checked against IRD [GST plus IR546, March 2026, page 4](https://www.ird.govt.nz/-/media/project/ir/home/documents/forms-and-guides/ir500---ir599/ir546/ir546-2026.pdf) and [GST Act sections 19B–19C](https://www.legislation.govt.nz/act/public/1985/0141/latest/whole.html).

## Validation performed

- Twelve isolated PostgreSQL-compatible database/browser test groups passed, including all six independently expected transition amounts, partial and multiple payments, private use, credits/refunds, repeated changes, changed-evidence refresh, filing rollback/locks, permissions/RLS, P&L/Balance Sheet, settlement reversals, payroll and bank matching without duplicate journals.
- Actual modal connected to the isolated database passed at 1200px and 390px, including confirmation, one apply call and no horizontal overflow.
- Adjacent regression run: 19 tests, 18 passed. The one failure is the existing dashboard label assertion for `GST receivable`; the same test fails against unchanged main at cfd45f5f. Dashboard code was not changed.
- JavaScript syntax and diff whitespace checks passed.

These checks do not constitute a full-system or real-device test. No genuine business transactions were created or changed for testing.

## Deployment and recovery

Migrations: `20261106035826_gst_basis_change_activation.sql` and `20261106050956_gst_basis_activation_lookup_indexes.sql`. Deploy database before frontend. The migration itself contains no business-data updates; settings, adjustments and journals change only through confirmed user actions. Publication uses an expected-main-head lease.

To stop new applications while investigating, revoke authenticated execute on `public.frindly_apply_gst_basis_change_v1(uuid,text,boolean)` via a reviewed migration. Keep read, filing and settlement support for existing activated records. Do not remove controls or reverse journals as a deployment rollback.

Full backend restoration is safe only BEFORE use: first verify there are zero applied requests and zero `gst_return_transfer` journals. If either exists, retain accounting/settlement support and prepare a forward fix. Before-use recovery can restore exactly the eight definitions in `tests/gst-basis/fixtures/pre-activation-functions.sql`, remove only the five newly added triggers (history guard, filed transfer guard, filed adjustment guard, source posting guard and adjustment lock), and revoke the new mutation RPC. Retain request data and additive columns. Execute recovery transactionally through a reviewed migration, not by running test fixture files wholesale. The restored finalisation guard remains in place. Preserve any pending requests for review.

Post-migration security/performance advisors were reviewed. The new authenticated security-definer RPC notices are intentional: checked, current-business Financials endpoints with empty search paths and no anonymous execution. The two new foreign-key lookups received covering indexes. Existing unrelated advisor findings were left unchanged. Advisor guidance: [security-definer RPC exposure](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable), [foreign-key indexing](https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys).

Production read-only verification found zero applied requests and zero transfer journals immediately after migration; all five new guards were installed. CareClean preview returned activation-v2 and blocking evidence reviews, without changing its records.
