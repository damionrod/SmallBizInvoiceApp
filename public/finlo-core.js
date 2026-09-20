/* Finlo shared frontend primitives — V61.72A
   Intentionally small: only behaviour-neutral utilities with identical semantics belong here. */
(()=>{
  'use strict';
  if(window.FinloCore)return;
  const byId=id=>document.getElementById(id);
  const num=value=>Number(value)||0;
  const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,ch=>({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'
  }[ch]));
  const loadScript=(src)=>new Promise((resolve,reject)=>{
    const script=document.createElement('script');
    script.src=src;
    script.onload=()=>resolve(script);
    script.onerror=()=>reject(new Error(`Unable to load ${src}`));
    document.body.appendChild(script);
  });
  const loadScriptsSequentially=async(sources)=>{
    for(const src of sources)await loadScript(src);
  };
  Object.freeze(window.FinloCore={
    dom:Object.freeze({byId}),
    value:Object.freeze({num}),
    text:Object.freeze({escapeHtml}),
    loader:Object.freeze({loadScript,loadScriptsSequentially})
  });
})();
