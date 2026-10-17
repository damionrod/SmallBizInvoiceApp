-- Market only. Old row importer and new logical-record importer must not finish each other's batches.
DO $patch$
DECLARE source text;anchor text;
BEGIN
 IF public.frindly_market_environment_status()->>'project_ref' IS DISTINCT FROM 'smvvevrtjqkflyqkyape' THEN RAISE EXCEPTION 'Market only';END IF;
 source:=pg_get_functiondef('public.v6171b_confirm_import(uuid,text)'::regprocedure);
 anchor:='if b.status<>''reviewed'' then';
 IF strpos(source,anchor)=0 THEN RAISE EXCEPTION 'Legacy import source changed; review the patch';END IF;
 source:=replace(source,anchor,'if exists(select 1 from public.import_records where batch_id=p_batch and business_id=bid) then raise exception ''This is a Smart Migration batch. Confirm it through the Smart Migration review.'' using errcode=''22023'';end if;'||anchor);
 EXECUTE source;
 source:=pg_get_functiondef('public.v6215_confirm_import(uuid)'::regprocedure);
 anchor:='if v_batch.status not in (''analysed'',''reviewed'') then';
 IF strpos(source,anchor)=0 THEN RAISE EXCEPTION 'Smart import source changed; review the patch';END IF;
 source:=replace(source,anchor,'if not exists(select 1 from public.import_records where batch_id=p_batch and business_id=v_bid) then raise exception ''This batch has no Smart Migration records. Analyse a file with data or use its original import review.'' using errcode=''22023'';end if;'||chr(10)||'  '||anchor);
 EXECUTE source;
END$patch$;
