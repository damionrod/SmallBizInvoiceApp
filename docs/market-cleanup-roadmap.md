# Frindly Market cleanup and completion roadmap

Updated 18 October 2026. Implementation is confined to `market/frindly-market` and the isolated Market services. This is an execution register, not a statement that every feature is complete or commercially certified.

## Ownership and release rules

- Publish `public/` through `scripts/build-market.cjs`; root legacy copies are not a second runtime source. Retain them until every consumer, packaging script and deployment path has been traced.
- Business profile owns company identity. Tax settings own GST/ABN and effective dates. Banking owns bank accounts. Invoice settings display references to these authorities. Use the server-confirmed revision-checked saves already introduced in v62.21.
- Keep existing ledger, invoice/expense payments, import audit, role and statutory-history models. Extend their owners rather than introducing parallel models.
- Keep applied migrations and policies. Old-looking SQL is deployment history, not disposable source. Restrictive policies depend on the remaining permissive policies.
- Release one bounded change at a time. Record source commit, deployed backend migration versions, test evidence and rollback. Never merge or deploy to Main as part of this work.

## Delivery register

| Order | Work | Current evidence | Completion gate |
| --- | --- | --- | --- |
| 1 | Isolated baseline | Market site/database separated; outbound integrations blocked; live untouched | Repeat tenant, role, storage and service isolation checks after each backend change |
| 2 | Reliable runtime loading | v62.22 deployed hash/order loading and removed duplicate Community evaluation | Loader and build regressions pass; exact-source Market deploy and authenticated smoke test |
| 3 | Test baseline recovery | All previous offline failures resolved; full suite now 290/290 passing, including importer and promotion regressions | Keep the full offline CI gate enabled; authenticated HTTP/browser checks remain separate |
| 4 | Settings and shared service consolidation | v62.21 canonical profile, banking and tax save paths; export pagination and context guards | Inventory all remaining writers and route them through the existing authorities; stale, denied and business-switch checks |
| 5 | Permissions, payments and communications | Payment replay/account/amount/currency/session/intent regressions covered offline | Revocation, expiry, storage access and refund/concurrency checks; safe delivery/retry semantics; no real provider calls in Market |
| 6 | Access recovery and MFA | Existing authentication retained | Recovery/support procedure and enrollment/unenrollment tests before enforcement; avoid locking out existing users |
| 7 | Tax & IRD visibility | Existing read-only overview and bounded income-tax estimate | NZ accountant acceptance of supported entity/basis/balance-date cases; unavailable values stay unknown; file preparation distinct from confirmed filing |
| 8 | Migration completion | Nine-type schema, domain/raw-file access, route ownership, atomic review/confirmation, immutable completed evidence, large-file completeness, financial conflicts and settlement parsing fixed; part-paid operational imports and starting-balance posting gated | Reconciled sample conversion, idempotent commit, duplicate review, cross-business rejection, document-to-ledger-to-bank totals; atomic rollback |
| 9 | Opening balances and accountant handoff | Exact-cent balanced review and cutover checks available | Accountant-reviewed posting contract, no duplicated opening documents/postings, AR/AP/bank/assets/owner/tax reconciliation; dated IR10 mappings and reconciled pack |
| 10 | Leave and employee access | v62.26 atomic hours entries and revision-checked balance corrections; employee details no longer overwrite balances | Trace existing request/entitlement tables first; one leave-entry path; own-record isolation; approval and payrun consistency; holiday/final-pay regression cases |
| 11 | Optional payrun approval | v62.26 implemented, off by default: atomic pay-run save, saved-figure review, separate approver, revision/fingerprint checks | Maker/reviewer rules and immutable approval evidence; changes invalidate approval; no silent payroll recalculation |
| 12 | Practice dashboard | Demand-led extension | Reuse current memberships; no cross-client data leakage; drill-down totals match existing reports |
| 13 | Receipt intake | Existing upload/scan flow retained | Durable inbound queue, deduplication and attachment authorization; provider/domain setup and delivery tests before enabling email intake |
| 14 | Asset depreciation | Extend existing stock/equipment ownership | Accountant-reviewed dates, disposals and adjustment history; reconciled reports; no replacement asset register |
| 15 | Contractor/owner workflows | Scope and existing-table review required | Verified jurisdiction rules, dated calculations and professional acceptance before automated statutory results |
| 16 | PWA/native, public API/webhooks, POS, Peppol, full tax worksheets | Separate product/integration projects from the review | Defined supported commercial scope, provider/platform prerequisites, policy review, security and support readiness; no placeholder advertised as complete |
| 17 | Commercial acceptance | Not yet complete | Full regression pass, authenticated desktop/mobile/keyboard/200% zoom review, backup-and-storage restore rehearsal, monitoring/incident ownership and accountant/payroll sign-off |

## Removal evidence

Completed locally in this cleanup:

