const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const app=fs.readFileSync(path.join(__dirname,'../public/app.js'),'utf8');
const bank=fs.readFileSync(path.join(__dirname,'../public/bank-reconciliation.js'),'utf8');
function take(source,start,end){const a=source.indexOf(start),b=source.indexOf(end,a);assert.ok(a>=0&&b>a,`Missing source boundary: ${start}`);return source.slice(a,b)}
function fixture(events=[],options={}){
  const calls=[],storage=new Map(),cached=[],warnings=[];
  const window={SAAS:{state:{business:{id:'business-a'}}}};
  const sb={from(table){
    const filters=[],sorts=[];let offset=0,end=99;
    const q={select(){return q},eq(k,v){filters.push([k,v]);return q},in(k,v){filters.push([k,v]);return q},order(k,v){sorts.push([k,v]);return q},range(a,b){offset=a;end=b;return q},
      async then(resolve,reject){try{
        assert.equal(table,'email_delivery_events');calls.push({table,filters,sorts,offset,end});
        if(options.onRead)await options.onRead();
        if(options.fail)return resolve({data:null,error:new Error('History unavailable')});
        const rows=events.filter(e=>filters.every(([k,v])=>Array.isArray(v)?v.includes(e[k]):e[k]===v)).sort((a,b)=>String(b.sent_at).localeCompare(String(a.sent_at))||String(b.id).localeCompare(String(a.id)));
        resolve({data:rows.slice(offset,Math.min(end+1,offset+(options.apiCap||100))),error:null});
      }catch(e){reject(e)}}};return q;
  }};
  const context={window,sb,console:{warn(...x){warnings.push(x)}},localStorage:{getItem:k=>storage.get(k)||null,setItem(k,v){if(options.storageFails)throw Error('Quota exceeded');storage.set(k,v)}},tenantStorageKey:key=>`${key}:${window.SAAS.state.business.id}`,cacheInvoice:x=>cached.push(x)};
  vm.createContext(context);
  vm.runInContext(take(app,'const invoiceEmailEvidence=new WeakMap();','function emailActivityHuman('),context);
  vm.runInContext(take(app,'async function markInvoiceEmailed(inv,to)','async function refreshInvoiceFromCloud('),context);
  return {context,window,storage,calls,cached,warnings};
}
const invoice=id=>({id,business_id:'business-a',invoice_number:`INV-${id}`});
const event=(id,source_id,status='sent',extra={})=>({id,source_id,status,business_id:'business-a',source_table:'invoices',message_type:'invoice',recipient:'billing@example.test',sent_at:'2026-10-16T12:00:00Z',...extra});
test('a second computer reads invoice sending evidence from the server with no local cache',async()=>{
  const f=fixture([event('e1','i1')]),rows=[invoice('i1')];
  await f.context.attachInvoiceEmailStatuses(rows,'business-a');
  assert.equal(f.context.getEmailStatus(rows[0]).sent,true);
  assert.equal(f.context.getEmailStatus(rows[0]).source,'server');
  assert.match(f.context.sentStatusText(rows[0]),/Sent to email provider/);
  assert.doesNotMatch(f.context.sentStatusText(rows[0]),/Delivered/);
  assert.equal(f.storage.size,0);
});
test('tenant, source table and message type constrain all summary queries',async()=>{
  const f=fixture([event('e1','i1','sent',{business_id:'other-business'}),event('e2','i1','sent',{message_type:'invoice_reminder'}),event('e3','i1','sent',{source_table:'quotes'})]),rows=[invoice('i1')];
  await f.context.attachInvoiceEmailStatuses(rows,'business-a');
  assert.equal(f.context.getEmailStatus(rows[0]).sent,false);
  assert.equal(f.context.getEmailStatus(rows[0]).status,'no_activity');
  for(const c of f.calls){assert.deepEqual(c.filters.slice(0,3),[['business_id','business-a'],['source_table','invoices'],['message_type','invoice']])}
});
test('latest attempt and delivery result are shown without treating queued or failed as sent',async()=>{
  for(const [status,sent,label] of [['delivered',true,'Delivered'],['bounced',true,'bounced'],['failed',false,'failed'],['queued',false,'queued']]){
    const f=fixture([event('older','i1'),event('newer','i1',status,{sent_at:'2026-10-17T12:00:00Z'})]),rows=[invoice('i1')];
    await f.context.attachInvoiceEmailStatuses(rows,'business-a');
    assert.equal(f.context.getEmailStatus(rows[0]).sent,sent,status);assert.match(f.context.sentStatusText(rows[0]),new RegExp(label));
  }
});
test('pagination does not miss records when the server caps results below the requested page size',async()=>{
  const events=Array.from({length:111},(_,i)=>event(`event-${i}`,`invoice-${i}`)),rows=events.map(e=>invoice(e.source_id));
  const f=fixture(events,{apiCap:7});await f.context.attachInvoiceEmailStatuses(rows,'business-a');
  assert.equal(rows.filter(x=>f.context.getEmailStatus(x).sent).length,111);
  assert.ok(f.calls.length>16);assert.ok(f.calls.every(c=>c.end-c.offset===99));
});
test('history failure is unknown and is not displayed as an unsent invoice',async()=>{
  const f=fixture([],{fail:true}),rows=[invoice('i1')];await f.context.attachInvoiceEmailStatuses(rows,'business-a');
  assert.equal(f.context.getEmailStatus(rows[0]).known,false);
  assert.match(f.context.sentStatusText(rows[0]),/history unavailable/);
});
test('switching businesses discards an in-flight email-history response',async()=>{
  let f;f=fixture([event('e1','i1')],{onRead:()=>{f.window.SAAS.state.business.id='business-b'}});
  const rows=await f.context.attachInvoiceEmailStatuses([invoice('i1')],'business-a');assert.equal(rows.length,0);
});
test('successful sends keep immediate UI evidence without any invoice-table writes',async()=>{
  const f=fixture(),out=await f.context.markInvoiceEmailed(invoice('i1'),'billing@example.test');
  assert.equal(f.calls.length,0);assert.equal(f.cached.length,1);
  assert.equal(f.context.getEmailStatus(out).source,'send_response');assert.equal(f.context.getEmailStatus(out).sent,true);
});
test('server evidence is temporary UI state and cannot be spread into persisted invoice payloads',async()=>{
  const f=fixture([event('e1','i1')]),rows=[invoice('i1')];const before=JSON.stringify(rows);
  await f.context.attachInvoiceEmailStatuses(rows,'business-a');assert.equal(JSON.stringify(rows),before);
});
test('browser storage failure cannot turn a successful email response into a failed send',async()=>{
  const f=fixture([],{storageFails:true}),out=await f.context.markInvoiceEmailed(invoice('i1'),'billing@example.test');
  assert.equal(f.context.getEmailStatus(out).sent,true);assert.equal(f.calls.length,0);
});
test('a business switch after sending cannot cache the other business invoice',async()=>{
  const f=fixture();f.window.SAAS.state.business.id='business-b';
  await f.context.markInvoiceEmailed(invoice('i1'),'billing@example.test');
  assert.equal(f.storage.size,0);assert.equal(f.cached.length,0);
});
function bankFixture(options={}){
  const calls=[],window={SAAS:{state:{business:{id:'business-a'}}}},state={accounts:[]};let fills=0,renders=0;
  const client={from(table){assert.equal(table,'bank_accounts');calls.push(['from',table]);const q={
    select(x){calls.push(['select',x]);return q},eq(k,v){calls.push(['eq',k,v]);return q},or(x){calls.push(['or',x]);return q},order(k,v){calls.push(['order',k,v]);return q},
    async then(resolve,reject){try{if(options.onRead)await options.onRead();resolve({data:options.rows||[],error:options.error||null})}catch(e){reject(e)}}};return q}};
  const context={client:()=>options.noClient?null:client,businessId:()=>window.SAAS.state.business.id,state,fillAccountPickers(){fills++},renderAccounts(){renders++},toast(){}};
  vm.createContext(context);vm.runInContext(take(bank,'async function loadAccounts(){','function fillAccountPickers()'),context);
  return {context,state,calls,window,get fills(){return fills},get renders(){return renders}};
}
test('opening Banking only reads current active accounts and never imports, updates or unarchives',async()=>{
  const rows=[{id:'a',archived:false,is_default:true}],f=bankFixture({rows});await f.context.loadAccounts();
  assert.equal(f.state.accounts,rows);assert.equal(f.fills,1);assert.equal(f.renders,1);
  assert.ok(f.calls.some(c=>c[0]==='or'&&c[1]==='archived.eq.false,archived.is.null'));
  assert.ok(f.calls.some(c=>c[0]==='eq'&&c[1]==='business_id'&&c[2]==='business-a'));
  assert.equal(bank.includes('syncSetupBankAccounts'),false);
});
test('switching businesses cannot paint old bank accounts after a delayed query',async()=>{
  let f;f=bankFixture({rows:[{id:'old'}],onRead:()=>{f.window.SAAS.state.business.id='business-b'}});
  await f.context.loadAccounts();assert.equal(f.state.accounts.length,0);assert.equal(f.renders,0);
});
test('missing authorised bank context clears pickers without attempting a database query',async()=>{
  const f=bankFixture({noClient:true});f.state.accounts=[{id:'old'}];await f.context.loadAccounts();
  assert.equal(f.state.accounts.length,0);assert.equal(f.calls.length,0);assert.equal(f.renders,1);
});
