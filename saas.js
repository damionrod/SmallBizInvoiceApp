(() => {
  const C = window.APP_CONFIG || {};
  const q = id => document.getElementById(id);
  const state = { client:null, session:null, user:null, profile:null, business:null, subscription:null, plan:null, loadedApp:false, checkoutAvailable:null };

  function message(text, kind=''){
    const el=q('authMessage'); if(!el)return; el.textContent=text||''; el.className='auth-message '+kind;
  }
  function businessSettingsKey(businessId=state.business?.id){return businessId?`invoice_app_settings:${businessId}`:'invoice_app_settings'}
  function readJsonStorage(key){try{return JSON.parse(localStorage.getItem(key)||'{}')||{}}catch{return{}}}
  function appSettings(){const bid=state.business?.id;return bid?readJsonStorage(businessSettingsKey(bid)):readJsonStorage('invoice_app_settings')}
  function writeBusinessSettingsCache(s,businessId=state.business?.id){const value=JSON.stringify(injectInfra(s||{}));if(businessId)localStorage.setItem(businessSettingsKey(businessId),value);localStorage.setItem('invoice_app_settings',value)}
  function stripInfra(s){ const x={...(s||{})}; delete x.supabaseUrl; delete x.supabaseKey; return x }
  function injectInfra(s={}){ return {...s,supabaseUrl:C.supabaseUrl||'',supabaseKey:C.supabaseKey||''} }
  function meaningfulLegacySettings(s){ return !!(s.company||s.trading||s.address||s.phone||s.email||s.gstNumber||s.logoData||((s.products||[]).some(p=>p&&p.name&&!['Service','Product','Other'].includes(p.name)))) }
  function sameJson(a,b){try{return JSON.stringify(a??null)===JSON.stringify(b??null)}catch{return false}}

  async function init(){
    document.body.classList.add('auth-locked');
    if(!C.supabaseUrl || !C.supabaseKey || !window.supabase){
      q('authShell').classList.add('open'); message('Application cloud configuration is missing.','error'); return;
    }
    state.client=window.supabase.createClient(C.supabaseUrl,C.supabaseKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
    bindAuthUI();
    await loadSignupPlans();
    const {data:{session}}=await state.client.auth.getSession();
    if(session) await enter(session); else q('authShell').classList.add('open');
    state.client.auth.onAuthStateChange(async (event,session)=>{
      if(event==='SIGNED_OUT'){location.reload();return}
      if((event==='SIGNED_IN'||event==='TOKEN_REFRESHED')&&session&&!state.loadedApp) await enter(session);
    });
  }

  function switchAuthTab(tab,email=''){
    document.querySelectorAll('[data-auth-tab]').forEach(x=>x.classList.toggle('active',x.dataset.authTab===tab));
    q('loginForm').hidden=tab!=='login';
    q('signupForm').hidden=tab!=='signup';
    if(tab==='login'&&email&&q('loginEmail'))q('loginEmail').value=email;
  }

  function existingAccountMessage(email){
    switchAuthTab('login',email);
    message('An account already exists with this email. Log in below, or use Forgot password if you cannot remember your password.','error');
    q('loginPassword')?.focus();
  }

  async function getCheckoutAvailability(force=false){
    if(!state.client)return false;
    if(!force&&typeof state.checkoutAvailable==='boolean')return state.checkoutAvailable;
    const {data,error}=await state.client.rpc('v35_checkout_available');
    state.checkoutAvailable=!error&&data===true;
    return state.checkoutAvailable;
  }

  function bindAuthUI(){
    document.querySelectorAll('[data-auth-tab]').forEach(btn=>btn.onclick=()=>{switchAuthTab(btn.dataset.authTab);message('');});
    if(q('alreadyAccountBtn'))q('alreadyAccountBtn').onclick=()=>{const email=q('signupEmail')?.value.trim()||'';switchAuthTab('login',email);message('Log in with your existing account.');};
    q('loginForm').onsubmit=async e=>{
      e.preventDefault(); message('Logging in…');
      const {error}=await state.client.auth.signInWithPassword({email:q('loginEmail').value.trim(),password:q('loginPassword').value});
      if(error)message(error.message,'error');
    };
    q('signupForm').onsubmit=async e=>{
      e.preventDefault();
      const selectedPlan=q('signupPlan')?.value||'trial';
      const submit=q('signupSubmitBtn');
      if(!selectedPlan){message('Choose a subscription plan first.','error');return}
      if(submit){submit.disabled=true;submit.textContent=selectedPlan==='trial'?'Creating account…':'Creating account…'}
      message(selectedPlan==='trial'?'Creating your trial account…':'Creating your account…');
      const email=q('signupEmail').value.trim();
      const {data,error}=await state.client.auth.signUp({
        email,password:q('signupPassword').value,
        options:{data:{full_name:q('signupName').value.trim(),business_name:q('signupBusiness').value.trim(),business_address:q('signupAddress').value.trim(),phone:q('signupPhone').value.trim(),selected_plan_slug:selectedPlan}}
      });
      if(submit){submit.disabled=false;submit.textContent='Create account'}
      if(error){
        if(/already registered|already exists|user exists/i.test(error.message||'')){existingAccountMessage(email);return}
        message(error.message,'error');return
      }
      // With Supabase email confirmation enabled, an existing confirmed account can return
      // an obfuscated user instead of an explicit duplicate-user error. An empty identities
      // collection is the safe client-side signal Supabase exposes for this case.
      if(data?.user && Array.isArray(data.user.identities) && data.user.identities.length===0){existingAccountMessage(email);return}
      if(data.session){
        message(selectedPlan==='trial'?'Account created. Loading your business…':'Account created. Opening secure payment…','success');
        await enter(data.session);
      } else {
        message(selectedPlan==='trial'?'Account created. Check your email to confirm your address, then log in.':'Account created. Confirm your email, then log in to continue to secure Stripe payment.','success');
      }
    };
    q('forgotPasswordBtn').onclick=async()=>{
      const email=q('loginEmail').value.trim(); if(!email)return message('Enter your email address first.','error');
      const {error}=await state.client.auth.resetPasswordForEmail(email,{redirectTo:location.origin});
      message(error?error.message:'Password reset email sent.',error?'error':'success');
    };
  }

  async function loadSignupPlans(){
    const select=q('signupPlan'); if(!select||!state.client)return;
    const [{data:plans,error},checkoutReady]=await Promise.all([
      state.client.from('plans').select('id,slug,name,description,monthly_price,invoice_limit,is_public,sort_order,stripe_price_id').order('sort_order'),
      getCheckoutAvailability(true)
    ]);
    if(error){select.innerHTML='<option value="trial">Trial</option>'; if(q('signupPlanSummary'))q('signupPlanSummary').textContent='Plan list could not be loaded. Trial is available.'; return}
    const available=(plans||[]).filter(p=>p.slug==='trial'||p.is_public);
    select.innerHTML=available.map(p=>{
      const paid=p.slug!=='trial';
      const purchasable=!paid||(checkoutReady&&!!p.stripe_price_id);
      const suffix=p.slug==='trial'?'Free trial':('$'+Number(p.monthly_price||0).toFixed(2)+'/month'+(purchasable?'':' — unavailable'));
      return `<option value="${escapeHtml(p.slug)}" ${purchasable?'':'disabled'}>${escapeHtml(p.name)} — ${suffix}</option>`;
    }).join('');
    if(available.some(p=>p.slug==='trial'))select.value='trial';
    const update=()=>{
      const plan=available.find(p=>p.slug===select.value);
      if(!q('signupPlanSummary')||!plan)return;
      const limit=plan.invoice_limit==null?'Unlimited invoices':`${plan.invoice_limit} invoices per period`;
      let pay='No payment required.';
      if(plan.slug!=='trial')pay=checkoutReady&&plan.stripe_price_id?'Secure online payment follows account creation.':'Online paid subscriptions are not available yet. Please choose Trial for now.';
      q('signupPlanSummary').textContent=`${plan.description||''}${plan.description?' · ':''}${limit} · ${pay}`;
    };
    select.onchange=update; update();
  }

  async function enter(session){
    state.session=session; state.user=session.user;
    const ok=await loadAccount(); if(!ok){q('authShell').classList.add('open');return}
    await loadBusinessSettings();
    await migrateLegacyLocalData();
    q('authShell').classList.remove('open'); document.body.classList.remove('auth-locked');
    setupAccountUI();
    if(await maybeContinueSignupCheckout())return;
    // A customer must never be able to retain or enter the owner route manually.
    if(location.hash==='#super-admin' && state.profile?.is_super_admin!==true){
      history.replaceState(null,'',location.pathname+location.search);
    }
    if(!state.loadedApp){
      state.loadedApp=true;
      const s=document.createElement('script'); s.src='app.js?v=52'; s.onload=()=>{const j=document.createElement('script');j.src='job-costing.js?v=52';j.onload=()=>{const e=document.createElement('script');e.src='expenses.js?v=52';e.onload=async()=>{await bindAfterAppLoad();refreshUsage();const mw=Number(localStorage.getItem('v22_migration_warning')||0);if(mw)console.warn(`${mw} legacy browser record(s) remain safely stored locally; cloud migration can be reviewed from account support if needed.`)};document.body.appendChild(e)};document.body.appendChild(j)}; document.body.appendChild(s);
    }
  }

  async function loadAccount(){
    for(let attempt=0;attempt<8;attempt++){
      const {data,error}=await state.client.from('profiles').select('id,business_id,full_name,email,role,is_super_admin,businesses(id,name,address,phone,status,settings)').eq('id',state.user.id).maybeSingle();
      if(!error&&data){state.profile=data;state.business=data.businesses;return true}
      await new Promise(r=>setTimeout(r,300));
    }
    message('Your account exists, but the SaaS database migration has not been completed. Run V22-SAAS-MIGRATION.sql in Supabase, then reload.','error'); return false;
  }

  async function loadBusinessSettings(){
    const businessId=state.business?.id;
    const cloud=state.business?.settings||{};
    const tenantLocal=readJsonStorage(businessSettingsKey(businessId));
    const legacyLocal=readJsonStorage('invoice_app_settings');
    const claimed=localStorage.getItem('v22_settings_claimed_by')||localStorage.getItem('v22_legacy_claimed_by');
    let chosen={...(cloud||{})};
    let needsCloudSave=false;

    if(!cloud||Object.keys(cloud).length===0){
      const mayClaimLegacy=!claimed||claimed===businessId;
      const source=Object.keys(tenantLocal).length?tenantLocal:(mayClaimLegacy&&meaningfulLegacySettings(legacyLocal)?legacyLocal:null);
      chosen=source?stripInfra(source):{company:state.business?.name||'',trading:state.business?.name||'',address:state.business?.address||'',phone:state.business?.phone||'',email:state.user?.email||'',invoicePrefix:'INV'};
      if(source&&!claimed)localStorage.setItem('v22_settings_claimed_by',businessId);
      needsCloudSave=true;
    }else if(!chosen._settingsBusinessId){
      // v47 and earlier could seed a new business from another business's browser settings.
      // Only remove the two business-specific sections when they exactly match the legacy
      // settings claimed by a different business; otherwise preserve existing cloud data.
      if(claimed&&claimed!==businessId&&meaningfulLegacySettings(legacyLocal)){
        if(chosen.products&&sameJson(chosen.products,legacyLocal.products))delete chosen.products;
        if(chosen.jobCostingSettings&&sameJson(chosen.jobCostingSettings,legacyLocal.jobCostingSettings))delete chosen.jobCostingSettings;
      }
      needsCloudSave=true;
    }

    chosen={...chosen,_settingsBusinessId:businessId};
    if(needsCloudSave){
      await state.client.from('businesses').update({settings:chosen,updated_at:new Date().toISOString()}).eq('id',businessId);
      state.business.settings=chosen;
    }
    writeBusinessSettingsCache(chosen,businessId);
  }

  async function migrateLegacyLocalData(){
    const marker='v22_legacy_migrated_'+state.business.id; if(localStorage.getItem(marker)==='1')return;const claimed=localStorage.getItem('v22_legacy_claimed_by');if(claimed&&claimed!==state.business.id){localStorage.setItem(marker,'1');return;}
    let customers=[],invoices=[];
    try{customers=JSON.parse(localStorage.getItem('invoice_app_customers')||localStorage.getItem('cc_customers')||'[]')||[]}catch{}
    try{invoices=JSON.parse(localStorage.getItem('invoice_app_invoices')||localStorage.getItem('cc_invoices')||'[]')||[]}catch{}
    if(!customers.length&&!invoices.length){localStorage.setItem(marker,'1');return}

    let migrationFailures=0;
    const customerMap=new Map();
    const {data:cloudCustomers}=await state.client.from('customers').select('id,customer_number,name');
    for(const c of cloudCustomers||[]) customerMap.set(String(c.customer_number||c.name||'').toLowerCase(),c.id);
    for(const c of customers){
      const key=String(c.customer_number||c.name||'').toLowerCase(); if(customerMap.has(key))continue;
      const row={...c,business_id:state.business.id,dob:c.dob||null,contacts:(c.contacts||[]).map(x=>({...x,id:undefined,dob:x.dob||null}))};
      delete row.id; (row.contacts||[]).forEach(x=>delete x.id);
      const {data,error}=await state.client.from('customers').insert(row).select('id').single();
      if(!error&&data)customerMap.set(key,data.id);else if(error){migrationFailures++;console.warn('Legacy customer migration failed',error)}
    }
    const {data:cloudInvoices}=await state.client.from('invoices').select('invoice_number');
    const existing=new Set((cloudInvoices||[]).map(x=>x.invoice_number));
    for(const inv of invoices){
      if(!inv.invoice_number||existing.has(inv.invoice_number))continue;
      const row={...inv,business_id:state.business.id}; delete row.id;delete row._sync_pending;
      if(inv.customer_id){
        const lc=customers.find(c=>String(c.id)===String(inv.customer_id));
        row.customer_id=lc?customerMap.get(String(lc.customer_number||lc.name||'').toLowerCase())||null:null;
      }
      const {error}=await state.client.from('invoices').insert(row); if(!error)existing.add(inv.invoice_number);else{migrationFailures++;console.warn('Legacy invoice migration failed',error)}
    }
    if(migrationFailures){localStorage.setItem('v22_migration_warning',String(migrationFailures));return;}localStorage.setItem(marker,'1');localStorage.setItem('v22_legacy_claimed_by',state.business.id);
  }

  async function maybeContinueSignupCheckout(){
    const slug=String(state.user?.user_metadata?.selected_plan_slug||'trial').trim();
    if(!slug||slug==='trial')return false;
    const billing=new URLSearchParams(location.search).get('billing');
    if(billing==='success'){history.replaceState(null,'',location.pathname+location.hash);return false;}
    if(billing==='cancel'){history.replaceState(null,'',location.pathname+location.hash);setTimeout(()=>showPlans().catch(console.warn),500);return false;}
    const sub=await getSubscription();
    if(sub?.plans?.slug===slug && ['active','trialing'].includes(sub.status) && sub.stripe_subscription_id)return false;
    if(sub?.plans?.slug===slug && sub.status==='active')return false;
    const result=await startCheckout(slug,null,{silent:true});
    return result===true;
  }

  async function openAdminPortal(){
    closeAccountPopover();

    // Never trust the visibility of a button for platform-owner access.
    // Re-check the authenticated user's current profile before opening Admin.
    const {data:permissionProfile,error}=await state.client
      .from('profiles')
      .select('id,is_super_admin')
      .eq('id',state.user.id)
      .maybeSingle();

    const allowed=!error && permissionProfile?.id===state.user.id && permissionProfile?.is_super_admin===true;
    state.profile.is_super_admin=allowed;
    applyAdminVisibility();

    if(!allowed){
      document.body.classList.remove('admin-portal-active');
      if(q('adminPortalBar'))q('adminPortalBar').hidden=true;
      if(location.hash==='#super-admin')history.replaceState(null,'',location.pathname+location.search);
      alert('Super Admin access is restricted to the platform owner.');
      return;
    }

    document.body.classList.add('admin-portal-active');
    if(q('adminPortalBar'))q('adminPortalBar').hidden=false;
    if(window.switchView)window.switchView('admin');
    else renderAdmin();
    history.replaceState(null,'','#super-admin');
  }
  function closeAdminPortal(){
    document.body.classList.remove('admin-portal-active');
    if(q('adminPortalBar'))q('adminPortalBar').hidden=true;
    history.replaceState(null,'',location.pathname+location.search);
    if(window.switchView)window.switchView('create');
  }

  function applyAdminVisibility(){
    const isAdmin=state.profile?.is_super_admin===true;
    if(q('adminNav'))q('adminNav').hidden=!isAdmin;
    if(q('accountAdminNav'))q('accountAdminNav').hidden=!isAdmin;
  }

  function setupAccountUI(){
    const initials=(state.profile.full_name||state.business.name||'A').split(/\s+/).slice(0,2).map(x=>x[0]||'').join('').toUpperCase();
    if(q('accountInitials'))q('accountInitials').textContent=initials||'A';
    if(q('accountAvatarLarge'))q('accountAvatarLarge').textContent=initials||'A';
    if(q('accountDisplayName'))q('accountDisplayName').textContent=state.profile.full_name||state.business.name||'Account';
    if(q('accountPopoverEmail'))q('accountPopoverEmail').textContent=state.user.email||'';
    applyAdminVisibility();
    if(q('accountChip'))q('accountChip').onclick=e=>{e.stopPropagation();const pop=q('accountPopover');if(pop)pop.hidden=!pop.hidden};
    if(q('openAccountSettings'))q('openAccountSettings').onclick=()=>openAccountSettings();
    if(q('accountManagePlan'))q('accountManagePlan').onclick=()=>{closeAccountPopover();showPlans()};
    if(q('accountAdminNav'))q('accountAdminNav').onclick=openAdminPortal;
    if(q('accountSignOut'))q('accountSignOut').onclick=()=>state.client.auth.signOut();
    if(q('signOutBtn'))q('signOutBtn').onclick=()=>state.client.auth.signOut();
    if(q('manageSubscription'))q('manageSubscription').onclick=showPlans;
    if(q('billingPortalBtn'))q('billingPortalBtn').onclick=openBillingPortal;
    if(q('closeAccountModal'))q('closeAccountModal').onclick=()=>q('accountModal').classList.remove('open');
    if(q('accountModal'))q('accountModal').onclick=e=>{if(e.target===q('accountModal'))q('accountModal').classList.remove('open')};
    if(q('saveAccountProfile'))q('saveAccountProfile').onclick=saveAccountProfile;
    if(q('saveAccountPreferences'))q('saveAccountPreferences').onclick=saveAccountPreferences;
    if(q('saveAccountEmail'))q('saveAccountEmail').onclick=saveAccountPreferences;
    if(q('exportMyData'))q('exportMyData').onclick=()=>exportBusinessData(state.business.id,state.business.name,q('exportMyData'));
    document.addEventListener('click',e=>{const pop=q('accountPopover');if(pop&&!pop.hidden&&!pop.contains(e.target)&&e.target!==q('accountChip')&&!q('accountChip')?.contains(e.target))pop.hidden=true});
    if(q('closePlanModal'))q('closePlanModal').onclick=()=>q('planModal').classList.remove('open');
    if(q('adminRefresh'))q('adminRefresh').onclick=renderAdmin;
    if(q('adminReloadPlans'))q('adminReloadPlans').onclick=renderAdminPlans;
    if(q('adminReloadPayments'))q('adminReloadPayments').onclick=renderPaymentSettings;
    if(q('adminReloadModules'))q('adminReloadModules').onclick=renderAdminModules;
    if(q('adminAddModule'))q('adminAddModule').onclick=addAdminModule;
    if(q('adminSearch'))q('adminSearch').oninput=renderAdmin;
    if(q('adminStatusFilter'))q('adminStatusFilter').onchange=renderAdmin;
    if(q('adminAddBusiness'))q('adminAddBusiness').onclick=openAdminUserModal;
    if(q('closeAdminUserModal'))q('closeAdminUserModal').onclick=()=>q('adminUserModal').classList.remove('open');
    if(q('cancelAdminUser'))q('cancelAdminUser').onclick=()=>q('adminUserModal').classList.remove('open');
    if(q('saveAdminUser'))q('saveAdminUser').onclick=createAdminBusiness;
    if(q('closeModuleModal'))q('closeModuleModal').onclick=()=>q('moduleModal').classList.remove('open');
    if(q('saveModules'))q('saveModules').onclick=saveBusinessModules;
  }

  function closeAccountPopover(){const pop=q('accountPopover');if(pop)pop.hidden=true}
  const FALLBACK_CURRENCIES='AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HRK HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAF XAG XAU XBA XBB XBC XBD XCD XDR XOF XPD XPF XPT XSU XTS XUA XXX YER ZAR ZMW ZWL'.split(' ');
  function currencyCodes(){try{const a=Intl.supportedValuesOf?.('currency');if(Array.isArray(a)&&a.length)return a}catch{}return FALLBACK_CURRENCIES}
  function currencyName(code){try{return new Intl.DisplayNames([navigator.language||'en'],{type:'currency'}).of(code)||code}catch{return code}}
  function populateCurrencySelect(){const el=q('accountCurrency');if(!el)return;const current=String(state.business?.settings?.currency||el.value||'NZD').toUpperCase();el.innerHTML=currencyCodes().map(code=>`<option value="${code}">${code} — ${escapeHtml(currencyName(code))}</option>`).join('');el.value=current;if(!el.value){const o=document.createElement('option');o.value=current;o.textContent=`${current} — ${currencyName(current)}`;el.prepend(o);el.value=current}}
  async function openAccountSettings(){
    closeAccountPopover();
    if(q('accountProfileName'))q('accountProfileName').value=state.profile?.full_name||'';
    if(q('accountProfileEmail'))q('accountProfileEmail').value=state.user?.email||'';
    if(q('accountBusinessName'))q('accountBusinessName').value=state.business?.name||'';
    if(q('accountBusinessPhone'))q('accountBusinessPhone').value=state.business?.phone||'';
    if(q('accountBusinessAddress'))q('accountBusinessAddress').value=state.business?.address||'';
    if(q('accountSenderEmail'))q('accountSenderEmail').value=state.business?.settings?.outboundEmail||'';
    populateCurrencySelect();
    if(q('accountCurrency'))q('accountCurrency').value=String(state.business?.settings?.currency||'NZD').toUpperCase();
    await refreshUsage();
    q('accountModal')?.classList.add('open');
  }
  async function saveAccountProfile(){
    const full_name=q('accountProfileName')?.value.trim()||'';
    const name=q('accountBusinessName')?.value.trim()||state.business.name;
    const phone=q('accountBusinessPhone')?.value.trim()||'';
    const address=q('accountBusinessAddress')?.value.trim()||'';
    const p1=state.client.from('profiles').update({full_name}).eq('id',state.user.id);
    const p2=state.client.from('businesses').update({name,phone,address,updated_at:new Date().toISOString()}).eq('id',state.business.id);
    const [a,b]=await Promise.all([p1,p2]);
    if(a.error||b.error)return alert(a.error?.message||b.error?.message||'Could not save account details.');
    state.profile.full_name=full_name;state.business.name=name;state.business.phone=phone;state.business.address=address;
    setupAccountUI();
    if(q('brandCompanyName'))q('brandCompanyName').textContent=(state.business.settings?.company||state.business.settings?.trading||name||'Invoice Manager');
    q('accountModal')?.classList.remove('open');
  }


  async function saveAccountPreferences(){
    const senderEmail=q('accountSenderEmail')?.value.trim()||'';
    const currency=String(q('accountCurrency')?.value||'NZD').trim().toUpperCase();
    if(senderEmail&&!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(senderEmail))return alert('Please enter a valid sender email address.');
    const nextSettings={...(state.business.settings||{}),outboundEmail:senderEmail,currency,_settingsBusinessId:state.business.id};
    const buttons=[q('saveAccountPreferences'),q('saveAccountEmail')].filter(Boolean);buttons.forEach(btn=>{btn.disabled=true;btn.dataset.oldText=btn.textContent;btn.textContent='Saving…'});
    const {error}=await state.client.from('businesses').update({settings:nextSettings,updated_at:new Date().toISOString()}).eq('id',state.business.id);
    buttons.forEach(btn=>{btn.disabled=false;btn.textContent=btn.dataset.oldText||'Save'});
    if(error)return alert('Could not save business preferences: '+error.message);
    state.business.settings=nextSettings;
    writeBusinessSettingsCache(nextSettings,state.business.id);
    window.invoiceAppHelpers?.updateSettings?.({outboundEmail:senderEmail,currency,_settingsBusinessId:state.business.id});
    alert('Business preferences saved.');
  }

  function safeFileName(value){return String(value||'business').trim().replace(/[^a-z0-9-_]+/gi,'-').replace(/^-+|-+$/g,'').toLowerCase()||'business'}
  function downloadJson(data,filename){
    const blob=new Blob([JSON.stringify(data,null,2)],{type:'application/json;charset=utf-8'});
    const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=filename;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }
  async function collectBusinessData(businessId){
    const queries={
      business:state.client.from('businesses').select('*').eq('id',businessId).single(),
      profiles:state.client.from('profiles').select('id,business_id,full_name,email,role,is_super_admin,created_at').eq('business_id',businessId),
      subscriptions:state.client.from('subscriptions').select('*,plans(*)').eq('business_id',businessId),
      business_modules:state.client.from('business_modules').select('*,modules(*)').eq('business_id',businessId),
      customers:state.client.from('customers').select('*').eq('business_id',businessId).order('created_at'),
      invoices:state.client.from('invoices').select('*').eq('business_id',businessId).order('created_at'),
      recurring_rules:state.client.from('recurring_rules').select('*').eq('business_id',businessId).order('next_invoice_date'),
      job_costings:state.client.from('job_costings').select('*').eq('business_id',businessId).order('created_at'),
      quotes:state.client.from('quotes').select('*').eq('business_id',businessId).order('created_at'),
      expense_categories:state.client.from('expense_categories').select('*').eq('business_id',businessId).order('sort_order'),
      suppliers:state.client.from('suppliers').select('*').eq('business_id',businessId).order('created_at'),
      expenses:state.client.from('expenses').select('*').eq('business_id',businessId).order('created_at'),
      expense_lines:state.client.from('expense_lines').select('*').eq('business_id',businessId).order('created_at'),
      expense_attachments:state.client.from('expense_attachments').select('*').eq('business_id',businessId).order('uploaded_at'),
      expense_payments:state.client.from('expense_payments').select('*').eq('business_id',businessId).order('created_at'),
      expense_reconciliations:state.client.from('expense_reconciliations').select('*').eq('business_id',businessId).order('created_at'),
      batch_payments:state.client.from('batch_payments').select('*').eq('business_id',businessId).order('created_at'),
      batch_payment_items:state.client.from('batch_payment_items').select('*').eq('business_id',businessId).order('created_at'),
      supplier_credits:state.client.from('supplier_credits').select('*').eq('business_id',businessId).order('created_at'),
      recurring_expense_rules:state.client.from('recurring_expense_rules').select('*').eq('business_id',businessId).order('created_at'),
      expense_audit_log:state.client.from('expense_audit_log').select('*').eq('business_id',businessId).order('created_at')
    };
    const entries=await Promise.all(Object.entries(queries).map(async([key,promise])=>{const result=await promise;if(result.error)throw new Error(`${key}: ${result.error.message}`);return [key,result.data]}));
    const data=Object.fromEntries(entries);
    return {export_version:'1.0',exported_at:new Date().toISOString(),business_id:businessId,note:'Passwords, authentication tokens and payment gateway secrets are intentionally excluded.',...data};
  }
  async function exportBusinessData(businessId,businessName,button){
    if(!businessId)return alert('Business information is missing.');
    const original=button?.textContent||'Export';if(button){button.disabled=true;button.textContent='Exporting…'}
    try{
      const payload=await collectBusinessData(businessId);
      const date=new Date().toISOString().slice(0,10);
      downloadJson(payload,`${safeFileName(businessName)}-business-data-${date}.json`);
    }catch(e){alert('Could not export business data: '+(e instanceof Error?e.message:'Unknown export error'));}
    finally{if(button){button.disabled=false;button.textContent=original}}
  }

  async function getSubscription(){
    const {data}=await state.client.from('subscriptions').select('*,plans(*)').eq('business_id',state.business.id).maybeSingle();
    state.subscription=data||null; state.plan=data?.plans||null; return data;
  }
  async function refreshUsage(){
    const sub=await getSubscription(); if(!sub)return;
    const start=sub.current_period_start, end=sub.current_period_end;
    let query=state.client.from('invoices').select('id',{count:'exact',head:true}).eq('business_id',state.business.id);
    if(start)query=query.gte('created_at',start); if(end)query=query.lt('created_at',end);
    const {count}=await query; const used=count||0; const limit=sub.invoice_limit_override??sub.plans?.invoice_limit;
    const label=limit==null?`${used} / Unlimited`:`${used} / ${limit}`;
    if(q('accountPlan'))q('accountPlan').textContent=sub.plans?.name||'—'; if(q('accountUsage'))q('accountUsage').textContent=label;
    if(q('accountMenuPlan'))q('accountMenuPlan').textContent=`${sub.plans?.name||'Plan'} · ${label}`;
    if(q('accountStatus'))q('accountStatus').textContent=sub.status==='trialing'?'Trial':sub.status.replace('_',' ');
    if(q('accountEmail'))q('accountEmail').textContent=state.user.email||'';
    if(q('usageBar')){const pct=limit?Math.min(100,Math.round(used/limit*100)):0;q('usageBar').style.width=pct+'%'}
    if(q('accountPlanHint')&&sub.status==='trialing'&&sub.trial_ends_at){const d=new Date(sub.trial_ends_at);q('accountPlanHint').textContent=`Trial ends ${d.toLocaleDateString()}. Your data is synced across devices.`}
    if(q('billingPortalBtn'))q('billingPortalBtn').hidden=!sub.stripe_customer_id;
    return {sub,used,limit};
  }

  async function canCreateInvoice(){
    const x=await refreshUsage(); if(!x)return {ok:false,message:'No subscription is attached to this business.'};
    const {sub,used,limit}=x;
    if(['suspended','canceled','past_due'].includes(sub.status))return{ok:false,message:'Your subscription is not active. Open Settings → Manage plan.'};
    if(sub.status==='trialing'&&sub.trial_ends_at&&new Date(sub.trial_ends_at)<new Date())return{ok:false,message:'Your trial has ended. Choose a plan to continue creating invoices.'};
    if(limit!=null&&used>=limit)return{ok:false,message:`You have reached your ${limit}-invoice limit for this period. Upgrade your plan to create more invoices.`};
    return {ok:true};
  }

  async function saveBusinessSettings(s){
    const clean={...stripInfra(s),_settingsBusinessId:state.business.id}; const {error}=await state.client.from('businesses').update({settings:clean,name:clean.company||clean.trading||state.business.name,address:clean.address||state.business.address,phone:clean.phone||state.business.phone,updated_at:new Date().toISOString()}).eq('id',state.business.id);
    if(!error){state.business.settings=clean;writeBusinessSettingsCache(clean,state.business.id);return true} console.warn('Business settings cloud sync failed',error);return false;
  }

  async function openBillingPortal(){
    const {data,error}=await state.client.functions.invoke('create-portal',{body:{returnUrl:location.origin}});
    if(error||!data?.url)return alert(error?.message||data?.error||'Billing portal is not available yet.');
    location.href=data.url;
  }

  async function showPlans(){
    const [{data:plans},checkoutReady]=await Promise.all([
      state.client.from('plans').select('*').eq('is_public',true).order('sort_order'),
      getCheckoutAvailability(true)
    ]);
    await getSubscription();
    const root=q('customerPlanGrid');
    root.innerHTML=(plans||[]).map(p=>{
      const current=state.plan?.id===p.id;
      const purchasable=current||(checkoutReady&&!!p.stripe_price_id);
      const buttonText=current?'Current plan':(!checkoutReady?'Online subscriptions unavailable':(!p.stripe_price_id?'Plan payment not configured':'Choose '+escapeHtml(p.name)));
      return `<div class="plan-card ${current?'current':''} ${purchasable?'':'unavailable'}"><span class="plan-name">${escapeHtml(p.name)}</span><strong>$${Number(p.monthly_price||0).toFixed(0)}<small>/month</small></strong><p>${escapeHtml(p.description||'')}</p><div class="plan-limit">${p.invoice_limit==null?'Unlimited':p.invoice_limit} invoices / period</div><div class="plan-modules">${(p.included_modules||[]).map(m=>`<span>${escapeHtml(human(m))}</span>`).join('')}</div>${!purchasable?'<p class="plan-unavailable-note">Online payment is not available yet. Your trial remains active.</p>':''}<button class="${current?'secondary':'primary'}" data-choose-plan="${p.slug}" ${purchasable&&!current?'':'disabled'}>${buttonText}</button></div>`;
    }).join('');
    root.querySelectorAll('[data-choose-plan]:not([disabled])').forEach(b=>b.onclick=()=>startCheckout(b.dataset.choosePlan,b));
    q('planModal').classList.add('open');
  }

  async function startCheckout(slug,btn,opts={}){
    const ready=await getCheckoutAvailability(true);
    if(!ready){
      if(!opts.silent)alert('Online paid subscriptions are not available yet. Please continue using the Trial plan for now.');
      else message('Online paid subscriptions are not available yet.','error');
      return false;
    }
    const original=btn?.textContent||'Choose plan';
    if(btn){btn.disabled=true;btn.textContent='Opening checkout…'}
    const {data,error}=await state.client.functions.invoke('create-checkout',{body:{planSlug:slug,returnUrl:location.origin}});
    if(error||!data?.url){
      if(btn){btn.disabled=false;btn.textContent=original}
      const text=error?.message||data?.error||'Billing is not configured yet.';
      if(!opts.silent)alert('We could not open online checkout right now. Please try again later or contact support.');
      else message(text,'error');
      return false;
    }
    location.href=data.url; return true;
  }

  function openAdminUserModal(){
    ['adminNewName','adminNewBusiness','adminNewEmail','adminNewPhone','adminNewAddress','adminNewPassword'].forEach(id=>{if(q(id))q(id).value=''});if(q('adminNewTrialDays'))q('adminNewTrialDays').value='14';if(q('adminUserMessage'))q('adminUserMessage').textContent='';q('adminUserModal').classList.add('open');
  }

  async function createAdminBusiness(){
    const payload={fullName:q('adminNewName').value.trim(),businessName:q('adminNewBusiness').value.trim(),email:q('adminNewEmail').value.trim(),phone:q('adminNewPhone').value.trim(),address:q('adminNewAddress').value.trim(),password:q('adminNewPassword').value,trialDays:Number(q('adminNewTrialDays').value||14)};
    if(!payload.fullName||!payload.businessName||!payload.email||payload.password.length<8){q('adminUserMessage').textContent='Enter name, business, email and a password of at least 8 characters.';return}
    q('saveAdminUser').disabled=true;q('saveAdminUser').textContent='Creating…';
    const {data,error}=await state.client.functions.invoke('admin-create-user',{body:payload});
    q('saveAdminUser').disabled=false;q('saveAdminUser').textContent='Create account';
    if(error||data?.error){q('adminUserMessage').textContent=error?.message||data.error;return}
    q('adminUserModal').classList.remove('open');await renderAdmin();
  }

  async function openModuleManager(businessId,businessName){
    const [{data:mods},{data:enabled},{data:sub}]=await Promise.all([
      state.client.from('modules').select('*').order('name'),
      state.client.from('business_modules').select('module_id,status').eq('business_id',businessId),
      state.client.from('subscriptions').select('plans(included_modules)').eq('business_id',businessId).maybeSingle()
    ]);
    const overrides=new Map((enabled||[]).map(x=>[x.module_id,x.status]));
    const included=new Set(sub?.plans?.included_modules||[]);
    q('moduleModal').dataset.businessId=businessId;q('moduleBusinessName').textContent=businessName;
    q('moduleChecklist').innerHTML=(mods||[]).map(m=>{
      const explicit=overrides.get(m.id);
      const inherited=included.has(m.slug);
      const checked=explicit?['active','trialing'].includes(explicit):inherited;
      const source=explicit==='suspended'?'Blocked for this business':(explicit?'Enabled for this business':(inherited?'Included by subscription plan':'Not included'));
      return `<label class="module-toggle"><span><strong>${escapeHtml(m.name)}</strong><small>${escapeHtml(m.description||'')} · ${source}</small></span><input type="checkbox" data-module-id="${m.id}" ${checked?'checked':''}></label>`;
    }).join('')||'<p>No modules have been configured yet.</p>';
    q('moduleModal').classList.add('open');
  }

  async function saveBusinessModules(){
    const bid=q('moduleModal').dataset.businessId;if(!bid)return;const boxes=[...q('moduleChecklist').querySelectorAll('[data-module-id]')];
    for(const box of boxes){
      const status=box.checked?'active':'suspended';
      const {error}=await state.client.from('business_modules').upsert({business_id:bid,module_id:box.dataset.moduleId,status},{onConflict:'business_id,module_id'});
      if(error){alert('Could not update module access: '+error.message);return}
    }
    q('moduleModal').classList.remove('open');await renderAdmin();
  }

  function paymentProviderDefinitions(){
    const webhook=(C.supabaseUrl||'').replace(/\/$/,'')+'/functions/v1/stripe-webhook';
    return [
      {
        provider:'stripe',name:'Stripe',supported:true,
        description:'Cards and subscription billing. This gateway is fully wired into the current signup and billing flow.',
        publicFields:[{key:'publishable_key',label:'Publishable key',placeholder:'pk_test_... or pk_live_...'}],
        secretFields:[{key:'secret_key',label:'Secret key',placeholder:'sk_test_... or sk_live_...'},{key:'webhook_secret',label:'Webhook signing secret',placeholder:'whsec_...'}],
        webhook
      },
      {
        provider:'paypal',name:'PayPal',supported:false,
        description:'Credentials can be stored now so the platform is ready for a PayPal checkout adapter later.',
        publicFields:[{key:'client_id',label:'Client ID',placeholder:'PayPal client ID'}],
        secretFields:[{key:'client_secret',label:'Client secret',placeholder:'PayPal client secret'},{key:'webhook_id',label:'Webhook ID',placeholder:'Optional webhook ID'}]
      },
      {
        provider:'mollie',name:'Mollie',supported:false,
        description:'Credentials can be stored now. Mollie requires its own checkout and recurring-payment integration before it can process subscriptions.',
        publicFields:[],
        secretFields:[{key:'api_key',label:'API key',placeholder:'test_... or live_...'}]
      },
      {
        provider:'other',name:'Other / future gateway',supported:false,
        description:'Reserve configuration for another gateway. Saving credentials does not automatically create an API integration.',
        publicFields:[{key:'provider_name',label:'Provider name',placeholder:'e.g. Windcave'}],
        secretFields:[{key:'api_key',label:'API key / token',placeholder:'Secret API credential'}]
      }
    ];
  }

  async function renderPaymentSettings(){
    if(!state.profile?.is_super_admin||!q('adminPaymentGrid'))return;
    const root=q('adminPaymentGrid');
    root.innerHTML='<p class="hint">Loading payment settings…</p>';
    if(q('adminPaymentMessage'))q('adminPaymentMessage').textContent='';
    const {data,error}=await state.client.rpc('v34_admin_get_payment_providers');
    if(error){root.innerHTML='<p class="hint">Payment settings are unavailable until V34-PAYMENT-GATEWAYS.sql is run.</p>';if(q('adminPaymentMessage'))q('adminPaymentMessage').textContent=error.message;return}
    const saved=new Map((data||[]).map(x=>[x.provider,x]));
    root.innerHTML=paymentProviderDefinitions().map(def=>{
      const row=saved.get(def.provider)||{};
      const cfg=row.public_config||{};
      const configured=row.has_secret===true;
      const enabled=row.enabled===true;
      const status=configured?(enabled?'Enabled':'Configured'):'Not configured';
      const statusClass=enabled?'enabled':(configured?'ready':'');
      const publicFields=def.publicFields.map(f=>`<label class="wide">${escapeHtml(f.label)}<input data-pay-public="${f.key}" value="${escapeHtml(cfg[f.key]||'')}" placeholder="${escapeHtml(f.placeholder||'')}"></label>`).join('');
      const secretFields=def.secretFields.map(f=>`<label class="wide">${escapeHtml(f.label)}<input type="password" data-pay-secret="${f.key}" value="" placeholder="${configured?'Saved securely — enter only to replace/add':escapeHtml(f.placeholder||'')}"></label>`).join('');
      const webhook=def.webhook?`<label class="wide">Stripe webhook URL<div class="gateway-webhook">${escapeHtml(def.webhook)}</div></label>`:'';
      return `<div class="payment-gateway-card" data-payment-card="${def.provider}"><div class="gateway-head"><div><h3>${escapeHtml(def.name)}</h3><p>${escapeHtml(def.description)}</p></div><span class="gateway-status ${statusClass}">${status}</span></div><div class="gateway-fields"><label>Mode<select data-pay-mode><option value="test" ${row.mode!=='live'?'selected':''}>Test / Sandbox</option><option value="live" ${row.mode==='live'?'selected':''}>Live</option></select></label><label>Gateway status<select data-pay-enabled><option value="false" ${!enabled?'selected':''}>Disabled</option><option value="true" ${enabled?'selected':''} ${!def.supported?'disabled':''}>Enabled for checkout</option></select></label>${publicFields}${secretFields}${webhook}</div>${configured?'<div class="gateway-secret-state">✓ Secret credentials are stored securely in Supabase Vault.</div>':''}<p class="gateway-note ${def.supported?'':'warning'}">${def.supported?'Once enabled, the current subscription checkout can use this provider.':'Configuration storage is ready, but this provider is not yet an active checkout adapter.'}</p><div class="gateway-actions"><button class="primary" type="button" data-payment-save="${def.provider}">Save ${escapeHtml(def.name)}</button>${def.supported?`<button class="secondary" type="button" data-payment-test="${def.provider}">Test connection</button>`:''}</div></div>`;
    }).join('');
    root.querySelectorAll('[data-payment-save]').forEach(btn=>btn.onclick=()=>savePaymentProvider(btn.dataset.paymentSave));
    root.querySelectorAll('[data-payment-test]').forEach(btn=>btn.onclick=()=>testPaymentProvider(btn.dataset.paymentTest,btn));
  }

  async function savePaymentProvider(provider){
    const card=q('adminPaymentGrid')?.querySelector(`[data-payment-card="${provider}"]`);if(!card)return;
    const def=paymentProviderDefinitions().find(x=>x.provider===provider);if(!def)return;
    const publicConfig={};card.querySelectorAll('[data-pay-public]').forEach(i=>{if(i.value.trim())publicConfig[i.dataset.payPublic]=i.value.trim()});
    const secretPatch={};card.querySelectorAll('[data-pay-secret]').forEach(i=>{if(i.value.trim())secretPatch[i.dataset.paySecret]=i.value.trim()});
    const enabled=card.querySelector('[data-pay-enabled]')?.value==='true';
    if(enabled&&!def.supported){alert(`${def.name} is not an active checkout adapter yet. Its credentials can be saved, but it cannot be enabled for payments in this version.`);return}
    const btn=card.querySelector(`[data-payment-save="${provider}"]`),original=btn?.textContent||'Save';if(btn){btn.disabled=true;btn.textContent='Saving…'}
    const {error}=await state.client.rpc('v34_admin_save_payment_provider',{p_provider:provider,p_enabled:enabled,p_mode:card.querySelector('[data-pay-mode]')?.value||'test',p_display_name:def.name,p_public_config:publicConfig,p_secret_patch:Object.keys(secretPatch).length?secretPatch:null});
    if(btn){btn.disabled=false;btn.textContent=original}
    if(error){alert('Could not save payment settings: '+error.message);return}
    if(q('adminPaymentMessage')){q('adminPaymentMessage').textContent=`${def.name} settings saved.`;setTimeout(()=>{if(q('adminPaymentMessage'))q('adminPaymentMessage').textContent=''},2500)}
    await renderPaymentSettings();
  }

  async function testPaymentProvider(provider,btn){
    if(provider!=='stripe')return;
    const original=btn?.textContent||'Test connection';if(btn){btn.disabled=true;btn.textContent='Testing…'}
    const {data,error}=await state.client.functions.invoke('test-payment-provider',{body:{provider}});
    if(btn){btn.disabled=false;btn.textContent=original}
    if(error||data?.error){alert('Connection test failed: '+(data?.error||error?.message||'Unknown error'));return}
    alert(`Stripe connection successful${data?.account_name?' — '+data.account_name:''}.`);
  }

  async function renderAdmin(){
    if(!state.profile?.is_super_admin)return;
    const {data:businesses,error}=await state.client.from('businesses').select('id,name,status,created_at,profiles(id,full_name,email,role),subscriptions(id,status,trial_ends_at,current_period_start,current_period_end,invoice_limit_override,plans(id,name,slug,invoice_limit,included_modules)),business_modules(status,modules(slug,name))').order('created_at',{ascending:false});
    if(error){console.warn(error);alert('Could not load Super Admin businesses: '+error.message);return}
    const asArray=x=>Array.isArray(x)?x:(x?[x]:[]);
    const getSub=b=>asArray(b.subscriptions)[0]||{};
    const getProfiles=b=>asArray(b.profiles);
    const qtxt=(q('adminSearch')?.value||'').toLowerCase(),sf=q('adminStatusFilter')?.value||'';
    let rows=(businesses||[]).filter(b=>{const profiles=getProfiles(b),owner=profiles.find(p=>p.role==='owner')||profiles[0]||{},sub=getSub(b);return(!qtxt||[b.name,owner.full_name,owner.email].join(' ').toLowerCase().includes(qtxt))&&(!sf||sub.status===sf)});
    q('adminBusinessCount').textContent=(businesses||[]).length;
    q('adminUserCount').textContent=(businesses||[]).reduce((n,b)=>n+getProfiles(b).length,0);
    q('adminActiveCount').textContent=(businesses||[]).filter(b=>getSub(b).status==='active').length;
    q('adminTrialCount').textContent=(businesses||[]).filter(b=>getSub(b).status==='trialing').length;
    const {data:plans,error:planError}=await state.client.from('plans').select('id,name,slug,invoice_limit').order('sort_order');
    if(planError){alert('Could not load subscription plans: '+planError.message);return}
    const body=q('adminBusinessRows'); body.innerHTML='';
    const ownerEmailCounts=new Map();
    for(const b of (businesses||[])){
      const ps=getProfiles(b),o=ps.find(p=>p.role==='owner')||ps[0]||{},key=(o.email||'').trim().toLowerCase();
      if(key)ownerEmailCounts.set(key,(ownerEmailCounts.get(key)||0)+1);
    }
    for(const b of rows){
      const profiles=getProfiles(b),owner=profiles.find(p=>p.role==='owner')||profiles[0]||{},sub=getSub(b),plan=sub.plans||{};
      const overrideBySlug=new Map(asArray(b.business_modules).map(x=>[x.modules?.slug,x.status]));
      const moduleNames=new Map(asArray(b.business_modules).map(x=>[x.modules?.slug,x.modules?.name]));
      const effectiveSlugs=new Set(plan.included_modules||[]);
      for(const [slug,status] of overrideBySlug){if(!slug)continue;if(['active','trialing'].includes(status))effectiveSlugs.add(slug);else if(['suspended','canceled'].includes(status))effectiveSlugs.delete(slug)}
      const mods=[...effectiveSlugs].map(slug=>moduleNames.get(slug)||human(slug));
      let countQ=state.client.from('invoices').select('id',{count:'exact',head:true}).eq('business_id',b.id);if(sub.current_period_start)countQ=countQ.gte('created_at',sub.current_period_start);if(sub.current_period_end)countQ=countQ.lt('created_at',sub.current_period_end);const {count}=await countQ;
      const tr=document.createElement('tr');
      const ownerKey=(owner.email||'').trim().toLowerCase();
      const duplicateBadge=ownerKey&&ownerEmailCounts.get(ownerKey)>1?'<span class="duplicate-account-badge" title="More than one business record is linked to this owner email">Duplicate record</span>':'';
      tr.innerHTML=`<td><strong>${escapeHtml(b.name)}</strong>${duplicateBadge}<small>${new Date(b.created_at).toLocaleDateString()}</small></td><td>${escapeHtml(owner.full_name||'')}<small>${escapeHtml(owner.email||'')}</small></td><td><select data-admin-plan="${b.id}">${(plans||[]).map(p=>`<option value="${p.id}" ${p.id===plan.id?'selected':''}>${escapeHtml(p.name)}</option>`).join('')}</select></td><td><select data-admin-status="${b.id}">${['trialing','active','past_due','suspended','canceled'].map(x=>`<option ${x===sub.status?'selected':''}>${x}</option>`).join('')}</select></td><td>${count||0} / ${sub.invoice_limit_override??plan.invoice_limit??'∞'}</td><td>${sub.trial_ends_at?new Date(sub.trial_ends_at).toLocaleDateString():'—'}</td><td>${mods.join(', ')||'Invoice Manager'}</td><td><div class="row-actions"><button class="secondary" data-admin-save="${b.id}">Save</button><button class="secondary" data-admin-modules="${b.id}" data-business-name="${escapeHtml(b.name)}">Modules</button><button class="secondary" data-admin-trial="${b.id}">+14d trial</button><button class="danger" data-admin-suspend="${b.id}" data-suspended="${sub.status==='suspended'||b.status==='suspended'?'true':'false'}">${sub.status==='suspended'||b.status==='suspended'?'Activate':'Suspend'}</button><button class="secondary" data-admin-export="${b.id}" data-business-name="${escapeHtml(b.name)}">Export</button><button class="danger" data-admin-delete="${b.id}" data-business-name="${escapeHtml(b.name)}">Delete</button></div></td>`;
      body.appendChild(tr);
    }
    body.querySelectorAll('[data-admin-save]').forEach(btn=>btn.onclick=async()=>{
      const bid=btn.dataset.adminSave,planId=body.querySelector(`[data-admin-plan="${bid}"]`)?.value,status=body.querySelector(`[data-admin-status="${bid}"]`)?.value;
      if(!bid||!planId||!status)return alert('Business, plan or status is missing. Reload the admin page and try again.');
      btn.disabled=true;btn.textContent='Saving…';
      const {error}=await state.client.rpc('v33_admin_set_subscription',{p_business_id:bid,p_plan_id:planId,p_status:status});
      btn.disabled=false;
      if(error){btn.textContent='Save';alert('Could not update subscription: '+error.message);return}
      btn.textContent='Saved';setTimeout(()=>btn.textContent='Save',900);await renderAdmin();
    });
    body.querySelectorAll('[data-admin-modules]').forEach(btn=>btn.onclick=()=>openModuleManager(btn.dataset.adminModules,btn.dataset.businessName));
    body.querySelectorAll('[data-admin-trial]').forEach(btn=>btn.onclick=async()=>{
      btn.disabled=true;btn.textContent='Extending…';
      const {error}=await state.client.rpc('v33_admin_extend_trial',{p_business_id:btn.dataset.adminTrial,p_days:14});
      btn.disabled=false;
      if(error){btn.textContent='+14d trial';alert('Could not extend trial: '+error.message);return}
      await renderAdmin();
    });
    body.querySelectorAll('[data-admin-suspend]').forEach(btn=>btn.onclick=async()=>{
      const bid=btn.dataset.adminSuspend;
      const suspend=btn.dataset.suspended!=='true';
      btn.disabled=true;btn.textContent=suspend?'Suspending…':'Activating…';
      const {error}=await state.client.rpc('v33_admin_set_suspension',{p_business_id:bid,p_suspend:suspend});
      btn.disabled=false;
      if(error){btn.textContent=suspend?'Suspend':'Activate';alert('Could not change account status: '+error.message);return}
      await renderAdmin();
    });
    body.querySelectorAll('[data-admin-export]').forEach(btn=>btn.onclick=()=>exportBusinessData(btn.dataset.adminExport,btn.dataset.businessName,btn));
    body.querySelectorAll('[data-admin-delete]').forEach(btn=>btn.onclick=async()=>{
      const bid=btn.dataset.adminDelete;
      const businessName=btn.dataset.businessName||'';
      if(!bid||!businessName)return alert('Business information is missing. Reload the admin page and try again.');
      const warning=`Permanently delete ${businessName}?

This will permanently remove the business account, its users, invoices, customers, recurring rules, job costings, quotes, subscriptions, module settings and all other database records linked to this business. This cannot be undone.`;
      if(!confirm(warning))return;
      const typed=prompt(`Type the business name exactly to confirm deletion:

${businessName}`,'');
      if(typed===null)return;
      if(typed.trim()!==businessName.trim())return alert('Business name did not match. Nothing was deleted.');
      btn.disabled=true;btn.textContent='Deleting…';
      // Expense documents live in Supabase Storage, not in Postgres, so database
      // ON DELETE CASCADE cannot remove the physical receipt/PDF objects. Remove
      // the tenant's known attachment paths first; abort account deletion if this
      // cleanup fails so "permanent delete" never knowingly leaves documents behind.
      try{
        const {data:attachments,error:attachmentError}=await state.client.from('expense_attachments').select('stored_path').eq('business_id',bid);
        if(attachmentError)throw attachmentError;
        const paths=[...new Set((attachments||[]).map(x=>String(x.stored_path||'').trim()).filter(Boolean))];
        for(let i=0;i<paths.length;i+=100){
          const {error:storageError}=await state.client.storage.from('expense-documents').remove(paths.slice(i,i+100));
          if(storageError)throw storageError;
        }
      }catch(storageCleanupError){
        btn.disabled=false;btn.textContent='Delete';
        alert('Could not delete the business because its expense documents could not be removed safely. No database account deletion was performed. '+(storageCleanupError?.message||storageCleanupError));
        return;
      }
      const {data,error}=await state.client.rpc('v36_admin_delete_business',{p_business_id:bid,p_confirmation_name:typed.trim()});
      btn.disabled=false;
      if(error){btn.textContent='Delete';alert('Could not delete account: '+error.message);return}
      alert(`${businessName}, its linked database information and its expense documents have been permanently deleted.`);
      await renderAdmin();
    });
    renderAdminPlans();
    renderPaymentSettings();
    renderAdminModules();
  }

  function planEditorCard(p,isNew=false){
    const id=isNew?'new':p.id;
    return `<div class="plan-card ${isNew?'new-plan-card':''}" data-plan-card="${id}"><span class="plan-name">${isNew?'Create new plan':escapeHtml(p.name)}</span><label>Name<input data-plan-name="${id}" value="${escapeHtml(p.name||'')}" placeholder="Business"></label><label>Slug<input data-plan-slug="${id}" value="${escapeHtml(p.slug||'')}" placeholder="business"></label><label>Description<input data-plan-description="${id}" value="${escapeHtml(p.description||'')}" placeholder="Plan description"></label><label>Monthly price<input type="number" min="0" step="0.01" data-plan-price="${id}" value="${Number(p.monthly_price||0)}"></label><label>Invoice limit<input type="number" min="0" data-plan-limit="${id}" value="${p.invoice_limit??''}" placeholder="Blank = unlimited"></label><label>Stripe Price ID<input data-plan-stripe="${id}" value="${escapeHtml(p.stripe_price_id||'')}" placeholder="price_..."></label><label>Included modules<input data-plan-modules="${id}" value="${escapeHtml((p.included_modules||['invoice_manager']).join(', '))}" placeholder="invoice_manager, job_costing"></label><label>Sort order<input type="number" step="1" data-plan-sort="${id}" value="${Number(p.sort_order||0)}"></label><label class="tick-option"><input type="checkbox" data-plan-public="${id}" ${p.is_public?'checked':''}> <span>Visible to customers</span></label><button class="${isNew?'primary':'secondary'}" data-plan-save="${id}">${isNew?'+ Create plan':'Save plan'}</button></div>`;
  }

  async function savePlanFromCard(id){
    const root=q('adminPlanGrid'),card=root?.querySelector(`[data-plan-card="${id}"]`);if(!card)return;
    const name=card.querySelector(`[data-plan-name="${id}"]`).value.trim();
    const slug=card.querySelector(`[data-plan-slug="${id}"]`).value.trim().toLowerCase().replace(/[^a-z0-9_]+/g,'_').replace(/^_+|_+$/g,'');
    const description=card.querySelector(`[data-plan-description="${id}"]`).value.trim();
    const monthlyPrice=Number(card.querySelector(`[data-plan-price="${id}"]`).value||0);
    const lv=card.querySelector(`[data-plan-limit="${id}"]`).value;
    const stripe=card.querySelector(`[data-plan-stripe="${id}"]`).value.trim();
    const modules=card.querySelector(`[data-plan-modules="${id}"]`).value.split(',').map(x=>x.trim()).filter(Boolean);
    const sortOrder=Number(card.querySelector(`[data-plan-sort="${id}"]`).value||0);
    const isPublic=card.querySelector(`[data-plan-public="${id}"]`).checked;
    if(!name||!slug)return alert('Plan name and slug are required.');
    if(slug!=='trial'&&monthlyPrice>0&&isPublic&&!stripe){
      if(!confirm('This paid plan has no Stripe Price ID. Customers can see it but payment checkout will not work until you add one. Save anyway?'))return;
    }
    const btn=card.querySelector(`[data-plan-save="${id}"]`);btn.disabled=true;btn.textContent=id==='new'?'Creating…':'Saving…';
    const {error}=await state.client.rpc('v33_admin_upsert_plan',{p_id:id==='new'?null:id,p_slug:slug,p_name:name,p_description:description||null,p_monthly_price:monthlyPrice,p_invoice_limit:lv===''?null:Number(lv),p_included_modules:modules.length?modules:['invoice_manager'],p_stripe_price_id:stripe||null,p_is_public:isPublic,p_sort_order:sortOrder});
    btn.disabled=false;
    if(error){btn.textContent=id==='new'?'+ Create plan':'Save plan';alert('Could not save plan: '+error.message);return}
    if(q('adminPlanMessage')){q('adminPlanMessage').textContent=id==='new'?`${name} created.`:`${name} updated.`;q('adminPlanMessage').className='admin-inline-message success'}
    await renderAdminPlans(); await loadSignupPlans();
  }

  async function renderAdminPlans(){
    if(!state.profile?.is_super_admin||!q('adminPlanGrid'))return;
    const {data:plans,error}=await state.client.from('plans').select('*').order('sort_order');
    if(error){if(q('adminPlanMessage')){q('adminPlanMessage').textContent='Could not load plans: '+error.message;q('adminPlanMessage').className='admin-inline-message error'}return}
    q('adminPlanGrid').innerHTML=planEditorCard({name:'',slug:'',description:'',monthly_price:0,invoice_limit:null,included_modules:['invoice_manager'],stripe_price_id:null,is_public:true,sort_order:40},true)+(plans||[]).map(p=>planEditorCard(p,false)).join('');
    q('adminPlanGrid').querySelectorAll('[data-plan-save]').forEach(btn=>btn.onclick=()=>savePlanFromCard(btn.dataset.planSave));
  }

  async function renderAdminModules(){
    if(!state.profile?.is_super_admin||!q('adminModuleGrid'))return;
    const {data:mods}=await state.client.from('modules').select('*').order('name');
    q('adminModuleGrid').innerHTML=(mods||[]).map(m=>`<div class="plan-card"><span class="plan-name">${escapeHtml(m.name)}</span><label>Name<input data-module-name="${m.id}" value="${escapeHtml(m.name)}"></label><label>Slug<input data-module-slug="${m.id}" value="${escapeHtml(m.slug)}"></label><label>Monthly price<input type="number" step="0.01" data-module-price="${m.id}" value="${Number(m.monthly_price||0)}"></label><label>Stripe Price ID<input data-module-stripe="${m.id}" value="${escapeHtml(m.stripe_price_id||'')}" placeholder="price_..."></label><label>Description<input data-module-description="${m.id}" value="${escapeHtml(m.description||'')}"></label><label class="tick-option"><input type="checkbox" data-module-active="${m.id}" ${m.is_active?'checked':''}> Active</label><button class="secondary" data-module-save="${m.id}">Save module</button></div>`).join('');
    q('adminModuleGrid').querySelectorAll('[data-module-save]').forEach(btn=>btn.onclick=async()=>{const id=btn.dataset.moduleSave,root=q('adminModuleGrid');await state.client.from('modules').update({name:root.querySelector(`[data-module-name="${id}"]`).value.trim(),slug:root.querySelector(`[data-module-slug="${id}"]`).value.trim().toLowerCase().replace(/[^a-z0-9_]+/g,'_'),monthly_price:Number(root.querySelector(`[data-module-price="${id}"]`).value||0),stripe_price_id:root.querySelector(`[data-module-stripe="${id}"]`).value.trim()||null,description:root.querySelector(`[data-module-description="${id}"]`).value.trim(),is_active:root.querySelector(`[data-module-active="${id}"]`).checked}).eq('id',id);btn.textContent='Saved';setTimeout(()=>btn.textContent='Save module',900)});
  }

  async function addAdminModule(){
    const name=q('adminModuleName').value.trim(),slug=q('adminModuleSlug').value.trim().toLowerCase().replace(/[^a-z0-9_]+/g,'_'),description=q('adminModuleDescription').value.trim(),monthly_price=Number(q('adminModulePrice').value||0),stripe_price_id=q('adminModuleStripe').value.trim()||null;if(!name||!slug)return alert('Enter a module name and slug.');
    const {error}=await state.client.from('modules').insert({name,slug,description,monthly_price,stripe_price_id,is_active:true});if(error)return alert(error.message);['adminModuleName','adminModuleSlug','adminModuleDescription','adminModuleStripe'].forEach(id=>q(id).value='');q('adminModulePrice').value='0';renderAdminModules();
  }

  async function hasModule(slug){
    if(slug==='invoice_manager')return true;
    const {data}=await state.client.from('business_modules').select('status,modules!inner(slug)').eq('business_id',state.business.id).eq('modules.slug',slug).maybeSingle();
    if(data){
      if(['active','trialing'].includes(data.status))return true;
      if(['suspended','canceled'].includes(data.status))return false;
    }
    const sub=state.subscription||await getSubscription();
    return Array.isArray(sub?.plans?.included_modules)&&sub.plans.included_modules.includes(slug);
  }

  function ensureAccountLock(){
    let el=q('accountAccessBlock');
    if(el)return el;
    el=document.createElement('div');el.id='accountAccessBlock';el.hidden=true;
    el.innerHTML=`<div class="account-lock-card"><div class="account-lock-icon">🔒</div><h2>Account unavailable</h2><p id="accountAccessMessage">This business account is currently unavailable.</p><button class="primary" id="accountAccessSignOut" type="button">Sign out</button></div>`;
    document.body.appendChild(el);
    q('accountAccessSignOut').onclick=()=>state.client.auth.signOut();
    return el;
  }

  async function refreshEntitlements(){
    if(!state.client||!state.business||state.profile?.is_super_admin===true)return;
    const [{data:sub},{data:biz}]=await Promise.all([
      state.client.from('subscriptions').select('*,plans(*)').eq('business_id',state.business.id).maybeSingle(),
      state.client.from('businesses').select('id,status').eq('id',state.business.id).maybeSingle()
    ]);
    if(sub){state.subscription=sub;state.plan=sub.plans||null}
    if(biz?.status)state.business.status=biz.status;
    const locked=biz?.status==='suspended'||biz?.status==='closed'||['suspended','canceled'].includes(sub?.status);
    const lock=ensureAccountLock();
    if(locked){
      const reason=(biz?.status==='suspended'||sub?.status==='suspended')?'This business account has been suspended by the platform administrator.':'This business account is not active.';
      q('accountAccessMessage').textContent=reason+' Please contact the platform owner if you believe this is an error.';
      lock.hidden=false;document.body.classList.add('account-suspended');
    }else{lock.hidden=true;document.body.classList.remove('account-suspended')}
    if(q('jobCostingNav')){
      const allowed=await hasModule('job_costing');
      q('jobCostingNav').hidden=!allowed;
      if(!allowed && document.getElementById('view-jobcosting')?.classList.contains('active') && window.switchView)window.switchView('create');
      if(allowed)window.JobCosting?.init?.();
    }
    if(q('expensesNav')){
      const allowed=await hasModule('expenses');
      q('expensesNav').hidden=!allowed;
      if(!allowed && document.getElementById('view-expenses')?.classList.contains('active') && window.switchView)window.switchView('create');
      if(allowed)window.Expenses?.init?.();
    }
  }

  async function bindAfterAppLoad(){
    if(q('adminNav')) q('adminNav').onclick=openAdminPortal;
    if(q('adminBackToApp'))q('adminBackToApp').onclick=closeAdminPortal;
    if(q('saveSettings')) q('saveSettings').addEventListener('click',()=>setTimeout(()=>saveBusinessSettings(appSettings()),100));
    if(q('jobCostingNav')){const allowed=state.profile?.is_super_admin||await hasModule('job_costing');q('jobCostingNav').hidden=!allowed;if(allowed)window.JobCosting?.init?.()}
    if(q('expensesNav')){const allowed=state.profile?.is_super_admin||await hasModule('expenses');q('expensesNav').hidden=!allowed;if(allowed)window.Expenses?.init?.()}
    await refreshEntitlements();
    let entitlementTimer=0;
    const recheck=()=>{const now=Date.now();if(now-entitlementTimer<2500)return;entitlementTimer=now;refreshEntitlements().catch(console.warn)};
    window.addEventListener('focus',recheck);
    document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')recheck()});
    // Keep infrastructure config automatic and hidden from customers.
    if(q('sSupabaseUrl'))q('sSupabaseUrl').value=C.supabaseUrl;if(q('sSupabaseKey'))q('sSupabaseKey').value=C.supabaseKey;
  }

  function human(s){return String(s||'').replace(/_/g,' ').replace(/\b\w/g,c=>c.toUpperCase())}
  function escapeHtml(s){return String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]))}

  window.SAAS={state,client:()=>state.client,canCreateInvoice,refreshUsage,saveBusinessSettings,renderAdmin,showPlans,hasModule};
  init().catch(err=>{console.error(err);q('authShell')?.classList.add('open');message(err.message||'Unable to start application.','error')});
})();
