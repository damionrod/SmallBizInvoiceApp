/* Frindly v61.98P — mobile shell only. No business logic. */
(function(){
  'use strict';
  var OPEN='mobile-nav-open';
  function el(id){return document.getElementById(id)}
  function close(){
    if(document.body) document.body.classList.remove(OPEN);
    var b=el('mobileMenuBtn'); if(b) b.setAttribute('aria-expanded','false');
  }
  function toggle(ev){
    if(ev){ev.preventDefault();ev.stopPropagation()}
    if(!document.body) return;
    var b=el('mobileMenuBtn'); if(!b) return;
    var open=!document.body.classList.contains(OPEN);
    document.body.classList.toggle(OPEN,open);
    b.setAttribute('aria-expanded',open?'true':'false');
  }
  window.FrindlyMobileNav={close:close,toggle:toggle};
  function bind(){
    var b=el('mobileMenuBtn'), nav=el('primaryNav');
    if(!b||!nav) return;
    if(!b.dataset.mobileShellBound){
      b.dataset.mobileShellBound='1';
      b.addEventListener('click',toggle,false);
    }
    document.addEventListener('click',function(e){
      if(!document.body.classList.contains(OPEN)) return;
      if(b.contains(e.target)||nav.contains(e.target)) return;
      close();
    },false);
    nav.addEventListener('click',function(e){if(e.target.closest('.nav-btn')) close()},false);
    document.addEventListener('keydown',function(e){if(e.key==='Escape') close()},false);
    window.addEventListener('resize',function(){if(window.innerWidth>760) close()},{passive:true});
  }
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',bind,{once:true}); else bind();
})();
