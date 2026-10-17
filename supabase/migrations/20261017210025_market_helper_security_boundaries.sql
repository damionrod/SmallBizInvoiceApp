-- Retain public pricing/checkout discovery. Trigger functions are not public RPCs.
-- Fixed search paths preserve both isolated helpers' existing bodies and invoker rights.
alter function public.frindly_expense_correction_bridge_probe_v1() set search_path='';
alter function public.frindly_isolated_expense_posting_readiness_v2(uuid) set search_path='';
revoke all on function public.v61142k_block_po_changes_during_send() from public,anon;
