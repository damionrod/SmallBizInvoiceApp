-- V61.101M — Keep the current Helper instruction version explicit for deployments.
-- The full current-module instruction is established by the immediately preceding V61.101L migration.
update public.finlo_helper_settings
set instruction_version='v61.101M'
where id=true and instruction_version='v61.101L';
