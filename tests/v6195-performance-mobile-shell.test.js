const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');
const html=fs.readFileSync('public/index.html','utf8'),js=fs.readFileSync('public/app.js','utf8'),css=fs.readFileSync('public/styles.css','utf8');

test('optional heavy browser libraries are deferred from initial parsing',()=>{
 for(const lib of ['jspdf.umd.min.js','jspdf.plugin.autotable.min.js','html2canvas.min.js','chart.umd.min.js','jszip.min.js']){
  assert.match(html,new RegExp(`<script defer src="[^"]*${lib.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}`));
 }
 assert.match(html,/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2"><\/script>/);
});

test('mobile app shell uses one menu button and the existing gated primary nav',()=>{
 assert.match(html,/id="mobileMenuBtn"/);
 assert.match(html,/aria-controls="primaryNav"/);
 assert.match(html,/id="primaryNav"/);
 assert.match(js,/function closeMobileNav/);
 assert.match(js,/function toggleMobileNav/);
 assert.match(js,/mobile-nav-open/);
 assert.match(css,/body\.mobile-nav-open #primaryNav/);
 assert.match(css,/#primaryNav \.nav-btn:not\(\[hidden\]\)/);
});

test('shared busy button styles are present without changing workflows',()=>{
 assert.match(css,/button\[aria-busy="true"\]/);
 assert.match(css,/@keyframes frindlySpin/);
 assert.match(css,/button:disabled/);
});
