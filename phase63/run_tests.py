"""Execute only against the disposable Phase60 PostgreSQL fixture (Phase57 database name)."""
import os, sys, uuid, concurrent.futures
from pathlib import Path
from urllib.parse import urlparse
url = os.environ.get('PHASE57_DATABASE_URL','')
u = urlparse(url)
if u.scheme not in ('postgresql','postgres') or u.hostname not in ('localhost','127.0.0.1') or u.port != 55457 or u.path != '/frindly_phase57_disposable' or u.username != 'phase57':
    sys.exit('REFUSED: expected disposable localhost Phase57 database only')
import psycopg2
from psycopg2.errors import UniqueViolation

def connect(): return psycopg2.connect(url,connect_timeout=5)
with connect() as c:
    with c.cursor() as q:
        q.execute("select current_database(),current_user")
        assert q.fetchone()==('frindly_phase57_disposable','phase57')
        q.execute("select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema') and table_type='BASE TABLE'")
        assert q.fetchone()[0]==0, 'REFUSED: nonempty database'
        q.execute((Path(__file__).parent/'01_schema.sql').read_text())
        q.execute((Path(__file__).parent/'02_settlement_function.sql').read_text())
        q.execute((Path(__file__).parent/'03_verified_triggers.sql').read_text())

def execute(sql,args=(),fetch=False):
    with connect() as c:
        with c.cursor() as q:
            q.execute(sql,args)
            return q.fetchone() if fetch else None

def corrupt(sql,args=()):
    """Only for deliberate corruption regression cases in disposable database.
    Temporarily bypass triggers; never use this helper on a real database.
    """
    with connect() as c:
        with c.cursor() as q:
            # Transactional DDL: if the intended corruption fails, the context
            # manager rolls back the trigger-disable automatically. Do not
            # issue ENABLE TRIGGER inside an already-aborted transaction.
            q.execute('ALTER TABLE public.customer_payments DISABLE TRIGGER USER')
            q.execute(sql,args)
            q.execute('ALTER TABLE public.customer_payments ENABLE TRIGGER USER')

def make(amount=25,total=100,b=None,i=None,intent=None,invoice=True,void=False):
    b=b or uuid.uuid4(); i=i or uuid.uuid4(); t=uuid.uuid4()
    if invoice: execute('insert into public.invoices(id,business_id,total,lifecycle_state) values (%s,%s,%s,%s)',(str(i),str(b),total,'voided' if void else 'issued'))
    execute("insert into public.invoice_payment_transactions(id,business_id,invoice_id,amount,currency,status,stripe_payment_intent_id) values (%s,%s,%s,%s,'nzd','processing',%s)",(str(t),str(b),str(i),amount,intent or 'pi_'+t.hex))
    return t,b,i

def settle(t):
    return execute('select public.v6181_record_online_invoice_payment(%s)',(str(t),),True)[0]

def count(t): return execute('select count(*) from public.customer_payments where invoice_payment_transaction_id=%s',(str(t),),True)[0]

t,b,i=make(); a=settle(t); assert a['status']=='succeeded' and a['customer_payment_id'] and count(t)==1
assert settle(t)['already_recorded'] is True and count(t)==1
print('PASS 1: success and idempotent repeat')

# Production transaction uniqueness rejects duplicate PaymentIntent at the transaction INSERT,
# before settlement. Do not mislabel that constraint as a settlement-function test.
t2,b2,i2=make(intent='pi_shared_unique')
assert settle(t2)['status']=='succeeded'
try:
    make(intent='pi_shared_unique')
except UniqueViolation: pass
else: raise AssertionError('Transaction-level duplicate PaymentIntent was accepted')
print('PASS 2a: duplicate PaymentIntent rejected by transaction unique index')

# Test 2b: isolate a Stripe Checkout session uniqueness conflict.
# Use a different valid transaction ID so the transaction-link unique
# index cannot be responsible for rejecting the settlement.
t3,b3,i3=make()
other_t3,_,_=make()

execute(
    "insert into public.customer_payments(business_id,invoice_id,amount,payment_source,invoice_payment_transaction_id,currency,stripe_checkout_session_id) values (%s,%s,1,'stripe_connect',%s,'NZD','cs_conflict_phase53')",
    (str(b3),str(i3),str(other_t3))
)
execute(
    "update public.invoice_payment_transactions set stripe_checkout_session_id='cs_conflict_phase53' where id=%s",
    (str(t3),)
)

