const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
test('owner register renders on Settings refresh without visiting Financials owner tab and fits each viewport',async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH,args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{const page=await browser.newPage({viewport:{width:1440,height:1200}}),base=path.join(__dirname,'../../public'),html=fs.readFileSync(path.join(base,'index.html'),'utf8'),source=fs.readFileSync(path.join(base,'financials.js'),'utf8');
 const section=html.match(/<section class="settings-page-panel" data-settings-panel="owners" hidden>([\s\S]*?)<\/section>/)[1];
 await page.setContent('<div id="view-settings" class="view active"><div class="settings-owner-section" style="max-width:1000px;margin:16px" id="centralOwnerSettings">'+section+'</div></div><div id="financialSettingsCard" hidden></div>');
 await page.addStyleTag({path:path.join(base,'styles-core.css')});await page.addStyleTag({path:path.join(base,'styles.css')});
 const ownerFns=source.slice(source.indexOf('function ownerBalance('),source.indexOf('function ownerRoleValue('));
 const settingsFn=source.slice(source.indexOf('async function renderSettings(){'),source.indexOf('\n',source.indexOf('async function renderSettings(){')));
 const refreshFn=source.slice(source.indexOf('async function refresh(){'),source.indexOf('\n',source.indexOf('async function refresh(){')));
 await page.evaluate(async({ownerFns,settingsFn,refreshFn})=>{
  const q=id=>document.getElementById(id),esc=s=>String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;'),num=n=>Number(n||0),human=s=>s,money=n=>'$'+Number(n).toFixed(2);
  const state={businessId:'fix',activeTab:'overview',owners:[],ownerBalances:[]};window.edits=[];window.histories=[];
  const openOwnerEdit=id=>edits.push(id),openOwnerHistory=id=>histories.push(id);
  const renderOwners=eval('(function(){'+ownerFns+';return renderOwners;})()');
  const init=async()=>{},loadFinancialData=async()=>{state.owners=structuredClone(window.people);state.ownerBalances=[{owner_id:'one',balance:75}];},renderAll=()=>{window.activeTabSeen=state.activeTab;};
  const renderSettings=eval('('+settingsFn+')'),refresh=eval('('+refreshFn+')');
  window.people=[{id:'one',display_name:'Shareholder One',is_shareholder:true,is_director:false,ownership_percent:50,status:'active'},{id:'two',display_name:'Shareholder Two',is_shareholder:true,is_director:false,ownership_percent:50,status:'active'}];
  window.reloadOwnerSettings=refresh;await refresh();
 },{ownerFns,settingsFn,refreshFn});
 assert.equal(await page.locator('#finOwnerRegisterRows tr').count(),2);assert.match(await page.textContent('#finOwnerRegisterRows'),/Shareholder One/);assert.match(await page.textContent('#finOwnerRegisterRows'),/Shareholder Two/);assert.match(await page.textContent('#finOwnerRegisterRows'),/75.00/);assert.equal(await page.locator('#finOwnerRegisterEmpty').isVisible(),false);assert.equal(await page.evaluate(()=>activeTabSeen),'overview');
 await page.click('[data-owner-edit="one"]');await page.click('[data-owner-history="two"]');assert.deepEqual(await page.evaluate(()=>edits),['one']);assert.deepEqual(await page.evaluate(()=>histories),['two']);
 await page.evaluate(()=>{document.getElementById('finOwnerRegisterRows').innerHTML='';return reloadOwnerSettings()});assert.equal(await page.locator('#finOwnerRegisterRows tr').count(),2);
 for(const width of [1440,1024,768,390]){await page.setViewportSize({width,height:1100});const layout=await page.evaluate(()=>{const grid=document.querySelector('.fin-owner-add-grid'),b=document.getElementById('finOwnerAdd').getBoundingClientRect(),r=grid.getBoundingClientRect(),fields=['finOwnerName','finOwnerRole','finOwnerPercent','finOwnerEffectiveFrom'].map(id=>document.getElementById(id).getBoundingClientRect());return {fits:b.left>=r.left-1&&b.right<=r.right+1,actionBelow:b.top>=Math.max(...fields.map(x=>x.bottom)),overflow:document.documentElement.scrollWidth>innerWidth,fieldsFit:fields.every(f=>f.left>=r.left-1&&f.right<=r.right+1)};});assert.equal(layout.fits,true,'button width '+width);assert.equal(layout.actionBelow,true,'action row '+width);assert.equal(layout.overflow,false,'page overflow '+width);assert.equal(layout.fieldsFit,true,'field widths '+width);}
 }finally{await browser.close();}
});
test('owner edit fields align and scroll between visible header and actions',async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH,args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{const page=await browser.newPage(),base=path.join(__dirname,'../../public'),html=fs.readFileSync(path.join(base,'index.html'),'utf8');
 const start=html.indexOf('<div class="modal" id="finOwnerEditModal"'),end=html.indexOf('<div class="modal" id="finOwnerHistoryModal"',start);
 await page.setContent(html.slice(start,end));await page.addStyleTag({path:path.join(base,'styles-core.css')});await page.addStyleTag({path:path.join(base,'styles.css')});await page.locator('#finOwnerEditModal').evaluate(e=>e.classList.add('open'));
 for(const width of [1440,1024,768,390]){await page.setViewportSize({width,height:800});await page.locator('#finOwnerEditModal .form-grid').evaluate(e=>e.scrollTop=0);
 const layout=await page.evaluate(()=>{const m=document.getElementById('finOwnerEditModal'),grid=m.querySelector('.form-grid'),head=m.querySelector('.modal-head').getBoundingClientRect(),foot=m.querySelector('.actions').getBoundingClientRect(),fields=[...grid.querySelectorAll('input,select')].map(e=>e.getBoundingClientRect()),r=grid.getBoundingClientRect();return {first:fields[0].top>=head.bottom,paired:innerWidth<=760||Math.abs(fields[2].top-fields[3].top)<1,fit:fields.every(f=>f.left>=r.left&&f.right<=r.right),header:head.top>=0,footer:foot.bottom<=innerHeight,scroll:grid.scrollHeight>grid.clientHeight,overflow:document.documentElement.scrollWidth>innerWidth};});
 for(const k of ['first','paired','fit','header','footer'])assert.equal(layout[k],true,k+' '+width);assert.equal(layout.overflow,false,'overflow '+width);
 await page.locator('#finOwnerEditNote').scrollIntoViewIfNeeded();assert.equal(await page.locator('#finOwnerEditSave').isVisible(),true);
 const clear=await page.evaluate(()=>document.getElementById('finOwnerEditNote').getBoundingClientRect().bottom<=document.querySelector('#finOwnerEditModal .actions').getBoundingClientRect().top);assert.equal(clear,true,'last field above footer '+width);
 }
 }finally{await browser.close();}
});
