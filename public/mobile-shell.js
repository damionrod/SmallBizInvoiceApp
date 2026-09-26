/* Frindly v61.99D — single mobile navigation controller.
   Deliberately independent of app.js / saas.js / Supabase. */
(function(){
  'use strict';
  var BP=760, OPEN='mobile-nav-open';
  function id(x){return document.getElementById(x);}
  function mobile(){return window.matchMedia?window.matchMedia('(max-width:'+BP+'px)').matches:(window.innerWidth<=BP);}
  function state(){return !!(document.body&&document.body.classList.contains(OPEN));}
  function set(open){
    open=!!open&&mobile();
    if(document.body)document.body.classList.toggle(OPEN,open);
    var b=id('mobileMenuBtn'),n=id('primaryNav');
    if(b)b.setAttribute('aria-expanded',open?'true':'false');
    if(n)n.setAttribute('aria-hidden',mobile()?(open?'false':'true'):'false');
  }
  function toggle(e){if(e){e.preventDefault();e.stopPropagation();}set(!state());}
  function close(){set(false);} function open(){set(true);}
  function bind(){
    var b=id('mobileMenuBtn'),n=id('primaryNav');
    if(b&&!b.dataset.mobileNavBound){b.dataset.mobileNavBound='1';b.addEventListener('click',toggle,false);}
    if(n&&!n.dataset.mobileNavBound){n.dataset.mobileNavBound='1';n.addEventListener('click',function(e){if(mobile()&&e.target.closest('.nav-btn'))close();});}
    if(!document.documentElement.dataset.mobileNavGlobalBound){
      document.documentElement.dataset.mobileNavGlobalBound='1';
      document.addEventListener('click',function(e){if(!state())return;var b=id('mobileMenuBtn'),n=id('primaryNav');if((b&&b.contains(e.target))||(n&&n.contains(e.target)))return;close();},false);
      document.addEventListener('keydown',function(e){if(e.key==='Escape'&&state())close();});
      window.addEventListener('resize',function(){if(!mobile())close();},{passive:true});
      window.addEventListener('orientationchange',function(){setTimeout(function(){close();},100);},{passive:true});
    }
    set(false);
  }
  window.FrindlyMobileNav={open:open,close:close,toggle:toggle,isOpen:state,sync:set};
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',bind,{once:true});else bind();
})();
