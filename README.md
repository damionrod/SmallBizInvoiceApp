# Frindly

Frindly is a small-business application with invoicing, expenses, payroll,
banking and financial reporting. This guide identifies the current deployment
sources so fixes are made in the files the application actually uses.

## Authoritative source locations

| Location | Purpose |
|---|---|
| `public/` | Published browser application, including `index.html`, modules, styles and assets |
| `netlify.toml` | Netlify configuration; publishes `public/` |
| `supabase/functions/` | Supabase Edge Functions and their shared modules |
| `supabase/migrations/` | Ordered database migration history; preserve existing migrations |
| `supabase/config.toml` | Checked-in Edge Function configuration |
| `netlify/functions/` | Scheduled wrappers which call the compliance-monitor endpoints |
| `tests/` | Automated checks, browser fixtures and local database fixtures |
| `docs/` | Feature notes, investigations and implementation reports |

The browser loads some modules dynamically through `public/saas.js`; a script
need not appear directly in `public/index.html` to be required. Check imports,
loaders, event handlers, HTML and exported APIs before removing code.

Root-level browser copies and `v6171b/` contain older packaging/snapshot sources.
They are retained for historical reference and are not the source published by
the checked-in Netlify configuration. Do not copy them over `public/` or deploy
them without reviewing differences. Versioned deployment notes and old test
reports describe their original releases, not current verification results.

## Run locally

On Windows, use `START-FINLO-LOCAL.bat` or `START-FINLO-LOCAL.ps1`. Both serve
`public/`. With Python installed, an equivalent command from the repository root
is:

```bash
python -m http.server 8765 --directory public
```

Open `http://localhost:8765/`. Use an HTTP server rather than opening HTML files
with a `file://` URL. Application features still require the configured backend
and appropriate account access.

## Validation

Use Node.js 24 for the existing Node/TypeScript fixtures. From the repository root,
a dependency-free regression check is:

```bash
node --test tests/invoice-payroll-error-ux.test.js
```

Browser and local database fixtures use the dependencies pinned under
`tests/settlements/`:

```bash
npm --prefix tests/settlements ci --ignore-scripts --no-audit --no-fund
```

For browser fixtures, set `SETTLEMENT_CHROMIUM_PATH` to a compatible Chromium
executable when one is not installed in Playwright's default location. Then,
from that directory:

```bash
cd tests/settlements
npm test
```

Some historical tests use outdated asset tags, labels or isolated mocks. A
failure needs investigation; do not weaken accounting, permission or posting
assertions to obtain a green run. Passing source-pattern checks or mocked/local
fixtures does not certify a live end-to-end workflow. Read the individual test
before running it: some separate tests require a disposable authenticated
project.

## Change and deployment boundaries

- Make browser changes in `public/`; review asset versions where needed.
- Preserve tenant isolation, permission checks, posting/idempotency guards and
  recorded financial history.
- Keep database migration history intact. Add a reviewed migration when a schema
  change is required.
- Test Edge Functions separately before deployment. A frontend deployment does
  not itself verify or deploy Supabase functions and migrations.
- Check the actual deployment status before claiming a change is live.

The support console is an isolated, Super-Admin-authorised Edge Function for
customer/account checks, recovery/verification email actions and sanitised
operational diagnostics. See
[`supabase/functions/support-console/README.md`](supabase/functions/support-console/README.md)
for its function-specific documentation.

See [`docs/cleanup-first-pass.md`](docs/cleanup-first-pass.md) for the limited
November 2026 cleanup scope and verification.
