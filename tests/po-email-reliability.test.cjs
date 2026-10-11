const fs=require('node:fs');const assert=require('node:assert/strict');
const sql=fs.readFileSync('supabase/migrations/20261012150000_v61142k_po_email_reliability.sql','utf8');
const edge=fs.readFileSync('supabase/functions/send-purchase-order/index.ts','utf8');
for(const name of ['v61142k_reserve_po_email','v61142k_finish_po_email','po_email_one_unresolved_per_order','v61142k_block_po_changes_during_send'])assert.ok(sql.includes(name),`Missing ${name}`);
for(const name of ['v61142k_reserve_po_email','v61142k_finish_po_email','Idempotency-Key','p_outcome:\'uncertain\'','Purchase Order totals need verification'])assert.ok(edge.includes(name),`Missing ${name}`);
assert.ok(sql.includes("v_po.status not in ('draft','approved','sent')"));
assert.ok(sql.includes("auth.role() <> 'service_role'"));
console.log('PO email reliability static checks passed');

// Recovery must require privileged provider verification, not time-based unlocking.
const fsRecovery = require('node:fs');
const recoverySql = fsRecovery.readFileSync('supabase/migrations/20261012160000_v61142l_po_email_recovery.sql','utf8');
if (!recoverySql.includes("auth.role() <> 'service_role'")) throw Error('Recovery must require service role');
if (!recoverySql.includes("a.state <> 'uncertain'")) throw Error('Recovery must only resolve uncertain attempts');
if (!recoverySql.includes('Provider verification evidence required')) throw Error('Recovery must require provider evidence');
