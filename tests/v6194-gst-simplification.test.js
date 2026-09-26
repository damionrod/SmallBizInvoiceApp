const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');
const html=fs.readFileSync('public/index.html','utf8'),js=fs.readFileSync('public/financials.js','utf8'),css=fs.readFileSync('public/styles.css','utf8');
test('GST page is a guided review screen with myIR figures and safe wording',()=>{
 assert.match(html,/GST Returns/);
 assert.match(html,/Figures for myIR/);
 assert.match(html,/Before you finish/);
 assert.match(html,/Included transactions/);
 assert.match(html,/Review GST collected and paid before exporting or marking as filed/);
 assert.match(html,/id="financialReportPeriodCard"/);
 assert.match(html,/id="finGstCsv"/);
 assert.doesNotMatch(html,/id="finGstExcel"/);
 assert.doesNotMatch(html,/IRD upload file|myIR-ready CSV|Submit to IRD/i);
});
test('GST simplification keeps existing calculation, export and finalise hooks',()=>{
 assert.match(js,/rpc\('v6170e_gst_calculate'/);
 assert.match(js,/rpc\('v6170e_save_gst_return'/);
 assert.match(js,/function gstExportRows/);
 assert.match(js,/function downloadCsvRows/);
 assert.match(js,/function exportGstPdf/);
 assert.match(js,/periodCard\.hidden=tab==='gst'/);
 assert.match(js,/Sales included/);
 assert.match(js,/Expenses included/);
 assert.match(js,/q\('finGstCsv'\)\.onclick=\(\)=>downloadCsvRows/);
 assert.doesNotMatch(js,/finGstExcel/);
 assert.match(js,/q\('finGstFinalise'\)\.onclick=\(\)=>saveGst\('finalised'\)/);
 assert.doesNotMatch(js,/IRD upload file|myIR-ready CSV|Submit to IRD/i);
});
test('GST redesign has mobile-specific compact transaction rows',()=>{
 assert.match(css,/gst-simple-summary/);
 assert.match(css,/gst-checklist/);
 assert.match(css,/gst-segmented/);
 assert.match(css,/@media\(max-width:720px\).*gst-transaction-table/s);
});
test('GST UX pass keeps one active period selector and de-emphasises setup fields',()=>{
 assert.match(html,/class="card financial-gst-period-card"/);
 assert.match(html,/class="gst-filing-note"/);
 assert.doesNotMatch(html,/summary-grid gst-period-summary/);
 assert.match(js,/periodCard\.hidden=tab==='gst'/);
 assert.match(js,/function renderGstChecklist/);
 assert.match(js,/data-gst-show-checks/);
 assert.match(js,/All checks passed/);
 assert.match(css,/notice\.notice-strong/);
 assert.match(css,/gst-check-summary/);
 assert.match(css,/gst-filing-note/);
});
