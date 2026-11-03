const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');const {chromium}=require('playwright');
test('linked share confirmation previews holdings, preserves history, routes existing payments and excludes sole traders',async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH,args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{const page=await browser.newPage();await page.setContent('<div></div>');for(const f of ['styles-core.css','styles.css'])await page.addStyleTag({path:path.join(__dirname,'../../public',f)});
 await page.evaluate(()=>{
  window.crypto.randomUUID=()=>String(Math.random());window.entity='company';window.confirmed=false;window.calls=[];window.Financials={refresh:async()=>{}};
  window.people=[{id:'a',display_name:'Departing holder',shares_held:50,ownership_percent:50,share_class:'Ordinary',shareholding_effective_from:'2026-01-01',is_shareholder:true,status:'active'},{id:'b',display_name:'Remaining holder',shares_held:50,ownership_percent:50,share_class:'Ordinary',shareholding_effective_from:'2026-01-01',is_shareholder:true,status:'active'}];
  window.payment={id:'pay',purpose:'share_buyback',owner_id:'a',amount:600,description:'Buyback payment',status:'recorded',legs:[],request_payload:{capital_authority_ref:'Resolution 17',capital_allocations:[]}};
  window.FinloCore={format:{money:n=>'$'+Number(n).toFixed(2)},ui:{toast:()=>{}}};
  window.SAAS={state:{business:{id:'tenant',settings:{country:'NZ'}}},client:()=>({rpc:async(name,args)=>{
   if(name==='frindly_cash_snapshot')return {data:{entity_type:entity,can_write:true,transactions:[payment],capital:{can_record:true,accounts:[]}}};
   if(name==='frindly_share_change_snapshot')return {data:{can_confirm:true,owners:people,linked_event_id:confirmed?'event':null,events:confirmed?[{id:'event',change_type:'cancellation',effective_date:'2026-10-01',authority_ref:'Resolution 17',note:'Approved signed completion',before_data:people,after_data:people.map((o,i)=>({...o,shares_held:i?50:0,ownership_percent:i?100:0})),payments:[payment]}]:[]}};
   calls.push({name,args});confirmed=true;return {data:'event'};
  }})};
 });
 await page.addScriptTag({path:path.join(__dirname,'../../public/cash-transactions.js')});
 await page.evaluate(()=>CashTransactions.view('pay'));await page.click('#ctShareChange');assert.equal(await page.locator('#ctShareForm').count(),1,await page.textContent('#ctContent'));await page.waitForSelector('#ctShareForm');
 await page.fill('#ctShareDate','2026-10-01');await page.fill('#ctShareQuantity','50');await page.fill('#ctShareNote','Approved signed completion');await page.check('#ctShareComplete');assert.match(await page.textContent('#ctSharePreview'),/100.00%/);assert.equal(await page.evaluate(()=>calls.length),0);
 for(const width of [1440,768,390]){await page.setViewportSize({width,height:900});const layout=await page.evaluate(()=>{const m=document.querySelector('#cashTransactionModal .modal-box');return {fits:m.scrollWidth<=m.clientWidth+1,overflow:[...document.querySelectorAll('#ctShareForm *')].filter(e=>e.scrollWidth>e.clientWidth+1).map(e=>[e.id,e.tagName,e.clientWidth,e.scrollWidth])};});assert.equal(layout.fits,true,'width '+width+' '+JSON.stringify(layout.overflow));}
 await page.check('#ctShareAuthorised');await page.click('#ctShareConfirm');await page.waitForFunction(()=>calls.length===1);assert.equal(await page.evaluate(()=>calls[0].name),'frindly_confirm_share_change');assert.equal(await page.evaluate(()=>calls[0].args.p_change.shares_acquired),50);assert.equal(await page.evaluate(()=>calls[0].args.p_change.expected_owners.length),2);
 await page.waitForSelector('[data-share-payment="pay"]');assert.match(await page.textContent('#ctContent'),/Confirmed share cancellation/);assert.equal(await page.locator('#ctShareConfirm').count(),0);await page.click('[data-share-payment="pay"]');await page.waitForSelector('#ctShareChange');
 const dated=await page.evaluate(()=>CashTransactions.ownershipPeriods(people[0],[{owner_id:'a',effective_date:'2026-10-01',before_data:people[0],after_data:{...people[0],ownership_percent:0,shares_held:0}}],'2026-09-01','2026-10-31'));
 assert.deepEqual(dated.periods.map(s=>[s.from,s.to,s.owner.ownership_percent]),[['2026-09-01','2026-09-30',50],['2026-10-01','2026-10-31',0]]);
 const before=await page.evaluate(()=>CashTransactions.ownershipPeriods(people[0],[{owner_id:'a',effective_date:'2026-10-01',before_data:people[0],after_data:{...people[0],ownership_percent:0}}],'2026-02-01','2026-03-31'));assert.equal(before.asOf.ownership_percent,50);
 const appSource=fs.readFileSync(path.join(__dirname,'../../public/app.js'),'utf8'),reportFn=appSource.slice(appSource.indexOf('async function renderShareholderSummary(){'),appSource.indexOf('\nfunction receivableAgeBucket('));
 await page.evaluate(async reportFn=>{
  for(const id of ['reportFrom','reportTo','shareReportOwnershipRows','shareReportPositionRows','shareReportRevenue','shareReportExpenses','shareReportProfit','shareReportDistributions']){const e=document.createElement(id.startsWith('report')?'input':'div');e.id=id;document.body.append(e);}document.getElementById('reportFrom').value='2026-09-01';document.getElementById('reportTo').value='2026-10-31';
  const history=people.map((o,i)=>({owner_id:o.id,effective_date:'2026-10-01',before_data:o,after_data:{...o,shares_held:i?50:0,ownership_percent:i?100:0,is_shareholder:!!i,status:i?'active':'inactive'}})),current=history.map(h=>h.after_data);
  const sb={rpc:async name=>({data:name==='frindly_shareholding_report_history'?history:name==='v6170b_profit_loss'?[{revenue:300,net_profit:300}]:[]}),from:table=>({select(){return this},eq(){return this},gte(){return this},lte(){return Promise.resolve({data:[]})},order:async()=>({data:current})})};
  window.Financials.managementProfitLoss=async(from,to)=>({businessId:'tenant',revenue:from==='2026-09-01'&&to==='2026-10-31'?300:from==='2026-09-01'?100:200,net_profit:from==='2026-09-01'&&to==='2026-10-31'?300:from==='2026-09-01'?100:200});
  const $=id=>document.getElementById(id),num=n=>Number(n||0),esc=s=>String(s??''),money=n=>'$'+Number(n).toFixed(2);await eval('('+reportFn+')')();
 },reportFn);
 const ownership=await page.textContent('#shareReportOwnershipRows');assert.match(ownership,/Departing holder[\s\S]*\$50.00/);assert.match(ownership,/Remaining holder[\s\S]*\$250.00/);
 await page.evaluate(()=>{entity='sole_trader';return CashTransactions.choose('out')});assert.equal(await page.locator('[data-money-route="share_buyback"]').count(),0);assert.equal(await page.locator('[data-money-route="return_share_capital"]').count(),0);
 }finally{await browser.close();}
});
