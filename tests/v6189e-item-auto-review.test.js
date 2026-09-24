const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

const source=fs.readFileSync('public/stock-equipment.js','utf8').replace('window.StockEquipment={onShow,renderTaxRules};','window.StockEquipment={onShow,renderTaxRules,__review:{state,initialRows,reviewForm,readReviewRows,proposedAmounts,act}};');
function setup(){
 const window={SAAS:{canWriteArea:()=>true,currentBusinessId:()=> 'bingo'}};
 const document={querySelectorAll:()=>[],addEventListener:()=>{},getElementById:()=>null};
 vm.runInNewContext(source,{window,document,console,FormData});
 return window.StockEquipment.__review;
}
// The saved photo shows page two only. Rendering each recognized row must never
// fill the unobserved balance of the full supplier invoice with invented prices.
test('Bingo page-two proposals display as three priced rows awaiting full invoice allocation',()=>{
 const {state,initialRows,reviewForm}=setup();
 const bill={id:'exp-0004',expense_number:'EXP-0004',supplier_name:'NZ CLEANING SUPPLIES LTD',category_id:'cat-other',ex_gst:361.94,gst_amount:54.29,total_amount:416.23,expense_attachments:[{id:'image'}]};
 state.expenses=[bill];
 state.categories=[{id:'cat-other',name:'Other',group_name:'Operating Expenses'},{id:'cat-tools',name:'Tools',group_name:'Operating Expenses'}];
 state.documentItems.set(bill.id,{proposals:[
  {description:'SABCO/PULEX WINDOW BUCKET 13L BLUE',amount:20.22,quantity:1},
  {description:'OATES CONTRACTOR MOP RED 400GMS',amount:14.64,quantity:1},
  {description:'OATES CONTRACTOR ALUMINIUM HANDLE RED 1.5M',amount:18.25,quantity:1}
 ]});
 const rows=initialRows(bill);
 assert.equal(rows.length,3);
 assert.equal(rows.reduce((sum,row)=>sum+Number(row.ai_amount),0).toFixed(2),'53.11');
 assert.ok(rows.every(row=>row.ex_gst===''&&row.gst===''));
 assert.ok(rows.every(row=>row.kind==='regular'&&row.category_id==='cat-other'));
 const html=reviewForm(bill.id);
 assert.equal((html.match(/class="se-review-item"/g)||[]).length,3);
 assert.equal((html.match(/value="cat-other" selected/g)||[]).length,3);
 assert.equal((html.match(/data-field="kind" value="regular" checked/g)||[]).length,3);
 assert.ok(html.includes('value="cat-tools"'));
 for(const amount of ['$20.22','$14.64','$18.25'])assert.ok(html.includes(amount));
 assert.ok(html.indexOf('WINDOW BUCKET')<html.indexOf('MOP RED')&&html.indexOf('MOP RED')<html.indexOf('ALUMINIUM HANDLE'));
});
test('review collects only the checked Use and preserves a changed category for each item',()=>{
 const {readReviewRows}=setup();
 const input=(name,value,checked=true,type='text')=>({name,value,checked,type,dataset:{field:name.startsWith('kind_')?'kind':undefined}});
 const sections=[
  [input('kind_0','regular',false,'radio'),input('kind_0','supplies',true,'radio'),input('category_id','cat-a'),input('description','Mop')],
  [input('kind_1','regular',true,'radio'),input('kind_1','supplies',false,'radio'),input('category_id','cat-b'),input('description','Paper')]
 ];
 const form={querySelectorAll:()=>sections.map(inputs=>({querySelectorAll:()=>inputs}))};
 const rows=readReviewRows(form);
 assert.equal(JSON.stringify(rows.map(r=>[r.kind,r.category_id])),JSON.stringify([['supplies','cat-a'],['regular','cat-b']]));
});
test('split invoice defaults only an identifiable line category',()=>{
 const {initialRows,state}=setup();
 const bill={id:'split',is_split:true,ex_gst:30,gst_amount:4.5,expense_lines:[{description:'Bucket',category_id:'tools',ex_gst:10,gst_amount:1.5},{description:'Chemicals',category_id:'materials',ex_gst:20,gst_amount:3}]};
 state.documentItems.set('split',{proposals:[{description:'Chemicals',amount:20,suggested_use:'supplies'},{description:'Unknown',amount:10,suggested_use:'needs_review'}]});
 const [matched,ambiguous]=initialRows(bill);
 assert.equal(matched.category_id,'materials');
 assert.equal(ambiguous.category_id,'');
 assert.equal(matched.kind,'supplies');
 assert.equal(ambiguous.kind,'regular');
});
test('GST drafts match complete ex-GST and inclusive invoices to the cent',()=>{
 const {proposedAmounts}=setup();
 const exclusive=proposedAmounts([{amount:20},{amount:80}],{ex_gst:100,gst_amount:15,total_amount:115});
 assert.equal(JSON.stringify(exclusive),JSON.stringify([{ex_gst:'20.00',gst:'3.00'},{ex_gst:'80.00',gst:'12.00'}]));
 const inclusive=proposedAmounts([{amount:23},{amount:92}],{ex_gst:100,gst_amount:15,total_amount:115});
 assert.equal(JSON.stringify(inclusive),JSON.stringify([{ex_gst:'20.00',gst:'3.00'},{ex_gst:'80.00',gst:'12.00'}]));
});
test('zero GST, mixed GST and partial ambiguous scans do not invent taxable amounts',()=>{
 const {proposedAmounts}=setup();
 const none=proposedAmounts([{amount:20},{amount:30}],{ex_gst:50,gst_amount:0,total_amount:50});
 assert.equal(JSON.stringify(none),JSON.stringify([{ex_gst:'20.00',gst:'0.00'},{ex_gst:'30.00',gst:'0.00'}]));
 const mixed=proposedAmounts([{amount:100,amount_basis:'ex_gst',gst_treatment:'taxable'},{amount:50,amount_basis:'ex_gst',gst_treatment:'no_gst'}],{ex_gst:150,gst_amount:15,total_amount:165});
 assert.equal(JSON.stringify(mixed),JSON.stringify([{ex_gst:'100.00',gst:'15.00'},{ex_gst:'50.00',gst:'0.00'}]));
 const ambiguous=proposedAmounts([{amount:20.22},{amount:14.64},{amount:18.25}],{ex_gst:361.94,gst_amount:54.29,total_amount:416.23});
 assert.ok(ambiguous.every(row=>row.ex_gst===''&&row.gst===''));
 const partialKnown=proposedAmounts([{amount:20.22,amount_basis:'ex_gst',gst_treatment:'taxable'}],{ex_gst:361.94,gst_amount:54.29,total_amount:416.23});
 assert.equal(JSON.stringify(partialKnown),JSON.stringify([{ex_gst:'20.22',gst:'3.03'}]));
});
test('compact review keeps requested columns and remove control in the same grid row',()=>{
 const {reviewForm,state}=setup();
 state.categories=[{id:'cat',name:'Other',group_name:'Operating Expenses'}];
 state.expenses=[{id:'one',expense_number:'EXP-1',supplier_name:'Sample',category_id:'cat',ex_gst:10,gst_amount:1.5,total_amount:11.5}];
 state.draftRows=[{description:'Tool',category_id:'cat',kind:'equipment',quantity:1,ex_gst:'10.00',gst:'1.50',ai_amount:10}];
 const html=reviewForm('one');
 const fields=['class="se-item-description"','class="se-item-category"','class="se-use-options"','class="se-qty"','name="ex_gst"','name="gst"','class="se-incl"','class="se-remove-item"'];
 let pos=0;for(const marker of fields){const next=html.indexOf(marker,pos);assert.ok(next>pos,marker+' must follow prior field');pos=next}
 assert.match(html,/name="available_on"/);
 const css=fs.readFileSync('public/stock-equipment.css','utf8');
 assert.match(css,/\.se-review-item \.se-remove-item\{grid-column:auto/);
});
