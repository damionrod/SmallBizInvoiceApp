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
