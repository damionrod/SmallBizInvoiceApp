# Frindly PO email delivery recovery (v61.142L)

**Never resolve an uncertain attempt based only on the browser timeout or an assumption.**

1. Find the uncertain `purchase_order_email_attempts` record (attempt ID, recipient, timestamp, PO number). Access requires authorized operational support; do not expose service-role credentials in the browser.
2. Search the Resend dashboard/API for the exact recipient, subject, timestamp, and any message identifier or idempotency key. A missing dashboard entry alone does **not** prove the message was not accepted. Escalate to provider support if ambiguous.
3. Record the provider evidence (ticket ID, message ID, provider-confirmed outcome). Confirm whether the email was **accepted** (not necessarily delivered to inbox), or definitely **not accepted**.
4. Only with conclusive evidence, invoke `v61142l_resolve_po_email` via a service-role administrative backend, passing attempt UUID, `sent` or `failed`, evidence, and provider ID if known. This RPC is intentionally not callable by ordinary authenticated users.
5. Reopen the PO and verify its status and event history. A verified `failed` attempt can be manually retried; `sent` must not be resent without explicit user action.
6. If provider evidence is inconclusive, leave the attempt `uncertain` and escalate. Never clear the lock automatically by age.

## Release order

1. In a staging project with the current PO schema, apply `v61.142I`, `v61.142J`, `v61.142K`, then `v61.142L` migrations in order; check whether prior migrations already exist.
2. Run authenticated integration tests for permissions, duplicate sends, provider 2xx/4xx/5xx/timeouts, uncertain resolution, status updates and rollback behaviour.
3. Deploy the updated Edge Function only after the database changes; deploy frontend after the Edge Function is healthy.
4. Verify production smoke tests with an explicitly approved test supplier/recipient. Do not email real suppliers as a test.

This release is **not production-certified** until these tests pass. Database changes are not automatically applied by uploading the ZIP to GitHub.
