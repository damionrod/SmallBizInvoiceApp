-- Bank CSV imports only. Preserve existing reconciliation/accounting behaviour.
-- One RPC makes the batch header and transaction rows atomic and idempotent.
create or replace function public.v6201_import_bank_csv(
  p_business_id uuid,
  p_bank_account_id uuid,
  p_filename text,
  p_mapping jsonb,
  p_rows jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_user_id uuid:=auth.uid();
  v_batch_id uuid;
  v_requested integer;
  v_inserted integer:=0;
  v_duplicates integer:=0;
  v_possible integer:=0;
  v_item jsonb;
begin
  if v_user_id is null then
    raise exception 'Bank import permission denied';
  end if;
  if p_business_id is null or p_business_id is distinct from public.current_business_id() then
    raise exception 'Bank import business is not active';
  end if;
  if not coalesce(public.v6147_can_write_area(p_business_id,'bank'),false) then
    raise exception 'Bank import permission denied';
  end if;
  if not exists(
    select 1 from public.bank_accounts
    where id=p_bank_account_id
      and business_id=p_business_id
      and coalesce(archived,false)=false
  ) then
    raise exception 'Bank account does not belong to the active business';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Bank import rows must be an array';
  end if;

  v_requested:=jsonb_array_length(p_rows);
  if v_requested<1 or v_requested>5000 then
    raise exception 'Bank import must contain between 1 and 5000 transactions';
  end if;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    if jsonb_typeof(v_item) is distinct from 'object'
       or coalesce(v_item->>'import_fingerprint','') !~ '^v2:[0-9a-f]{64}$'
       or jsonb_typeof(v_item->'amount') is distinct from 'number'
       or (v_item->>'amount')::numeric=0 then
      raise exception 'Bank import contains an invalid transaction';
    end if;
    begin
      perform (v_item->>'transaction_date')::date;
    exception when invalid_datetime_format or datetime_field_overflow then
      raise exception 'Bank import contains an invalid transaction date';
    end;
  end loop;

  select count(*)::integer into v_possible
  from jsonb_array_elements(p_rows) as source(item)
  where source.item->>'duplicate_status'='possible_duplicate';

  insert into public.bank_import_batches(
    business_id,bank_account_id,filename,imported_count,
    duplicate_count,possible_duplicate_count,mapping,imported_by
  ) values(
    p_business_id,p_bank_account_id,nullif(trim(p_filename),''),0,
    0,v_possible,coalesce(p_mapping,'{}'::jsonb),v_user_id
  ) returning id into v_batch_id;

  with source as (
    select item
    from jsonb_array_elements(p_rows) as input(item)
  ), inserted as (
    insert into public.bank_transactions(
      business_id,bank_account_id,import_batch_id,transaction_date,amount,
      description,reference,payee,bank_transaction_id,import_fingerprint,
      duplicate_status,status,source_provider,source_payload,created_by,updated_by
    )
    select
      p_business_id,
      p_bank_account_id,
      v_batch_id,
      (source.item->>'transaction_date')::date,
      (source.item->>'amount')::numeric,
      nullif(source.item->>'description',''),
      nullif(source.item->>'reference',''),
      nullif(source.item->>'payee',''),
      nullif(source.item->>'bank_transaction_id',''),
      source.item->>'import_fingerprint',
      case when source.item->>'duplicate_status'='possible_duplicate' then 'possible_duplicate' else 'new' end,
      'unreconciled',
      'csv',
      coalesce(source.item->'source_payload','{}'::jsonb),
      v_user_id,
      v_user_id
    from source
    where not exists(
      select 1
      from public.bank_transactions existing
      where existing.business_id=p_business_id
        and existing.bank_account_id=p_bank_account_id
        and existing.import_fingerprint in (
          source.item->>'import_fingerprint',
          source.item->>'legacy_fingerprint'
        )
    )
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_inserted from inserted;

  v_duplicates:=v_requested-v_inserted;
  if v_inserted=0 then
    delete from public.bank_import_batches where id=v_batch_id;
    v_batch_id:=null;
  else
    update public.bank_import_batches
    set imported_count=v_inserted,
        duplicate_count=v_duplicates,
        possible_duplicate_count=v_possible
    where id=v_batch_id;
  end if;

  return jsonb_build_object(
    'batch_id',v_batch_id,
    'requested_count',v_requested,
    'imported_count',v_inserted,
    'duplicate_count',v_duplicates,
    'possible_duplicate_count',v_possible
  );
end
$$;

revoke all on function public.v6201_import_bank_csv(uuid,uuid,text,jsonb,jsonb) from public;
revoke all on function public.v6201_import_bank_csv(uuid,uuid,text,jsonb,jsonb) from anon;
grant execute on function public.v6201_import_bank_csv(uuid,uuid,text,jsonb,jsonb) to authenticated;

comment on function public.v6201_import_bank_csv(uuid,uuid,text,jsonb,jsonb)
is 'Atomically imports validated CSV bank transactions for the active business and skips exact reimports.';
