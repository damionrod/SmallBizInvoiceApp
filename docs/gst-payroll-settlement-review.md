# GST and payroll settlements — release verification

Release authorised by the owner on 2 November 2026 after verification of the historical discrepancies. The final migration passed a rollback-only check against the production schema; isolated PostgreSQL, browser/mobile and dashboard tests passed again. Deployment status is recorded in the release update below.

## Historical wages resolved

Two existing employee bank allocations together equal their pay run’s original net-wages bank credit. The original posted payroll journal already credited bank, and both reconciliation audit events explicitly record `legacy_bank_posted=true` with no additional journal. These are intentional matches to a bank credit already posted by payroll, not missing wage-payment journals.

The draft derives wages payable from original payroll journals, recognises this legacy bank-credit treatment separately and prevents another wage settlement. Modern pay runs derive wages and statutory balances from the original liability accounts, including older account 265 with account type `current_liability`.

## Release blocker found in saved GST history

A read-only comparison of finalised GST snapshots with net posted GST source movements found:

One finalised return agrees exactly. Two historical finalised returns do not agree with their posted GST source movements; one is a zero saved return and the other is an older positive return. Financial amounts and source IDs are intentionally omitted from this repository report.

The older positive return has no stored `accounting_basis`. This does not establish why it differs. The frozen return, source transaction history, adjustments and any external filing evidence must be traced before deciding on an accounting correction. Do not overwrite finalised returns or create a balancing journal merely to make these numbers agree.

The owner has verified the historical discrepancies and authorised release. Historical records are preserved. Settlement still rejects a saved GST return that differs from its posted source movements; owner verification does not bypass the posting guard or create a balancing adjustment.

## Draft application changes

- `public/liability-payments.js`: shared expense-style modal; default linked bank; full/partial settlements; GST refund; multi-run IRD allocations; history; recorded-payment bank matching; retry token and double-click protection; stale-business guard.
- `public/payroll.js`: wages and IRD settlement actions on finalised runs, on desktop and mobile.
- `public/financials.js`: payment/refund action on saved GST returns. Source calculation and finalisation logic is unchanged.
- `public/bank-reconciliation.js`: GST/payroll create-or-match action, existing IRD action routed to allocation workflow, unmatch preserves the recorded settlement.
- `public/dashboard.js`: net input GST against GST payable when displaying money to reserve. Payroll continues to use posted liability balances.
- `public/saas.js` and `public/index.html`: load the shared module and refresh affected script versions.
- Expense payment source code, invoice source code, payroll calculations, entitlements, tax rules and payslips are unchanged.

## Draft database changes

The Supabase CLI generated the migration file; its filename was aligned with the authoritative applied Supabase migration version: `supabase/migrations/20261102014924_gst_payroll_settlements.sql`. The reviewed migration has been applied successfully.

New tables:

- `public.liability_payments`: request token, date, selected bank, amount, direction, reference, journal and actor.
- `public.liability_payment_allocations`: GST-return/pay-run allocation to the original mapped account.

Existing table extensions:

- `public.bank_transactions`: narrowly extended reconciliation-type constraint.
- `public.bank_reconciliation_allocations`: payment link, composite tenant FK, unique match index, narrowly extended type constraint, controlled-write validation trigger.

New private-schema functions:

- `frindly_settlement.assert_access`
- `frindly_settlement.obligations`
- `frindly_settlement.snapshot`
- `frindly_settlement.record_payment`
- `frindly_settlement.reconcile`
- `frindly_settlement.unmatch`
- `frindly_settlement.guard_bank_allocation`
- `frindly_settlement.guard_payrun_reversal`
- `frindly_settlement.guard_payroll_journal_reversal`

New public security-invoker RPC wrappers:

- `frindly_settlement_snapshot(text,uuid)`
- `frindly_record_liability_payment(uuid,date,uuid,text,jsonb)`
- `frindly_reconcile_liability_payment(uuid,uuid,uuid,jsonb)`
- `frindly_unmatch_liability_payment(uuid,text)`

Existing function changes:

- `v61109_reconcile_payroll_bank_transaction`: legacy bank-credit branch retained; modern settlement delegates to the shared journal/payment path; additional legacy over-allocation guard.
- `v61109_reconcile_payroll_ird_bank_transaction`: refuses unallocated settlement and directs callers to the allocation workflow.

