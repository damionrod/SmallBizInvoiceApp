const {test}=require('node:test'),assert=require('node:assert/strict'),{chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path');const fixture=require('./activation-fixture.cjs');
test('actual basis modal applies through the real isolated database RPCs at desktop and mobile sizes',async()=>{
 const {db,scalar,seed}=await fixture();const browser=await chromium.launch({headless:true,executablePath:process.env.SETTLEMENT_CHROMIUM_PATH,args:['--no-sandbox','--disable-gpu','--disable-software-rasterizer','--no-zygote','--single-process']});
 try{for(const width of [1200,390]){
 const f=await seed('invoice');await f.prior();const page=await browser.newPage({viewport:{width,height:844}});const calls=[];
 await page.exposeFunction('dbList',async()=>({data:(await db.query("select id,period_start,period_end,effective_from,requested_basis,change_kind,status from gst_basis_change_requests where business_id=$1 and status in ('pending_verification','applied') order by created_at desc",[f.b])).rows}));
 await page.exposeFunction('dbRpc',async(name,a)=>{calls.push(name);try{
  let data;if(name==='frindly_preview_gst_basis_change_v1')data=await scalar('select public.frindly_preview_gst_basis_change_v1($1,$2,$3,$4,$5)',[a.p_from,a.p_to,a.p_basis,a.p_effective,a.p_kind]);
  else if(name==='frindly_request_gst_basis_change_v1')data=await scalar('select to_jsonb(public.frindly_request_gst_basis_change_v1($1,$2,$3,$4,$5,$6,$7,$8,$9))',[a.p_id,a.p_from,a.p_to,a.p_basis,a.p_effective,a.p_kind,a.p_evidence,a.p_fingerprint,a.p_confirm_unfiled]);
  else if(name==='frindly_gst_basis_request_review_v1')data=await scalar('select public.frindly_gst_basis_request_review_v1($1)',[a.p_id]);
  else if(name==='frindly_apply_gst_basis_change_v1')data=await scalar('select to_jsonb(public.frindly_apply_gst_basis_change_v1($1,$2,$3))',[a.p_id,a.p_fingerprint,a.p_confirm]);
  else throw Error('Unexpected RPC '+name);
  return {data};
 }catch(e){return {error:{message:e.message}};}});
 await page.setContent('<div><label id="finGstBasisControl"></label></div><input id="finGstFrom" value="2026-10-01"><input id="finGstTo" value="2026-10-31">');
 for(const file of ['styles-core.css','styles.css'])await page.addStyleTag({path:path.join(__dirname,'../../public',file)});
 await page.evaluate(b=>{
  window.q=id=>document.getElementById(id);window.esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]));window.human=v=>v;window.money=n=>'$'+Number(n||0).toFixed(2);window.isAu=()=>false;window.state={businessId:b};window.biz=()=>({id:b});window.gstRange=()=>({from:q('finGstFrom').value,to:q('finGstTo').value});window.gstSelectedBasis=()=> 'payments';window.gstConfig=()=>({gst_accounting_basis:'invoice'});window.toastMsg=s=>{throw Error(s)};window.renderGst=async()=>{};window.loadFinancialData=async()=>{};window.FrindlyDialogs={confirm:async()=>true};window.crypto.randomUUID=()=> '90000000-0000-0000-0000-'+String(innerWidth).padStart(12,'0');
  window.client=()=>({rpc:window.dbRpc,from:()=>({select(){return this},eq(){return this},in(){return this},order(){return this},limit:()=>window.dbList()})});
 },f.b);
 const source=fs.readFileSync(path.join(__dirname,'../../public/financials.js'),'utf8');await page.addScriptTag({content:source.slice(source.indexOf('function ensureGstBasisChangeUi'),source.indexOf('function gstRange'))});await page.evaluate(()=>ensureGstBasisChangeUi());await page.click('#finGstBasisChange');await page.selectOption('[data-field="kind"]','ird_change');await page.click('[data-action="preview"]');await page.getByText('Ready for confirmation',{exact:true}).waitFor();
 await page.fill('[data-field="evidence"]','Isolated IRD approval');await page.check('[data-field="unfiled"]');await page.click('[data-action="save"]');await page.getByText('Request saved. Choose Review & apply below to confirm it. Official settings have not changed yet.',{exact:true}).waitFor();await page.click('[data-review]');await page.getByRole('button',{name:'Confirm and apply basis',exact:true}).waitFor();await page.click('[data-apply]');await page.getByText('Basis applied. The transition adjustment and filing controls are linked to this request.',{exact:true}).waitFor();
 assert.equal(await scalar("select accounting_basis from gst_settings_history where business_id=$1 and effective_from='2026-10-01'",[f.b]),'payments');assert.equal(Number(await scalar("select gst_amount from gst_adjustments where business_id=$1 and status='active'",[f.b])),90);assert.equal(calls.filter(x=>x==='frindly_apply_gst_basis_change_v1').length,1);assert.equal(Number(await scalar("select count(*) from accounting_journals where business_id=$1 and source_type='gst_return_transfer'",[f.b])),0);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
 console.log('PASS real modal -> database request -> confirmed settings/adjustment at',width,'px');
 }}finally{await browser.close();await db.close();}
});
