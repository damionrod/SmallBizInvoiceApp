# Share Buyback and Return of Share Capital

## Forensic findings

Netlify publishes `public/`. Money In capital receipts resolve the permanent-equity account via
`frindly_cash.owner_account(...,'capital_contribution')`; this resolver is reused, not replaced.
Shareholders are existing `business_owners` rows with `is_shareholder`, status, ownership, share class,
share quantity and effective date. Temporary owner loans use a liability and owner current-account
entries; permanent capital payments must not reduce that loan register.

`frindly_cash.record` is the shared entry point for manual and bank-first recording. It enforces
Financials write access, business locks, open periods, selected mapped bank, currency, precision,
request-id idempotency and audit. `frindly_cash.lines` supplies allocations to the unchanged
`v6192_create_posted_journal`. One cash transaction has one bank leg and one journal for these payments.
Reconciliation allocations link the existing leg. Normal same-date matches do not post a journal.

Cash Book and Dashboard use posted bank/account mappings. Balance Sheet sums actual equity account
balances and retained profit. P&L filters income and expense types; Statement of Cash Flows classifies
equity counterpart postings as financing. None of these reporting engines require modification.

## Minimal changes

- Add `share_buyback` and `return_share_capital` to the existing Money Out purpose list/chooser,
  including the existing bank-first recording dialog.
- Reuse the existing cash form, bank picker, duplicate warning, save/match/view/reversal RPCs and links.
- Store approvals and explicit allocation rows in the existing immutable `request_payload` and audit
  record. No new transaction table, duplicate posting engine or automatic chart creation.
- Extend the existing snapshot with permitted capital users, existing active shareholders and eligible
  equity accounts. Extend the existing line builder for these two purposes only.
- Keep amounts/date/approval/allocation validation server-side as well as form validation.

## Accounting and safeguards

Both entries debit approved equity allocations and credit the selected bank once. They carry NO_GST
and zero GST amount; no operating P&L line or owner-loan entry is generated. A buyback can split its
approved consideration across share capital and other eligible equity accounts; no allocation is
preselected. Return of Share Capital must use the same mapped permanent-capital account as Money In.
Debits to that account cannot exceed its posted credit balance at the payment date.

New entries require NZ company configuration, existing Financials write and accounting access, an
active same-business shareholder on the date, resolution reference/date, adviser, share/class or
capital-reduction details, allocation note, and explicit authorisation/solvency/tax-review confirmations.
Approval must precede or equal payment. Opening-balance equity, drawings, control, archived,
foreign-business, bank, expense and liability accounts are rejected. Allocations must be positive,
two-decimal, distinct, and sum exactly to the payment. Existing request retries remain idempotent.

This is the completed-payment route, not an approval service or legal/tax opinion. If withholding
requires additional posting, or the equity reduction has already been accrued as a payable, this
form blocks recording and directs the user to the existing accountant workflow. It does not infer
available subscribed capital, dividend treatment, imputation or RWT/NRWT. Separate transaction fees
remain in their existing expense workflow.

A same-date match reuses the existing bank leg without reposting. Capital date mismatches stop for
accountant correction, rather than automatically reversing/reposting an authorised capital payment.
Existing ordinary cash date-correction behaviour is unchanged. Reversal requires accounting access,
open periods and no bank match. Reversing an underlying capital receipt is guarded when a recorded
capital payment would leave insufficient posted capital.

Ownership percentages and share quantities are not changed by a payment alone. The linked confirmation
step below updates Settings only after explicit legal completion; statutory register and Companies
Register maintenance remain separate.
This avoids turning payment entry or bank unmatching into an unreviewed ownership transfer.

## Validation

The migration was compiled in isolated PGlite against current tables, triggers and journal guards.
Tests cover split buyback (capital + retained earnings), capital return, exact bank/equity changes,
unchanged P&L and owner-loan register, zero GST, actual production Balance Sheet balance, financing
cash-flow reporting, Cash Book ledger projection, one journal/idempotent retry, bank-first recording,
same-date matching with no extra journal, no-repost date guard, unmatch preservation, reversal,
capital availability, company/shareholder/account/tenant isolation and required confirmations.
Accounting permission is checked even for a staff member explicitly granted Financials write.
New private helpers are not executable by client roles.

