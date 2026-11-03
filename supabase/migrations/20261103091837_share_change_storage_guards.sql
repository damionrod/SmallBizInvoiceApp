-- Private RPC-only storage: explicit deny policies and covering foreign-key indexes.
create policy share_changes_rpc_only on frindly_cash.share_changes for all to authenticated using (false) with check (false);
create policy share_change_payments_rpc_only on frindly_cash.share_change_payments for all to authenticated using (false) with check (false);
create index share_changes_owner_idx on frindly_cash.share_changes(owner_id);
create index share_change_payments_business_idx on frindly_cash.share_change_payments(business_id);
