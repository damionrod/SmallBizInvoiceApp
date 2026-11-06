const {PGlite}=require('@electric-sql/pglite');const fs=require('node:fs'),path=require('node:path');
const read=p=>fs.readFileSync(path.join(__dirname,p),'utf8');
module.exports=async()=>{
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;create function auth.role() returns text language sql stable as $$select current_setting('request.jwt.claim.role',true)$$;create function public.current_business_id() returns uuid language sql as $$select null::uuid$$;`);
 await db.exec(read('../settlements/fixtures/current-tables.sql'));
 await db.exec(read('../settlements/fixtures/current-checks.sql'));
 await db.exec(read('../settlements/fixtures/current-functions.sql'));
 await db.exec(read('fixtures/current-tables.sql').replace(/create table public\./g,'create table if not exists public.'));
 await db.exec(read('fixtures/activation-tables.sql'));
 for(const table of ['gst_settings_history','gst_adjustments','financial_settings','invoices','expenses','customer_payments','expense_payments','customer_credit_notes','supplier_credits','customer_refunds','supplier_refunds','supplier_refund_allocations'])await db.exec(`alter table ${table} alter column id set default gen_random_uuid()`);
 await db.exec("alter table gst_adjustments alter column status set default 'active';");
 await db.exec('alter table gst_adjustments add primary key(id);create unique index on gst_settings_history(business_id,effective_from);');
 await db.exec('create table public.bank_reconciliation_groups(id uuid,business_id uuid);create table public.business_owners(id uuid,business_id uuid);');
 await db.exec(read('../settlements/fixtures/current-triggers.sql'));
 await db.exec(read('../../supabase/migrations/20261102014924_gst_payroll_settlements.sql'));
 await db.exec('create schema frindly_cash;');
 await db.exec(read('fixtures/activation-core.sql'));
 const cash=read('../../supabase/migrations/20261102064121_shared_cash_transactions.sql');const checkAt=cash.indexOf('create function frindly_cash.check_date(');await db.exec(cash.slice(checkAt,cash.indexOf('end $$;',checkAt)+7));
 await db.exec(read('../../supabase/migrations/20261104083000_gst_settlement_reversal.sql'));
 await db.exec(read('../settlements/fixtures/cash-profit-loss.sql'));
 await db.exec(read('../settlements/fixtures/capital-balance-sheet.sql'));
 await db.exec(read('fixtures/current-functions.sql'));
 await db.exec(read('../../supabase/migrations/20261106033020_gst_basis_change_preview.sql'));
 await db.exec(read('../../supabase/migrations/20261106035826_gst_basis_change_activation.sql'));
 await db.exec(read('../../supabase/migrations/20261106050956_gst_basis_activation_lookup_indexes.sql'));
 // Actual immutable-return trigger, in addition to the new finalisation guard.
 await db.exec(`create function public.v6170e_guard_gst_return_mutation() returns trigger language plpgsql set search_path=public as $$begin if old.status='finalised' then raise exception 'Finalised GST return is immutable';end if;return new;end$$;create trigger trg_v6170e_guard_gst_return before delete or update on public.gst_returns for each row execute function public.v6170e_guard_gst_return_mutation();`);
 const scalar=async(q,p=[])=>Object.values((await db.query(q,p)).rows[0])[0];let seq=0;const uid='00000000-0000-0000-0000-000000000001';
 await db.query('insert into auth.users values($1)',[uid]);await scalar("select set_config('request.jwt.claim.sub',$1,false)",[uid]);await scalar("select set_config('request.jwt.claim.role','authenticated',false)");
 const account=(b,k,n,t)=>scalar('select frindly_cash.account($1,$2,$3,$4)',[b,k,n,t]);
 const journal=(b,date,kind,id,lines)=>scalar('select public.v6192_create_posted_journal($1,$2,$3,$4,$5,null,$4,$6)',[b,date,kind==='customer_credit_note'?'credit_note':kind,kind,id,JSON.stringify(lines)]);
 const line=(account_id,debit,credit)=>({account_id,debit,credit});
 async function seed(old,opts={}){
  const b=`10000000-0000-0000-0000-${String(++seq).padStart(12,'0')}`;
  await db.query("insert into businesses(id,name) values($1,'Isolated NZ GST fixture')",[b]);await db.query("insert into business_memberships(business_id,user_id,role,status) values($1,$2,'owner','active')",[b,uid]);
  if(seq===1)await db.query('insert into profiles(id,business_id,active_business_id) values($1,$2,$2)',[uid,b]);else await db.query('update profiles set active_business_id=$1 where id=$2',[b,uid]);
  await db.query("insert into accounting_periods(business_id,period_start,period_end,financial_year,status) values($1,'2026-01-01','2027-12-31',2027,'open')",[b]);
  await db.query("insert into financial_settings(business_id,gst_registered,gst_accounting_basis,gst_filing_frequency,balance_date_month,balance_date_day) values($1,true,$2,'monthly',3,31)",[b,old]);
  await db.query("insert into gst_settings_history(business_id,effective_from,gst_registered,accounting_basis,filing_frequency,balance_date_month,balance_date_day,jurisdiction) values($1,'2026-01-01',true,$2,'monthly',3,31,'NZ')",[b,old]);
  const bankGl=await account(b,'bank_main','Main bank','asset');await db.query("update accounting_accounts set account_subtype='bank' where id=$1",[bankGl]);
  const bank=await scalar("insert into bank_accounts(business_id,name,accounting_account_id,is_default) values($1,'Main',$2,true) returning id",[b,bankGl]);
  const out=await account(b,'gst_payable','GST collected','liability'),input=await account(b,'gst_receivable','GST claimable','asset'),ar=await account(b,'test_ar','Trade debtors','asset'),ap=await account(b,'test_ap','Trade creditors','liability'),sales=await account(b,'test_sales','Sales','income'),cost=await account(b,'test_cost','Costs','expense');
  const saleTax=opts.zeroTax?0:150;
  const inv=await scalar("insert into invoices(business_id,invoice_date,invoice_number,total,gst,lifecycle_state,amount_paid,customer_id) values($1,'2026-09-01','TEST-SALE',1150,$2,'issued',0,'20000000-0000-0000-0000-000000000001') returning id",[b,saleTax]);
  const fraction=opts.fraction??1,tax=(opts.zeroTax?0:60)*fraction;
  const exp=await scalar("insert into expenses(business_id,invoice_date,expense_number,total_amount,ex_gst,gst_amount,business_use_percent,lifecycle_state,amount_paid) values($1,'2026-09-01','TEST-BILL',460,$3,$4,$2,'recorded',0) returning id",[b,fraction*100,opts.zeroTax?460:400,opts.zeroTax?0:60]);
  await journal(b,'2026-09-01','invoice',inv,[line(ar,1150,0),line(sales,0,1150-saleTax),line(out,0,saleTax)]);
  const privateUse=await account(b,'test_drawings','Private use','equity');
  await journal(b,'2026-09-01','expense',exp,[line(cost,(460-(opts.zeroTax?0:60))*fraction,0),line(privateUse,460*(1-fraction),0),line(input,tax,0),line(ap,0,460)]);
  async function payInvoice(amount,date='2026-09-15',estimated=false){const id=await scalar('insert into customer_payments(business_id,invoice_id,payment_date,amount,is_legacy_estimate) values($1,$2,$3,$4,$5) returning id',[b,inv,date,amount,estimated]);await db.query('update invoices set amount_paid=coalesce(amount_paid,0)+$1 where id=$2',[amount,inv]);await journal(b,date,'customer_payment',id,[line(bankGl,amount,0),line(ar,0,amount)]);return id;}
  async function payExpense(amount,date='2026-09-15'){const id=await scalar('insert into expense_payments(business_id,expense_id,payment_date,amount) values($1,$2,$3,$4) returning id',[b,exp,date,amount]);await db.query('update expenses set amount_paid=coalesce(amount_paid,0)+$1 where id=$2',[amount,exp]);await journal(b,date,'supplier_payment',id,[line(ap,amount,0),line(bankGl,0,amount)]);return id;}
  if(opts.paidInvoice)await payInvoice(opts.paidInvoice);if(opts.paidExpense)await payExpense(opts.paidExpense);
  async function prior(){return scalar("select to_jsonb(public.frindly_save_gst_basis_v1('2026-09-01','2026-09-30','finalised',null))");}
  async function preview(basis,kind='ird_change',from='2026-10-01',to='2026-10-31'){return scalar('select public.frindly_preview_gst_basis_change_v1($1,$2,$3,$1,$4)',[from,to,basis,kind]);}
  async function request(basis,kind='ird_change',from='2026-10-01',to='2026-10-31'){
   const p=await preview(basis,kind,from,to);const id=await scalar('select gen_random_uuid()');return scalar('select to_jsonb(public.frindly_request_gst_basis_change_v1($1,$2,$3,$4,$2,$5,$6,$7,true))',[id,from,to,basis,kind,'Isolated approval/correction evidence',p.fingerprint]);
  }
  async function apply(q){const p=await scalar('select public.frindly_gst_basis_request_review_v1($1)',[q.id]);return scalar('select to_jsonb(public.frindly_apply_gst_basis_change_v1($1,$2,true))',[q.id,p.preview?.fingerprint||p.fingerprint]);}
  const balance=id=>scalar("select coalesce(sum(l.credit-l.debit),0) from accounting_journal_lines l join accounting_journals j on j.id=l.journal_id and j.business_id=l.business_id where l.account_id=$1 and j.status in ('posted','reversed')",[id]);
  return {b,uid,bank,bankGl,out,input,ar,ap,sales,cost,inv,exp,fraction,payInvoice,payExpense,prior,preview,request,apply,balance};
 }
 return {db,scalar,seed,account,journal,line,uid,read};
};
