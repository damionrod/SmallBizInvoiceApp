-- V61.71B Import & Migration
create table if not exists public.import_migration_settings(
 id boolean primary key default true check(id=true), enabled boolean not null default true,
 max_upload_bytes integer not null default 10485760 check(max_upload_bytes between 1024 and 52428800),
 max_rows integer not null default 10000 check(max_rows between 1 and 100000),
 ai_mapping_enabled boolean not null default true, updated_at timestamptz not null default now(), updated_by uuid
);
insert into public.import_migration_settings(id) values(true) on conflict(id) do nothing;
alter table public.import_migration_settings enable row level security; revoke all on public.import_migration_settings from anon,authenticated;

create table if not exists public.import_batches(
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 user_id uuid not null, filename text not null, source_type text not null check(source_type in('csv','xlsx')),
 source_adapter text not null default 'generic_file', file_sha256 text not null, cutover_date date,
 migration_mode text not null default 'continue_today' check(migration_mode in('continue_today','historical_reference')),
 mapping_version text not null default 'v61.71b', status text not null default 'uploaded' check(status in('uploaded','analysed','reviewed','importing','completed','failed','cancelled')),
 total_rows integer not null default 0, valid_rows integer not null default 0, warning_rows integer not null default 0,
 rejected_rows integer not null default 0, imported_rows integer not null default 0, error_summary text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), completed_at timestamptz
);
create index if not exists import_batches_business_created_idx on public.import_batches(business_id,created_at desc);
create index if not exists import_batches_hash_idx on public.import_batches(business_id,file_sha256);
alter table public.import_batches enable row level security;
drop policy if exists import_batches_read on public.import_batches;create policy import_batches_read on public.import_batches for select to authenticated using(business_id=public.current_business_id() or public.is_super_admin());
revoke insert,update,delete on public.import_batches from anon,authenticated;

create table if not exists public.import_sheets(
 id uuid primary key default gen_random_uuid(), batch_id uuid not null references public.import_batches(id) on delete cascade,
 business_id uuid not null references public.businesses(id) on delete cascade, sheet_index integer not null, sheet_name text not null,
 detected_record_type text not null default 'unknown' check(detected_record_type in('customers','suppliers','invoices','expenses','employees','unknown')),
 row_count integer not null default 0, headers jsonb not null default '[]'::jsonb, sample_rows jsonb not null default '[]'::jsonb,
 ai_suggested_type text, ai_confidence numeric, created_at timestamptz not null default now(), unique(batch_id,sheet_index)
);
alter table public.import_sheets enable row level security;drop policy if exists import_sheets_read on public.import_sheets;create policy import_sheets_read on public.import_sheets for select to authenticated using(business_id=public.current_business_id() or public.is_super_admin());revoke insert,update,delete on public.import_sheets from anon,authenticated;

create table if not exists public.import_mappings(
 id uuid primary key default gen_random_uuid(), batch_id uuid not null references public.import_batches(id) on delete cascade,
 sheet_id uuid not null references public.import_sheets(id) on delete cascade, business_id uuid not null references public.businesses(id) on delete cascade,
 source_column text not null, suggested_target text, confirmed_target text, confidence numeric, suggestion_source text not null default 'deterministic',
 confirmed_by uuid, confirmed_at timestamptz, unique(sheet_id,source_column)
);
alter table public.import_mappings enable row level security;drop policy if exists import_mappings_read on public.import_mappings;create policy import_mappings_read on public.import_mappings for select to authenticated using(business_id=public.current_business_id() or public.is_super_admin());revoke insert,update,delete on public.import_mappings from anon,authenticated;

create table if not exists public.import_rows(
 id uuid primary key default gen_random_uuid(), batch_id uuid not null references public.import_batches(id) on delete cascade,
 sheet_id uuid not null references public.import_sheets(id) on delete cascade, business_id uuid not null references public.businesses(id) on delete cascade,
 source_row_number integer not null, source_hash text not null, source_data jsonb not null, normalized_data jsonb not null default '{}'::jsonb,
 record_type text not null default 'unknown', validation_status text not null default 'pending' check(validation_status in('pending','ready','warning','rejected','imported','skipped')),
 validation_messages jsonb not null default '[]'::jsonb, imported_record_type text, imported_record_id uuid, created_at timestamptz not null default now(), unique(batch_id,sheet_id,source_row_number)
);
create index if not exists import_rows_batch_status_idx on public.import_rows(batch_id,validation_status);
create index if not exists import_rows_business_hash_idx on public.import_rows(business_id,source_hash);
alter table public.import_rows enable row level security;drop policy if exists import_rows_read on public.import_rows;create policy import_rows_read on public.import_rows for select to authenticated using(business_id=public.current_business_id() or public.is_super_admin());revoke insert,update,delete on public.import_rows from anon,authenticated;

