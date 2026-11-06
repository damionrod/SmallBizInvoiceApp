const {chromium}=require('playwright');const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH,args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});try{
 for(const width of [1200,390]){
 const page=await browser.newPage({viewport:{width,height:844}});await page.setContent('<div><label id="finGstBasisControl"></label></div><input id="finGstFrom" value="2026-10-01"><input id="finGstTo" value="2026-10-31">');
 for(const name of ['styles-core.css','styles.css'])await page.addStyleTag({path:path.join(__dirname,'../../public',name)});
 await page.evaluate(()=>{
 window.q=id=>document.getElementById(id);window.esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]));window.human=v=>v;window.money=n=>'$'+Number(n||0).toFixed(2);window.isAu=()=>false;window.state={businessId:'fixture'};window.biz=()=>({id:'fixture'});window.gstRange=()=>({from:q('finGstFrom').value,to:q('finGstTo').value});window.gstSelectedBasis=()=> 'payments';window.gstConfig=()=>({gst_accounting_basis:'invoice'});window.toastMsg=s=>{throw Error(s);};window.renderGst=async()=>{};window.FrindlyDialogs={confirm:async()=>true};window.calls=[];
 window.crypto.randomUUID=()=> '90000000-0000-0000-0000-000000000001';
 window.client=()=>({from:()=>({select(){return this},eq(){return this},order(){return this},limit:async()=>({data:[]})}),rpc:async(name,args)=>{calls.push({name,args});if(name==='frindly_preview_gst_basis_change_v1')return {data:{fingerprint:'fixture',previous_basis:'invoice',requested_basis:'payments',effective_from:'2026-10-01',change_kind:args.p_kind,filed_conflict:false,current_calculation:{gst_net:150},proposed_calculation:{gst_net:0},transactions:[{reference:'SALE',date:'2026-09-01',outstanding:1150,outstanding_gst:150}],review_items:[],provisional_net_adjustment:-150,outstanding_customer_gst:150,outstanding_supplier_gst:0}};return {data:{status:'pending_verification'}};}});
 });
 const source=fs.readFileSync(path.join(__dirname,'../../public/financials.js'),'utf8');await page.addScriptTag({content:source.slice(source.indexOf('function ensureGstBasisChangeUi'),source.indexOf('function gstRange'))});
 await page.evaluate(()=>ensureGstBasisChangeUi());await page.click('#finGstBasisChange');await page.selectOption('[data-field="kind"]','ird_change');await page.click('[data-action="preview"]');await page.getByText('Preview only — pending verification',{exact:true}).waitFor();
 assert.equal(await page.locator('[data-action="save"]').isDisabled(),true);await page.fill('[data-field="evidence"]','IRD test reference');await page.check('[data-field="unfiled"]');assert.equal(await page.locator('[data-action="save"]').isEnabled(),true);
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
 await page.click('[data-action="save"]');await page.getByText('Request saved — pending verification. Official GST settings and journals have not changed.',{exact:true}).waitFor();
 const calls=await page.evaluate(()=>calls);assert.equal(calls.filter(x=>x.name==='frindly_request_gst_basis_change_v1').length,1);assert.equal(calls.some(x=>/set_gst|adjustment|journal/.test(x.name)),false);
 await page.locator('[data-action="close"]').first().click();assert.equal(await page.locator('[role="dialog"]').count(),0);console.log(`PASS ${width}px preview, confirmation, single request, no posting calls and modal close`);
 }
 }finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