try:
    settle(t3)
except UniqueViolation:
    pass
else:
    raise AssertionError('Settlement swallowed Stripe session uniqueness conflict')

assert count(t3)==0, 'Failed settlement unexpectedly created a payment'
assert count(other_t3)==1, 'Pre-existing conflicting payment was changed'
print('PASS 2b: Stripe session uniqueness conflict rejected independently of transaction-link index')

t4,_,_=make()
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as p:
    outcomes=list(p.map(settle,[t4,t4]))
assert sorted(bool(o.get('already_recorded')) for o in outcomes)==[False,True] and count(t4)==1
print('PASS 3: two concurrent calls, one customer payment')

t5,_,_=make(void=True); assert settle(t5)['status']=='needs_review' and count(t5)==0
print('PASS 4: voided invoice blocked')

t6,_,_=make(amount=120,total=100); assert settle(t6)['status']=='needs_review' and count(t6)==0
print('PASS 5: overpayment blocked')

# Phase64: the verified invoice FK makes a missing invoice unrepresentable
# through normal SQL. Assert that PostgreSQL rejects deletion and the valid
# transaction can still settle. Do NOT bypass production-equivalent FK rules.
t7,_,i7=make()
try:
    execute('delete from public.invoices where id=%s',(str(i7),))
except psycopg2.errors.ForeignKeyViolation:
    pass
else:
    raise AssertionError('Invoice FK allowed deletion of referenced invoice')
assert execute('select count(*) from public.invoices where id=%s',(str(i7),),True)[0]==1
assert settle(t7)['status']=='succeeded' and count(t7)==1
print('PASS 6: invoice FK prevents missing-invoice state; valid settlement succeeds')

t8,b8,i8=make(); execute("update public.invoice_payment_transactions set status='succeeded',customer_payment_id=NULL where id=%s",(str(t8),))
# Phase50: corrupted succeeded rows must fail closed, not acknowledge settlement.
def rejected(t):
    try: settle(t)
    except Exception as e:
        assert 'Succeeded online payment has no matching customer payment record' in str(e), str(e)
    else: raise AssertionError('Corrupted succeeded transaction was acknowledged')
rejected(t8)
print('PASS 7: orphaned payment is rejected')

t9,b9,i9=make(); a9=settle(t9); assert a9['status']=='succeeded'
corrupt('update public.customer_payments set business_id=%s where id=%s',(str(uuid.uuid4()),a9['customer_payment_id']))
rejected(t9)
print('PASS 8: wrong business is rejected')

t10,b10,i10=make(); a10=settle(t10); assert a10['status']=='succeeded'
other_invoice = uuid.uuid4()
execute('insert into public.invoices(id,business_id,total,lifecycle_state) values (%s,%s,%s,%s)',(str(other_invoice),str(uuid.uuid4()),100,'issued'))
corrupt('update public.customer_payments set invoice_id=%s where id=%s',(str(other_invoice),a10['customer_payment_id']))
rejected(t10)
print('PASS 9: wrong invoice is rejected')

t11,b11,i11=make(); a11=settle(t11); assert a11['status']=='succeeded'
execute('update public.customer_payments set amount=amount+1 where id=%s',(a11['customer_payment_id'],))
rejected(t11)
print('PASS 10: wrong amount is rejected')

t12,b12,i12=make(); a12=settle(t12); assert a12['status']=='succeeded'
execute('update public.customer_payments set invoice_payment_transaction_id=NULL where id=%s',(a12['customer_payment_id'],))
rejected(t12)
print('PASS 11: wrong transaction link is rejected')

t13,b13,i13=make(); a13=settle(t13); assert a13['status']=='succeeded'
corrupt("update public.customer_payments set payment_source='manual' where id=%s",(a13['customer_payment_id'],))
rejected(t13)
print('PASS 12: wrong payment source is rejected')

t14,b14,i14=make(); a14=settle(t14); assert a14['status']=='succeeded'
corrupt("update public.customer_payments set currency='AUD' where id=%s",(a14['customer_payment_id'],))
rejected(t14)
print('PASS 13: wrong currency is rejected')


