# Frindly v61.99H — Mobile navigation consolidation

This build applies the targeted mobile UI findings without changing business logic.

Changes:
- Consolidated mobile `.topbar`, `#mobileMenuBtn`, and `#primaryNav` positioning/state into one authoritative CSS layer.
- Removed obsolete v61.95/v61.98P/v61.99A nav positioning/state declarations while retaining unrelated mobile shell styles.
- Removed older module-specific mobile `nav:has(...)` rules that could override the primary navigation when Admin, Job Costing, Expenses, or Payroll were enabled.
- Changed the four Dashboard/Schedule breakpoints from 759px to 760px.
- Removed dead `toggleMobileNav()` and duplicate `closeMobileNav()` ownership from `app.js`; `mobile-shell.js` is the sole mobile navigation state controller.
- Removed the obsolete 18px mobile body-bottom rule; the current 24px safe-area-aware rule remains.
- Bumped mobile shell asset versions to `61.99H-nav-consolidated`.

No accounting, database, GST, payroll calculation, scheduling data, permissions, entitlements, subscription, or desktop workflow logic was changed.

## v61.99I — dark navigation redesign (navigation-only)
- Restyled the desktop top navigation to the requested dark navy gradient (`#12263f` → `#0b1c30`).
- Added consistent inline line icons to every existing navigation item and Account without adding an icon dependency.
- Kept existing nav order, IDs, data attributes, hidden/entitlement behavior and routing hooks unchanged. The Stock & Equipment nav label is shortened to **Stock** only; its aria label remains **Stock & Equipment**.
- Rebuilt the mobile drawer as one authoritative navigation block in `styles.css`: dark navy, single-column, white icon+label rows, 48px minimum touch targets, contained scrolling and safe-area positioning.
- Removed older mobile nav/header/button declarations from `styles-core.css` and older mobile Account positioning from `styles.css`; retained unrelated mobile page, popover, helper and toast rules.
- `mobile-shell.js` behavior is unchanged apart from the version comment: outside click, Escape, nav-item close and resize/orientation close remain intact.
- Scope intentionally excludes page content, app-wide primary/secondary/danger buttons, cards, tables, forms and business logic.
- The four pre-existing Dashboard/Schedule `max-width:759px` rules are intentionally left at 759px in this build, per task scope.

Validation: all public JS passes `node --check`; CSS braces balance. Existing Node test suite: 67/70 pass. The 3 failures are legacy source-shape/cache-tag assertions (`v6195-performance-mobile-shell` expects removed `app.js` nav wrappers and old 61.98L stylesheet tag; `v6198j-schedule-drag-drop` also expects that old stylesheet tag), not runtime/business-logic failures. Automated Chromium viewport interaction was attempted but Chromium hung in this container, so no browser interaction pass is claimed.


## v61.99J — navigation spacing refinement
- Navigation-only change from v61.99I.
- Main desktop nav spacing tightened slightly (9px horizontal padding, 5px icon gap).
- Referral shortcut label changed in navigation only to **Share & Save** and moved beside the Frindly brand, outside the primary module item group. Existing `#referralShortcut` ID and entitlement/show-hide behavior are preserved.
- Desktop account control is forced to a true 42x42 circle.
- Mobile top bar accommodates the same entitlement-controlled referral shortcut without changing page content or business logic.
- No page, form, table, business logic, routing, entitlement logic, or non-navigation button styles changed.


## v61.99L — transparent top navigation logo
- Navigation-logo-only fix.
- Removed the legacy generic `.brand img` white background/border/radius/shadow from the Frindly product logo only.
- The supplied PNG/WebP alpha transparency is preserved so the navy navigation bar shows directly behind the logo.
- No navigation behavior, spacing, entitlement logic, page content, business logic, or other images were changed.


## v61.99N — Zoho-inspired typography only
- UI font changed to Lato, with Zoho Puvi in the fallback stack where locally available.
- Lato is loaded from Google Fonts; no proprietary Zoho font files are bundled.
- No layout, navigation, page content, controls, business logic, routing, permissions, calculations, database, or module behavior changed.
- Intentional monospace and invoice-template display fonts remain untouched.