Additional source guards prevent reversing a settled pay run or its accrual underneath active settlement journals. Existing accountant journal reversal remains the correction mechanism; unmatch alone never reverses a payment. The existing `v6192_create_posted_journal` engine is reused unchanged. No accounts are created by this workflow and no historical records are backfilled.

New tables enable RLS and deny direct anonymous/authenticated table access; permission-checked private functions serve public invoker wrappers. Payroll/financial access is checked independently of banking entitlement. Bank matching additionally requires bank write access. Original accounting periods, dates, mapped bank and liability balances, source allocations, tenant identity and actor are checked on the server. Matching an existing payment creates no second journal. Undoing a match preserves payment and audit history.

## Verification actually performed

Local PostgreSQL (PGlite) used disposable synthetic businesses, current production table columns and journal/GST/bank CHECK constraints, current authorisation functions, the existing journal writer and current journal/bank allocation triggers. No dummy transactions were created in customer businesses.

Passed:

1. Draft SQL compiles in the local PostgreSQL fixture.
2. Legacy bank-posted wages reject another payment.
3. Filed GST and finalised modern payroll retain unpaid obligations.
4. Partial/full GST, outstanding reduction, request replay and overpayment rejection.
5. GST refund debits the chosen bank and credits GST receivable.
6. Partial/full wages debit the original net-wages liability.
7. Partial IRD allocation across multiple runs; over-allocation rejected.
8. Locked payment period rejected.
9. Cross-business source/bank access rejected using current access functions.
10. Manual-first bank matching and unmatch preserve journal/payment without reposting.
11. Bank-first settlement creates one shared payment.
12. All fixture journals balance.
13. Settled payroll and its accrual cannot be reversed underneath payments.
14. GST snapshot/source mismatch rejects settlement.
15. Net GST settlement does not recreate source accruals.
16. Authenticated RPC access works while direct payment-table access is denied.
17. Actual Chromium dialog test at 390px: linked/default/alternate bank, amount validation, partial/historical date, double click, retry, refund, history, multi-run allocation, legacy guard, stale-tenant guard and matching an existing payment.
18. Dashboard calculation before/after partial and full settlements.
19. JavaScript syntax and whitespace checks.

A rollback-only production-schema compilation was also executed successfully before the final additional guards, and the historical source was recognised as bank-posted with zero wages outstanding. The transaction was rolled back. A subsequent read confirmed no new payment table persisted. The complete final migration subsequently passed another rollback-only production-schema compatibility check, identifying both new tables and all four RPC wrappers.

Selected existing regression suites: 19 checks, 9 passed and 10 failed. An unchanged checkout of the same main commit produced the exact same failing test names and pass/fail counts. These failures predate this draft; this does not constitute a clean full-application regression pass.

## Remaining work before release

- Historical discrepancies: verified by the owner; preserve existing records and retain the source-ledger settlement guard.
- Final production-schema compatibility and isolated test suites: passed.
- Review full-app regression coverage, including the pre-existing suite failures; no signed-in end-to-end test of the deployed application has been performed.
- Verify concurrent requests using independent PostgreSQL connections; local tests cover sequential request replay, double-click and balance limits, not multi-session concurrency.
- Bank matching currently matches a complete recorded settlement to one bank line. Split a real transfer into separate recorded payments when it will appear as separate bank lines. Existing legacy wages matches remain in the existing mechanism.
- Commit the authorised release to main, apply the generated migration and verify the Netlify Git CD deployment. See the release update for completion status.

Run local tests from `tests/settlements` after `npm ci` using `npm test`. In restricted hosts, `SETTLEMENT_CHROMIUM_PATH` may point to an extracted Chromium binary. Tests do not use production credentials or production transaction rows.

## Release update

Owner verification cleared the historical-data release hold on 2 November 2026. Migration `20261102014924_gst_payroll_settlements` applied successfully. Post-migration checks confirmed both new tables have RLS enabled, anonymous/authenticated direct table writes remain denied, and both tables contain zero records. No historical payments, journals or GST returns were backfilled. The security advisor reported the expected no-policy informational notices for the two RPC-only tables. Main/Netlify publication is being verified.
