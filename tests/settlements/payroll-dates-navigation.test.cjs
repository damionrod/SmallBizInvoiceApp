// Runs the actual payroll module and production navigation in local Chromium.
// Test-only exports are injected in memory; no backend calls or app test API are added.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
const root=path.join(__dirname,'../..');
const launch=()=>chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH,args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
async function payrollPage(browser,timezoneId){
 const page=await browser.newPage({timezoneId});
 await page.evaluate(()=>{window.SAAS={state:{business:{settings:{country:'NZ'}}},client:()=>{throw Error('Date tests must not access the backend')}}});
 const source=fs.readFileSync(path.join(root,'public/payroll.js'),'utf8');
 const marker='  window.Payroll={init,';assert.ok(source.includes(marker));
 await page.addScriptTag({content:source.replace(marker,'  window.payrollDates={today,addDays,nextConfiguredPayDate,nextPaydayOnOrAfter,defaultRunPeriod,state};\n'+marker)});
 await page.evaluate(()=>{payrollDates.state.settings={country_code:'NZ',default_pay_day:1,week_start_day:1}});
 return page;
}
for(const timezoneId of ['Pacific/Auckland','UTC','America/Los_Angeles'])test(`payroll calendar dates retain their day in ${timezoneId}`,async()=>{
 const browser=await launch();
 try{
  const page=await payrollPage(browser,timezoneId);
  await page.clock.install({time:new Date('2026-09-24T23:00:00Z')}); // 25 September in NZ.
  const actual=await page.evaluate(()=>{
   const p=payrollDates;
   p.state.runs=[{pay_frequency:'fortnightly',pay_date:'2026-10-01'}];const next=p.nextConfiguredPayDate('fortnightly');
   p.state.runs=[];
   return {next,monday:p.nextConfiguredPayDate('fortnightly'),transition:p.addDays('2026-09-26',2),back:p.addDays('2026-09-28',-2),leap:p.addDays('2028-02-28',1),year:p.addDays('2026-12-31',1),configured:p.nextPaydayOnOrAfter('2026-10-15',1),fortnight:p.defaultRunPeriod('fortnightly','2026-10-15'),month:p.defaultRunPeriod('monthly','2026-11-05')};
  });
  assert.equal(await page.evaluate(()=>{try{payrollDates.addDays('not-a-date',1);return 'accepted'}catch(e){return e.name}}),'RangeError');
  assert.deepEqual(actual,{next:'2026-10-15',monday:'2026-09-28',transition:'2026-09-28',back:'2026-09-26',leap:'2028-02-29',year:'2027-01-01',configured:'2026-10-19',fortnight:{start:'2026-09-28',end:'2026-10-11'},month:{start:'2026-10-01',end:'2026-10-31'}});
  await page.clock.setFixedTime(new Date('2026-11-04T20:00:00Z'));
  assert.equal(await page.evaluate(()=>payrollDates.nextConfiguredPayDate('weekly')),'2026-11-09');
  await page.clock.setFixedTime(new Date('2026-07-01T21:00:00Z'));
  assert.equal(await page.evaluate(()=>payrollDates.nextConfiguredPayDate('weekly')),'2026-07-06');
 }finally{await browser.close()}
});
test('NZ payroll today follows Auckland at morning and year boundaries, while non-NZ defaults retain their prior UTC behaviour',async()=>{
 const browser=await launch();
 try{
  const page=await payrollPage(browser,'UTC');
  await page.clock.install({time:new Date('2026-11-04T20:00:00Z')});
  assert.equal(await page.evaluate(()=>payrollDates.today()),'2026-11-05');
  await page.clock.setFixedTime(new Date('2026-06-30T21:00:00Z'));
  assert.equal(await page.evaluate(()=>payrollDates.today()),'2026-07-01');
  await page.clock.setFixedTime(new Date('2026-12-31T12:00:00Z'));
  assert.equal(await page.evaluate(()=>payrollDates.today()),'2027-01-01');
  assert.equal(await page.evaluate(()=>{payrollDates.state.settings.country_code='AU';return payrollDates.today()}),'2026-12-31');
 }finally{await browser.close()}
});
test('next period follows a finalised run without mutating saved dates',async()=>{
 const browser=await launch();
 try{
  const page=await payrollPage(browser,'Pacific/Auckland');
  const actual=await page.evaluate(()=>{
   const p=payrollDates;p.state.runs=[{id:'saved',status:'finalised',pay_frequency:'fortnightly',pay_date:'2026-10-15',period_start:'2026-09-14',period_end:'2026-09-27'}];
   const period=p.defaultRunPeriod('fortnightly','2026-10-15');const saved=JSON.stringify(p.state.runs);
   p.state.runs=[{status:'finalised',pay_frequency:'monthly',period_end:'2026-09-30'}];
   return {period,saved,month:p.defaultRunPeriod('monthly','2026-11-05')};
  });
  assert.deepEqual(actual.period,{start:'2026-09-28',end:'2026-10-11'});
  assert.deepEqual(actual.month,{start:'2026-10-01',end:'2026-10-31'});
  assert.equal(JSON.parse(actual.saved)[0].pay_date,'2026-10-15');assert.equal(JSON.parse(actual.saved)[0].period_end,'2026-09-27');
 }finally{await browser.close()}
});
for(const width of [390,1440])test(`hidden module navigation stays hidden at ${width}px and returns when enabled`,async()=>{
 const browser=await launch();
 try{
  const page=await browser.newPage({viewport:{width,height:844}});
  await page.route('**/*',r=>r.abort());
  const html=fs.readFileSync(path.join(root,'public/index.html'),'utf8'),start=html.indexOf('<header class="topbar">');
  await page.setContent(html.slice(start,html.indexOf('</header>',start)+9));
  for(const file of ['styles-core.css','styles.css','frontend-quality.css'])await page.addStyleTag({path:path.join(root,'public',file)});
  await page.addScriptTag({path:path.join(root,'public/mobile-shell.js')});
  if(width<760){assert.equal(await page.isVisible('#primaryNav'),false);await page.click('#mobileMenuBtn')}
  assert.equal(await page.isVisible('#dashboardNav'),true);
  for(const id of ['scheduleNav','payrollNav','bankReconciliationNav']){
   await page.evaluate(id=>{document.getElementById(id).hidden=true},id);
   assert.equal(await page.isVisible('#'+id),false);
   await page.evaluate(id=>{document.getElementById(id).hidden=false},id);
   assert.equal(await page.isVisible('#'+id),true);
   await page.evaluate(id=>{document.getElementById(id).hidden=true},id);
   assert.equal(await page.isVisible('#'+id),false);
  }
  if(width<760){await page.click('#dashboardNav');assert.equal(await page.isVisible('#primaryNav'),false);await page.click('#mobileMenuBtn');await page.keyboard.press('Escape');assert.equal(await page.isVisible('#primaryNav'),false)}
 }finally{await browser.close()}
});