# Phase51: Stripe identity mismatch must fail closed even when other links match.
t15,_,_=make(); a15=settle(t15); corrupt("update public.customer_payments set stripe_payment_intent_id='pi_wrong_identity' where id=%s",(a15['customer_payment_id'],)); rejected(t15)
print('PASS 14: mismatched Stripe PaymentIntent rejected')
t16,_,_=make(); a16=settle(t16); corrupt("update public.customer_payments set stripe_checkout_session_id='cs_wrong_identity' where id=%s",(a16['customer_payment_id'],)); rejected(t16)
print('PASS 15: mismatched Stripe Checkout session rejected')
# Phase53: demonstrate the actual schema permits multiple payment rows for one transaction
# when Stripe IDs differ. This is a documented risk, not a passing security guarantee.
t17,b17,i17=make(); a17=settle(t17)
try:
    execute("insert into public.customer_payments(business_id,invoice_id,amount,payment_source,invoice_payment_transaction_id,currency,stripe_payment_intent_id,stripe_checkout_session_id) values (%s,%s,1,'stripe_connect',%s,'NZD','pi_second_for_same_tx','cs_second_for_same_tx')",(str(b17),str(i17),str(t17)))
except UniqueViolation:
    pass
else:
    raise AssertionError('Duplicate transaction payment was accepted')
assert count(t17)==1, 'Duplicate transaction payment was inserted'
print('PASS 16: duplicate transaction payment rejected by unique index')
print('17 assertions/scenarios defined; PostgreSQL execution required to verify results')

# Phase57: exercise reconstructed production customer-payment triggers without bypass.
t18,b18,i18=make();
try:
    execute("insert into public.customer_payments(business_id,invoice_id,amount) values (%s,%s,1)",(str(uuid.uuid4()),str(i18)))
except Exception as e:
    assert 'same business' in str(e)
else: raise AssertionError('Business ownership trigger did not reject wrong business')
print('PASS 17: guard rejects payment for another business')

t19,b19,i19=make(total=10);
try:
    execute("insert into public.customer_payments(business_id,invoice_id,amount) values (%s,%s,11)",(str(b19),str(i19)))
except Exception as e:
    assert 'exceeds invoice outstanding balance' in str(e)
else: raise AssertionError('Overpayment trigger did not reject')
print('PASS 18: guard rejects payment exceeding invoice total')

t20,b20,i20=make(); a20=settle(t20);
paid,balance=execute('select amount_paid,balance_due from public.invoices where id=%s',(str(i20),),True)
assert float(paid)==25 and float(balance)==75, (paid,balance)
print('PASS 19: refresh trigger updates invoice amount_paid and balance_due')

# Phase58: verify the real guard blocks normal mismatched UPDATEs;
# tests 8/9 above intentionally bypass the guard only to exercise the settlement fail-closed path.
t21,b21,i21=make(); a21=settle(t21)
try:
    execute('update public.customer_payments set business_id=%s where id=%s', (str(uuid.uuid4()),a21['customer_payment_id']))
except Exception as e:
    assert 'same business' in str(e), str(e)
else:
    raise AssertionError('Customer-payment guard accepted wrong-business UPDATE')
assert count(t21)==1
print('PASS 20: real guard rejects wrong-business UPDATE')

t22,b22,i22=make(); a22=settle(t22)
other_invoice=uuid.uuid4()
execute('insert into public.invoices(id,business_id,total,lifecycle_state) values (%s,%s,100,%s)',(str(other_invoice),str(uuid.uuid4()),'issued'))
try:
    execute('update public.customer_payments set invoice_id=%s where id=%s',(str(other_invoice),a22['customer_payment_id']))
except Exception as e:
    assert 'same business' in str(e), str(e)
else:
    raise AssertionError('Customer-payment guard accepted wrong-invoice UPDATE')
assert count(t22)==1
print('PASS 21: real guard rejects cross-business invoice UPDATE')
# Phase61: an otherwise valid transaction with no Stripe identity must fail closed.
t23,b23,i23=make()
execute('update public.invoice_payment_transactions set stripe_payment_intent_id=NULL, stripe_checkout_session_id=NULL where id=%s',(str(t23),))
try:
    settle(t23)
except Exception as e:
    assert 'Online payment has no Stripe payment identity' in str(e), str(e)
else:
    raise AssertionError('Settlement accepted a transaction with no Stripe payment identity')
assert count(t23)==0
assert execute('select status from public.invoice_payment_transactions where id=%s',(str(t23),),True)[0]=='processing'
print('PASS 22: missing Stripe identity rejected with no payment or state change')
print('22 labelled scenarios (including 2a/2b) reached; check individual assertions above')
