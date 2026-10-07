-- ISOLATED FIXTURE ONLY. Reconstructed from READ-ONLY live definitions 2026-10-07.
-- This is not a migration. Does not include subscription gating (auth context unavailable).
CREATE OR REPLACE FUNCTION public.v60_customer_payment_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE inv_business uuid; inv_total numeric(14,2); existing_paid numeric(14,2);
BEGIN
 SELECT business_id,total INTO inv_business,inv_total FROM public.invoices WHERE id=NEW.invoice_id;
 IF inv_business IS NULL THEN RAISE EXCEPTION 'Invoice not found'; END IF;
 IF NEW.business_id<>inv_business THEN RAISE EXCEPTION 'Customer payment must belong to the same business as the invoice'; END IF;
 SELECT coalesce(sum(amount),0) INTO existing_paid FROM public.customer_payments WHERE invoice_id=NEW.invoice_id AND id<>coalesce(NEW.id,gen_random_uuid());
 IF existing_paid+NEW.amount>inv_total+0.005 THEN RAISE EXCEPTION 'Payment exceeds invoice outstanding balance'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER v60_customer_payment_guard_trg BEFORE INSERT OR UPDATE ON public.customer_payments FOR EACH ROW EXECUTE FUNCTION public.v60_customer_payment_guard();
CREATE OR REPLACE FUNCTION public.v60_refresh_invoice_paid() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE iid uuid; paid numeric(14,2); tot numeric(14,2);
BEGIN
 IF TG_OP='DELETE' THEN iid=OLD.invoice_id; ELSE iid=NEW.invoice_id; END IF;
 SELECT total INTO tot FROM public.invoices WHERE id=iid;
 IF tot IS NULL THEN IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF; END IF;
 SELECT coalesce(sum(amount),0) INTO paid FROM public.customer_payments WHERE invoice_id=iid;
 UPDATE public.invoices SET amount_paid=least(tot,paid),balance_due=greatest(0,tot-paid),updated_at=now() WHERE id=iid;
 IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
CREATE TRIGGER v60_customer_payment_refresh_trg AFTER INSERT OR UPDATE OR DELETE ON public.customer_payments FOR EACH ROW EXECUTE FUNCTION public.v60_refresh_invoice_paid();