create table if not exists public.import_record_links(
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 batch_id uuid not null references public.import_batches(id) on delete restrict, import_row_id uuid not null references public.import_rows(id) on delete restrict,
 record_type text not null, record_id uuid not null, source_hash text not null, created_at timestamptz not null default now(), unique(business_id,record_type,record_id), unique(business_id,source_hash,record_type)
);
alter table public.import_record_links enable row level security;drop policy if exists import_record_links_read on public.import_record_links;create policy import_record_links_read on public.import_record_links for select to authenticated using(business_id=public.current_business_id() or public.is_super_admin());revoke insert,update,delete on public.import_record_links from anon,authenticated;

insert into public.finlo_helper_module_controls(module_context,enabled) values('import_migration',true) on conflict(module_context) do nothing;

create or replace function public.v6171b_import_config() returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id(); cfg import_migration_settings;begin if bid is null then raise exception 'No active business' using errcode='42501';end if;select * into cfg from import_migration_settings where id=true;return jsonb_build_object('enabled',cfg.enabled,'max_upload_bytes',cfg.max_upload_bytes,'max_rows',cfg.max_rows,'ai_mapping_enabled',cfg.ai_mapping_enabled);end$$;
revoke all on function public.v6171b_import_config() from public,anon;grant execute on function public.v6171b_import_config() to authenticated;

create or replace function public.v6171b_import_history() returns jsonb language sql security definer set search_path=public as $$
select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'filename',b.filename,'source_type',b.source_type,'status',b.status,'created_at',b.created_at,'completed_at',b.completed_at,'total_rows',b.total_rows,'imported_rows',b.imported_rows,'warning_rows',b.warning_rows,'rejected_rows',b.rejected_rows,'cutover_date',b.cutover_date,'migration_mode',b.migration_mode) order by b.created_at desc),'[]'::jsonb) from import_batches b where b.business_id=current_business_id();$$;
revoke all on function public.v6171b_import_history() from public,anon;grant execute on function public.v6171b_import_history() to authenticated;

create or replace function public.v6171b_import_get(p_batch uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();b import_batches;begin if bid is null then raise exception 'No active business';end if;select * into b from import_batches where id=p_batch and business_id=bid;if not found then raise exception 'Import batch not found' using errcode='42501';end if;return jsonb_build_object('batch',to_jsonb(b),'sheets',(select coalesce(jsonb_agg(to_jsonb(s) order by sheet_index),'[]') from import_sheets s where s.batch_id=b.id),'mappings',(select coalesce(jsonb_agg(to_jsonb(m) order by source_column),'[]') from import_mappings m where m.batch_id=b.id),'rows',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'sheet_id',r.sheet_id,'source_row_number',r.source_row_number,'record_type',r.record_type,'validation_status',r.validation_status,'validation_messages',r.validation_messages,'normalized_data',r.normalized_data) order by r.source_row_number) filter(where r.validation_status in('warning','rejected')),'[]') from import_rows r where r.batch_id=b.id));end$$;
revoke all on function public.v6171b_import_get(uuid) from public,anon;grant execute on function public.v6171b_import_get(uuid) to authenticated;

