const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {stripTypeScriptTypes}=require('node:module');
const source=fs.readFileSync(path.join(__dirname,'../supabase/functions/invoice-reminder-worker/index.ts'),'utf8');
function fixture(secret='a'.repeat(40)){
  let handler;const calls=[],environment={INVOICE_REMINDER_WORKER_SECRET:secret,SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_ROLE_KEY:'fixture-server-key',RESEND_API_KEY:'fixture-mail-key'};
  const context={Request,Response,TextEncoder,URL,Intl,console,
    Deno:{serve(fn){handler=fn},env:{get:key=>environment[key]}},corsHeaders:()=>({}),
    createClient(){calls.push('createClient');return {async rpc(name){calls.push(name);assert.equal(name,'v61126_claim_invoice_auto_reminders');return{data:[],error:null}}}},
    fetch(){throw Error('No network is allowed in this test')},
  };
  vm.createContext(context);const executable=stripTypeScriptTypes(source.replace(/^import .*;\r?\n/gm,''),{mode:'strip'});
  vm.runInContext(executable,context);
  return {calls,request:async(method='POST',provided)=>handler(new Request('https://fixture.invalid/worker',{method,headers:provided?{'x-frindly-worker-secret':provided}:{}}))};
}
test('missing, incorrect and differently sized secrets cannot claim reminders',async()=>{
  for(const secret of [undefined,'incorrect','a'.repeat(39),'a'.repeat(41)]){
    const f=fixture(),response=await f.request('POST',secret);assert.equal(response.status,401);assert.equal(f.calls.length,0);
  }
});
test('worker fails closed if its server secret is absent or too short',async()=>{
  for(const configured of ['', 'short']){const f=fixture(configured),response=await f.request('POST',configured||'provided');assert.equal(response.status,401);assert.equal(f.calls.length,0)}
});
test('methods other than POST are rejected before any database access',async()=>{
  for(const method of ['GET','PUT','OPTIONS']){const f=fixture(),response=await f.request(method,'a'.repeat(40));assert.equal(response.status,405);assert.equal(f.calls.length,0)}
});
test('the authorised scheduled worker can still claim an empty batch',async()=>{
  const f=fixture(),response=await f.request('POST','a'.repeat(40));assert.equal(response.status,200);
  const body=await response.json();assert.equal(body.success,true);assert.equal(body.claimed,0);
  assert.deepEqual(f.calls,['createClient','v61126_claim_invoice_auto_reminders']);
});
