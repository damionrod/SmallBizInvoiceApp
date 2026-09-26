/* Frindly v61.99C — authoritative mobile navigation state controller.
   Opening/closing is backed by a native checkbox + label so portrait touch activation
   does not depend on application bootstrap, Pointer Events, or synthetic click timing. */
(function(){
  'use strict';
  var OPEN='mobile-nav-open';
  var BREAKPOINT=760;
  function byId(id){ return document.getElementById(id); }
  function button(){ return byId('mobileMenuBtn'); }
  function toggleInput(){ return byId('mobileNavToggle'); }
  function nav(){ return byId('primaryNav'); }
  function isMobile(){
    try{return window.matchMedia('(max-width:'+BREAKPOINT+'px)').matches;}
    catch(e){return (document.documentElement.clientWidth||window.innerWidth||9999)<=BREAKPOINT;}
  }
  function isOpen(){ var t=toggleInput(); return !!(isMobile() && t && t.checked); }
  function sync(open){
    var mobile=isMobile(), state=!!open&&mobile, t=toggleInput(), b=button(), n=nav();
    if(t && t.checked!==state) t.checked=state;
    if(document.body) document.body.classList.toggle(OPEN,state);
    if(b) b.setAttribute('aria-expanded',state?'true':'false');
    if(n) n.setAttribute('aria-hidden',mobile?(state?'false':'true'):'false');
  }
  function close(){sync(false);}
  function open(){if(isMobile())sync(true);}
  function toggle(ev){if(ev){ev.preventDefault();ev.stopPropagation();}sync(!isOpen());}
  function bind(){
    var t=toggleInput(), b=button(), n=nav();
    if(t && t.dataset.frindlyMobileNavBound!=='1'){
      t.dataset.frindlyMobileNavBound='1';
      t.addEventListener('change',function(){sync(t.checked);});
    }
    if(b && b.dataset.frindlyMobileNavKeyBound!=='1'){
      b.dataset.frindlyMobileNavKeyBound='1';
      b.addEventListener('keydown',function(e){
        if(e.key==='Enter'||e.key===' '){e.preventDefault();sync(!isOpen());}
      });
    }
    if(n && n.dataset.frindlyMobileNavBound!=='1'){
      n.dataset.frindlyMobileNavBound='1';
      n.addEventListener('click',function(e){if(isMobile()&&e.target.closest('.nav-btn'))close();});
    }
    if(document.documentElement.dataset.frindlyMobileNavGlobalBound!=='1'){
      document.documentElement.dataset.frindlyMobileNavGlobalBound='1';
      document.addEventListener('click',function(e){
        if(!isOpen())return;
        var bb=button(),nn=nav();
        if((bb&&bb.contains(e.target))||(nn&&nn.contains(e.target)))return;
        close();
      },false);
      document.addEventListener('keydown',function(e){if(e.key==='Escape'&&isOpen())close();});
      if(window.matchMedia){
        var mq=window.matchMedia('(max-width:'+BREAKPOINT+'px)'), changed=function(){close();};
        if(mq.addEventListener)mq.addEventListener('change',changed);else if(mq.addListener)mq.addListener(changed);
      }else window.addEventListener('resize',function(){if(!isMobile())close();},{passive:true});
    }
    sync(false);
  }
  window.FrindlyMobileNav={open:open,close:close,toggle:toggle,isOpen:isOpen,sync:sync};
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',bind,{once:true});else bind();
})();
