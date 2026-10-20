# Manager Leave Draft — isolated test deployment

This file exists only on the `feature/payroll-manager-leave-20261020` branch.

Test page: `/payroll-manager-leave-test.html`

- The standalone page explicitly targets Supabase project `smvvevrtjqkflyqkyape`.
- The normal Frindly application (`index.html`) still points to production Supabase and **must not be used for isolated tests**.
- No payroll calculation, approval, leave-balance or accounting workflow is changed.
- Use only test credentials in the isolated environment.
- Do not merge this branch into `main` until the isolation and authenticated tests pass.

Deployment note: committed after enabling this branch in Netlify's branch-deploy settings, to request a new branch build. A successful Netlify deployment must be verified independently.
