# Frindly v61.95 Performance and Mobile UI Audit

## Scope

This pass was intentionally limited to the app shell and shared UI behavior. It did not change accounting, GST, payroll, invoice/payment, Stripe, banking, reporting, export, database, RLS, role, tenant, or entitlement logic.

## Proven Issues Found

1. Heavy optional browser libraries were loaded in the document head without `defer`.
   - `jsPDF`, `jspdf-autotable`, `html2canvas`, `Chart.js`, and `JSZip` are only needed for exports, PDFs, charts, or ZIP generation.
   - Loading them during initial parsing can delay first render.

2. Mobile navigation had competing layout rules.
   - Existing CSS had several mobile `nav` column-count overrides, including 4, 5, 6, and 7 column variants.
   - This made the mobile header/menu feel inconsistent and cramped as modules were enabled.

3. Busy/disabled button styling was inconsistent.
   - Many workflows already disable buttons during save/process actions, but shared visual treatment was not consistent.

## Fixes Made

1. Deferred optional browser libraries in `public/index.html`.
   - This reduces parser blocking while preserving the same libraries and export/PDF/chart behavior.
   - Supabase remains non-deferred so auth and business context behavior is unchanged.

2. Added one consistent mobile app shell.
   - Added a `Menu` button in the existing top bar.
   - Reused the existing primary navigation and hidden states, so module visibility still follows current role and entitlement logic.
   - The mobile menu opens as a compact drawer and closes after navigation, outside tap, or Escape.

3. Added shared disabled/busy button styling in `public/styles.css`.
   - Existing save/process logic is unchanged.
   - Disabled or `aria-busy` buttons now have consistent visual feedback.

4. Added regression coverage in `tests/v6195-performance-mobile-shell.test.js`.
   - Confirms optional heavy libraries are deferred.
   - Confirms the mobile shell/menu hook exists.
   - Confirms shared busy button styles exist.

## Files Changed

- `public/index.html`
- `public/app.js`
- `public/styles.css`
- `public/financials.js`
- `tests/v6194-gst-simplification.test.js`
- `tests/v6195-performance-mobile-shell.test.js`
- `PERFORMANCE-UI-AUDIT-v61.95.md`

## Verification

- `node --check public/app.js` passed.
- `node --check public/financials.js` passed.
- `node --test tests/*.test.js` passed, 15/15.
- File count after this pass: 96.

## Test Limitation

The local sandbox blocked starting a test HTTP server, and Playwright's browser binary is not installed in this environment. No browser binary was downloaded or installed. The mobile shell was verified through static regression tests and syntax checks only in this pass.

## Deferred Larger Work

The following should be handled as a separate measured pass:

- Real browser network timing on the deployed Netlify preview.
- Supabase query timing and index review using production/staging query evidence.
- Module-level lazy loading for large local app files.
- A full design-system cleanup across every module.
- Save/action idempotency audit across every workflow.