create or replace function public.v6171b_apply_mapping(p_batch uuid,p_sheet uuid,p_record_type text,p_mapping jsonb,p_cutover date default current_date,p_mode text default 'continue_today') returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();r record;m jsonb;norm jsonb;msgs jsonb;st text;nm text;em text;ph text;addr text;target text;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Import access denied' using errcode='42501';end if;
 if p_record_type not in('customers','suppliers','invoices','expenses','employees','unknown') then raise exception 'Invalid record type';end if;
 if p_mode not in('continue_today','historical_reference') then raise exception 'Invalid migration mode';end if;
 if not exists(select 1 from import_batches where id=p_batch and business_id=bid and status in('analysed','reviewed')) then raise exception 'Import batch is not ready for mapping';end if;
 if not exists(select 1 from import_sheets where id=p_sheet and batch_id=p_batch and business_id=bid) then raise exception 'Import sheet not found';end if;
 update import_sheets set detected_record_type=p_record_type where id=p_sheet;
 for m in select * from jsonb_array_elements(coalesce(p_mapping,'[]'::jsonb)) loop
  update import_mappings set confirmed_target=nullif(m->>'target','skip'),confirmed_by=auth.uid(),confirmed_at=now() where sheet_id=p_sheet and source_column=m->>'source';
 end loop;
 for r in select * from import_rows where sheet_id=p_sheet order by source_row_number loop
  norm:='{}'::jsonb;msgs:='[]'::jsonb;st:='ready';
  for m in select to_jsonb(x) from import_mappings x where x.sheet_id=p_sheet and x.confirmed_target is not null loop
   target:=m->>'confirmed_target';norm:=norm||jsonb_build_object(target,coalesce(r.source_data->>(m->>'source_column'),''));
  end loop;
  if p_record_type='customers' then nm:=btrim(coalesce(norm->>'name',''));em:=btrim(coalesce(norm->>'email',''));ph:=btrim(coalesce(norm->>'phone',''));addr:=btrim(coalesce(norm->>'address',''));if nm='' then st:='rejected';msgs:=msgs||jsonb_build_array('Customer name is required.');end if;if nm<>'' and exists(select 1 from customers c where c.business_id=bid and lower(btrim(c.name))=lower(nm)) then st:='warning';msgs:=msgs||jsonb_build_array('A customer with this name already exists and will be skipped.');end if;
  elsif p_record_type='suppliers' then nm:=btrim(coalesce(norm->>'name',''));if nm='' then st:='rejected';msgs:=msgs||jsonb_build_array('Supplier name is required.');end if;if nm<>'' and exists(select 1 from suppliers s where s.business_id=bid and lower(btrim(s.supplier_name))=lower(nm) and not s.archived) then st:='warning';msgs:=msgs||jsonb_build_array('A supplier with this name already exists and will be skipped.');end if;
  elsif p_record_type in('invoices','expenses') then st:='rejected';msgs:=jsonb_build_array('V61.71B does not import historical financial transactions because the protected lifecycle would create native accounting/tax semantics. This row was not written to Finlo financial records.');
  elsif p_record_type='employees' then st:='rejected';msgs:=jsonb_build_array('Employee import is deferred because creating an employee applies payroll/tax defaults that cannot be safely inferred from basic contact data.');
  else st:='rejected';msgs:=jsonb_build_array('Choose what this sheet contains before importing.');end if;
  update import_rows set record_type=p_record_type,normalized_data=norm,validation_status=st,validation_messages=msgs where id=r.id;
 end loop;
 update import_batches set cutover_date=p_cutover,migration_mode=p_mode,status='reviewed',updated_at=now(),valid_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='ready'),warning_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='warning'),rejected_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='rejected') where id=p_batch;
 return v6171b_import_get(p_batch);
end$$;
revoke all on function public.v6171b_apply_mapping(uuid,uuid,text,jsonb,date,text) from public,anon;grant execute on function public.v6171b_apply_mapping(uuid,uuid,text,jsonb,date,text) to authenticated;