- Removed Community from the dynamic module list because `public/index.html` already loads it. The second evaluation could reset module-local initialization state.
- Removed the redundant Community entitlement/init block in `bindAfterAppLoad`; the immediately called `refreshEntitlements` retains the canonical permission check, active-view redirect and initialization.
- Removed manual dynamic-module version strings. The loader resolves generated content hashes; local development falls back to the configured release version.

Do not yet remove root/public file pairs, old CSS blocks, database objects, AU functionality or historical tests. Each needs caller/dependency evidence and relevant behavioral coverage. File age and naming are insufficient evidence.

## Acceptance and rollback

Use `node scripts/check-release.cjs` for the focused offline gate and `node scripts/check-release.cjs --full` for the full offline gate. Authenticated HTTP/RLS tests are separately scoped to Market. A passing focused gate is not a full-suite pass.

The generated `dist-market/runtime-assets.js` maps final published bytes. It is a build output, not another manually maintained configuration file. Build isolation guards and CSP remain mandatory. Runtime loading retains concurrent fetches with ordered classic-script execution.

Before any Market publication, compare the complete source tree with the remote branch, run the relevant database rollback fixtures for any SQL change, verify the deploy commit, and confirm Main/live identifiers remain unchanged. Restore the previous Market deploy for frontend rollback. For database changes use a reviewed compensating migration; never erase applied history.

Netlify team protection currently prevents authenticated browser acceptance in the shared session. Do not remove protection or claim visual acceptance without completing that check. External provider setup, tax/payroll review and real-device acceptance remain explicit release dependencies.

## Historical pre-v62.22 local checkpoint

- Focused gate: 106/106 pass, including isolation, generated assets and payment mismatch cases.
- Full offline suite: 205 tests; 190 pass, 15 fail. These unresolved tests remain enabled and block a claim of full acceptance.
- Static runtime inventory: 47 recognized local asset edges, no missing targets; 35 root/public pairs retained for consumer review. See `docs/releases/market-runtime-inventory.json`, reproducible with `node scripts/inventory-runtime.cjs`.
- Current cleanup has not been deployed. No SQL was applied during this increment. Main and the live services were not modified.

## v62.22 execution checkpoint

The original 39 failures have been resolved without excluding tests. The full offline suite is now 217/217 passing, including actual execution of the formerly incomplete Schedule async harness. Market CI now runs that full gate.

Implemented: runtime hash/order ownership; duplicate Community removal; stale-business/view and repeated-submit migration protection; business-currency import formatting; preservation of mapping choices; starting-balance context protection; atomic legacy bank undo with rollback fixtures; narrow helper security boundaries. Removed only the two unloaded public CSS copies whose exact rules already exist in the active stylesheet.

The two v62.22 database migrations are applied only to Market and their fixture data is rolled back. Frontend publication and authenticated acceptance must be recorded separately. Product rows 8–17 above remain explicitly open wherever their completion gates have not been met; this checkpoint is not a claim that every roadmap feature is built.


## v62.23 migration safety checkpoint

Applied only to Market: 20261017212154 (domain permissions), 20261017212723 (financial conflicts and nine-type sheet constraint), 20261017212844 (raw source-file scope), 20261017213455 (old/new route ownership). Rollback fixtures run with authenticated roles and leave no fixture businesses, documents, or employees. The older preview, history and commit RPCs use the same boundary as the current importer; restrictive policies also protect direct table reads. Raw source files belong to their uploader, with owner/admin oversight, because unexpected CSV columns cannot be classified reliably as harmless.

Fixed the `paid` substring test that also matched `unpaid` and `partially paid`, the outstanding-only settlement calculation, cancelled-history fabricated paid amount, and the duplicate check that treated an earlier analysis as a completed import. Native invoice, expense and quote number collisions now stop atomically instead of silently linking the wrong document. Existing financial documents are never replaced. Source amounts and currency are checked server-side.

The schema test exposed that `import_sheets` still rejected quotes, stock, equipment and payroll history. The allowed-type constraint now includes all nine supported types and retains the previous `unknown` value. No old type or financial evidence was deleted.

**Conversion is still incomplete.** A rollback fixture proved the legacy expense insert trigger overwrites a part-paid opening balance; both invoice and expense payment refreshers derive paid totals only from Frindly payment rows. A complete correction requires an immutable source opening-paid authority used consistently by payment guards, recalculation, credits/refunds, reports and conversion posting. Creating synthetic historic payments or changing only the first displayed balance would be incorrect. Part-paid opening records now show a warning, and the server rejects native confirmation; the user can choose historical reference. Starting-balance posting remains disabled. Existing imported documents were not rewritten.

Full offline gate: 233/233 passed. Browser acceptance remains gated by Netlify team login. Leave/self-service, optional approvals and the remaining product roadmap are not marked complete by this migration checkpoint.

The old row importer now refuses newer logical-record batches, and Smart Migration refuses a batch with no logical records. This removes the overlapping confirmation path that could falsely complete a batch without importing it. Existing completed/history reads are preserved.

