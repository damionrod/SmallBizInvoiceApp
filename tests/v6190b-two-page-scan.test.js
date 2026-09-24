const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

const expenses=fs.readFileSync('public/expenses.js','utf8');
const reviewer=fs.readFileSync('public/purchase-review.js','utf8');
const edge=fs.readFileSync('supabase/functions/scan-expense-document/index.ts','utf8');

function extract(name,next){const from=expenses.indexOf(`  function ${name}(`);const to=expenses.indexOf(`  function ${next}(`,from+1);assert.ok(from>=0&&to>from);return expenses.slice(from,to)}
test('selecting two images starts a scan of both pages in order without another tap',async()=>{
 const code=extract('queueInvoiceScan','renderPendingFiles');
 const state={pendingFiles:[],aiScanGeneration:0,aiScanPromise:null,aiResult:null},scans=[];
 const context={state,AI_FILE_TYPES:new Set(['image/jpeg']),scanExpenseFile:async files=>scans.push(files.map(f=>f.name)),renderPendingFiles(){},toast(){}};
 vm.runInNewContext(code+';globalThis.pick=pickFiles;',context);
 const a={name:'page-one.jpg',type:'image/jpeg',size:120},b={name:'page-two.jpg',type:'image/jpeg',size:120},c={name:'page-three.jpg',type:'image/jpeg',size:120};
 context.pick([a,b]);await state.aiScanPromise;
 assert.equal(JSON.stringify(scans),JSON.stringify([['page-one.jpg','page-two.jpg']]));
 context.pick([c]);await state.aiScanPromise;
 assert.equal(JSON.stringify(scans[1]),JSON.stringify(['page-one.jpg','page-two.jpg','page-three.jpg']));
});
test('absent AI amounts are unknown rather than a zero total or verified zero GST',()=>{
 const from=expenses.indexOf('  function scanAmount('),to=expenses.indexOf('  function applyAiResult(',from);
 const context={Number};vm.runInNewContext(expenses.slice(from,to)+';globalThis.parse=scanAmount;globalThis.reconcile=reconcileAi;',context);
 assert.equal(Number.isNaN(context.parse(null)),true);assert.equal(Number.isNaN(context.parse('')),true);
 assert.equal(context.reconcile({subtotal:null,gst:null,total:null}).ok,null);
 assert.equal(context.reconcile({subtotal:100,gst:15,total:115}).ok,true);
});
test('a missing printed total or GST does not overwrite entered bill figures',()=>{
 const from=expenses.indexOf('  function scanAmount('),to=expenses.indexOf('  async function scanExpenseFile(',from);
 const controls={expAmount:{value:'416.23'},expGstTreatment:{value:'gst'},expGstOverride:{checked:false},expAiReview:{innerHTML:'',hidden:true}};
 const context={state:{userTouched:new Set()},Number,Set,$:id=>controls[id],setIfUntouched:()=>false,updateAmountDisplay(){},confidenceFlag:()=>'',esc:x=>x,aiStatus(){}};
 vm.runInNewContext(expenses.slice(from,to)+';globalThis.apply=applyAiResult;',context);
 context.apply({total:null,subtotal:null,gst:null,line_items:[]});
 assert.equal(controls.expAmount.value,'416.23');
 assert.equal(controls.expGstTreatment.value,'gst');
 assert.match(controls.expAiReview.innerHTML,/GST not identified/);
 assert.match(controls.expAiReview.innerHTML,/No individual items were found/);
});
test('function accepts ordered documents and review rescans saved pages automatically',()=>{
 assert.match(edge,/Array\.isArray\(body\?\.documents\)/);
 assert.match(edge,/for\(const \[index,doc\] of prepared\.entries\(\)\)/);
 assert.match(edge,/page_conflict/);
 assert.match(reviewer,/if\(needsScan\)await scan\(\)/);
 assert.match(reviewer,/scan\.data\?\.attachment_ids/);
});
