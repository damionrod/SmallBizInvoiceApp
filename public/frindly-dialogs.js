/* Frindly in-app dialogs. UI-only: alerts can be non-blocking; confirm/prompt are
   exposed as asynchronous APIs for call sites to migrate explicitly. */
(function () {
  'use strict';
  const nativeAlert = window.alert.bind(window);
  const queue = [];
  let active = false;
  const css = `
.frindly-dialog-overlay{position:fixed;inset:0;z-index:2147483000;background:rgba(11,20,43,.55);display:flex;align-items:center;justify-content:center;padding:20px;box-sizing:border-box;overscroll-behavior:contain}
.frindly-dialog-card{width:min(100%,430px);max-height:min(85dvh,650px);overflow:auto;box-sizing:border-box;background:#fff;color:#14213d;border:1px solid #e8e8f2;border-radius:20px;box-shadow:0 24px 75px rgba(9,14,36,.28);padding:24px;font:inherit}
.frindly-dialog-heading{font-size:18px;font-weight:750;margin:0 0 12px;line-height:1.3}
.frindly-dialog-message{white-space:pre-wrap;overflow-wrap:anywhere;font-size:14px;line-height:1.6;margin:0 0 20px;color:#39425b}
.frindly-dialog-field{box-sizing:border-box;width:100%;min-height:44px;border:1px solid #c9cadd;border-radius:11px;padding:11px 12px;margin:0 0 20px;font:inherit;color:#17213e;background:#fff}
.frindly-dialog-field:focus-visible,.frindly-dialog-action:focus-visible{outline:3px solid #b2a2ff;outline-offset:2px}
.frindly-dialog-actions{display:flex;gap:10px;justify-content:flex-end;flex-wrap:wrap}
.frindly-dialog-action{min-height:44px;min-width:88px;border-radius:11px;border:1px solid #d8d7e6;padding:10px 16px;font:inherit;font-weight:650;cursor:pointer;background:#f5f5fa;color:#17213e}
.frindly-dialog-action.primary{background:#4932a8;border-color:#4932a8;color:white}
@media(max-width:520px){.frindly-dialog-overlay{align-items:flex-end;padding:0}.frindly-dialog-card{width:100%;max-height:88dvh;border-radius:20px 20px 0 0;padding:22px 18px max(20px,env(safe-area-inset-bottom))}.frindly-dialog-actions{display:grid;grid-template-columns:repeat(2,minmax(0,1fr))}.frindly-dialog-actions.single{grid-template-columns:1fr}.frindly-dialog-action{width:100%}}
@media(prefers-reduced-motion:no-preference){.frindly-dialog-card{animation:frindly-dialog-in .16s ease-out}@keyframes frindly-dialog-in{from{opacity:.7;transform:translateY(9px)}to{opacity:1;transform:translateY(0)}}}`;
  function ensureStyle(){
    if(document.getElementById('frindly-dialog-style'))return;
    const style=document.createElement('style');style.id='frindly-dialog-style';style.textContent=css;(document.head||document.documentElement).appendChild(style);
  }
  function showNext(){
    if(active||!queue.length)return;
    if(!document.body){document.addEventListener('DOMContentLoaded',showNext,{once:true});return;}
    active=true;ensureStyle();
    const request=queue.shift();
    const previous=document.activeElement;
    const overlay=document.createElement('div');overlay.className='frindly-dialog-overlay';
    const card=document.createElement('section');card.className='frindly-dialog-card';card.setAttribute('role','alertdialog');card.setAttribute('aria-modal','true');
    const heading=document.createElement('h2');heading.className='frindly-dialog-heading';heading.textContent=request.title||'Frindly';heading.id='frindly-dialog-heading';
    const message=document.createElement('p');message.className='frindly-dialog-message';message.textContent=String(request.message??'');message.id='frindly-dialog-message';
    card.setAttribute('aria-labelledby',heading.id);card.setAttribute('aria-describedby',message.id);
    card.append(heading,message);
    let field;
    if(request.kind==='prompt'){
      field=document.createElement('input');field.className='frindly-dialog-field';field.type='text';field.value=String(request.defaultValue??'');field.setAttribute('aria-label',String(request.message||'Enter a value'));card.append(field);
    }
    const actions=document.createElement('div');actions.className='frindly-dialog-actions'+(request.kind==='alert'?' single':'');
    function finish(value){overlay.removeEventListener('keydown',onKey);overlay.remove();active=false;request.resolve(value);if(previous&&previous.isConnected&&typeof previous.focus==='function')previous.focus({preventScroll:true});showNext();}
    function button(label,primary,value){const b=document.createElement('button');b.type='button';b.className='frindly-dialog-action'+(primary?' primary':'');b.textContent=label;b.addEventListener('click',()=>finish(typeof value==='function'?value():value));actions.append(b);return b;}
    if(request.kind!=='alert')button('Cancel',false,request.kind==='prompt'?null:false);
    const ok=button(request.kind==='confirm'?'Confirm':'OK',true,request.kind==='prompt'?()=>field.value:true);
    card.append(actions);overlay.append(card);document.body.append(overlay);
    function onKey(e){if(e.key==='Escape'){e.preventDefault();finish(request.kind==='alert'?true:request.kind==='prompt'?null:false);}else if(e.key==='Enter'&&(!field||e.target===field)){e.preventDefault();ok.click();}else if(e.key==='Tab'){const nodes=[...card.querySelectorAll('button,input')];const first=nodes[0],last=nodes[nodes.length-1];if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}}
    overlay.addEventListener('keydown',onKey);(field||ok).focus({preventScroll:true});
  }
  function request(kind,message,defaultValue){return new Promise(resolve=>{queue.push({kind,message,defaultValue,resolve});showNext();});}
  window.FrindlyDialogs=Object.freeze({alert:(message)=>request('alert',message),confirm:(message)=>request('confirm',message),prompt:(message,defaultValue='')=>request('prompt',message,defaultValue)});
  // Informational alerts have no meaningful synchronous return value. Do not
  // override confirm/prompt: those must be migrated with explicit awaits.
  window.alert=function(message){if(!document||!document.documentElement)return nativeAlert(message);void request('alert',message);};
})();
