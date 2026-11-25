const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../public/payroll.js'),'utf8');
function fixture(){
 const elements={};const $=id=>elements[id]??={value:'',hidden:false};
 const state={settings:{default_pay_frequency:'weekly',default_pay_day:4,week_start_day:1},runs:[],runCalc:[],runLocked:false};
 const context={state,$,num:Number,today:()=> '2026-11-26',dateOnly:d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`,addDays:(s,n)=>{const d=new Date(s+'T12:00:00');d.setDate(d.getDate()+n);return context.dateOnly(d)},currentRunDef:()=>({pay_frequency:$('prFrequency').value,period_start:$('prStart').value,period_end:$('prEnd').value,pay_date:$('prPayDate').value}),renderRunCalc:()=>{},bindRunActionHandlers:()=>{},loadRunCalc:()=>{}};
 vm.runInNewContext(source.slice(source.indexOf('  function nextConfiguredPayDate('),source.indexOf('  function openRun(')),context);
 $('prFrequency').value='weekly';$('prStart').value='2026-11-16';$('prEnd').value='2026-11-22';return{context,state,$};
}
test('weekly Thursday follows the selected period, including today and historical periods',()=>{const {context,$}=fixture();assert.equal(context.automaticRunPayDate(),'2026-11-26');assert.equal(context.nextConfiguredPayDate(),'2026-11-26');$('prEnd').value='2026-11-15';assert.equal(context.automaticRunPayDate(),'2026-11-19');});
test('automatic date follows period changes but a manual override survives them',()=>{const {context,state,$}=fixture();context.onRunDateChanged('prEnd');assert.equal($('prPayDate').value,'2026-11-26');$('prPayDate').value='2026-11-27';context.onRunDateChanged('pay_date');assert.equal(state.payDateManual,true);$('prEnd').value='2026-11-29';context.onRunDateChanged('prEnd');assert.equal($('prPayDate').value,'2026-11-27');context.useUsualPayday();assert.equal($('prPayDate').value,'2026-12-03');assert.equal(state.payDateManual,false);});
test('new run uses the next period after the last finalised run without jumping to a future saved payday',()=>{const {context,state,$}=fixture();state.runs=[{status:'finalised',pay_frequency:'weekly',period_end:'2026-11-15',pay_date:'2026-12-10'}];context.initialiseRun();assert.equal($('prEnd').value,'2026-11-22');assert.equal($('prPayDate').value,'2026-11-26');});
test('saved date is preserved and finalised run cannot be reset',()=>{const {context,state,$}=fixture();context.initialiseRun({id:'saved',pay_run_number:'PAY-0006',pay_frequency:'weekly',period_start:'2026-11-16',period_end:'2026-11-22',pay_date:'2026-11-27',status:'finalised'});assert.equal($('prPayDate').value,'2026-11-27');context.useUsualPayday();assert.equal($('prPayDate').value,'2026-11-27');assert.equal(state.runLocked,true);});
test('fortnightly payday uses configured weekday after period end',()=>{const {context,$}=fixture();$('prFrequency').value='fortnightly';assert.equal(context.automaticRunPayDate(),'2026-11-26');});
