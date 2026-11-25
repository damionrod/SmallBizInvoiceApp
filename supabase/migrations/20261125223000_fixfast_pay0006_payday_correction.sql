-- One-off, user-authorised correction. Locks isolate the maintenance window;
-- normal immutability guards are restored before the transaction commits.
LOCK TABLE public.payroll_pay_runs, public.payroll_payslips, public.accounting_journals IN ACCESS EXCLUSIVE MODE;
ALTER TABLE public.payroll_pay_runs DISABLE TRIGGER v55_lock_finalised_pay_run;
ALTER TABLE public.payroll_payslips DISABLE TRIGGER v55_lock_finalised_child;
ALTER TABLE public.accounting_journals DISABLE TRIGGER v6170a_guard_posted_journal_mutation;
DO $$
DECLARE r public.payroll_pay_runs%rowtype; jid uuid; n integer;
BEGIN
 SELECT p.* INTO STRICT r FROM public.payroll_pay_runs p JOIN public.businesses b ON b.id=p.business_id
 WHERE b.name='Fixfast Limited' AND p.pay_run_number='PAY-0006' AND p.period_start=DATE '2026-11-16' AND p.period_end=DATE '2026-11-22' FOR UPDATE OF p;
 IF r.pay_date=DATE '2026-11-26' THEN RETURN; END IF;
 IF r.pay_date<>DATE '2026-12-03' OR r.status<>'finalised' OR r.net_pay<>197.70 OR r.gross_pay<>225.13 THEN RAISE EXCEPTION 'Unexpected pay run state; stop correction'; END IF;
 IF EXISTS(SELECT 1 FROM public.liability_payment_allocations WHERE pay_run_id=r.id)
 OR EXISTS(SELECT 1 FROM public.bank_reconciliation_allocations WHERE pay_run_id=r.id)
 OR EXISTS(SELECT 1 FROM public.payroll_ird_filings WHERE pay_run_id=r.id AND status<>'file_downloaded') THEN RAISE EXCEPTION 'Pay run has settlements or filing activity; review correction'; END IF;
 IF EXISTS(SELECT 1 FROM public.accounting_periods WHERE business_id=r.business_id AND status<>'open' AND (DATE '2026-11-26' BETWEEN period_start AND period_end OR r.pay_date BETWEEN period_start AND period_end)) THEN RAISE EXCEPTION 'Correction touches a locked period'; END IF;
 SELECT id INTO STRICT jid FROM public.accounting_journals WHERE business_id=r.business_id AND source_type='payroll' AND source_id=r.id AND status='posted' AND journal_date=r.pay_date;
 IF (SELECT count(*) FROM public.payroll_payslips WHERE pay_run_id=r.id)<>2 THEN RAISE EXCEPTION 'Unexpected payslip count'; END IF;
 INSERT INTO public.accounting_audit_log(business_id,entity_type,entity_id,action,details)
 VALUES(r.business_id,'payroll_pay_run',r.id,'pay_date_correction',jsonb_build_object('reason','User authorised correction of automatic payday bug: weekly Thursday after 16–22 November is 26 November 2026','old_pay_date',r.pay_date,'new_pay_date','2026-11-26','before_run',to_jsonb(r),'before_payslips',(SELECT jsonb_agg(to_jsonb(p)) FROM public.payroll_payslips p WHERE pay_run_id=r.id),'journal_id',jid,'previous_downloads_remain_historical',true));
 UPDATE public.payroll_pay_runs SET pay_date=DATE '2026-11-26',rules_snapshot=jsonb_set(rules_snapshot,'{pay_date}','"2026-11-26"'),updated_at=now() WHERE id=r.id;
 UPDATE public.accounting_journals SET journal_date=DATE '2026-11-26' WHERE id=jid;
 UPDATE public.payroll_payslips SET payslip_data=jsonb_set(payslip_data,'{run,pay_date}','"2026-11-26"') WHERE pay_run_id=r.id;
 IF EXISTS(SELECT 1 FROM public.payroll_payslips WHERE pay_run_id=r.id AND payslip_data#>>'{run,pay_date}' IS DISTINCT FROM '2026-11-26') THEN RAISE EXCEPTION 'Payslip date verification failed'; END IF;
END $$;
ALTER TABLE public.payroll_pay_runs ENABLE TRIGGER v55_lock_finalised_pay_run;
ALTER TABLE public.payroll_payslips ENABLE TRIGGER v55_lock_finalised_child;
ALTER TABLE public.accounting_journals ENABLE TRIGGER v6170a_guard_posted_journal_mutation;
