# Frindly helper workflow knowledge refresh

The typed Helper and Live Voice now share one identical, versioned catalogue: `2026-11-07-workflow-catalogue` (69 topics). This replaces the deployed 23-topic catalogue and the still older repository copies.

## Coverage

Dashboard/reminders; onboarding; invoice creation, payments, corrections, reminders and templates; customer records/statements; quotes and progress billing; job costing; scheduling/navigation/recurrence/payroll time; multipage expense capture, drafts, business/private allocations, supplier bills/payments/credits/refunds; purchase review/orders; stock, quantities, jobs and equipment; employees/timesheets/pay runs/payslips/leave/IRD filing; bank imports, matching, transfers and undo; Money In & Out; loans and direct supplier finance; owners/shareholders/capital changes; GST refunds/payments/reversal/basis review; P&L/Balance Sheet/Cash Book/ledger/budgets/planning; accountant exports/manual journals/year-end review; business/account/bank/team/billing settings; migration; Community; referrals; support and authorised administration.

Every topic has source file references in `tests/helper/knowledge-sources.json`. The catalogue contains exact current navigation, verified capabilities, workflow steps and important boundaries. It distinguishes posted transactions from plans, bank matching from payment recording, filing packages from external filing, and actual functionality from test/preview pages or merely listed optional integrations. It contains no tenant/customer records.

## Scope retained

No frontend, chat/voice UI, model, provider adapter, authentication, JWT configuration, business context RPC, subscription/allowance/cost gate, usage logging, business-data write engine or retrieval algorithm was changed. Production `index.ts` files were read before deployment and copied byte-for-byte into source because repository versions were stale. Their pre-refresh hashes and deployment metadata are in `tests/helper/runtime-baselines.json`. Existing production `verify_jwt=false` is preserved; both functions perform their existing authenticated-user and active-business checks internally.

The existing database instruction text, personalised helper names and creator facts are retained. The new guidance uses Frindly consistently and preserves permissions, tenant isolation, no financial actions, no background-work promises, evidence review and non-duplication rules.

## Validation

Six test groups pass: identical typed/voice content and source references; primary-query retrieval for all 69 topics; 16 cross-module questions for newer features; byte-identical production handlers; real handler prompt assembly with isolated mock provider/auth/database adapters; and unauthenticated/wrong-business denial without provider calls. Tests verify the same provider/model/usage paths remain. No paid provider requests or genuine customer transactions are needed for these checks.

This is knowledge coverage and runtime-contract testing, not a guarantee that a language model will answer every possible wording correctly or evidence of real-device audio testing. The selector still sends a bounded three-topic packet for typed questions; Live Voice receives the catalogue when a new session starts. Uncertain tax/legal/accounting decisions remain outside the helper's role.

## Release and maintenance

Publish the catalogue with the unchanged production handlers to both `finlo-helper` and `finlo-live-voice-session`; retain internal auth and existing JWT flags. Read back both deployed sources and verify the knowledge version/content and handler hashes. Typed answers use the new knowledge on the next request; an existing Live Voice session must be ended and restarted to receive refreshed instructions.

For future features, add/update the relevant facts, keywords, steps and source references in both identical knowledge files and extend retrieval examples. Knowledge does not automatically stay current merely because an app screen changes. Recover an incorrect knowledge release by redeploying the prior catalogue with the same production handler; do not roll back unrelated runtime/auth code.

Production verification: typed Helper version 13 and Live Voice session version 14 are ACTIVE. Read-back confirmed exact new knowledge, byte-identical pre-refresh handler code, and preserved JWT configuration. Twelve existing helper subscription/access cases also pass. No genuine business records or model-provider sessions were created for testing.
