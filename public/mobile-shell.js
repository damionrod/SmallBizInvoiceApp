/* Frindly v61.99A — authoritative mobile navigation controller only. */
(function(){
  'use strict';
  var OPEN='mobile-nav-open';
  var BREAKPOINT=760;
  var bound=false;
  function byId(id){ return document.getElementById(id); }
  function button(){ return byId('mobileMenuBtn'); }
  function nav(){ return byId('primaryNav'); }
  function isMobile(){ return window.innerWidth <= BREAKPOINT; }
  function isOpen(){ return !!document.body && document.body.classList.contains(OPEN); }
  function sync(open){
    var b=button();
    if(document.body) document.body.classList.toggle(OPEN, !!open && isMobile());
    if(b) b.setAttribute('aria-expanded', (!!open && isMobile()) ? 'true' : 'false');
  }
  function close(){ sync(false); }
  function open(){ if(isMobile()) sync(true); }
  function toggle(ev){
    if(ev){ ev.preventDefault(); ev.stopPropagation(); }
    if(!isMobile()){ close(); return; }
    sync(!isOpen());
  }
  function bind(){
    if(bound) return;
    var b=button(), n=nav();
    if(!b || !n) return;
    bound=true;
    b.addEventListener('click', toggle);
    n.addEventListener('click', function(e){
      if(e.target.closest('.nav-btn')) close();
    });
    document.addEventListener('click', function(e){
      if(!isOpen()) return;
      if(b.contains(e.target) || n.contains(e.target)) return;
      close();
    });
    document.addEventListener('keydown', function(e){
      if(e.key === 'Escape' && isOpen()) close();
    });
    window.addEventListener('resize', function(){ if(!isMobile()) close(); }, {passive:true});
    window.addEventListener('orientationchange', close, {passive:true});
    sync(false);
  }
  window.FrindlyMobileNav={open:open, close:close, toggle:toggle, isOpen:isOpen};
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',bind,{once:true});
  else bind();
})();
