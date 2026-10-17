'use strict';
// Read-only source inventory. Equality and reachability are evidence, not deletion permission.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..'),publicDir=path.join(root,'public');
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const entries=fs.readdirSync(publicDir).sort().filter(name=>/\.(?:html|js|css)$/.test(name));
const edges=[];
for(const name of entries){
 const source=fs.readFileSync(path.join(publicDir,name),'utf8');
 if(name.endsWith('.html'))for(const [,url]of source.matchAll(/(?:src|href)=["']([^"']+)["']/g)){
  if(/^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(url))continue;
  const target=url.split(/[?#]/)[0].replace(/^\.\//,'').replace(/^\//,'');
  if(/\.(?:js|css)$/.test(target))edges.push({from:name,to:target,type:'html',exists:fs.existsSync(path.join(publicDir,target))});
 }
 for(const match of source.matchAll(/loadScriptsSequentially\(\[([\s\S]*?)\]\)/g))for(const [,url]of match[1].matchAll(/['"]([^'"]+\.js(?:\?[^'"]*)?)['"]/g)){
  const target=url.split('?')[0];edges.push({from:name,to:target,type:'dynamic-loader',exists:fs.existsSync(path.join(publicDir,target))});
 }
}
const rootPairs=entries.filter(name=>fs.existsSync(path.join(root,name))).map(name=>({name,identical:hash(path.join(root,name))===hash(path.join(publicDir,name)),action:'retain until non-Market consumers and packaging paths are verified'}));
const inbound=new Set(edges.map(edge=>edge.to));
const result={schemaVersion:1,scope:'static HTML and recognized dynamic-loader edges; globals, CSS imports and backend callers require separate analysis',entrypoints:entries.filter(name=>name.endsWith('.html')),edges,rootPairs,notDirectlyReferenced:entries.filter(name=>!name.endsWith('.html')&&!inbound.has(name)),warning:'Not directly referenced does not mean unused. No files or database objects are deleted by this inventory.'};
process.stdout.write(JSON.stringify(result,null,2)+'\n');