create or replace function public.v6171b_confirm_import(p_batch uuid,p_duplicate_action text default 'skip') returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid:=current_business_id();b import_batches;r record;rid uuid;n integer:=0;seq integer;contact jsonb;begin
 if bid is null or not v6147_can_write_area(bid,'core') then raise exception 'Import access denied' using errcode='42501';end if;
 if p_duplicate_action<>'skip' then raise exception 'V61.71B only supports safe Skip existing behaviour. Existing financial records are never overwritten.';end if;
 select * into b from import_batches where id=p_batch and business_id=bid for update;if not found then raise exception 'Import batch not found';end if;if b.status='completed' then return v6171b_import_get(p_batch);end if;if b.status<>'reviewed' then raise exception 'Review and confirm mappings before importing.';end if;
 update import_batches set status='importing',updated_at=now() where id=p_batch;
 perform pg_advisory_xact_lock(hashtext('v6171b-import-'||bid::text));
 for r in select * from import_rows where batch_id=p_batch and validation_status in('ready','warning') order by sheet_id,source_row_number loop
  if exists(select 1 from import_record_links l where l.business_id=bid and l.source_hash=r.source_hash and l.record_type=r.record_type) then update import_rows set validation_status='skipped',validation_messages=validation_messages||jsonb_build_array('Already imported from an earlier batch.') where id=r.id;continue;end if;
  if r.record_type='customers' then
   if exists(select 1 from customers c where c.business_id=bid and lower(btrim(c.name))=lower(btrim(r.normalized_data->>'name'))) then update import_rows set validation_status='skipped' where id=r.id;continue;end if;
   select coalesce(max(nullif(regexp_replace(customer_number,'\D','','g'),'')::int),0)+1 into seq from customers where business_id=bid and customer_number ~ '[0-9]';
   contact:=case when coalesce(nullif(btrim(r.normalized_data->>'email'),''),nullif(btrim(r.normalized_data->>'phone'),'')) is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'name',r.normalized_data->>'name','designation','','phone',coalesce(r.normalized_data->>'phone',''),'mobile',coalesce(r.normalized_data->>'mobile',''),'email',coalesce(r.normalized_data->>'email',''),'dob','','billing',true)) end;
   insert into customers(business_id,customer_number,customer_type,name,address,contacts,custom_fields) values(bid,'C'||lpad(seq::text,4,'0'),'individual',btrim(r.normalized_data->>'name'),nullif(btrim(r.normalized_data->>'address'),''),contact,'[]') returning id into rid;
  elsif r.record_type='suppliers' then
   if exists(select 1 from suppliers s where s.business_id=bid and lower(btrim(s.supplier_name))=lower(btrim(r.normalized_data->>'name')) and not s.archived) then update import_rows set validation_status='skipped' where id=r.id;continue;end if;
   insert into suppliers(business_id,supplier_name,contact_person,address,phone,mobile,email,registration_number,tax_number,default_gst_treatment,payment_terms_days) values(bid,btrim(r.normalized_data->>'name'),nullif(btrim(r.normalized_data->>'contact_person'),''),nullif(btrim(r.normalized_data->>'address'),''),nullif(btrim(r.normalized_data->>'phone'),''),nullif(btrim(r.normalized_data->>'mobile'),''),nullif(btrim(r.normalized_data->>'email'),''),nullif(btrim(r.normalized_data->>'registration_number'),''),nullif(btrim(r.normalized_data->>'tax_number'),''),'gst',0) returning id into rid;
  else continue;end if;
  insert into import_record_links(business_id,batch_id,import_row_id,record_type,record_id,source_hash) values(bid,p_batch,r.id,r.record_type,rid,r.source_hash);
  update import_rows set validation_status='imported',imported_record_type=r.record_type,imported_record_id=rid where id=r.id;n:=n+1;
 end loop;
 update import_batches set status='completed',imported_rows=n,warning_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='warning'),rejected_rows=(select count(*) from import_rows where batch_id=p_batch and validation_status='rejected'),completed_at=now(),updated_at=now() where id=p_batch;
 return v6171b_import_get(p_batch);
exception when others then update import_batches set status='failed',error_summary=left(sqlerrm,500),updated_at=now() where id=p_batch and business_id=bid;raise;end$$;
revoke all on function public.v6171b_confirm_import(uuid,text) from public,anon;grant execute on function public.v6171b_confirm_import(uuid,text) to authenticated;

create or replace function public.v6171b_admin_import_overview() returns jsonb language plpgsql security definer set search_path=public as $$begin if not is_super_admin() then raise exception 'Super Admin required' using errcode='42501';end if;return jsonb_build_object('settings',(select to_jsonb(x) from import_migration_settings x where id=true),'stats',jsonb_build_object('batches_30d',(select count(*) from import_batches where created_at>=now()-interval '30 days'),'completed_30d',(select count(*) from import_batches where status='completed' and created_at>=now()-interval '30 days'),'failed_30d',(select count(*) from import_batches where status='failed' and created_at>=now()-interval '30 days'),'rows_imported_30d',(select coalesce(sum(imported_rows),0) from import_batches where created_at>=now()-interval '30 days')),'recent',(select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'business',x.name,'filename',b.filename,'status',b.status,'created_at',b.created_at,'total_rows',b.total_rows,'imported_rows',b.imported_rows,'rejected_rows',b.rejected_rows,'error_summary',b.error_summary) order by b.created_at desc),'[]') from (select * from import_batches order by created_at desc limit 50)b join businesses x on x.id=b.business_id));end$$;
revoke all on function public.v6171b_admin_import_overview() from public,anon;grant execute on function public.v6171b_admin_import_overview() to authenticated;

create or replace function public.v6171b_admin_import_save(p_enabled boolean,p_max_upload_bytes integer,p_max_rows integer,p_ai_mapping_enabled boolean) returns void language plpgsql security definer set search_path=public as $$begin if not is_super_admin() then raise exception 'Super Admin required' using errcode='42501';end if;if p_max_upload_bytes not between 1024 and 52428800 or p_max_rows not between 1 and 100000 then raise exception 'Import limits are outside supported bounds';end if;update import_migration_settings set enabled=p_enabled,max_upload_bytes=p_max_upload_bytes,max_rows=p_max_rows,ai_mapping_enabled=p_ai_mapping_enabled,updated_at=now(),updated_by=auth.uid() where id=true;end$$;
revoke all on function public.v6171b_admin_import_save(boolean,integer,integer,boolean) from public,anon;grant execute on function public.v6171b_admin_import_save(boolean,integer,integer,boolean) to authenticated;