Browser tests cover both chooser entries, no default equity allocation, shareholder-only selection,
required approvals, mismatch/tax blocking, selected bank and shared save RPC payload, return-capital
form, ordinary form reset, permission denial, and 390px/1440px layout. The existing settlement, shared
cash, bank grouping, dashboard, invoice/expense route and reconciliation regression suites are run.
No production financial records are created or rewritten for testing.

## Primary references

- XRB NZ IAS 32, paragraph 33: consideration for own equity instruments is recognised directly in
  equity, without gain/loss in profit or loss: https://standards.xrb.govt.nz/standards-navigator/nz-ias-32/
- Companies Act / own-share acquisitions and solvency requirements:
  https://www.legislation.govt.nz/act/public/1993/0105/latest/DLM323508.html
- Companies Office / distribution certificates:
  https://companies-register.companiesoffice.govt.nz/help-centre/shares-and-shareholders/distributions-to-shareholders/
- IRD / share sales usually GST exempt: https://www.ird.govt.nz/income-tax/income-tax-for-businesses-and-organisations/buying-or-selling-a-business/tax-on-share-sales
- IRD company return guide, share-repurchase dividend/available-subscribed-capital considerations:
  https://www.ird.govt.nz/-/media/project/ir/home/documents/forms-and-guides/ir1---ir99/ir4gu/ir4gu-2025.pdf

## Linked ownership confirmation

Existing capital payment details now offer Confirm / review shareholding change. The existing
Settings owner edit dialog links back to that person's capital payments. These features and purposes
are company-only (NZ backend enforcement); sole traders and proprietors are excluded.

A separate confirmed event stores the legal date, document/approval reference, quantities, full
before/after snapshots and links to existing cash transactions in private, RLS-enabled tables.
The existing owner/history RPC performs the updates atomically. No journal writer is called.

The guided cancellation route supports a complete, single-class register with explicit quantities,
reduces the selected holder by the confirmed shares, and recalculates each holder's percentage using
the remaining issued shares. Full exit sets zero shares/ownership and removes the shareholder flag,
without resigning a director or clearing owner-loan balances. Unknown quantities, mixed classes,
treasury shares, cancelling every share, future legal dates and changes before later recorded
ownership changes are blocked for accountant handling. The completeness confirmation includes all
issued shares; Frindly does not infer these from investment dollars or claim to maintain every
statutory-register requirement. Capital-only returns leave quantities/percentages unchanged.

Additional payments can link an existing compatible event in the payment form or from payment
details, including payments to a former shareholder explicitly linked to their confirmed acquisition.
A payment cannot link two events. Request retries and stale previews are guarded. A previously
accrued full equity reduction must still be settled through the existing accountant payable route.

Reversing a linked payment flags the event for review without undoing a legal acquisition. Authorised
company users can record their accountant's review and replacement-payment arrangement to clear
the flag; that audit action does not change shares or create a journal. Any actual legal rescission
requires a separate dated ownership correction through existing Settings/accountant tools.

The shareholder summary uses the existing dated before/after owner history once linked events
exist, includes former holders and calculates profit-share estimates by ownership interval using the
existing management P&L. Earlier periods retain earlier holdings. Ordinary businesses without linked
events retain their existing calculation. This is an ownership-based estimate, not a dividend
declaration or entitlement determination for special share rights.

Live storage checks confirm both tables have RLS, deny direct authenticated reads/writes, and reject
anonymous confirmation. Covering FK indexes and explicit RPC-only deny policies are installed.
The security advisor reports the four intentionally authenticated SECURITY DEFINER RPCs; these
perform existing membership/business/permission checks and expose no direct table grants. New
unused-index informational notices are expected before the feature has real records.
