# Settings consolidation: implementation contract

Status: partially implemented in isolated Market v62.21. See `v62.21-market-reliability.md` for implemented commands, tests and remaining boundaries. This contract is not a claim that every historical consumer or payroll/onboarding setting has migrated.

## Ownership and compatibility

| Domain | Authority | Current consumers that must move together | Historical rule |
| --- | --- | --- | --- |
| Profile | Business profile columns, with an explicit legal/trading-name contract | Account profile, Invoice Settings, document defaults, onboarding | Existing issued document/company snapshots remain unchanged |
| NZ/AU GST | Effective-dated tax settings and existing tax RPCs | Financials tax editor, GST summary, invoice/quote/expense defaults, payroll identifier fallback review | Preserve effective dates, filed returns and document tax snapshots |
| Bank accounts | `bank_accounts`, including archive/default state | Banking, invoice/quote default bank selectors, setup bank fields | Existing document payment instructions remain as issued |
| Sales presentation | A bounded sales-settings JSON projection | Invoice Settings and quote/job document defaults | Changes apply to new drafts or an explicit editable-draft refresh |
| Payroll employer | Explicit payroll employer configuration | Payroll settings and filing validation | Finalised pay runs and generated filing evidence remain unchanged |
| Identity/team/plan | Auth, memberships and subscriptions | Central account/team/billing screens | Never rewrite login email from a public business contact field |

Country is `settings.country`; do not invent a competing `countryCode`. Payroll jurisdiction may have a documented override. Standard GST rates come from statutory rules, not independent free-form fields.

## One command and one success result per domain

Implement separate, narrow commands for profile, tax and banking. Proposed function names are design placeholders, not APIs that exist today:

* `v6221_save_business_profile`: only legal/trading name, address, phone and public business email plus explicitly allowed presentation fields.
* `v6221_save_tax_settings`: delegate to the existing jurisdiction-specific tax command and update required current projections inside the same database transaction.
* `v6221_save_bank_account` / `v6221_set_default_bank_account`: validate ownership, archive state and currency; update account/default state atomically.

For each command:

1. Derive the current business and active membership on the server. A supplied business ID is never authorization. Preserve existing area permissions, including suspended and read-only cases.
2. Lock the business/domain revision, compare the expected revision and reject a stale save before writing. Return an actionable conflict; do not silently overwrite another tab's changes.
3. Validate an allowlist of fields and all tenant links. Prefer invoker rights; if existing protected operations require a definer wrapper, pin its search path, revoke PUBLIC/anon access and test authorization inside it.
4. Commit the authority, required compatibility projections, revision and redacted audit event in one transaction. Raise on any failure, so none of the writes commit partially.
5. Return the canonical saved projection and new revision. Only then update browser caches, clear dirty state and show success.

Replace the app.js settings click handler and saas.js delayed 100-ms second writer together. Do not simply delete the cloud writer while leaving a local-only success toast. Do not accept arbitrary settings JSON or client-supplied role/security fields in a generic privileged RPC.

## Bank compatibility migration

1. Read JSON and account-table rows for each tenant without changing either.
2. Normalize account identifiers for comparison. Review conflicts, missing rows, duplicate identities and default choices. A similar name or count is not proof of equivalence.
3. Make legacy setup fields read-only when Banking becomes their editor. Provide a clear link to Banking and an explicit import/review step for JSON-only legacy accounts.
4. Import only a reviewed missing account through the new command. Never unarchive an existing account as a side effect of reading or saving unrelated settings.
5. Read table accounts for new invoice/quote defaults. Snapshot the chosen instructions when a document is issued. Retain historical snapshot readers.
6. Stop the remaining explicit `syncSettingsBankAccountsToBanking` writer only after all consumers use the new contract. v62.20 removes the independent Banking page-load writer, but intentionally leaves this compatibility writer until that switch is verified.

Default switching must serialize concurrent requests. Clearing one default and setting another must be one transaction, with a business-scoped uniqueness rule if suitable after existing data is checked.

## GST conflicts

The re-audit found two mismatches between business JSON and agreeing financial/tax-history records. Do not copy actual identifiers automatically or pick the newest value by timestamp. Record the authoritative owner-confirmed decision, effective date, impacted current projections and audit evidence. Never rewrite filed or issued historical records.

## Customer numbering

Use a separate idempotent create command with a client request UUID, business-row/advisory serialization and server numbering. Reusing the same request UUID must return the same created customer after a lost response. Check for possible duplicates on the server; allow a deliberate override for legitimate shared names or contacts. Review existing number conflicts before adding a business-scoped unique constraint. Do not impose unique customer names or merge existing customer records automatically.

## Required tests before switching writers

* Owner/admin/accounting/read-only/suspended and cross-tenant direct API cases.
* Two tabs saving the same revision; two concurrent default switches; request retry after a lost response.
* Failure injection after each internal write: no partial saved profile, tax projection or bank default.
* Blank-field clearing, NZ/AU registration boundaries, effective-date changes and unchanged issued-document output.
* JSON-only bank setup, archived accounts, multiple currencies and invoice/quote default selection.
* Business switch during load/save and dirty-form navigation on desktop and mobile.

Run shadow comparisons of reads before switching a consumer. Do not shadow-write financial records. Record unresolved differences and keep the old reader available during a defined compatibility window. Delete old inputs/writers only when their replacement is verified; dropping old fields/tables is a later migration with its own dependency and retention checks.

## Cleanup boundaries

The CSS cascade, invoice post-render action wrapper, Settings DOM relocation, duplicate Community loading, voice paths, overlapping applied migrations, customer unique-index dependencies and old payroll fallback tables remain separate work items. Their appearance, names or current usage statistics do not prove that they are safe to remove. Preserve applied migration/audit history and avoid `DROP CASCADE` cleanup.


## v62.27 implemented domain commands

The canonical Payroll editor now reads its settings and three editable lists in one database snapshot through `v6227_get_payroll_settings`. `v6227_save_payroll_settings` updates the existing settings, pay-item, leave-type and document-type rows in one transaction with the loaded settings revision. It preserves fields outside the editor, including statutory leave codes and historical snapshots. List edits advance the same parent revision. Bulk saves cannot create arbitrary item IDs or move rows between businesses.

`v6227_payroll_catalog_command` owns add/archive actions, with a request identifier, exact retry matching, business/permission checks and audit. Archived rows are retained. `v6227_save_bank_preferences` owns matching tolerance/confidence changes, with permission/module checks and a revision-checked audit transaction. The obsolete direct browser mutation grants for these five tables are revoked in Market. The default-seeding and business-creation database functions retain their existing privileged operation. Root legacy JavaScript remains retained and is not the Market runtime.

This closes these two remaining editor save paths; it does not finish the entire settings inventory, resolve owner-confirmed historical GST conflicts, redesign employer IRD/GST fallback semantics, or consolidate provider/team settings.