## v61.99O — Unified Frindly visual system
Style-only refresh across existing pages/modules based on the approved bright/navy dashboard reference. Standardises page hierarchy, cards, buttons, forms, tables, tabs, badges, modals and responsive spacing. No DOM workflow, database, entitlement, routing or business-logic changes. Mobile rules preserve 44px+ controls and responsive stacking.


## v61.99Q — Dashboard reference refinement
- Style-only follow-up to v61.99P.
- Added a subtle repeated finance/success watermark icon background to the Dashboard using an embedded SVG pattern (no external dependency).
- Reduced Dashboard heading, action, metric and supporting text sizing to better match the supplied reference and improve density.
- Preserved all DOM structure, IDs, events, logic, navigation, permissions, entitlements and workflows.
- Added a new stylesheet cache key.


## v61.99S — Reference consistency pass
Style-only refinement: much smaller irregularly scattered finance/success watermark field across all app views; dashboard scale tightened; dashboard quick-action buttons aligned to supplied reference; common page/card/action styling harmonised; mobile rules retained. No business logic, permissions, routing, data, workflow or entitlement changes.


## v61.99T — Launch-ready UI forensic consistency pass
Style-only release. Removes competing dashboard watermark backgrounds, installs one global micro-watermark pattern with intentionally irregular placement/scale/rotation, standardises compact typography, controls, cards, tables, rows/columns, page headers and spacing, and preserves >=44px mobile touch targets. No application/business logic or DOM workflow changes.


## v61.99X — Colourful Schedule
- Schedule-only visual refresh based on the supplied reference.
- Added soft per-day header colours and varied pastel job-card colours.
- Unscheduled cards use a restrained purple treatment.
- Active Day/Week state and New Job retain a clearer blue treatment.
- Existing seven-day viewport fit from v61.99U is preserved.
- No schedule markup, IDs, data logic, drag/drop, filters, recurrence, permissions, or mobile day-first behaviour changed.


## v61.99Y — Simplified Payroll Report
- Reorganised Reports > Payroll into one compact report toolbar, payroll summary, and employee detail table.
- Added Last month / 3 / 6 / 12 month shortcuts using the existing payroll report date inputs and existing report renderer.
- Moved Download CSV beside Payroll Details.
- Preserved all existing report IDs, calculations, finalised-pay-run filtering, employee/job filtering, CSV export and payroll data logic.
- Removed no data and changed no payroll calculations.
- Responsive two-column/mobile controls and summary cards; touch targets remain mobile friendly.


## v61.99Z — Payroll Report Centre
- Replaced the single overloaded payroll report with four simple views: Monthly Payroll, Allowances & Reimbursements, Employee Payroll, and PAYE & Deductions.
- Default reporting is month-first with previous/next month and This month controls.
- Removed Job from the visible general payroll reporting workflow; the existing hidden control remains for compatibility.
- All figures are derived from existing finalised pay runs, payroll run employee totals, and existing pay-run lines. No payroll calculation or persistence logic changed.
- CSV export now follows the selected payroll report view.
- Existing payroll report IDs needed by the module are retained.
- Responsive mobile report tabs, filters, summary cards and tables included.


## v61.100A — Compact Invoice & Expense Lists
- Desktop invoice and Bills & Expenses tables now fit within the available page width without horizontal scrolling.
- Existing columns, values, actions, statuses and row functionality are unchanged.
- Uses fixed column allocation, smaller desktop table typography/padding and compact action controls only.
- Long customer/supplier text truncates visually with ellipsis rather than expanding the table.
- Existing mobile list/card presentation and mobile breakpoints are unchanged.


## v61.100D — Expense List Readability
- Rebalanced the actual 12-column Bills & Expenses table so supplier names, dates, money values and payment dates have usable space.
- Reserved a larger Actions column for unpaid rows that show View + Payment + More.
- Header and body use the exact same width map.
- Reduced only desktop table typography/padding enough to fit the full row without a horizontal scrollbar.
- Preserved every existing field, action, payment flow and mobile layout.
