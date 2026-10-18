# Conversion posting contract — proposed, not approved

18 October 2026. Market-only preparation. This document records the remaining implementation contract; it does not authorise or certify a posting.

## Evidence now available

The Starting balances review compares the source trial balance, existing ledger and dated document/settlement summaries. Its JSON download retains source mappings, all returned evidence, discrepancy items and a snapshot hash. It does not include original source-file bytes or individual bank-statement evidence. The hash covers the returned review evidence; it is not a global database revision or permission to post.

## Required conversion inputs

| Input | Required treatment |
| --- | --- |
| Cutover date and currency | Explicit business-local start date and one supported base currency; foreign currency requires a separate reviewed FX model |
| Source trial balance | Exact debits/credits, complete account mapping, fiscal-year context and source closing/report date |
| Individual invoices and bills | Original totals, tax, dates, party and remaining obligation; distinguish actual money received/paid, credit allocations, discounts, write-offs and other settlement |
| Prior GST | Source accounting basis, effective registration history and which amounts were already returned; do not infer this from a current registration flag or a generic `paid` column |
| Control detail | Receivables/payables including customer/supplier credits and refunds must reconcile to their source control balances |
| Bank | Statement closing balances at cutover, including reconciliation differences; imported movements alone cannot establish opening balances |
| Other balances | Reconcile assets/depreciation, stock, loans, owner accounts, payroll liabilities, GST and retained balances to their existing owners |
| Approval | Accountant-reviewed treatment and a reconciled sample conversion before enabling posting |

IRD's accounting-basis guidance distinguishes payments, invoice and hybrid timing. Source: https://www.ird.govt.nz/gst/registering-for-gst/which-gst-accounting-basis-and-filing-frequency-should-i-use (reviewed 18 October 2026). Changing software must not silently change the GST basis or duplicate amounts already returned.

## Proposed implementation boundaries

1. Preserve completed source evidence. Introduce one immutable opening-settlement authority linked to the completed import record and the native document, after classifying cash, credits and other settlement. Do not represent prior settlement as a new Frindly bank payment.
2. Preserve original document details for ongoing collections/payments. Mark opening documents so every legacy/current posting path recognises their conversion treatment. Do not let a later repair/backfill post the original historic revenue/GST again.
3. Use one controlled conversion transaction: validate source membership, permissions, period, currency, mappings, source/control reconciliation and unchanged financial evidence; insert the opening journal and authority together; audit and return the same result on exact retries.
4. Define prior-year retained balances and current-year trading separately. A difference between an all-history ledger and a source trial balance is not sufficient authority to post. Historical source invoices posted into an earlier year can otherwise distort current-year profit when an offset is posted at cutover.
5. Record normal post-cutover payments against the outstanding document, using the existing payment ledger owner. Refunds and credits must consume the same opening-settlement authority and retain their own evidence and permissions.
6. Update every payment guard/refresher, credit/refund limit, AR/AP report, statement, bank matching, correction preflight, posting/backfill and tax calculation that consumes settlement. Thirty-one related functions were identified; changing only a display field or first insert is insufficient.
7. Keep payments/GST treatment explicit. A source `paid` total may include credit or discount adjustments. Payments-basis tax needs reliable dated cash treatment; invoice-basis history needs protection against reporting historic tax again. Unsupported/unknown source treatment stops conversion.

## Acceptance before enabling

- Reconcile source trial balance, native open-document detail, bank statement balances and opening journal exactly in cents.
- Cover part-paid and fully unpaid documents, advances, credit balances, refunds, mixed settlement types, prior/current fiscal years, NZ invoice/payments/hybrid basis, registration changes and mid-period cutover.
- Reject cross-business links, revoked/read-only access, changed source or ledger, duplicate commit and incomplete source membership.
- Prove transaction rollback and exact retry, then simultaneous multi-session behavior.
- Prove normal future payment, credit/refund, bank undo, corrections, statements, GST and year-end behavior use the same authority.
- Preserve issued documents, filed returns, existing journal history and audit. No synthetic historic cash and no silent data rewrite.

The read-only v62.28 check is implemented. This posting contract and its remaining accounting treatment are not yet implemented or approved. The native part-paid import and posting gates stay closed.
