'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const planning=require('../public/business-planning.js');
const {readAll}=require('../public/data-access.js');
test('January through March stay in the preceding April business year',()=>{
  for(const [on,end] of [['2027-01-15','2027-03-31'],['2027-03-31','2027-03-31'],['2026-10-17','2027-03-31']]){
    const p=planning.taxYear({},on);assert.equal(p.from,'2026-04-01');assert.equal(p.end,end);assert.ok(p.from<=p.to);
  }
  assert.equal(planning.taxYear({},'2027-04-01').from,'2027-04-01');
});
test('non-standard and leap-year balance dates keep exact calendar bounds',()=>{
  const june={balance_date_month:6,balance_date_day:30};
  assert.equal(planning.taxYear(june,'2027-01-15').from,'2026-07-01');
  assert.equal(planning.taxYear(june,'2027-07-01').end,'2028-06-30');
  assert.equal(planning.taxYear({},'2024-03-31').yearDays,366);
  const feb={balance_date_month:2,balance_date_day:29};
  assert.equal(planning.taxYear(feb,'2029-02-01').from,'2028-03-01');
  assert.equal(planning.taxYear(feb,'2028-02-29').end,'2028-02-29');
});
test('financial-year start is used when a balance date has not been configured',()=>{
  const p=planning.taxYear({financial_year_start_month:7,financial_year_start_day:1},'2027-01-15');
  assert.equal(p.from,'2026-07-01');assert.equal(p.end,'2027-06-30');
});
test('invalid dates and malformed balance dates do not become an estimate',()=>{
  for(const on of ['2027-02-30','not a date'])assert.throws(()=>planning.taxYear({},on));
  assert.throws(()=>planning.taxYear({balance_date_month:4,balance_date_day:31},'2027-01-01'));
});
test('annualisation uses elapsed days in this business year, not calendar month',()=>{
  const x=planning.estimate({estimated_tax_rate:28},1000,'2026-10-17');
  assert.equal(x.period.elapsedDays,200);assert.equal(x.annualised,1825);assert.equal(x.tax,511);
});
test('missing profit or rate stays unknown and an explicit zero rate remains valid',()=>{
  assert.throws(()=>planning.estimate({},undefined,'2027-01-15'));
  assert.equal(planning.estimate({},100,'2027-01-15').tax,null);
  assert.equal(planning.estimate({estimated_tax_rate:0},100,'2027-01-15').tax,0);
  assert.equal(planning.estimate({estimated_tax_rate:28},-100,'2027-01-15').tax,0);
});
test('the NZ business date does not slip back to yesterday before UTC midnight',()=>{
  assert.equal(planning.today(new Date('2027-01-14T12:30:00Z')),'2027-01-15');
});
test('usual dates stay in the correct tax cycle and are not invented for six-monthly GST or another balance date',()=>{
  assert.deepEqual(planning.usualStandardDates({},'2027-01-15'),['2026-08-28','2027-01-15','2027-05-07']);
  assert.deepEqual(planning.usualStandardDates({gst_filing_frequency:'six_monthly'},'2027-01-15'),[]);
  assert.deepEqual(planning.usualStandardDates({balance_date_month:6,balance_date_day:30},'2027-01-15'),[]);
});
function pages(rows,{serverLimit=2,failAt=-1,onRead=()=>{}}={}){
  const calls=[];
  return {calls,factory(){let after=null;const q={order(name){assert.equal(name,'id');return q},limit(){return q},gt(name,id){assert.equal(name,'id');after=id;return q},then(resolve){calls.push(after);onRead(calls.length);resolve(calls.length===failAt?{data:null,error:new Error('Access denied')}:{data:rows.filter(x=>after===null||x.id>after).slice(0,serverLimit),error:null})}};return q}};
}
test('readAll continues through server-capped short pages and finishes only at an empty page',async()=>{
  const rows=Array.from({length:7},(_,i)=>({id:i+1})),p=pages(rows);
  assert.deepEqual(await readAll(p.factory),rows);assert.deepEqual(p.calls,[null,2,4,6,7]);
});
test('readAll propagates a late page failure instead of returning an incomplete success',async()=>{
  const p=pages([{id:1},{id:2},{id:3}],{failAt:2});await assert.rejects(readAll(p.factory),/Access denied/);
});
test('readAll discards data if the business changes while a page is in flight',async()=>{
  let current='A';const p=pages([{id:1}],{onRead(){current='B'}});
  await assert.rejects(readAll(p.factory,{guard(){if(current!=='A')throw new Error('Business changed')}}),/Business changed/);
});
test('readAll rejects repeated pages and missing primary keys',async()=>{
  const p=pages([{id:null}]);await assert.rejects(readAll(p.factory),/could not|advance/);
  const repeat=()=>{const q={order(){return q},limit(){return q},gt(){return q},then(resolve){resolve({data:[{id:'a'}]})}};return q};
  await assert.rejects(readAll(repeat),/pagination did not advance/);
});
const saas=fs.readFileSync(path.join(__dirname,'../public/saas.js'),'utf8');
function exportRuntime(state){
  const start=saas.indexOf('  const BUSINESS_EXPORT_MANIFEST='),end=saas.indexOf('  async function addStoredFiles(',start);
  const context=vm.createContext({state,window:{FrindlyData:{readAll}},console});
  vm.runInContext(saas.slice(start,end)+';globalThis.manifest=BUSINESS_EXPORT_MANIFEST;',context);return context;
}
test('exports use tenant-filtered stable pagination and include newer business record families',async()=>{
  const rows=Array.from({length:1201},(_,i)=>({id:String(i).padStart(5,'0'),business_id:'A'}));
  const p=pages(rows,{serverLimit:500});let filters=0;
  const c=exportRuntime({business:{id:'A'},client:{from(table){assert.equal(table,'expenses');const q=p.factory();q.select=()=>q;q.eq=(name,id)=>{assert.equal(name,'business_id');assert.equal(id,'A');filters++;return q};return q}}});
  const out=await c.exportTable('expenses','A');assert.equal(out.rows.length,1201);assert.equal(out.error,null);assert.equal(filters,4);
  const manifest=Object.values(c.manifest).flat();for(const name of ['expense_revisions','import_records','import_commit_events','owner_current_account_entries','payroll_ird_filings','payroll_migration_opening_balances'])assert.ok(manifest.includes(name),name);
});
test('export sanitisation excludes nested credentials and neutralises spreadsheet formula cells',()=>{
  const c=exportRuntime({});
  assert.equal(JSON.stringify(c.exportClean({a:{password:'secret',access_token:'secret',token_hash:'secret',amount:-5}})),JSON.stringify({a:{amount:-5}}));
  assert.equal(c.csvCell('=HYPERLINK("bad")'),'"\'=HYPERLINK(""bad"")"');
  assert.equal(c.csvCell('-123.45'),'-123.45');assert.equal(c.csvCell(-123.45),'-123.45');
  const value=c.exportClean(JSON.parse('{"__proto__":{"value":"retained"}}'));
  assert.equal(Object.getPrototypeOf(value),null);assert.equal(value.__proto__.value,'retained');
});

