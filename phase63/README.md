# Isolated Stripe settlement tests (Dev branch only)

This package contains only test fixtures and a manually triggered GitHub Actions workflow. It does not modify the Frindly application, Supabase or Stripe.

Upload the contents of this ZIP to the repository root while **Dev** is selected, preserving `.github/workflows/` and `phase63/` directories. Do not upload to `main` or replace existing files.

Once committed to Dev, open GitHub Actions and select **Frindly Phase 63 disposable PostgreSQL settlement tests**. If GitHub does not offer manual execution on Dev, do not merge into main merely to run the workflow; ask for an alternative runner.

The workflow uses only an ephemeral PostgreSQL 16 service on localhost:55457. It requires no Supabase or Stripe secrets. The Python runner refuses any other database name, user, host or port and requires an empty database.

The test fixture is simplified. All 22 scenarios remain **unexecuted against PostgreSQL** until a workflow run reports results. This ZIP is NOT a production migration or deployment.
