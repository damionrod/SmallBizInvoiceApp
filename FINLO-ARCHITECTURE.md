# Finlo Architecture

## Core rule
Preserve business behaviour and server-enforced security. Shared frontend utilities may reduce mechanical duplication, but they must not become an alternate source of truth for accounting, tax, payroll, entitlements or tenant security.

## Runtime layers
1. **Shell** — `index.html`, `styles-core.css`, `styles.css`, `frontend-quality.css`.
2. **Shared browser primitives** — `finlo-core.js`; DOM lookup, numeric coercion, HTML escaping and ordered script loading only.
3. **Platform/session** — `app-config.js`, Supabase client, `saas.js`; auth, membership, active business, entitlements, switching and module orchestration.
4. **Operational modules** — invoices/customers, expenses/suppliers, bank, payroll, job costing, financials/reports, Accountant Centre.
5. **Guidance/import** — onboarding, Import & Migration, Finlo Helper/Basic Voice/Live Voice.
6. **Server boundary** — Supabase RLS/RPCs and Edge Functions.
7. **Accounting boundary** — accepted V61.70A–G lifecycle/posting/tax/reporting foundation; protected from architectural refactors.

## Module ownership
Each operational module owns its own workflow UI and business-specific client logic. Shared utilities are appropriate only for behaviour-neutral mechanics. A module must not mutate another module's private state merely to avoid a small helper function.

## Business context
`window.SAAS.state.business` is the authoritative current client business concept. It is convenience state, not a security boundary. `current_business_id()`, active membership validation, RLS and business-scoped server queries remain authoritative.

## Entitlements
Client entitlement state controls visibility/availability. Server checks remain authoritative for protected actions. Never replace an RPC/server entitlement check with frontend filtering.

## Shared UI convention
New work should prefer existing semantic classes and shared structural patterns for buttons, fields, tables, tabs, badges, modals, alerts/toasts, loading and empty states. Do not create a second visual system. Existing specialised components may remain until equivalence is proven.

## CSS convention
Load order is intentional:
1. `styles-core.css` — earliest legacy/core/shared cascade extracted without changing order.
2. `styles.css` — later historical, module and responsive overrides in their original order.
3. `frontend-quality.css` — final quality/accessibility layer.

Do not delete duplicate-looking selectors without checking specificity, cascade order, dynamic classes and media-query behaviour.

## Supabase boundaries
Frontend modules may call business-scoped tables/RPCs through the authenticated client. Security and financial integrity live on the server. Database/schema changes are separate releases and require explicit review.

## Edge Function boundaries
Edge Functions own privileged integrations such as email, OCR, Helper, Live Voice and payment/provider calls. Permanent provider credentials must never be exposed to the browser.

## Helper boundaries
Preserve P2 routing, Product Knowledge `v61.71B-P3.1`, P4 dictation, P5 context, P5.1 Basic Voice and P6/P6.1 Live Voice as separate accepted capabilities. Helper guidance must not perform financial actions.

## Adding a future module
- Define one module owner and one authoritative data source.
- Use `SAAS` business context and server tenant validation.
- Reuse `FinloCore` only for truly generic primitives.
- Reuse existing structural CSS before adding new selectors.
- Keep calculations/business semantics inside the owning domain or accepted server layer.
- Add regression coverage for business switching, tenant isolation, mobile layout and entitlements.