test('NZ instalment guidance is not shown for an Australian business',()=>{
  assert.deepEqual(planning.usualStandardDates({country:'AU'},'2027-01-15'),[]);
});
function settingsHarness(result,{during=()=>{}}={}){
  const source=fs.readFileSync(path.join(__dirname,'../public/saas.js'),'utf8');
  const start=source.indexOf('  async function saveBusinessSettings(s,{expectedRevision}={}){'),end=source.indexOf('\n  let billingReadyBusiness',start);
  const messages=[],cached=[],calls=[],state={business:{id:'business-a',updated_at:'revision-a',settings:{company:'Before'}},client:{async rpc(name,args){calls.push({name,args});during(state);return result}}};
  const ctx={state,stripInfra:s=>{const x={...s};delete x.supabaseKey;delete x.supabaseUrl;return x},message:m=>messages.push(m),writeBusinessSettingsCache:(s,id)=>cached.push({s,id}),console:{warn(){}}};
  vm.runInNewContext(source.slice(start,end)+'\nthis.save=saveBusinessSettings;',ctx);
  return {save:ctx.save,state,messages,cached,calls};
}
test('settings caches and canonical revision change only after server confirmation',async()=>{
  const h=settingsHarness({data:{id:'business-a',updated_at:'revision-b',settings:{company:'Canonical'}},error:null});
  assert.equal(await h.save({company:'Request',supabaseKey:'secret'}),true);
  assert.equal(h.calls[0].args.p_expected_updated_at,'revision-a');assert.equal(h.calls[0].args.p_settings.supabaseKey,undefined);
  assert.equal(h.state.business.settings.company,'Canonical');assert.equal(h.state.business.updated_at,'revision-b');assert.equal(h.cached.length,1);
});
test('a rejected settings save preserves the prior state and cache',async()=>{
  const h=settingsHarness({data:null,error:{message:'Reload Settings before saving.'}});
  assert.equal(await h.save({company:'Wrong'}),false);assert.equal(h.cached.length,0);assert.equal(h.state.business.settings.company,'Before');assert.match(h.messages[0],/Reload/);
});
test('a late settings response cannot update a different active business',async()=>{
  const h=settingsHarness({data:{id:'business-a',updated_at:'revision-b',settings:{company:'Wrong'}},error:null},{during:s=>{s.business={id:'business-b',settings:{company:'Other'}}}});
  assert.equal(await h.save({company:'Request'}),false);assert.equal(h.cached.length,0);assert.equal(h.state.business.settings.company,'Other');
});
test('unverified settings responses and missing revisions never become a successful save',async()=>{
  const h=settingsHarness({data:{id:'business-a'},error:null});assert.equal(await h.save({}),false);assert.equal(h.cached.length,0);
  delete h.state.business.updated_at;assert.equal(await h.save({}),false);assert.equal(h.calls.length,1);
});
const tax=require('../public/tax-overview.js');
test('tax overview includes finalised NZ payroll before any filing has happened',()=>{
  const runs=[{id:'a',country_code:'NZ',status:'finalised',pay_date:'2026-10-17'},{id:'b',country_code:'NZ',status:'draft'},{id:'c',country_code:'AU',status:'finalised'}];
  const rows=tax.payrollRows(runs,[]);assert.equal(rows.length,1);assert.equal(rows[0].filing,null);
});
test('a downloaded file stays a downloaded file rather than becoming an accepted filing',()=>{
  const runs=[{id:'a',country_code:'NZ',status:'finalised'}],events=[{id:'1',pay_run_id:'a',created_at:'2026-10-16',status:'draft'},{id:'2',pay_run_id:'a',created_at:'2026-10-17',status:'file_downloaded'}];
  assert.equal(tax.payrollRows(runs,events)[0].filing.status,'file_downloaded');
  assert.equal(tax.value(null),null);assert.equal(tax.value(''),null);assert.equal(tax.value(0),0);assert.equal(tax.value('-15.25'),-15.25);
});
test('tax overview keeps unavailable sections distinct from an empty visible result',async()=>{
  const calls=[];const client={from(table){let bid;const q={select(){return q},eq(k,v){assert.equal(k,'business_id');bid=v;return q},order(){return q},limit(){return q},then(resolve){calls.push({table,bid});resolve(table==='gst_returns'?{error:new Error('denied'),data:null}:{error:null,data:[]})}};return q}};
  const result=await tax.load(client,'business-a');assert.equal(result.gst.available,false);assert.equal(result.filings.available,true);assert.equal(result.filings.rows.length,0);assert.ok(calls.every(c=>c.bid==='business-a'));
});
test('tax overview discards all sections after the business changes',async()=>{
  let changed=false;const client={from(){const q={select(){return q},eq(){return q},order(){return q},limit(){return q},then(resolve){changed=true;resolve({data:[],error:null})}};return q}};
  await assert.rejects(tax.load(client,'business-a',()=>{if(changed)throw new Error('Business changed')}),/Business changed/);
});

