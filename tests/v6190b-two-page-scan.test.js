const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

const expenses=fs.readFileSync('public/expenses.js','utf8');
const reviewer=fs.readFileSync('public/purchase-review.js','utf8');
const edge=fs.readFileSync('supabase/functions/scan-expense-document/index.ts','utf8');

function extract(name,next){const from=expenses.indexOf(`  function ${name}(`);const to=expenses.indexOf(`  function ${next}(`,from+1);assert.ok(from>=0&&to>from);return expenses.slice(from,to)}
test('draft upload does not hide the explicit full-invoice scan or retry action',()=>{
 const pick=extract('pickFiles','renderPendingFiles');
 assert.doesNotMatch(pick,/scanExpenseFile\(/);
 assert.match(expenses,/scanExpenseFile\(invoicePages\(\)\)/);
 const controls={expAiScanState:{dataset:{}},expAiStatusTitle:{},expAiStatusText:{},expAiRescan:{}};
 const context={state:{aiFile:{},aiScanning:false},$:id=>controls[id],completeAiProgress(){},failAiProgress(){}};
 vm.runInNewContext(extract('aiStatus','renderAiPreview')+';globalThis.setStatus=aiStatus;',context);
 context.setStatus('Ready','Add more pages','ready');
 assert.equal(controls.expAiRescan.hidden,false);
 context.setStatus('Failed','Try again','error');
 assert.equal(controls.expAiRescan.hidden,false);
 assert.equal(controls.expAiRescan.textContent,'Retry scan');
 const from=expenses.indexOf('  function ensurePhotoDraft('),to=expenses.indexOf('  async function saveScannedItemSuggestions',from);
 assert.doesNotMatch(expenses.slice(from,to),/aiStatus/);
});
test('a reopened draft scans saved files first and appends newly selected files',()=>{
 const saved={mime_type:'application/pdf'},pending={type:'image/jpeg'};
 const context={state:{scanSavedPages:true,attachments:[saved],pendingFiles:[pending]},AI_FILE_TYPES:new Set(['application/pdf','image/jpeg'])};
 vm.runInNewContext(extract('invoicePages','updateScanReady')+';globalThis.pages=invoicePages;',context);
 assert.equal(context.pages()[0],saved);
 assert.equal(context.pages()[1],pending);
 assert.match(expenses,/facingMode:\{exact:'environment'\}/);
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
 assert.match(reviewer,/state.scans=new Map/);assert.match(reviewer,/state.expanded=new Set/);
 assert.match(reviewer,/state.scans.set\(id,\{attachment_ids:pages.map/);
});
