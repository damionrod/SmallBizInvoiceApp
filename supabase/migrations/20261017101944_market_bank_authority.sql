-- Banking is the only editor. All default changes and document-default projections commit together.
CREATE OR REPLACE FUNCTION public.v6221_save_bank_account(p_business_id uuid,p_account_id uuid,p_expected_updated_at timestamptz,p_action text,p_values jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE b public.businesses%ROWTYPE; a public.bank_accounts%ROWTYPE; projection jsonb; n text; c text; account_no text; bank text; changed boolean:=true;
BEGIN
 IF auth.uid() IS NULL OR p_business_id IS DISTINCT FROM public.current_business_id() OR NOT public.v6147_can_write_area(p_business_id,'bank') THEN RAISE EXCEPTION 'Bank account access denied.' USING ERRCODE='42501'; END IF;
 IF p_account_id IS NULL OR p_action NOT IN ('save','default','archive') OR p_action IS NULL OR jsonb_typeof(p_values) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid bank account request.' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_values) k WHERE k NOT IN ('name','bank_name','account_number','currency')) THEN RAISE EXCEPTION 'Unknown bank account field.' USING ERRCODE='22023'; END IF;
 SELECT * INTO b FROM public.businesses WHERE id=p_business_id FOR UPDATE;
 SELECT * INTO a FROM public.bank_accounts WHERE id=p_account_id FOR UPDATE;
 IF FOUND AND a.business_id IS DISTINCT FROM p_business_id THEN RAISE EXCEPTION 'Bank account access denied.' USING ERRCODE='42501'; END IF;
 IF a.id IS NULL THEN
   IF p_action<>'save' OR p_expected_updated_at IS NOT NULL THEN RAISE EXCEPTION 'Bank account not found.'; END IF;
 ELSE
   IF p_action<>'save' OR p_expected_updated_at IS NOT NULL THEN
     IF p_expected_updated_at IS NULL OR a.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'Bank account changed. Reload Banking before trying again.' USING ERRCODE='40001'; END IF;
   END IF;
   IF coalesce(a.archived,false) THEN RAISE EXCEPTION 'This bank account is archived. It has not been restored.'; END IF;
 END IF;
 IF p_action='save' THEN
   n:=btrim(p_values->>'name');c:=upper(p_values->>'currency');account_no:=nullif(btrim(p_values->>'account_number'),'');bank:=nullif(btrim(p_values->>'bank_name'),'');
   IF coalesce(n,'')='' OR length(n)>160 OR c IS NULL OR c NOT IN ('NZD','AUD','USD','GBP','EUR') OR length(coalesce(account_no,''))>100 OR length(coalesce(bank,''))>160 THEN RAISE EXCEPTION 'Review the bank name, number and currency.' USING ERRCODE='22023'; END IF;
   IF EXISTS(SELECT 1 FROM public.bank_accounts x WHERE x.business_id=p_business_id AND x.id<>p_account_id AND account_no IS NOT NULL AND regexp_replace(x.account_number,'[^A-Za-z0-9]','','g')=regexp_replace(account_no,'[^A-Za-z0-9]','','g')) THEN RAISE EXCEPTION 'This account number already exists, possibly in archived accounts. Review it before adding another.' USING ERRCODE='23505'; END IF;
   IF a.id IS NOT NULL AND p_expected_updated_at IS NULL THEN
     IF a.created_by IS DISTINCT FROM auth.uid() OR a.name IS DISTINCT FROM n OR a.currency IS DISTINCT FROM c OR a.account_number IS DISTINCT FROM account_no OR a.bank_name IS DISTINCT FROM bank THEN RAISE EXCEPTION 'Bank account changed. Reload Banking before trying again.' USING ERRCODE='40001'; END IF;
     changed:=false;
   ELSIF a.id IS NULL THEN
     INSERT INTO public.bank_accounts(id,business_id,name,bank_name,account_number,currency,is_default,archived,created_by,updated_by)
       VALUES(p_account_id,p_business_id,n,bank,account_no,c,NOT EXISTS(SELECT 1 FROM public.bank_accounts WHERE business_id=p_business_id AND is_default AND NOT coalesce(archived,false)) AND c=coalesce(b.settings->>'currency','NZD'),false,auth.uid(),auth.uid()) RETURNING * INTO a;
   ELSE
     IF a.is_default AND c<>coalesce(b.settings->>'currency','NZD') THEN RAISE EXCEPTION 'Choose a different default before changing this account currency.'; END IF;
     UPDATE public.bank_accounts SET name=n,bank_name=bank,account_number=account_no,currency=c,updated_at=clock_timestamp(),updated_by=auth.uid() WHERE id=a.id RETURNING * INTO a;
   END IF;
 ELSIF p_action='default' THEN
   IF a.currency<>coalesce(b.settings->>'currency','NZD') THEN RAISE EXCEPTION 'The default account must use the business currency.'; END IF;
   UPDATE public.bank_accounts SET is_default=false,updated_at=clock_timestamp(),updated_by=auth.uid() WHERE business_id=p_business_id AND is_default AND id<>a.id;
   UPDATE public.bank_accounts SET is_default=true,updated_at=clock_timestamp(),updated_by=auth.uid() WHERE id=a.id RETURNING * INTO a;
 ELSE
   UPDATE public.bank_accounts SET archived=true,is_default=false,updated_at=clock_timestamp(),updated_by=auth.uid() WHERE id=a.id RETURNING * INTO a;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('name',x.name,'account',coalesce(x.account_number,''),'isDefault',x.is_default) ORDER BY x.is_default DESC,x.name,x.id),'[]'::jsonb) INTO projection FROM public.bank_accounts x WHERE x.business_id=p_business_id AND NOT coalesce(x.archived,false) AND x.currency=coalesce(b.settings->>'currency','NZD');
 IF changed THEN
   UPDATE public.businesses SET settings=coalesce(settings,'{}'::jsonb)||jsonb_build_object('bankAccounts',projection),updated_at=clock_timestamp() WHERE id=p_business_id RETURNING * INTO b;
   INSERT INTO public.financial_audit_log(business_id,entity_type,entity_id,action,after_data,created_by) VALUES(p_business_id,'bank_account',a.id,'bank_account_'||p_action,jsonb_build_object('account_id',a.id,'action',p_action),auth.uid());
 END IF;
 RETURN jsonb_build_object('account',to_jsonb(a),'business',jsonb_build_object('id',b.id,'settings',b.settings,'updated_at',b.updated_at));
END;
$fn$;
REVOKE ALL ON FUNCTION public.v6221_save_bank_account(uuid,uuid,timestamptz,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.v6221_save_bank_account(uuid,uuid,timestamptz,text,jsonb) TO authenticated;
