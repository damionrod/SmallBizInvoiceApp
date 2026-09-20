-- V61.79 Phase B correction rollback only. Does not alter Phase A objects/data.
begin;
drop function if exists public.v6179_save_schedule_with_assignments(uuid,jsonb,uuid[]);
commit;
