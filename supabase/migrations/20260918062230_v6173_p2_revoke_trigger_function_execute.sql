-- V61.73-P2 live security correction.
-- Mirrors migration already applied to production on 2026-09-18.
-- Do not reapply manually outside normal migration reconciliation.
revoke execute on function public.v6173p2_validate_payroll_foundation_refs() from public, anon, authenticated;
