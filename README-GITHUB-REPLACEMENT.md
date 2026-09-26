Frindly v61.99G — Portrait Mobile Menu Root-Cause Fix

Scope
- Portrait mobile navigation only.
- No accounting, database, payroll, GST, scheduling, subscription, entitlement or desktop workflow logic changed.

Root cause addressed
- The portrait menu was the only navigation mode that required a JavaScript listener attached by mobile-shell.js before it could open. Landscape/desktop navigation is exposed by CSS, which explains why rotating the same phone appeared to fix navigation.
- The stylesheet also still contained obsolete v61.99C checkbox-based mobile navigation selectors after that checkbox implementation had been removed from the HTML. Those stale rules have now been removed.
- Multiple historical CSS navigation layers remain for backward styling compatibility, but the final v61.99D+ layer remains authoritative. No orphan mobileNavToggle selectors remain.

Fix
- mobileMenuBtn now invokes the navigation controller directly from the actual button activation. This removes DOMContentLoaded/listener-binding timing as a dependency.
- A direct inline fallback toggles mobile-nav-open even if mobile-shell.js fails to load or initialize.
- mobile-shell.js no longer attaches a second click handler to the Menu button, preventing double-toggle behaviour.
- Existing outside-click, Escape, nav-selection, resize and orientation close behaviour is preserved.
- Removed obsolete v61.99C checkbox navigation CSS.
- Bumped mobile shell/CSS asset query versions to v61.99G-nav-rootcause.

Verification
- All public/*.js files pass node --check.
- styles.css braces balanced (3557/3557 at verification).
- Exactly one #mobileMenuBtn exists in index.html.
- No mobileNavToggle references remain.
- Current production Netlify deployment was inspected and confirmed to be serving the v61.99F menu implementation before this fix.
- Automated Chromium interaction was attempted in the container; Chromium itself hung before returning a result, so no browser-pass claim is made.
