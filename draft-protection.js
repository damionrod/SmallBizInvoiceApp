(function(){
  'use strict';
  const timers=new Map(),restored=new Set(),watched=new WeakMap();
  function scope(){const s=window.SAAS?.state||{},b=s.business?.id||'no-business',u=s.user?.id||'no-user';return `frindly:draft:v1:${b}:${u}:`}
  function storageKey(key){return scope()+key}
  function save(key,data){try{localStorage.setItem(storageKey(key),JSON.stringify({savedAt:new Date().toISOString(),data}))}catch(e){console.warn('[DraftProtection] save skipped',e)}}
  function load(key){try{const raw=localStorage.getItem(storageKey(key));if(!raw)return null;const parsed=JSON.parse(raw);return parsed?.data??null}catch(e){console.warn('[DraftProtection] load skipped',e);return null}}
  function clear(key){try{localStorage.removeItem(storageKey(key))}catch{}restored.delete(storageKey(key))}
  function debounceSave(key,getData,delay=350){clearTimeout(timers.get(key));timers.set(key,setTimeout(()=>{try{const data=getData?.();if(data)save(key,data)}catch(e){console.warn('[DraftProtection] snapshot skipped',e)}},delay))}
  function watch(key,root,getData,restoreData,{restore=true}={}){const el=typeof root==='string'?document.querySelector(root):root;if(!el)return()=>{};let keys=watched.get(el);if(!keys){keys=new Set();watched.set(el,keys)}if(keys.has(key))return()=>{};keys.add(key);const handler=()=>debounceSave(key,getData);el.addEventListener('input',handler,true);el.addEventListener('change',handler,true);if(restore){const sk=storageKey(key);if(!restored.has(sk)){restored.add(sk);const data=load(key);if(data)try{restoreData?.(data)}catch(e){console.warn('[DraftProtection] restore skipped',e)}}}return()=>{el.removeEventListener('input',handler,true);el.removeEventListener('change',handler,true)}}
  window.DraftProtection={save,load,clear,watch,debounceSave};
})();
