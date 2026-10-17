# Frindly Market — isolated development environment

Status: database and source prepared locally. GitHub publication was blocked by automatic approval review; the first website publication also awaits the Netlify/GitHub connection and Auth redirect check.

## Environment

| Component | Target |
| --- | --- |
| Website project | [Frindly Market on Netlify](https://app.netlify.com/projects/frindly-market) |
| Website project ID | 2b57d35f-1627-4e0a-82f0-d1817966b606 |
| Intended website URL | https://frindly-market.netlify.app — not published yet |
| Supabase project reused | smvvevrtjqkflyqkyape |
| Current Supabase dashboard name | finlo-v6170b-isolated-test |
| Database region | Sydney, ap-southeast-2 |
| Prepared local branch | market/frindly-market; publication to GitHub needs explicit approval |
| Version | v62.20-market-foundation |
| Source baseline | v62.20-rc1 / 5fb34c1957b751424bc8f6655754eb53f2d84a89 |

The user selected reuse of the existing isolated project after creation of a third free project was blocked. No project was paused, deleted or upgraded. The live Supabase project, Main branch, Dev configuration and live Netlify deployment were not modified.

Use this branch only with the Frindly Market site. Future production feature changes should be promoted separately, retaining the production environment configuration.

## Database work completed

A read-only snapshot of the production application schema was compared with the existing test project. The missing definitions were applied to the test project in reviewed stages.

Verified matching production definitions:

- 214 tables and 2,963 columns, including types, nullability and defaults.
- 377 database functions, with matching definition hashes.
- 1,251 constraints and 246 standalone indexes.
- 188 triggers, 497 policies across public/storage and the existing export view.

Execute permissions for anon, authenticated and service_role were also compared and aligned with the production function ACLs. The older test project had service-role omissions and a few additional grants; these were corrected only in the test project.

Test-only tools were retained. The resulting test project has 217 public tables, 425 public functions, 478 public policies and 21 storage policies. All 217 public base tables have RLS enabled.

The bootstrap also created the six required storage buckets and their limits. No production storage files were copied.

The 206 original test records were preserved. Snapshot checks over the original columns verified their integrity before reference-data seeding. The only later record additions to original tables were 17 business-tax rules and 43 payroll rules. Existing tax-rule rows were retained; no business, invoice, expense, payment, payroll or journal record was imported from production.

The eight existing Auth users and the existing business were preserved. Passwords, sessions and production provider credentials were not copied.

## Services and isolation

The Market browser configuration uses only the test project's publishable key. Both client-creation entrypoints are constrained to that project, and auth sessions have a Market-specific storage key.

The build:
- rejects a production project reference or privileged key in published files;
- refuses to build under the live Netlify site ID;
- produces dist-market with a Content Security Policy allowing test database/Auth/storage routes and four reviewed internal functions;
- blocks email, payment, bank, OCR and other provider routes;
- adds a test banner and no-index headers.

Nine existing test Edge handlers were replaced with an explicit HTTP 503 MARKET_OUTBOUND_DISABLED response:
send-invoice, send-quote, send-payslip, business-invite, referral-invite, scan-expense-document, invoice-payments, stripe-webhook and receipt-recovery-worker.

The replacements do not read request bodies or provider secrets and do not make provider requests. They deliberately report an unavailable service rather than claiming an email was sent or payment was taken.

Deterministic Smart Migration remains available. The test import function's optional AI path has no provider key/model lookup, so enabling its argument cannot make an OpenAI request.

The three existing expense assessment/correction functions were retained. Their clients use the test project's own Supabase URL; no external posting bridge was found in these handlers.

Production Cron jobs and the pg_net/pg_cron extensions were not copied. The test project has no automatic production email/payment/bank job configuration.

Market's browser policy blocks signup/recovery/OTP email routes. Existing password sign-in remains available. Hosted Auth redirect settings still need review before publication; this is distinct from the document-email handlers already disabled on the server.

## Verification

- 36 frontend JavaScript syntax checks passed.
- 30 focused hardening tests passed.
- 16 Market isolation tests passed, including exclusion of legacy Netlify schedules.
- SQL rollback tests passed for own-business read/write; customer isolation in both directions; cross-business update/insert rejection; balanced journal posting; unbalanced journal rejection; foreign-business account rejection; closed-period rejection; cross-business journal read rejection; and fixture cleanup.
- All fixture rows were rolled back. Audit sequence gaps may occur normally during rollback tests.
- Real API checks returned the test environment marker, denied anonymous expense access, and returned MARKET_OUTBOUND_DISABLED for quote-email/payment requests.
- Full offline suite: 163 tests, 124 passing and 39 failing. The named failure set exactly matches the existing baseline's 39 failures; no new failures were introduced.
- Existing security-adviser categories remain, including search paths, definer-function review and leaked-password protection. This setup is not a full security or payroll/tax certification.

The lower-level journal engine remains executable only by postgres/service_role. Public journal actions use the authorised wrapper.

## Deployment settings

For the existing Frindly Market Netlify project:

- Repository: damionrod/SmallBizInvoiceApp.
- Branch: market/frindly-market.
- Base directory: repository root.
- Build command: node scripts/build-market.cjs.
- Publish directory: dist-market.
- Visitor access: Netlify team login, all deploys. This has already been applied and verified.
- Environment secrets: none copied from the live site.
- Netlify Functions: explicitly use ops/market/netlify-functions-disabled; no legacy scheduled handlers are deployed.
- Node: use the current supported Node 24 runtime for the checks.
- The .netlify directory is gitignored.

The initial source commit skips automatic Netlify builds so adding this branch cannot trigger the old site's branch deployment. Start the first build manually on Frindly Market after linking the repository.

Before publication, set/review the isolated Supabase Auth Site URL and permitted redirects for the Market URL. Keep Google OAuth off. Confirm existing test logins work; a live-product password is not automatically a test-project password.

The available Netlify connector can create and protect the site, but does not expose repository linking or first publication. The user has approved the browser fallback for those remaining steps. The existing Netlify account still needs to be signed in within the shared browser; an external browser session does not authenticate it.

The user explicitly approved uploading the prepared branch, schema records, configuration and rollback sources to damionrod/SmallBizInvoiceApp. The CLI has no GitHub credentials and the connected GitHub integration lacks write permission. The complete source was uploaded through the verified damionrod browser session, using only market/frindly-market and commits that skip automatic Netlify builds. The full GitHub tree matched the checked local source exactly (application commit 03d77d9e484c6564f087d487d1d85ab6961af7f3, tree 317d07aa238a5cbc514977d50b07a91aafdaf037). The Frindly Market isolation GitHub Actions run 39022231319 passed. Main and the live Netlify deploy were verified unchanged. Main and Dev are outside this deployment scope.

## Bootstrap and future work

The files under ops/market/bootstrap are one-off test-only bootstrap records, generated with Supabase CLI migration names and applied through the migration tool in smaller batches. They are deliberately outside the normal production migration directory. Their guard requires the existing isolated-test harness.

Do not replay the bootstrap blindly; verify the current catalogue first. Historical production migrations were retained, and this work did not remove old application paths without a dependency review.

Next: complete hosting/Auth setup, run authenticated desktop/mobile browser checks, then continue the scoped hardening programme. The provisional-tax date defect, settings ownership consolidation, broader permission coverage, known test failures and security-adviser review remain subsequent work.
