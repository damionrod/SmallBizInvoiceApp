# Money In & Out entry workspace — 3 November 2026

## Source findings

Netlify publishes `public/`; similarly named root files are older copies and are not deployed.
`Financials.renderCashFlow` delegates to `CashTransactions.render`. Previously that renderer loaded
`frindly_cash_ledger` and displayed both a balance summary and every bank ledger line, duplicating
Cash Book. Shared cash transactions already have durable transaction IDs, bank legs, journal links
and reconciliation allocations. `frindly_cash_snapshot` supplies those records under existing
Financials permissions. No new table, RPC, journal, or permission is required for this layout.

## Changes

- Recording buttons and existing dialogs lead the page; wording distinguishes invoice, expense,
  payroll and GST workflows. The incoming purpose question now asks where money came from.
- Removed the duplicate balance summary and ledger-wide history from this page only.
- History uses the existing snapshot and includes recorded shared transactions from either entry
  point; excludes reversed transactions, ordinary supplier/customer payments and payroll settlements.
- Existing Financials period controls move above history and return on tab navigation. There is
  only one date state; date selection remains intact when opening reports. Dates filter bank legs,
  so transfers with different sending/receiving dates remain accurate.
- Bank ID, direction/type and description/reference/amount search filter the list. Twenty account
  movements per page; paired transfers retain both bank legs, with a shared transaction detail link.
- Mobile cards, plain descriptions, existing View details and report navigation buttons.
- Cash Book and Statement of Cash Flows use their existing More financial reports buttons.
  Bank filtering remains local to this history; no new report filter or reporting logic was added.
- UI resources receive updated cache version strings.

## Accounting investigation boundary

The screenshot totals differ by $136.34, matching its displayed payroll cash-flow line.
Source confirms different selection criteria: the old page's ledger RPC joins active bank mappings
and legacy links; Statement of Cash Flows also recognises cash/bank account metadata. Cash Book
uses its existing bank grouping/alias helper. This establishes a scope difference, not which live
journal is responsible. Zero receipts cannot be diagnosed from screenshots or fixtures alone.
No live database access is available in this task, so no historical postings, balances, account
mappings or customer receipts were altered. Live receipt/journal tracing remains outstanding.

## Verification

Passed JavaScript syntax and diff whitespace checks. Existing database regression suite passed
against the current schema fixtures: posting and selected accounts, idempotency, permissions,
GST grant evidence, interest withholding, loan splits, transfers, reconciliation, date corrections,
period locks and reversals. Updated mobile browser regression passed: existing dialogs and matching,
duplicate protection, incoming entries, exclusion of ordinary payroll rows, paging 45 movements,
search resetting pagination and repeated date-control relocation. Existing bank grouping regression
passed for Dashboard and Cash Book. Browser fixtures use 390px width, not a live customer session.
