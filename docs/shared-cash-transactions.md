# Shared non-standard cash transactions

Money In & Out is the entry point for grants, income tax, bank interest, loans,
owner funds, refundable deposits and bank transfers. Ordinary invoices, expenses,
GST and payroll retain their existing payment workflows. Money In & Out now routes to these existing forms and lists posted bank movements.
See `unified-money-entry.md` for the expanded chooser, history and advanced-workflow boundaries.

## Accounting and reconciliation

- Manual recording requires Financials write permission, not Banking entitlement.
- Statement matching also requires Banking write permission and the module.
- All postings use `v6192_create_posted_journal`; bank GL IDs come from bank mappings.
- `cash_transactions` is the durable source. `cash_transaction_legs` links bank
  movements to journals; reconciliation allocations reference a unique leg.
- New rows are read-only through the table API. Controlled RPCs enforce tenant,
  permission, precision, date, balance and duplicate-request checks.
- Grants and interest use `other_income`, which the existing production P&L engine
  includes. Loan interest uses an expense account; principal remains a liability.
- Company income tax uses an existing mapped income-tax payable/paid account where
  available, otherwise an Income Tax Paid asset. Personal tax uses owner drawings.
- Owner funding/repayments retain the existing owner current-account register.
  Existing owner reconciliation RPC names now delegate to the shared workflow.
- Transfers use two bank legs and a single mapped clearing account. This allows
  independent statement dates and either-side-first matching. Clearing is excluded
  from operating cash flows and disclosed as transfers in transit.
- Matching an existing leg creates no payment or journal unless its date changes.
  A date change reverses at the old date and reposts the identical allocations at
  the statement date. The original date, original journal, reversal and replacement
  remain auditable. Both accounting periods must be open; affected finalised/filed
  GST periods block the change.
- Unmatching preserves the transaction and all journals. Reversing a transaction
  requires unmatched legs, open periods and a reason. Settled funding/deposit
  balances cannot be reversed underneath their repayments/returns.
- GST-bearing NZ grants feed the existing authoritative GST calculation/save path.
  No-GST grant receipts do not create GST. Tax treatment must be confirmed against
  the agreement; grant-specific income-tax/depreciation adjustments remain subject
  to accountant review rather than automatic assumptions.
- New purpose accounts are resolved by mapping/name and created only on first use
  under a business transaction lock. Ambiguous/mismatched existing accounts stop
  posting. No account IDs are hard-coded. No historical entries are migrated.

## Frontend changes

- `public/cash-transactions.js`: shared dialog, entry/detail/history, matching,
  bank-only ledger projection, summary and linked tax-payment history.
- `public/financials.js`: uses posted bank movements for Money In & Out and includes
  the new non-standard income/loan-interest effects in existing management estimates.
- `public/bank-reconciliation.js`: suggestions, shared create/match, owner/transfer
  entry points and preservation on unmatch.
- `public/advanced-business-features.js`: linked income-tax payment shortcut/history.
- `public/dashboard.js`: cash movement reads the shared posted projection.
- `public/index.html`, `public/saas.js`, `public/styles.css`: wording, script loading,
  cache versions and scoped mobile styling. Other modules retain their entry forms.

## Database migration

`supabase/migrations/20261102064121_shared_cash_transactions.sql`

New public tables: `cash_transactions`, `cash_transaction_legs`.
Existing allocation table: adds `cash_leg_id`, unique match index, controlled-write
trigger, and the cash allocation type. Bank statement type check is extended too.
`bank_accounts` gains a Financials SELECT policy; Banking write access is unchanged.

New public invoker RPCs:

- `frindly_record_cash_transaction(uuid,jsonb)`
- `frindly_match_cash_transaction(uuid,uuid,uuid,jsonb)`
- `frindly_unmatch_cash_transaction(uuid,text)`
- `frindly_void_cash_transaction(uuid,text)`
- `frindly_cash_snapshot()`
- `frindly_cash_ledger(date)`

New private schema `frindly_cash` owns access/date checks, account resolution,
posting orchestration, matching, audited corrections and the bank-only read model.
Its internal helpers cannot be called directly by client roles.

Existing functions narrowly updated:

- `v61106e_reconcile_owner_equity_bank_transaction`
- `v61107w_reconcile_owner_current_account`
- `v61106e_undo_owner_equity_bank_transaction`
- `v61107w_undo_owner_current_account`
- `frindly_gst_boundary_basis_v1`
- `v61114_statement_cash_flows`

The existing journal writer, invoice/expense/payment engines and payroll/GST
settlement RPCs are unchanged. Existing journals and historical transfer markers
are not rewritten. Normal use creates existing journal/audit/owner-register rows.

## Verification

Install pinned test dependencies with `npm ci --prefix tests/settlements`, then:

```
node --test --test-concurrency=1 tests/settlements/*.test.cjs tests/v6190-purchase-review.test.js
```

Database tests use isolated PGlite instances with the current schema, permissions,
posting engine and immutability guards. External GST source calculation/configuration
and Banking entitlement use explicit harness contracts. The unchanged production
P&L function is included as a fixture. No dummy customer financial transactions are
created in production. Browser tests run headless Chromium at a 390px mobile viewport.

Coverage includes manual/no-Banking posting, alternate banks, balanced journals,
owner balances, income tax, withholding, loan splits, deposit returns, grant GST,
P&L and cash-flow effects, transfers, both statement sides, retry safety, duplicate
prompts, date corrections, locks, filed GST, cross-business isolation, table write
protection, reversal, and existing settlement/purchase-review regression tests.

The broad root test suite has pre-existing failures on unchanged main (47 failures
out of 123 tests), including stale historical source assertions and harness issues.
Compare changed-code failures to that baseline rather than representing the entire
legacy suite as passing.

## Deliberate boundaries

- Statement matching for these transactions is one bank movement to one recorded
  leg; invoice/expense split/group matching remains its existing workflow.
- Transfers and manual bank postings use the business currency. Foreign-currency
  conversion is rejected until an exchange-rate workflow exists.
- GST-bearing general receipts are NZ-only; unsupported tax configuration is blocked.
- Historical payments before a bank's posted opening date require opening-history
  review rather than posting a second movement already included in opening balances.
- Existing historical transfer flags are not automatically converted to new postings.
- Loan/deposit balances need their correct opening records; the workflow blocks
  principal/deposit settlements exceeding the recorded balance.

## Release and recovery

Run the focused suite and baseline comparison before release. Apply the additive
migration before publishing frontend changes through the existing Git/main Netlify
process. Verify RPC permissions, published assets and the existing bank-group totals.

If an issue is found after transactions exist, fix forward. Preserve cash records,
match links and journal history; do not drop tables or deploy an old generic unmatch
path that would delete payment records. Disable the new entry controls if necessary
while correcting the specific problem. Production customer records are never test data.