test('a settings form keeps the revision it opened with even after another panel saves',async()=>{
 const h=settingsHarness({data:null,error:{message:'Settings changed'}});h.state.business.updated_at='newer-panel-revision';
 assert.equal(await h.save({company:'Old form'},{expectedRevision:'form-opened-revision'}),false);
 assert.equal(h.calls[0].args.p_expected_updated_at,'form-opened-revision');assert.equal(h.cached.length,0);
});
const starting=require('../public/starting-balances.js');
const chart=[{id:'asset',account_code:'100',account_name:'Bank',archived:false,is_control:true},{id:'equity',account_code:'800',account_name:'Equity',archived:false}];
const columns={code:0,debit:1,credit:2};
test('starting-balance review compares targets to the existing ledger without posting them twice',()=>{
 const r=starting.review([['100','100.00',''],['800','','100.00']],columns,chart,[{account_code:'100',debits:'40.00',credits:'0'},{account_code:'800',debits:'0',credits:'40.00'}]);
 assert.equal(r.errors.length,0);assert.equal(r.balanced,true);assert.equal(r.lines[0].difference,6000);assert.equal(r.lines[1].difference,-6000);assert.equal(r.canPost,false);assert.deepEqual(r.reviewRequired,['100']);
});
test('unknown and archived accounts need an explicit active account mapping',()=>{
 let r=starting.review([['OLD-BANK','100',''],['800','','100']],columns,chart,[]);assert.match(r.errors.join(' '),/Choose an active/);
 r=starting.review([['OLD-BANK','100',''],['800','','100']],columns,chart,[],{0:'asset'});assert.equal(r.errors.length,0);
 r=starting.review([['100','100',''],['800','','100']],columns,chart,[],{0:''});assert.match(r.errors.join(' '),/Choose an active/);
 assert.throws(()=>starting.review([],columns,[...chart,{id:'other',account_code:'100'}],[]),/ambiguous/);
});
test('duplicate accounts, missing existing balances and an unbalanced source are not approved',()=>{
 let r=starting.review([['100','50',''],['100','50',''],['800','','100']],columns,chart,[]);assert.match(r.errors.join(' '),/more than once/);
 r=starting.review([['100','100','']],columns,chart,[{account_code:'800',debits:'0',credits:'40'}]);assert.match(r.errors.join(' '),/do not balance/);assert.match(r.errors.join(' '),/800 is missing/);
});
test('starting-balance amounts use exact cents and reject ambiguous precision or invalid signs',()=>{
 assert.equal(starting.cents('1,234.56'),123456);assert.equal(starting.cents('(123.45)'),-12345);assert.equal(starting.cents('90071992547409.91'),Number.MAX_SAFE_INTEGER);
 for(const v of ['1.005','1,23','1e3','NaN','90071992547409.92'])assert.throws(()=>starting.cents(v));
 const r=starting.review([['100','-100',''],['800','','-100']],columns,chart,[]);assert.match(r.errors.join(' '),/non-negative/);
 assert.throws(()=>starting.review([], {code:0,debit:0,credit:2},chart,[]),/different columns/);
});
test('starting-balance column suggestions are deterministic and leave unfamiliar headings unmapped',()=>{
 assert.deepEqual(starting.mapping(['Account Code','Debit Balance','Credit Balance']),columns);
 assert.deepEqual(starting.mapping(['mystery','something','else']),{code:-1,debit:-1,credit:-1});
});
