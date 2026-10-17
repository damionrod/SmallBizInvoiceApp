'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {stripTypeScriptTypes}=require('node:module');
const root=path.resolve(__dirname,'..');
function harness(file,permit=()=>true){
 let handler;const calls=[],adminCalls=[];
 const client={auth:{getUser:async()=>({data:{user:{id:'user-a'}}})},rpc:async(name,args)=>{
  calls.push({name,args});
  if(name==='current_business_id')return{data:'business-a'};
  if(name==='v6147_can_write_area')return{data:true};
  if(name==='v6171b_import_config')return{data:{enabled:true,max_upload_bytes:200000,max_rows:100}};
  return{data:permit(name,args)};
 }};
 const admin={from(table){adminCalls.push(table);throw Error('Unexpected service-role access');}};
 const context=vm.createContext({console:{error(){}},TextEncoder,TextDecoder,URL,URLSearchParams,Response,Request,FormData,File,crypto,
  createClient:(_url,key)=>key==='service'?admin:client,
  Deno:{env:{get:key=>({SUPABASE_URL:'https://test.invalid',SUPABASE_ANON_KEY:'anon',SUPABASE_SERVICE_ROLE_KEY:'service'}[key])},serve:fn=>{handler=fn;}}
 });
 const source=fs.readFileSync(path.join(root,file),'utf8').replace(/^import .*?;\s*$/gm,'');
 vm.runInContext(stripTypeScriptTypes(source),context);
 const api=vm.runInContext('({requireImportAccess,storeRecords,buildRecords})',context);
 return{api,client,calls,adminCalls,request:(body)=>handler(new Request('https://test.invalid',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer fake'},body:JSON.stringify(body)}))};
}
for(const file of ['ops/market/functions/import-migration-analyse/index.ts','supabase/functions/import-migration-analyse/index.ts']){
 test(`${file}: mixed-type permission denied before service-role access`,async()=>{
  const h=harness(file,(name,args)=>name==='v6223_import_batch_access'||args.p_record_type!=='employees');
  const response=await h.request({action:'remap',batch_id:'batch-a',sheets:[{id:'one',record_type:'customers'},{id:'two',record_type:'employees'}]});
  assert.equal(response.status,403);assert.match((await response.json()).error,/permission.*employees/);assert.deepEqual(h.adminCalls,[]);
 });
 test(`${file}: inaccessible existing batch cannot be remapped into a permitted type`,async()=>{
  const h=harness(file,name=>name!=='v6223_import_batch_access');
  const response=await h.request({action:'remap',batch_id:'payroll-batch',sheets:[{id:'one',record_type:'customers'}]});
  assert.equal(response.status,403);assert.deepEqual(h.adminCalls,[]);
 });
 test(`${file}: access checks fail closed and deduplicate requested types`,async()=>{
  const h=harness(file);await h.api.requireImportAccess(h.client,'business-a',['customers','customers','employees'],'batch-a');
  assert.deepEqual(h.calls.map(x=>x.name),['v6223_import_batch_access','v6223_import_type_access','v6223_import_type_access']);
  await assert.rejects(h.api.requireImportAccess({rpc:async()=>({data:true,error:{message:'denied'}})},'business-a',['employees']),/permission/);
  await assert.rejects(h.api.requireImportAccess({rpc:async()=>({data:null})},'business-a',['employees']),/permission/);
 });
 test(`${file}: initial staging preserves row links without relying on a truncated insert response`,async()=>{
  const h=harness(file),writes=[];
  const admin={from:table=>({insert:async rows=>{writes.push({table,rows});return{error:null}}})};
  const records=Array.from({length:1001},(_,i)=>({canonical_hash:'same-hash',member_ids:['row-'+i],duplicate_status:'new',duplicate_action:'create',validation_status:'ready',validation_messages:[]}));
  await h.api.storeRecords(admin,'batch-a','business-a','sheet-a',records);
  assert.equal(writes.length,2);assert.equal(writes[0].rows.length,1001);assert.equal(writes[1].rows.length,1001);
  assert.equal(new Set(writes[0].rows.map(r=>r.id)).size,1001);
  for(let i=0;i<1001;i++)assert.equal(writes[1].rows[i].import_record_id,writes[0].rows[i].id);
  assert.ok(records.every(r=>r.duplicate_action==='create'));
 });
}

for(const file of ['ops/market/functions/import-migration-analyse/index.ts','supabase/functions/import-migration-analyse/index.ts']){
 async function record(type,values){const h=harness(file),raw={number:'INV-TEST',party_name:'Example',date:'2026-09-30',subtotal:'100',gst:'15',total:'115',...values};const mapping=Object.fromEntries(Object.keys(raw).map(k=>[k,k]));return(await h.api.buildRecords(type,'generic_file',[{id:'source',source_row_number:2,source_data:raw}],mapping,'2026-10-01'))[0];}
 test(`${file}: unpaid and part-paid documents remain opening records`,async()=>{
  for(const type of ['invoices','expenses'])for(const status of ['unpaid','partially paid','Part Paid','not paid']){
   const r=await record(type,{status,paid_amount:'40',outstanding_amount:'75'});
   assert.equal(r.commit_mode,'native_opening',status);assert.equal(r.validation_status,'warning');assert.match(r.validation_messages.join(' '),/starting-balance conversion/);assert.equal(r.normalized_data.paid_amount,40);assert.equal(r.normalized_data.outstanding_amount,75);
  }
 });
 test(`${file}: outstanding-only and paid-only exports preserve the remaining balance`,async()=>{
  const a=await record('invoices',{status:'partially paid',outstanding_amount:'75'});assert.equal(a.normalized_data.paid_amount,40);assert.equal(a.validation_status,'warning');
  const b=await record('expenses',{status:'partially paid',paid_amount:'40'});assert.equal(b.normalized_data.outstanding_amount,75);assert.equal(b.validation_status,'warning');
 });
 test(`${file}: paid history and void history do not manufacture the same settlement`,async()=>{
  const paid=await record('invoices',{status:'Paid'});assert.equal(paid.commit_mode,'historical_reference');assert.equal(paid.normalized_data.paid_amount,115);assert.equal(paid.normalized_data.outstanding_amount,0);assert.equal(paid.validation_status,'ready');
  const cancelled=await record('expenses',{status:'Cancelled'});assert.equal(cancelled.commit_mode,'historical_reference');assert.equal(cancelled.normalized_data.paid_amount,0);assert.equal(cancelled.normalized_data.outstanding_amount,0);
 });
 test(`${file}: conflicting or excessive settlements are rejected for review`,async()=>{
  for(const values of [{status:'Paid',outstanding_amount:'75'},{status:'unpaid',paid_amount:'140'},{status:'unpaid',outstanding_amount:'140'}]){
   const r=await record('invoices',values);assert.equal(r.validation_status,'rejected');assert.ok(r.validation_messages.length);
  }
 });
}
