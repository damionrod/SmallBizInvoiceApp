-- Trigger-only function: prevent direct API execution.
revoke all on function public.support_touch_thread() from public, anon, authenticated;
