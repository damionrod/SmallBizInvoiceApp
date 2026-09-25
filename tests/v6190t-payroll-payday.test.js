const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

const source=fs.readFileSync(path.join(__dirname,'../public/payroll.js'),'utf8');
const form=fs.readFileSync(path.join(__dirname,'../public/index.html'),'utf8');
function fixtures(runs=[]){
  const elements={};const $=id=>elements[id]??=(id==='prPaydayChange'?{hidden:true}:{value:'',textContent:'',hidden:false});
  const state={settings:{default_pay_frequency:'fortnightly',default_pay_day:1},runs,runCalc:[],runSelectedIds:[],runExpandedIds:[],paydayConflict:null,calculatedRunKey:null};
  const context={state,$,num:Number,today:()=> '2026-09-25',addDays:(date,amount)=>new Date(Date.parse(date+'T12:00:00Z')+amount*86400000).toISOString().slice(0,10),iso:s=>s,renderRunCalc:()=>{},bindRunActionHandlers:()=>{},loadRunCalc:()=>{},applyManual:(x,run)=>({...x,payDateUsed:run.pay_date}),currentRunDef:()=>({pay_frequency:$('prFrequency').value,period_start:$('prStart').value,period_end:$('prEnd').value,pay_date:$('prPayDate').value})};
  const slice=source.slice(source.indexOf('  function nextConfiguredPayDate('),source.indexOf('  function openRun('));
  assert.ok(slice.startsWith('  function nextConfiguredPayDate('));
  vm.runInNewContext(slice,context);
  $('prFrequency').value='fortnightly';$('prStart').value='2026-09-11';$('prEnd').value='2026-09-25';
  return {context,state,$};
}
test('new fortnightly run asks before following an old Thursday schedule instead of silently overriding Monday',()=>{
  const {context,state,$}=fixtures([{pay_frequency:'fortnightly',pay_date:'2026-10-01'}]);
  context.initialiseRun();
  assert.equal($('prPayDate').value,'');
  assert.equal($('prPaydayChange').hidden,false);
  assert.equal(state.paydayConflict.planned,'2026-10-15');
  assert.equal($('prConfiguredPaydayDate').value,'2026-10-19');
  context.resolvePaydayChoice('2026-10-19');
  assert.equal($('prPayDate').value,'2026-10-19');
  assert.equal($('prStart').value,'2026-09-12');
  assert.equal($('prEnd').value,'2026-09-25');
});
test('choosing the old payday defers the transition and a saved run keeps its own pay date',()=>{
  const {context,state,$}=fixtures([{pay_frequency:'fortnightly',pay_date:'2026-10-01'}]);
  context.initialiseRun();context.resolvePaydayChoice(state.paydayConflict.planned);
  assert.equal($('prPayDate').value,'2026-10-15');
  context.initialiseRun({id:'saved',pay_run_number:'PAY-0001',pay_frequency:'fortnightly',period_start:'2026-09-11',period_end:'2026-09-25',pay_date:'2026-10-01',status:'calculated'});
  assert.equal($('prPayDate').value,'2026-10-01');
  assert.equal($('prPaydayChange').hidden,true);
});
test('a manually changed payday recomputes existing values; a changed period is refused until recalculation',async()=>{
  const {context,state,$}=fixtures();context.initialiseRun();
  $('prPayDate').value='2026-09-28';
  state.runCalc=[{employee:{id:'employee'},payDateUsed:'2026-09-28'}];
  state.calculatedRunKey=context.runCalculationKey();
  $('prPayDate').value='2026-10-05';context.onRunDateChanged('pay_date');
  assert.equal(state.runCalc[0].payDateUsed,'2026-10-05');
  assert.equal(state.calculatedRunKey,context.runCalculationKey());
  $('prStart').value='2026-09-13';context.onRunDateChanged('prStart');
  assert.notEqual(state.calculatedRunKey,context.runCalculationKey());
  const savePrefix=source.slice(source.indexOf('  async function saveRun(finalise=false){'),source.indexOf('    const payEmployees=selectedRunCalc();'))+'\n  }';
  const messages=[];context.toast=message=>messages.push(message);
  vm.runInNewContext(savePrefix,context);
  await context.saveRun();
  assert.match(messages[0],/Select Load \/ Calculate before saving/);
  assert.match(form,/id="prPaydayChange"/);
});
test('without earlier fortnightly pay, the selected Monday is the default with no interruption',()=>{
  const {context,state,$}=fixtures();context.initialiseRun();
  assert.equal($('prPayDate').value,'2026-09-28');
  assert.equal(state.paydayConflict,null);
  assert.equal($('prPaydayChange').hidden,true);
});
