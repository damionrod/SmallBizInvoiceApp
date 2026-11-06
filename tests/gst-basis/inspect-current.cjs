// Isolated audit: exact database function definitions captured 6 November 2026.
// No connection to Supabase and no genuine business records are mutated.
const {PGlite}=require('@electric-sql/pglite');
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
(async()=>{
 const db=new PGlite();
 await db.exec(`CREATE SCHEMA auth;CREATE SCHEMA frindly_cash;
 CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$SELECT '00000000-0000-0000-0000-000000000001'::uuid$$;
 CREATE FUNCTION public.current_business_id() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('test.business',true),'')::uuid $$;
 CREATE FUNCTION public.v6147_can_read_area(uuid,text) RETURNS boolean LANGUAGE sql AS $$SELECT true$$;
 CREATE FUNCTION public.v6147_can_write_area(uuid,text) RETURNS boolean LANGUAGE sql AS $$SELECT true$$;`);
 await db.exec(fs.readFileSync(path.join(__dirname,'fixtures/current-tables.sql'),'utf8'));
 await db.exec(`CREATE UNIQUE INDEX ON public.gst_settings_history(business_id,effective_from);CREATE UNIQUE INDEX ON public.gst_returns(business_id,period_start,period_end);`);
 await db.exec(fs.readFileSync(path.join(__dirname,'fixtures/current-functions.sql'),'utf8'));
 const bid='10000000-0000-0000-0000-000000000001',other='10000000-0000-0000-0000-000000000002';
 const scalar=async(s,p=[])=>Object.values((await db.query(s,p)).rows[0])[0];
 await scalar("select set_config('test.business',$1,false)",[bid]);
 const results=[];
 async function seed(previous,next){
 await db.exec('TRUNCATE gst_settings_history,invoices,expenses,customer_payments,expense_payments,gst_returns');
 await db.query("insert into gst_settings_history(business_id,effective_from,gst_registered,accounting_basis,filing_frequency) values($1,'2026-01-01',true,$2,'monthly'),($1,'2026-10-01',true,$3,'monthly')",[bid,previous,next]);
 await db.query("insert into invoices(id,business_id,invoice_date,invoice_number,total,gst,lifecycle_state) values('20000000-0000-0000-0000-000000000001',$1,'2026-09-01','TEST-SALE',1150,150,'issued')",[bid]);
 await db.query("insert into expenses(id,business_id,invoice_date,expense_number,total_amount,ex_gst,gst_amount,business_use_percent,lifecycle_state) values('30000000-0000-0000-0000-000000000001',$1,'2026-09-01','TEST-BILL',460,400,60,100,'recorded')",[bid]);
 }
 // Independent IR546 March 2026, p4: debtor GST=150; creditor GST=60.
 for(const [from,to,expected] of [['invoice','payments',-90],['payments','invoice',90],['invoice','hybrid',60],['hybrid','invoice',-60],['payments','hybrid',150],['hybrid','payments',-150]]){
  await seed(from,to);
  const first=await scalar("select public.frindly_gst_boundary_basis_v1('2026-10-01','2026-10-31',null)");
  const repeat=await scalar("select public.frindly_gst_boundary_basis_v1('2026-10-01','2026-10-31',null)");
  assert.deepEqual(first,repeat,'Read-only calculation is repeatable');
  const actual=Number(first.debit_adjustments)-Number(first.credit_adjustments);
  results.push({case:from+' -> '+to,expected_net_adjustment:expected,actual_net_adjustment:actual,result:actual===expected?'PASS':'FAIL',blocking_review:(first.review_items||[]).some(x=>x.severity==='blocking')});
 }
 await seed('invoice','payments');
 await db.query("insert into customer_payments(business_id,invoice_id,payment_date,amount,is_legacy_estimate) values($1,'20000000-0000-0000-0000-000000000001','2026-11-03',1150,false)",[bid]);
 const sept=await scalar("select public.frindly_gst_boundary_basis_v1('2026-09-01','2026-09-30',null)"),nov=await scalar("select public.frindly_gst_boundary_basis_v1('2026-11-01','2026-11-30',null)");
 results.push({case:'Invoice GST followed by payment after basis change',expected_lifetime_sales_gst:150,actual_sales_gst:Number(sept.gst_collected)+Number(nov.gst_collected),missing_transition_credit:150});
 // Save path independently demonstrates that missing transition evidence is not a blocker.
 let finalised=false,finaliseError=null;
 try{await scalar("select public.frindly_save_gst_basis_v1('2026-10-01','2026-10-31','finalised',null)");finalised=true;}catch(e){finaliseError=e.message;}
 results.push({case:'Missing transition reconciliation prevents finalisation',expected_finalised:false,actual_finalised:finalised,error:finaliseError});
 await scalar("select public.v6170e_set_gst_settings(true,'TEST','hybrid','monthly',3::smallint,31::smallint,'2026-10-01')");
 const settings=await scalar("select accounting_basis from gst_settings_history where business_id=$1 and effective_from='2026-10-01'",[bid]);
 results.push({case:'Settings basis mutation affecting finalised return',expected_basis:'payments',actual_basis:settings});
 await scalar("select set_config('test.business',$1,false)",[other]);
 const isolated=await scalar("select public.frindly_gst_boundary_basis_v1('2026-11-01','2026-11-30',null)");
 assert.equal(Number(isolated.gst_collected),0,'Other tenant sees no sales');
 console.log(JSON.stringify({captured_at:'2026-11-06',checks:results,repeatability:'PASS',business_filtering:'PASS',note:'Fixture auth predicates are stubs; this is not a complete RLS or permission test.'},null,2));
 await db.close();
})().catch(e=>{console.error(e);process.exitCode=1});
