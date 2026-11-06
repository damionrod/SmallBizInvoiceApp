# Conservative cleanup — 6 November 2026

This first pass removes four unused declarations from the published browser
source and clarifies the current source/deployment layout. It does not attempt
the larger archival or stylesheet changes identified by the review.

## Runtime changes

| File | Removed declaration |
|---|---|
| `public/app.js` | `hexToRgb` |
| `public/compliance-reminders.js` | `monthEnd` |
| `public/dashboard.js` | `skeleton` |
| `public/financials.js` | `addMonths` |

No callers, HTML handlers or API exports were found for these declarations in the
active source review. Other functions with the same names in other modules,
including required date arithmetic functions, remain intact.

An AST comparison against the preceding source removed only the named
FunctionDeclaration from each baseline syntax tree and compared the remaining
nodes with the changed file, excluding location metadata. All four comparisons
matched. The runtime diff consists of exactly four declaration-line deletions.

## Repository housekeeping

- Replace the support-console-only root README with an application source map,
  local startup instructions, test guidance and deployment boundaries. Preserve
  the support-console reference through its existing function README.
- Add ignore rules for local dependencies, Python caches and generated browser
  test reports. These rules do not remove tracked files.

## Verification

- All published `public/*.js` files passed `node --check`.
- The seven payroll-date/navigation browser tests passed.
- Six invoice/payroll error UX tests and three invoice-option tests passed.
- The local GST/dashboard fixture, cash/accounting database fixture and
  settlement database fixture passed.
- Five synthetic NZ payroll and seven NZ leave/final-pay cases passed.
- Four invoice-address/PDF cases, the Cash Book/bank-grouping browser case and
  dashboard monetary-value fixture passed using the isolated fixture updates
  documented by the preceding failure triage. Original historical test files
  were not rewritten or assertions removed in this cleanup.
- `git diff --check` passed.

That is 37 Node test cases/file-level fixture runs. Database fixtures contain
multiple assertions within their file-level run. These are local/mocked checks,
not certification of all live workflows. No production records were used or
changed.

## Deferred

Retain root legacy copies, the `v6171b/` snapshot, standalone public preview/test
pages, CSS layers and migration history. Their removal needs separate usage and
regression checks. The compliance-monitor syntax defect noted by the review is
also a separate repair item and is not modified here.

No accounting/posting rules, database schema, permissions, business links,
payroll calculations, financial records or deployment configuration changed.
