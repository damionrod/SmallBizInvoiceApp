-- Cover only the two foreign keys introduced by the activation release.
create index gst_basis_request_adjustment_lookup on public.gst_basis_change_requests(adjustment_id);
create index gst_basis_request_applier_lookup on public.gst_basis_change_requests(applied_by);
