create or replace function public.se_new_item_code(p_business_id uuid, p_kind text)
returns text
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  prefix text := case p_kind when 'stock' then 'STK-' when 'supplies' then 'CON-' else 'EQ-' end;
  code text;
begin
  loop
    code := prefix || upper(left(replace(gen_random_uuid()::text, '-', ''), 10));
    if not exists (
      select 1 from public.se_items
      where business_id = p_business_id and lower(sku) = lower(code)
    ) then
      return code;
    end if;
  end loop;
end;
$function$;

revoke all on function public.se_new_item_code(uuid, text) from public, anon, authenticated;

create or replace function public.se_create_item(
  p_business_id uuid, p_kind text, p_name text, p_sku text default null,
  p_unit text default 'each', p_low_stock_at numeric default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  new_id uuid;
  supplied_code text := nullif(trim(coalesce(p_sku, '')), '');
  code text;
begin
  perform public.se_require_access(p_business_id, true);
  if p_kind not in ('stock', 'supplies', 'equipment') or trim(coalesce(p_name, '')) = '' then
    raise exception 'Select a type and name';
  end if;

  loop
    code := coalesce(supplied_code, public.se_new_item_code(p_business_id, p_kind));
    insert into public.se_items(business_id, kind, name, sku, unit, low_stock_at, created_by)
    values (p_business_id, p_kind, trim(p_name), code,
            coalesce(nullif(trim(p_unit), ''), 'each'), p_low_stock_at, auth.uid())
    on conflict (business_id, lower(sku)) where sku is not null and not archived do nothing
    returning id into new_id;

    exit when new_id is not null;
    if supplied_code is not null then
      raise exception 'This item code is already in use in this business.' using errcode = '23505';
    end if;
  end loop;

  insert into public.se_activity(business_id, actor, action, item_id)
  values (p_business_id, auth.uid(), 'item_added', new_id);
  return new_id;
end;
$function$;

-- An explicit import SKU identifies a stock item. Fall back to name only when the SKU is blank.
do $migration$
declare
  old_match constant text := $old$if nullif(v_n->>'sku','') is not null then select id into v_id from se_items where business_id=v_bid and lower(sku)=lower(v_n->>'sku') and not archived limit 1; end if;
      if v_id is null then select id into v_id from se_items where business_id=v_bid and lower(btrim(name))=lower(btrim(v_n->>'name')) and kind='stock' and not archived limit 1; end if;$old$;
  new_match constant text := $new$if nullif(btrim(v_n->>'sku'),'') is not null then
        select id into v_id from se_items where business_id=v_bid and kind='stock' and lower(sku)=lower(btrim(v_n->>'sku')) and not archived limit 1;
      else
        select id into v_id from se_items where business_id=v_bid and lower(btrim(name))=lower(btrim(v_n->>'name')) and kind='stock' and not archived limit 1;
      end if;$new$;
  definition text;
begin
  select pg_get_functiondef(p.oid) into strict definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='v6215_confirm_import'
    and p.prosrc like '%v_n->>''sku''%';

  if strpos(definition, new_match) > 0 then
    return;
  end if;
  if strpos(definition, old_match) = 0 then
    raise exception 'Unexpected stock import matching definition';
  end if;
  execute replace(definition, old_match, new_match);
end;
$migration$;

-- Only fill blank codes on existing active items. Keep all existing IDs and financial fields.
do $backfill$
declare
  item record;
begin
  lock table public.se_items in share row exclusive mode;
  for item in
    select id, business_id, kind
    from public.se_items
    where not archived and nullif(btrim(sku), '') is null
  loop
    update public.se_items
    set sku = public.se_new_item_code(item.business_id, item.kind)
    where id = item.id;
  end loop;
end;
$backfill$;
