'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..');
function loader(){
 const inserted=[],window={APP_CONFIG:{version:'test-release'},FRINDLY_BUILD_ASSETS:{'app.js':'abc123'}};
 vm.runInNewContext(fs.readFileSync(path.join(root,'public/finlo-core.js'),'utf8'),{window,URLSearchParams,document:{createElement:()=>({}),body:{appendChild:s=>inserted.push(s)}}});
 return {window,inserted,api:window.FinloCore.loader};
}
test('local asset versions replace stale tags, preserve parameters and leave remote URLs alone',()=>{
 const {api}=loader();
 assert.equal(api.assetUrl('app.js?v=old&mode=test#target'),'app.js?v=abc123&mode=test#target');
 assert.equal(api.assetUrl('other.js'),'other.js?v=test-release');
 for(const url of ['https://cdn.example/app.js?v=old','//cdn.example/app.js','data:text/javascript,test','image.svg'])assert.equal(api.assetUrl(url),url);
});
test('modules are inserted in requested execution order and completion waits for all modules',async()=>{
 const {api,inserted}=loader();let finished=false;
 const pending=api.loadScriptsSequentially(['first.js','app.js']).then(()=>{finished=true});
 assert.equal(inserted.length,2);
 assert.deepEqual(inserted.map(s=>[s.async,s.src]),[[false,'first.js?v=test-release'],[false,'app.js?v=abc123']]);
 inserted[1].onload();await Promise.resolve();assert.equal(finished,false);
 inserted[0].onload();await pending;assert.equal(finished,true);
});
test('failed script loads reject startup instead of reporting success',async()=>{
 const {api,inserted}=loader(),pending=api.loadScript('app.js');inserted[0].onerror();await assert.rejects(pending,/Unable to load app.js/);
});
test('published asset hashes match final bytes and HTML references the generated manifest',()=>{
 const {spawnSync}=require('node:child_process');
 const build=spawnSync(process.execPath,['scripts/build-market.cjs'],{cwd:root,encoding:'utf8'});assert.equal(build.status,0,build.stderr);
 const output=path.join(root,'dist-market'),window={};
 vm.runInNewContext(fs.readFileSync(path.join(output,'runtime-assets.js'),'utf8'),{window});
 for(const [name,hash] of Object.entries(window.FRINDLY_BUILD_ASSETS))assert.equal(hash,crypto.createHash('sha256').update(fs.readFileSync(path.join(output,name))).digest('hex').slice(0,16),name);
 for(const name of ['index.html','pay.html']){
  const html=fs.readFileSync(path.join(output,name),'utf8');assert.match(html,/<head[^>]*>\s*<script src="runtime-assets.js\?v=[a-f0-9]{16}"><\/script>/i);
  for(const [,file,hash]of html.matchAll(/(?:src|href)="([\w-]+\.(?:js|css))\?v=([a-f0-9]{16})"/g))if(file!=='runtime-assets.js')assert.equal(hash,window.FRINDLY_BUILD_ASSETS[file]);
 }
});
test('content versions are reproducible and change only for changed asset bytes',t=>{
 const os=require('node:os'),{spawnSync}=require('node:child_process');
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'market-assets-'));t.after(()=>fs.rmSync(temp,{recursive:true,force:true}));
 fs.mkdirSync(path.join(temp,'scripts'));fs.mkdirSync(path.join(temp,'public'));
 fs.copyFileSync(path.join(root,'scripts/build-market.cjs'),path.join(temp,'scripts/build-market.cjs'));
 fs.copyFileSync(path.join(root,'public/app-config.js'),path.join(temp,'public/app-config.js'));
 fs.writeFileSync(path.join(temp,'public/index.html'),'<html><head></head><body><script src="a.js?v=old"></script><script src="https://cdn.example/a.js?v=remote"></script></body></html>');
 for(const name of ['a.js','b.js','frontend-quality.css'])fs.writeFileSync(path.join(temp,'public',name),'/* initial */');
 function build(){const result=spawnSync(process.execPath,['scripts/build-market.cjs'],{cwd:temp,encoding:'utf8'});assert.equal(result.status,0,result.stderr);const window={};vm.runInNewContext(fs.readFileSync(path.join(temp,'dist-market/runtime-assets.js'),'utf8'),{window});return JSON.parse(JSON.stringify(window.FRINDLY_BUILD_ASSETS));}
 const first=build();assert.deepEqual(build(),first);
 fs.appendFileSync(path.join(temp,'public/a.js'),'/* changed */');const changed=build();assert.notEqual(changed['a.js'],first['a.js']);
 for(const name of ['b.js','frontend-quality.css','app-config.js'])assert.equal(changed[name],first[name]);
 const html=fs.readFileSync(path.join(temp,'dist-market/index.html'),'utf8');assert.ok(html.includes('a.js?v='+changed['a.js']));assert.ok(html.includes('https://cdn.example/a.js?v=remote'));
});
