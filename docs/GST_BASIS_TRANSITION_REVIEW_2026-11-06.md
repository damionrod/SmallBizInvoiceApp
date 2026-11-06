# GST basis transition safety review — 6 November 2026

> This report records the baseline before the staged build. See `GST_BASIS_CHANGE_STAGED.md` for the subsequent preview/request implementation and its remaining limitations.

## Baseline delivery status

**The requested feature is not implemented or deployed.** No runtime frontend changes, live database migrations, historical settings changes, journals, adjustments or genuine business transactions were made during this review. Main was inspected at commit `43ede9a60ee82c0cbc1af42988ef044a1ee9fb26`; other work may advance main independently.

This is a baseline investigation and a reproducible isolated test harness, not an acceptance report for a completed feature. The brief explicitly requires stopping rather than deploying a partial or potentially incorrect accounting solution. The results below do not support a safe rollout of the requested automatic workflow.

## Verified regulatory rules

Authoritative rule: IRD, **GST plus IR546, March 2026, printed page 4**, and GST Act sections 19B and 19C. Outstanding balances are measured at the end of the preceding taxable period. IRD confirms the effective date; changing a preview must not imply IRD approval. All amounts below are GST portions, not gross debtors or creditors.

| Change | Net debit (+) / credit (-) adjustment |
|---|---|
| Invoice to Payments | Creditors GST minus debtors GST |
| Payments to Invoice | Debtors GST minus creditors GST |
| Invoice to Hybrid | Creditors GST |
| Hybrid to Invoice | Negative creditors GST |
| Payments to Hybrid | Debtors GST |
| Hybrid to Payments | Negative debtors GST |

These formulas are conditional on eligible, supported and previously reported transaction evidence. A universal subtraction of previously reported GST from subsequent payments is not an adequate implementation. For example, Invoice to Payments requires a transition credit, after which the later payment is included under Payments. Merely excluding that payment omits the required transition treatment.

Sources inspected:

- https://www.ird.govt.nz/gst/changing-your-filing-frequency-or-accounting-basis/changing-your-gst-accounting-basis/change-your-gst-accounting-basis
- https://www.ird.govt.nz/-/media/project/ir/home/documents/forms-and-guides/ir500---ir599/ir546/ir546-2026.pdf
- https://www.legislation.govt.nz/act/public/1985/141/en/latest/
- https://central.xero.com/0/article/Select-or-update-your-GST-settings
- https://www.myob.com/au/support/myob-business/end-of-period/month-end-procedures/changing-your-accounting-basis

Xero documents outstanding receivable/payable reports, a cut-off lock and GST return adjustments. MYOB warns about omissions and duplication and allows selecting the NZ basis during return preparation. Neither source justifies automatically treating a dropdown change as an authorised historical change.

## Existing components inspected and retained

Read the actual live definitions of:

- `public.v6170e_gst_settings`
- `public.frindly_gst_calculate_basis_v1`
- `frindly_cash.gst_base`
- `public.frindly_gst_boundary_basis_v1`
- `public.frindly_save_gst_basis_v1`
- `public.v6170e_set_gst_settings`
- `public.v6170e_create_gst_adjustment`
- Existing finalised-return guards.

Inspected the live columns for GST settings, adjustments, returns, invoices, customer payments, expenses, expense payments, customer credits, supplier credits, assets, cash movements and IRD filing batches. Read frontend basis selection, rendering, finalisation and settings callers in `public/financials.js`. Checked Supabase logs and security/performance advisors read-only. No unrelated advisor issues were changed.

There is no second calculator in the test harness: it executes captured live function definitions in an isolated PostgreSQL-compatible PGlite database.

## Reproduced baseline failures

Fixture: September sale $1,150 including GST $150; September supplier bill $460 including GST $60; both unpaid at the 1 October transition. No credits, discounts, estimated dates, foreign currency or private use are needed to reproduce these failures.

| Case | Required net adjustment | Current result | Outcome |
|---|---:|---:|---|
| Invoice to Payments | -$90 | $0 | Fail |
| Payments to Invoice | $90 | $0 | Fail |
| Invoice to Hybrid | $60 | $0 | Fail |
| Hybrid to Invoice | -$60 | $0 | Fail |
| Payments to Hybrid | $150 | $0 | Fail |
| Hybrid to Payments | -$150 | $0 | Fail |

All six also lack a blocking review for the missing reconciliation.

Three additional failures were reproduced:

