from pathlib import Path
import ast
p=Path(__file__).parent
sql=(p/'02_settlement_function.sql').read_text()
tests=(p/'run_tests.py').read_text()
ast.parse(tests)
assert sql.count("raise exception 'Online payment has no Stripe payment identity'")==1
assert 'nullif(btrim(coalesce(v_tx.stripe_payment_intent_id' in sql
assert 'nullif(btrim(coalesce(v_tx.stripe_checkout_session_id' in sql
assert "assert count(t23)==0" in tests
assert "=='processing'" in tests
assert 'if v_tx.status = \'succeeded\' then' in sql
assert 'v6181_fixture_payment_link_verified' in sql
assert 'FOR UPDATE' in sql.upper()
print('PASS: 8 offline source/syntax assertions')