## v62.24 subscription promotion checkpoint

Implemented the requested optional subscription promo-code controls in the canonical Market UI and server source: immutable percentage offers, monthly/annual eligibility, first payment/ongoing duration, expiry, per-code controls and a master switch. Database permissions, revision checks and audit are applied only to Market. Controls default off and fixture records are rolled back. Existing referral rewards do not stack; invoice payments and existing subscription plan-change paths remain separate.

Full offline validation: 257/257 passed. Hosted Stripe checkout is **not activated** in Market: real sandbox checkout/webhook/renewal and authenticated visual acceptance are still release gates. Previously issued discounted payment pages have a disclosed 31-minute validity window after disabling an offer; existing accepted discounts continue. See `docs/v62.24-market-subscription-promotions.md` for the exact supported scope and validation limits.

Next core work remains the shared opening-paid authority and controlled starting-balance conversion; the existing part-paid native-import guard stays in place until that complete accounting path is verified. Leave/self-service, approvals and commercial acceptance remain open. No unrelated legacy files were deleted in this increment.


## v62.25 import evidence checkpoint

The opening-paid investigation identified import evidence integrity as a prerequisite. Review replacement and final decisions/confirmation now run as single database transactions with parent-batch locks, expected-revision checks and permission rechecks. Completed batch evidence is immutable, including against an older privileged importer. Both old and current Smart Migration confirmation paths reject incomplete source-row membership. This is not the opening-paid accounting correction itself.

Initial staging no longer depends on capped INSERT response rows or hash-to-ID lookup. All raw rows and logical records have explicit distinct IDs, remapping reads every page, and preview counters use exact database counts. A source file with more than 1,000 rows no longer silently becomes a partial review. Completed-duplicate classification is owned by the atomic database review; the obsolete Edge profile-write helper and overlapping duplicate-query path were removed.

Market migrations: `20261017222107_market_atomic_import_review.sql` and `20261017222437_market_import_evidence_completeness.sql`, and `20261017223412_market_import_requires_review.sql`. Full offline suite: 268/268. Database rollback fixtures cover failed second-sheet/decision rollback, stale reviews, repeated confirmation, foreign callers, completed duplicates, incomplete evidence and immutable completed evidence. True simultaneous multi-session load and authenticated browser acceptance remain additional gates.

A fixture exposed a pre-existing business-deletion bug: `v58_financial_audit_trigger` can insert an audit row after its business has been deleted, violating `financial_audit_log_business_id_fkey`. No real business was deleted; fixture changes rolled back. Record this as a separate scoped lifecycle fix; do not disable auditing to suppress it.

Initial upload/staging is still a multi-request operation; a failed upload may leave an incomplete staging batch. Such a batch cannot pass the new evidence-completeness confirmation check, but automatic abandoned-upload cleanup is not implemented here. Part-paid native imports and starting-balance posting remain blocked. Shared opening-paid authority, conversion posting, leave/self-service and approvals remain open, as do provider and commercial acceptance gates.

Reopening an analysed batch from history now returns to column mapping. New staging batches carry an explicit unreviewed marker; both old and new confirmation endpoints reject that marker until the atomic Build review step has applied duplicate classification. The history route and both database rejection paths are covered by regression fixtures.


## v62.26 payroll consistency checkpoint

Market-only migrations `20261017224555_market_atomic_leave_hours.sql` and `20261017230343_market_atomic_payroll_review.sql` are applied. Hours history, balance and audit now save together. Employee-detail saves no longer run the overlapping balance upsert. Corrections require a reason and the loaded balance revision. Statutory day/week balances are shown read-only in this hours editor; their existing workflows remain separate.

Pay-run employees, payment lines, payslips and financial entries now save in one transaction. Repeated requests reuse one identifier; stale versions are refused. Optional second-person approval defaults off. An owner/admin with Payroll write access can enable it; the preparer cannot approve their own run, changed saved evidence invalidates approval, and approval finalises through the existing ledger-posting function. Existing finalised-child locks are retained; their old payslip-only field access bug is corrected.

Full offline gate: 290/290. Managed-database rollback fixtures cover failure mid-bundle, retry, stale revisions, business boundaries, invalid amounts/timesheets, missing payslips, closed/uncovered pay dates, approval-off finalisation, preparer rejection, changed-evidence rejection and exactly-once posting. Fixtures leave no saved operations, reviews, settings or test businesses. This is not a simultaneous load test or authenticated visual acceptance.

Still open: shared opening-paid authority and controlled conversion posting (31 database functions traced); remaining statutory day/week multi-request saves; employee self-service; remaining settings writers; access recovery/MFA acceptance; practice dashboard; receipt email intake; asset and contractor/owner work; isolated Stripe checkout/webhook/renewal testing; restore rehearsal, real-device and accountant/payroll acceptance. The roadmap is not complete. See `docs/v62.26-market-payroll-save-review.md`.