1. **Double counting:** the September invoice is included under Invoice and its November payment under Payments, producing $300 output GST across the two calculations, with no $150 transition credit. Correct cumulative output tax after the required transition credit and later payment is $150.
2. **Unsafe finalisation:** `frindly_save_gst_basis_v1` finalises the October return despite the missing basis-transition reconciliation when called with Business Default (`p_basis = null`).
3. **Historical settings mutation:** `v6170e_set_gst_settings` changes the October basis after the October return is finalised. Existing guards protect the return row, but do not protect the effective-dated settings that influence later calculations and screen presentation.

Two limited control checks passed:

- Repeating each calculation gives identical results.
- Switching the fixture business context returns none of the first business's sales.

The fixture permission predicates are explicit stubs. The business filter check is **not** a full RLS, permissions or authentication test.

## Further verified gaps

- Frontend `renderGst` requests a fresh calculation even for a saved finalised period. It reads status from the saved row, while the displayed figures come from the current calculation. The immutable stored snapshot is not the authoritative source for that screen.
- `frindly_cash.gst_base` segments dates according to registration and basis but does not construct debtor/creditor wash-ups at changes.
- `v6170e_create_gst_adjustment` creates a return adjustment without posting a general-ledger journal. No transition-specific journal policy or duplicate safeguard was found in that function. Reusing it must be accompanied by an explicit, tested treatment of GST control/deferred balances; blindly adding another invoice or expense journal would be wrong.
- Saved return snapshots contain source evidence, but missing snapshots cannot establish what was actually filed externally. Estimated customer payment records are already blocked by the calculator and must remain blocked.
- Cash-basis credit/refund timing already has blocking warnings; these cannot safely be removed to make transition tests pass.

## Fixfast read-only verification

The principal record created on 27 September 2026 still has 39 invoices, 90 expenses, zero saved GST returns and zero GST adjustments. Its recorded basis settings are Invoice from 28 September, Invoice from 29 September and Payments from 27 October. There is also a separate empty Fixfast record.

**Neither record was changed.** The absence of saved returns is not evidence that nothing was filed in myIR. No automatic historical correction or transition adjustment for Fixfast can be considered verified without prior filing evidence, the intended correction-versus-authorised-change decision, and an IRD effective date where relevant.

## Exact rollout blockers

Before the complete feature can be safely deployed, implementation and testing must resolve all of the following together:

1. **Authoritative prior reporting evidence:** transaction-level attribution to filed snapshots or an audited external-filing/import process; unresolved historic evidence must block finalisation.
2. **Explicit authorisation and cut-off:** correction versus genuine IRD change, approved date/evidence, all affected period conflicts and immutable basis-change audit records.
3. **Six-way transition reconciliation:** actual payment allocations, credits, refunds, reversals, business use, repeated changes and already-reported tax. Missing or ambiguous evidence must remain visible and blocking.
4. **Atomic confirmation and deduplication:** settings and existing adjustment creation must succeed or fail together, with deterministic transition identity, concurrency safeguards and detection of changed evidence after confirmation.
5. **Filed-period protection:** settings writes, screen rendering, externally filed records and server finalisation must all preserve the same original snapshot.
6. **Accounting integration:** establish and verify the correct relationship between transition-only return adjustments, existing invoice-basis journals and settlement controls. Do not manufacture a duplicate operational journal.
7. **Acceptance coverage:** execute the full requested edge-case, browser/mobile and adjacent accounting regressions. Those tests have not yet run.

These are unresolved implementation blockers, not proof that the feature is impossible. The baseline harness is insufficient to claim that any replacement implementation satisfies them.

## Files created locally

- `tests/gst-basis/inspect-current.cjs` — isolated baseline audit runner.
- `tests/gst-basis/fixtures/current-tables.sql` — column types captured from live schema, excluding real data and table policies/constraints.
- `tests/gst-basis/fixtures/current-functions.sql` — captured calculator/save/settings/adjustment definitions for reproducibility and recovery reference.
- `tests/gst-basis/baseline-results.json` — actual observed results.
- This report.

Run from repository root with the existing pinned settlement-test dependencies available:

```bash
NODE_PATH=tests/settlements/node_modules node tests/gst-basis/inspect-current.cjs
```

The runner reports observed failures as JSON; exit zero means the audit completed, **not** that product acceptance passed. It never connects to the live database.

## Deployment, regression and rollback

- New implementation tests: **not run**, because no replacement implementation is complete.
- Baseline: **9 reproduced failed requirements; 2 limited controls passed**.
- Full invoicing, expenses, payroll, bank reconciliation, Cash Book, GL, P&L, Balance Sheet and tax reporting regression: **not run for this development**. No assertion is made that these workflows were verified.
- Production deployment: **none**.
- Main feature commit: **none**.
- Runtime files modified: **none**.
- Database migrations applied: **none**.
- Rollback required: **none**.
- Current feature acceptance: **not met**.
