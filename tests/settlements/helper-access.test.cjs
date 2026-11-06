const { PGlite } = require('@electric-sql/pglite');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const assert = require('node:assert/strict');
(async () => {
 const db = new PGlite();
 await db.exec(`CREATE TABLE public.subscriptions(business_id uuid,status text,manual_access_until timestamptz,trial_ends_at timestamptz,cancel_at_period_end boolean,cancel_at timestamptz,current_period_end timestamptz,created_at timestamptz DEFAULT now());
 CREATE FUNCTION public.current_business_id() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('test.business_id',true),'')::uuid $$;`);
 const sql = readFileSync(resolve(__dirname,'../../supabase/migrations/20261106012840_helper_manual_access_extension.sql'),'utf8');
 await db.exec(sql);
 await db.exec(sql); // Replacing the function is safe to repeat.
 const own='00000000-0000-0000-0000-000000000001', other='00000000-0000-0000-0000-000000000002';
 const future='2099-01-01', past='2000-01-01';
 let checked=0;
 async function check(label, sub, expected, business=own) {
  await db.exec('TRUNCATE public.subscriptions');
  await db.query("SELECT set_config('test.business_id',$1,false)",[business]);
  if(sub)await db.query(`INSERT INTO public.subscriptions(business_id,status,manual_access_until,trial_ends_at,cancel_at,current_period_end,cancel_at_period_end) VALUES ($1,$2,$3,$4,$5,$6,$7)`,[sub.business_id||own,sub.status||'active',sub.manual||null,sub.trial||null,sub.cancel||null,sub.period||null,!!sub.cancel_end]);
  const {rows}=await db.query('SELECT * FROM public.v61107aax_helper_subscription_access()');
  assert.deepEqual(rows,[expected],label);checked++;
 }
 await check('approved extension overrides old cancellation',{manual:future,cancel:past},{allowed:true,reason:'manual_access'});
 await check('expired extension cannot override cancellation',{manual:past,cancel:past},{allowed:false,reason:'ended'});
 await check('suspension still blocks extension',{status:'suspended',manual:future},{allowed:false,reason:'suspended'});
 await check('cancelled subscription with approved extension matches app gate',{status:'canceled',manual:future},{allowed:true,reason:'manual_access'});
 await check('active subscription unchanged',{}, {allowed:true,reason:'active'});
 await check('valid trial unchanged',{status:'trialing',trial:future},{allowed:true,reason:'trial'});
 await check('expired trial denied',{status:'trialing',trial:past},{allowed:false,reason:'trial_ended'});
 await check('payment grace unchanged',{status:'past_due',period:new Date(Date.now()-86400000).toISOString()},{allowed:true,reason:'payment_grace'});
 await check('expired grace denied',{status:'past_due',period:past},{allowed:false,reason:'past_due'});
 await check('missing subscription denied',null,{allowed:false,reason:'no_subscription'});
 await check('missing business denied',null,{allowed:false,reason:'no_business'},'');
 await check('another tenant extension cannot grant access',{business_id:other,manual:future},{allowed:false,reason:'no_subscription'});
 await db.close();
 console.log(`${checked} helper access regression cases passed`);
})().catch(e=>{console.error(e);process.exitCode=1;});
