# Unified Money In & Out entry hub

## Scope

The approved layout and three equal recording buttons remain. Record money in/out now opens a
searchable transaction chooser. Transfer retains the existing shared transfer form.

Routes reuse existing entry points:

- Invoice receipt: choose an issued outstanding invoice, then the existing Record Payment modal.
  Balances use the same credit-aware calculation as Invoices; original posting remains unchanged.
- Supplier payment: choose a recorded bill with credit-adjusted outstanding balance.
- Supplier refund: choose a recorded supplier credit and use its refund form.
- Customer refund: open existing Invoices > Refunds, preserving available-credit checks.
- GST payment/refund: choose a posted unsettled GST return in the selected direction; open the
  existing settlement form for that source. Wages and payroll IRD use the same source selection.
- New sale or purchase: open the existing invoice or expense workflow, with existing GST, split
  lines and account selection. These do not silently create documents or payments.
- Grants, income tax, loans, investor capital, owner funds, deposits and interest retain the
  shared cash forms, idempotent save, journal writer and bank match links.
- Other receipt/payment retains eligible non-control categories and explicit no-GST guidance.
- Split/advanced transactions, refundable customer security deposits and distributions open
  guidance with the existing Manual Journals route. Existing owner/admin/accountant permissions
  remain mandatory. These are not new automatic asset/dividend/customer-deposit subsystems.
- Asset sale guidance routes the sale/receipt through Invoices for tax handling, and distinguishes
  the accountant disposal adjustment from the bank receipt to avoid double counting.

## History

The history now shows all posted bank receipts/payments from `frindly_cash_ledger`, grouped once
per journal/bank. Existing shared cash journals link directly to their durable transactions.
Other rows open a source detail view; invoice/supplier payments resolve their original document
under tenant-scoped queries. Refunds route to existing refund sections. Opening balance journals
are omitted; Cash Book retains balances and Statement of Cash Flows retains grouped reporting.
Posted payment data is not recreated, and operational estimates are never substituted if the
ledger query fails. Dates, bank filter, direction, search and pagination apply to history.

## Permission and tenant protections

The chooser checks the existing Financials write permission. Source RPCs, tables and original
forms retain their own permissions and validation. Asynchronous choices and adapter calls check
business identity. Linked dialogs refresh history on closure only for the same business. Chooser
navigation creates no financial records. No schema, RPC, grants, historical data or posting engine
changes are part of this release.

## Verification

Live read-only function inspection confirmed the existing GST/refund settlement and manual-journal
entry points; manual journals enforce accounting access, same-business accounts, open periods and
balancing. No customer rows were changed or used as test transactions.

Isolated database regressions passed for shared cash posting, reconciliation, tax/loan/interest,
transfers, security, settlement payments/refunds, overpayment, retry and period locks. Browser
regressions covered linked route selection, GST direction separation, original dialog dispatch,
no write RPCs during navigation, permission denial, tenant change, history aggregation, paging,
mobile/desktop layout, and the existing GST/payroll payment dialog. Syntax and diff checks passed.

## Boundaries

Special transactions continue to need an authorised accounting user and may require several
linked steps. This release provides their starting route; it does not claim fully automated
accounting for arbitrary asset disposals, dividend tax or customer-deposit applications. No new
unrestricted posting endpoint is exposed to ordinary users. Live source-data completeness and
deployment are separate from fixture-based checks.
