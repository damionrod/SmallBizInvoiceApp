'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'..');
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}
function harness(){
 const nodes=new Map(),node=id=>{if(!nodes.has(id))nodes.set(id,{id,value:'',files:[],textContent:'',innerHTML:'',disabled:false,classList:{add(){},remove(){}},querySelectorAll:()=>[],querySelector:()=>null});return nodes.get(id);};
 const calls=[],pending=deferred();let rpcHandler=null;let response={batch:{id:'batch-1',filename:'test.csv',total_rows:2,status:'reviewed'},records:[],sheets:[],mappings:[]};
 const client={functions:{invoke:async(name,args)=>{calls.push({type:'invoke',name,args});return pending.promise;}},rpc:async(name,args)=>{calls.push({type:'rpc',name,args});return rpcHandler?rpcHandler(name,args):{data:response,error:null};}};
 const window={SAAS:{state:{business:{id:'business-a',settings:{currency:'AUD'}},user:{id:'user-a'}},client:()=>client,hasModule:async()=>false,canWriteArea:()=>true},FrindlyStartingBalances:{open(){}}};
 const document={getElementById:node,querySelectorAll:()=>[],querySelector:()=>null,addEventListener(){}};
 const context=vm.createContext({window,document,Intl,Date,Number,FormData,URLSearchParams,setTimeout,console});
 vm.runInContext(fs.readFileSync(path.join(root,'public/finlo-core.js'),'utf8'),context);
 let source=fs.readFileSync(path.join(root,'public/import-migration.js'),'utf8');
 source=source.replace(' window.ImportMigration={',' window.__test={state,analyse,confirmImport,close,renderResult,money};window.ImportMigration={');
 vm.runInContext(source,context);
 return {window,node,calls,pending,api:window.__test,setResponse:value=>{response=value;},setRpc:fn=>{rpcHandler=fn;},document};
}
test('shared context guard rejects changed identity and invalidated views',()=>{
 const h=harness();let active=true;
 const guard=h.window.FinloCore.context.createGuard(()=>({business:h.window.SAAS.state.business.id,user:h.window.SAAS.state.user.id}),{isCurrent:()=>active});
 assert.equal(guard(),true);active=false;assert.throws(guard,{code:'FRINDLY_STALE_CONTEXT'});active=true;
 h.window.SAAS.state.user.id='other';assert.throws(guard,{code:'FRINDLY_STALE_CONTEXT'});
});
test('analysis cannot paint or fetch batch details after a business switch',async()=>{
 const h=harness();await h.window.ImportMigration.open();h.node('importFile').files=[new Blob(['invoice,total\n1,10'])];
 const pending=h.api.analyse();h.window.SAAS.state.business.id='business-b';h.pending.resolve({data:{batch_id:'batch-1'},error:null});await pending;
 assert.equal(h.calls.filter(c=>c.type==='rpc').length,0);assert.equal(h.api.state.batch,null);
 assert.doesNotMatch(h.node('importMigrationContent').innerHTML,/Check the column mapping/);
});
test('closing the import invalidates an unfinished analysis',async()=>{
 const h=harness();await h.window.ImportMigration.open();h.node('importFile').files=[new Blob(['a,b'])];const pending=h.api.analyse();h.api.close();h.pending.resolve({data:{batch_id:'batch-1'},error:null});await pending;
 assert.equal(h.calls.filter(c=>c.type==='rpc').length,0);assert.equal(h.api.state.batch,null);
});
test('rapid analysis clicks issue one request and the current response opens its batch',async()=>{
 const h=harness();await h.window.ImportMigration.open();h.node('importFile').files=[new Blob(['a,b'])];const pending=h.api.analyse();await h.api.analyse();assert.equal(h.calls.filter(c=>c.type==='invoke').length,1);
 h.pending.resolve({data:{batch_id:'batch-1'},error:null});await pending;
 assert.equal(h.api.state.batch,'batch-1');assert.match(h.node('importMigrationContent').innerHTML,/Check the column mapping/);assert.equal(h.api.state.busy,false);
});
test('an unconfirmed or failed batch is never labelled completed',()=>{
 const h=harness();h.api.state.detail={batch:{id:'batch-1',status:'failed'},events:[]};h.api.renderResult();assert.match(h.node('importMigrationContent').innerHTML,/Migration needs review/);assert.doesNotMatch(h.node('importMigrationContent').innerHTML,/Migration completed/);
});
test('import preview amounts use the active business currency',()=>{const h=harness();assert.equal(h.api.money(115),new Intl.NumberFormat('en-NZ',{style:'currency',currency:'AUD'}).format(115));h.window.SAAS.state.business.settings.currency='NZD';assert.equal(h.api.money(115),new Intl.NumberFormat('en-NZ',{style:'currency',currency:'NZD'}).format(115));});

test('an old business form cannot start analysis after switching businesses',async()=>{const h=harness();await h.window.ImportMigration.open();h.node('importFile').files=[new Blob(['a,b'])];h.window.SAAS.state.business.id='business-b';await h.api.analyse();assert.equal(h.calls.length,0);});

test('repeated confirmation clicks submit one atomic commit',async()=>{
 const h=harness();await h.window.ImportMigration.open();h.api.state.batch='batch-1';h.api.state.detail={batch:{id:'batch-1'},records:[]};const response=deferred();h.setRpc(()=>response.promise);
 const pending=h.api.confirmImport();await h.api.confirmImport();assert.equal(h.calls.filter(c=>c.name==='v6215_confirm_import').length,1);
 response.resolve({data:{batch:{id:'batch-1',status:'completed'},events:[]},error:null});await pending;assert.match(h.node('importMigrationContent').innerHTML,/Migration completed/);
});
test('a business change while saving decisions stops before the import commit',async()=>{
 const h=harness();await h.window.ImportMigration.open();h.api.state.batch='batch-1';h.api.state.detail={batch:{id:'batch-1'},records:[{id:'r1',duplicate_action:'create'},{id:'r2',duplicate_action:'create'}]};
 h.document.querySelectorAll=selector=>selector==='[data-import-record]'?['r1','r2'].map(id=>({dataset:{importRecord:id},querySelector:()=>({value:'skip'})})):[];
 h.setRpc(async()=>{h.window.SAAS.state.business.id='business-b';return {data:{},error:null};});
 await h.api.confirmImport();assert.equal(h.calls.filter(c=>c.name==='v6215_set_record_action').length,1);assert.equal(h.calls.filter(c=>c.name==='v6215_confirm_import').length,0);
});
test('an analysis response with inconsistent batch detail is rejected',async()=>{
 const h=harness();await h.window.ImportMigration.open();h.node('importFile').files=[new Blob(['a,b'])];h.setResponse({batch:{id:'unexpected-batch'}});const pending=h.api.analyse();h.pending.resolve({data:{batch_id:'batch-1'},error:null});await pending;
 assert.equal(h.api.state.batch,null);assert.match(h.node('importMessage').textContent,/could not be verified/);assert.equal(h.node('importAnalyse').disabled,false);
});
