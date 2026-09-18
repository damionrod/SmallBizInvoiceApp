-- V61.73-P2 live security correction.
-- Applied live as: 20260918062230 — v6173_p2_revoke_trigger_function_execute
revoke execute on function public.v6173p2_validate_payroll_foundation_refs() from public, anon, authenticated;
