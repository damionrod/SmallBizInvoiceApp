/* Frindly v61.99B — authoritative mobile navigation controller only. */
(function(){
  'use strict';
  var OPEN='mobile-nav-open';
  var BREAKPOINT=760;
  var lastActivation=0;
  function byId(id){ return document.getElementById(id); }
  function button(){ return byId('mobileMenuBtn'); }
  function nav(){ return byId('primaryNav'); }
  function isMobile(){ return window.matchMedia ? window.matchMedia('(max-width:'+BREAKPOINT+'px)').matches : window.innerWidth <= BREAKPOINT; }
  function isOpen(){ return !!document.body && document.body.classList.contains(OPEN); }
  function sync(open){
    var mobile=isMobile(), state=!!open && mobile, b=button(), n=nav();
    if(document.body) document.body.classList.toggle(OPEN,state);
    if(b) b.setAttribute('aria-expanded',state?'true':'false');
    if(n) n.setAttribute('aria-hidden',state?'false':(mobile?'true':'false'));
  }
  function close(){ sync(false); }
  function open(){ if(isMobile()) sync(true); }
  function toggle(ev){
    if(ev){ ev.preventDefault(); ev.stopPropagation(); }
    if(!isMobile()){ close(); return; }
    sync(!isOpen());
  }
  function activate(ev){
    var now=Date.now();
    /* pointerup is the primary phone path; suppress the synthetic click that follows it. */
    if(ev.type==='click' && now-lastActivation<700){ ev.preventDefault(); ev.stopPropagation(); return; }
    lastActivation=now;
    toggle(ev);
  }
  function bindButton(){
    var b=button();
    if(!b || b.dataset.frindlyMobileNavBound==='1') return;
    b.dataset.frindlyMobileNavBound='1';
    if(window.PointerEvent) b.addEventListener('pointerup',activate,{passive:false});
    else b.addEventListener('touchend',activate,{passive:false});
    b.addEventListener('click',activate,false);
  }
  function bind(){
    bindButton();
    var n=nav();
    if(n && n.dataset.frindlyMobileNavBound!=='1'){
      n.dataset.frindlyMobileNavBound='1';
      n.addEventListener('click',function(e){ if(e.target.closest('.nav-btn')) close(); });
    }
    if(document.documentElement.dataset.frindlyMobileNavGlobalBound!=='1'){
      document.documentElement.dataset.frindlyMobileNavGlobalBound='1';
      document.addEventListener('pointerdown',function(e){
        if(!isOpen()) return;
        var b=button(), n=nav();
        if((b&&b.contains(e.target)) || (n&&n.contains(e.target))) return;
        close();
      },true);
      document.addEventListener('keydown',function(e){ if(e.key==='Escape'&&isOpen()) close(); });
      window.addEventListener('resize',function(){ if(!isMobile()) close(); },{passive:true});
      window.addEventListener('orientationchange',function(){ setTimeout(function(){ if(!isMobile()) close(); else sync(false); },120); },{passive:true});
      /* If another app bootstrap ever replaces the header node, restore the one controller binding. */
      new MutationObserver(bindButton).observe(document.body,{childList:true,subtree:true});
    }
    sync(false);
  }
  window.FrindlyMobileNav={open:open,close:close,toggle:toggle,isOpen:isOpen};
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',bind,{once:true}); else bind();
})();
