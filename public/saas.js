(() => {
  const C = window.APP_CONFIG || {};
  const q = id => document.getElementById(id);
  const PENDING_SIGNUP_CHECKOUT_KEY='v61_pending_signup_checkout';
  const state = { client:null, session:null, user:null, profile:null, business:null, subscription:null, plan:null, loadedApp:false, checkoutAvailable:null, inviteToken:new URLSearchParams(location.search).get('invite')||'', inviteInfo:null, businessMemberships:[], effectiveAccess:{}, referralCode:new URLSearchParams(location.search).get('ref')||'', referralInviteToken:new URLSearchParams(location.search).get('rid')||'' };
  let adminPlanRenderSequence=0;

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
    await prepareInviteMode();
    if(state.referralCode&&!state.inviteToken){switchAuthTab('signup');message('You were referred to Frindly. Create your business account to continue.');}
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
      const selectedPlan=state.inviteToken?'invite':(q('signupPlan')?.value||'trial');
      const selectedBillingInterval=q('signupBillingAnnual')?.classList.contains('active')?'annual':'monthly';
      const submit=q('signupSubmitBtn');
      if(!selectedPlan){message('Choose a subscription plan first.','error');return}
      if(submit){submit.disabled=true;submit.textContent=selectedPlan==='trial'?'Creating account…':'Creating account…'}
      message(state.inviteToken?'Creating your invited Frindly account…':(selectedPlan==='trial'?'Creating your trial account…':'Creating your account…'));
      const email=q('signupEmail').value.trim();
      const signupData=state.inviteToken
        ? {full_name:q('signupName').value.trim(),business_invite_token:state.inviteToken}
        : {full_name:q('signupName').value.trim(),business_name:q('signupBusiness').value.trim(),business_address:q('signupAddress')?.value?.trim()||'',phone:q('signupPhone')?.value?.trim()||'',selected_plan_slug:selectedPlan,selected_billing_interval:selectedBillingInterval,referral_code:state.referralCode||undefined,referral_invite_token:state.referralInviteToken||undefined};
      const signUpOptions={data:signupData};
      const redirect=publicAppUrl();if(redirect)signUpOptions.emailRedirectTo=redirect;
      const {data,error}=await state.client.auth.signUp({email,password:q('signupPassword').value,options:signUpOptions});
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
        if(selectedPlan!=='trial'&&!state.inviteToken)setPendingSignupCheckout({userId:data.user?.id||'',email,planSlug:selectedPlan,billingInterval:selectedBillingInterval});
        message(state.inviteToken?'Account created. Joining the invited business…':(selectedPlan==='trial'?'Account created. Loading your business…':'Account created. Opening secure payment…'),'success');
        await enter(data.session);
      } else {
        if(selectedPlan!=='trial'&&!state.inviteToken)setPendingSignupCheckout({email,planSlug:selectedPlan,billingInterval:selectedBillingInterval});
        message(state.inviteToken?'Account created for the invited business. Check your email to confirm your address, then log in.':(selectedPlan==='trial'?'Account created. Check your email to confirm your address, then log in.':'Account created. Confirm your email, then log in to continue to secure Stripe payment.'),'success');
      }
    };
    q('forgotPasswordBtn').onclick=async()=>{
      const email=q('loginEmail').value.trim(); if(!email)return message('Enter your email address first.','error');
      const {error}=await state.client.auth.resetPasswordForEmail(email,{redirectTo:location.origin});
      message(error?error.message:'Password reset email sent.',error?'error':'success');
    };
  }

  function annualPricing(p){
    const monthly=Number(p?.monthly_price||0), annual=p?.annual_price==null?null:Number(p.annual_price);
    const normal=monthly*12;
    const saving=annual==null?null:normal-annual;
    const pct=normal>0&&saving>0?(saving/normal)*100:0;
    return {monthly,annual,normal,saving,pct,equivalent:annual==null?null:annual/12,message:(p?.annual_saving_message||'').trim()||(pct>0?`Save ${Math.round(pct)}%`:'')};
  }
  function signupBillingInterval(){return q('signupBillingAnnual')?.classList.contains('active')?'annual':'monthly'}
  function bindBillingToggle(monthlyId,annualId,onchange){
    const m=q(monthlyId),a=q(annualId);if(!m||!a)return;
    m.onclick=()=>{m.classList.add('active');a.classList.remove('active');onchange?.('monthly')};
    a.onclick=()=>{a.classList.add('active');m.classList.remove('active');onchange?.('annual')};
  }

  async function loadSignupPlans(){
    const select=q('signupPlan'); if(!select||!state.client)return;
    const [{data:plans,error},checkoutReady]=await Promise.all([
      state.client.from('plans').select('id,slug,name,description,monthly_price,annual_price,annual_saving_message,invoice_limit,is_public,sort_order,stripe_price_id,stripe_annual_price_id').order('sort_order'),
      getCheckoutAvailability(true)
    ]);
    if(error){select.innerHTML='<option value="trial">Trial</option>'; if(q('signupPlanSummary'))q('signupPlanSummary').textContent='Plan list could not be loaded. Trial is available.'; return}
    const available=(plans||[]).filter(p=>p.slug==='trial'||p.is_public);
    const render=()=>{
      const interval=signupBillingInterval();
      select.innerHTML=available.map(p=>{
        const paid=p.slug!=='trial', ap=annualPricing(p);
        const configured=interval==='annual'?ap.annual!=null&&!!p.stripe_annual_price_id:!!p.stripe_price_id;
        const purchasable=!paid||(checkoutReady&&configured);
        const suffix=p.slug==='trial'?'Free trial':interval==='annual'?(ap.annual==null?'Annual unavailable':`$${ap.annual.toFixed(2)}/year${ap.message?' · '+ap.message:''}`):`$${ap.monthly.toFixed(2)}/month`;
        return `<option value="${escapeHtml(p.slug)}" ${purchasable?'':'disabled'}>${escapeHtml(p.name)} — ${suffix}${purchasable?'':' — unavailable'}</option>`;
      }).join('');
      if(!available.some(p=>p.slug===select.value&&!select.selectedOptions[0]?.disabled)) select.value=available.some(p=>p.slug==='trial')?'trial':'';
      update();
    };
    const update=()=>{
      const plan=available.find(p=>p.slug===select.value); if(!q('signupPlanSummary')||!plan)return;
      const limit=plan.invoice_limit==null?'Unlimited invoices':`${plan.invoice_limit} invoices per period`, interval=signupBillingInterval(), ap=annualPricing(plan);
      let pay='No payment required.';
      if(plan.slug!=='trial'){
        const configured=interval==='annual'?ap.annual!=null&&!!plan.stripe_annual_price_id:!!plan.stripe_price_id;
        pay=checkoutReady&&configured?(interval==='annual'?`$${ap.equivalent.toFixed(2)}/month equivalent · Billed $${ap.annual.toFixed(2)} annually${ap.message?' · '+ap.message:''}`:'Secure monthly online payment follows account creation.'):`${interval==='annual'?'Annual':'Monthly'} online subscription is not configured for this plan.`;
      }
      q('signupPlanSummary').textContent=`${plan.description||''}${plan.description?' · ':''}${limit} · ${pay}`;
    };
    select.onchange=update; bindBillingToggle('signupBillingMonthly','signupBillingAnnual',render); render();
  }

  async function enter(session){
    state.session=session; state.user=session.user;
    if(state.inviteToken){const accepted=await acceptInvitationIfPresent();if(!accepted){q('authShell').classList.add('open');return}}
    const ok=await loadAccount(); if(!ok){q('authShell').classList.add('open');return}
    await loadBusinessSettings();
    await migrateLegacyLocalData();
    q('authShell').classList.remove('open'); document.body.classList.remove('auth-locked');
    setupAccountUI();
    await window.Referrals?.init?.();
    if(await maybeContinueSignupCheckout())return;
    // A customer must never be able to retain or enter the owner route manually.
    if(/^#super-admin(?:\/|$)/.test(location.hash) && state.profile?.is_super_admin!==true){
      history.replaceState(null,'',location.pathname+location.search);
    }
    if(!state.loadedApp){
      state.loadedApp=true;
      await window.FinloCore.loader.loadScriptsSequentially(['app.js?v=61.79-phase-b','schedule.js?v=61.79h-quote-recurrence','dashboard.js?v=61.79i-unscheduled-quote-filter','job-costing.js?v=61.72A.1-gst','job-profitability.js?v=61.71','expenses.js?v=61.77-aged-payables','payroll-nz-holidays.js?v=61.73-P3.1','payroll-nz-statutory-leave.js?v=61.73-P4B.1','payroll-nz-public-holidays.js?v=61.73-P5B.1','payroll-nz-final-pay.js?v=61.73-P6C.2','payroll-nz-tax.js?v=61.73-P7','payroll.js?v=61.75A-employee-limit-upgrade-prompt','financials.js?v=61.78-simplified-financials-reports','accountant-centre.js?v=61.71','bank-reconciliation.js?v=61.72A.1-gst']);await bindAfterAppLoad();refreshUsage();const mw=Number(localStorage.getItem('v22_migration_warning')||0);if(mw)console.warn(`${mw} legacy browser record(s) remain safely stored locally; cloud migration can be reviewed from account support if needed.`);
    }
  }

  async function loadAccount(){
    for(let attempt=0;attempt<8;attempt++){
      const {data,error}=await state.client.from('profiles').select('id,business_id,active_business_id,full_name,email,role,is_super_admin').eq('id',state.user.id).maybeSingle();
      if(!error&&data){
        let {data:currentId,error:ctxError}=await state.client.rpc('current_business_id');
        // If the selected membership was suspended/removed, recover to another active membership server-side,
        // then resolve again. Never keep rendering the stale business from the profile/cache.
        if(!ctxError&&!currentId){
          const recovered=await inviteApi({action:'recover-current'});
          if(!recovered?.error&&recovered?.businessId){const again=await state.client.rpc('current_business_id');currentId=again.data;ctxError=again.error}
        }
        if(!ctxError&&currentId){
          const {data:business,error:bError}=await state.client.from('businesses').select('id,name,address,phone,status,settings').eq('id',currentId).maybeSingle();
          if(!bError&&business){
            const [{data:accessRole},{data:effectiveAccess}]=await Promise.all([
              state.client.rpc('v6147_current_business_role',{p_business_id:currentId}),
              state.client.rpc('v6148_my_effective_access',{p_business_id:currentId})
            ]);
            state.profile=data;state.business=business;state.accessRole=accessRole||(data.is_super_admin?'owner':data.role||'viewer');
            state.effectiveAccess={};(Array.isArray(effectiveAccess)?effectiveAccess:[]).forEach(x=>{state.effectiveAccess[x.area]={read:!!x.can_read,write:!!x.can_write}});return true
          }
        }
      }
      await new Promise(r=>setTimeout(r,300));
    }
    message('Your account has no active business access. Ask the business Owner or Admin to restore your access.','error'); return false;
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
    // V61.69C: legacy operational browser data may only ever be claimed by a single-business account.
    // Once an identity has multiple active businesses, never infer which tenant owns unscoped legacy records.
    if(!(state.businessMemberships||[]).length){
      try{const memberships=await inviteApi({action:'my-businesses'});if(!memberships?.error)state.businessMemberships=memberships.businesses||[]}catch{}
    }
    if((state.businessMemberships||[]).length!==1)return;
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

  function setPendingSignupCheckout(value){try{localStorage.setItem(PENDING_SIGNUP_CHECKOUT_KEY,JSON.stringify({...value,createdAt:Date.now()}))}catch{}}
  function clearPendingSignupCheckout(){try{localStorage.removeItem(PENDING_SIGNUP_CHECKOUT_KEY)}catch{}}
  function readPendingSignupCheckout(){
    try{
      const value=JSON.parse(localStorage.getItem(PENDING_SIGNUP_CHECKOUT_KEY)||'null');
      if(!value||typeof value!=='object')return null;
      const age=Date.now()-Number(value.createdAt||0);
      if(!Number.isFinite(age)||age<0||age>24*60*60*1000){clearPendingSignupCheckout();return null}
      return value;
    }catch{return null}
  }
  async function maybeContinueSignupCheckout(){
    const billing=new URLSearchParams(location.search).get('billing');
    if(billing==='success'){clearPendingSignupCheckout();history.replaceState(null,'',location.pathname+location.hash);return false;}
    if(billing==='cancel'){clearPendingSignupCheckout();history.replaceState(null,'',location.pathname+location.hash);setTimeout(()=>showPlans().catch(console.warn),500);return false;}
    const pending=readPendingSignupCheckout();
    if(!pending)return false;
    const pendingUser=String(pending.userId||'').trim(),pendingEmail=String(pending.email||'').trim().toLowerCase();
    if((pendingUser&&pendingUser!==String(state.user?.id||''))||(pendingEmail&&pendingEmail!==String(state.user?.email||'').trim().toLowerCase())){clearPendingSignupCheckout();return false}
    const slug=String(pending.planSlug||'').trim(),interval=pending.billingInterval==='annual'?'annual':'monthly';
    if(!slug||slug==='trial'){clearPendingSignupCheckout();return false}
    const sub=await getSubscription();
    if(sub?.plans?.slug===slug && ['active','trialing'].includes(sub.status) && sub.stripe_subscription_id){clearPendingSignupCheckout();return false}
    if(sub?.plans?.slug===slug && sub.status==='active'){clearPendingSignupCheckout();return false}
    clearPendingSignupCheckout();
    const result=await startCheckout(slug,null,{silent:true,billingInterval:interval});
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
      if(/^#super-admin(?:\/|$)/.test(location.hash))history.replaceState(null,'',location.pathname+location.search);
      alert('Super Admin access is restricted to the platform owner.');
      return;
    }

    document.body.classList.add('admin-portal-active');
    if(q('adminPortalBar'))q('adminPortalBar').hidden=false;
    if(window.switchView)window.switchView('admin');
    else renderAdmin();
    setAdminView(adminViewFromHash(),false);
  }
  const ADMIN_VIEWS=new Set(['dashboard','businesses','plans','modules','payroll-rules','tax-rules','payments','invoice-payments','referrals','finlo-helper','import-migration']);
  function adminViewFromHash(){const m=String(location.hash||'').match(/^#super-admin(?:\/([a-z-]+))?$/);return m&&ADMIN_VIEWS.has(m[1])?m[1]:'dashboard'}
  function setAdminView(view='dashboard',push=true){
    if(!state.profile?.is_super_admin)return;
    const next=ADMIN_VIEWS.has(view)?view:'dashboard';
    document.querySelectorAll('[data-admin-panel]').forEach(el=>el.hidden=el.dataset.adminPanel!==next);
    document.querySelectorAll('[data-admin-view]').forEach(el=>{const active=el.dataset.adminView===next;el.classList.toggle('active',active);el.setAttribute('aria-current',active?'page':'false')});
    const hash=next==='dashboard'?'#super-admin':`#super-admin/${next}`;
    if(push&&location.hash!==hash)history.pushState(null,'',hash);else if(!push&&location.hash!==hash)history.replaceState(null,'',hash);if(next==='finlo-helper')window.FinloHelper?.renderAdmin?.();if(next==='import-migration')window.ImportMigration?.renderAdmin?.();if(next==='invoice-payments')renderAdminInvoicePayments?.();if(next==='tax-rules')window.StockEquipment?.renderTaxRules?.();
  }
  function setupAdminNavigation(){
    document.querySelectorAll('[data-admin-view],[data-admin-view-link]').forEach(el=>el.onclick=()=>setAdminView(el.dataset.adminView||el.dataset.adminViewLink));
    window.addEventListener('popstate',()=>{if(document.body.classList.contains('admin-portal-active'))setAdminView(adminViewFromHash(),false)});
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

  function setupCentralSettingsIA(){
    const move=(id,target)=>{const el=q(id),dest=q(target);if(el&&dest&&el.parentElement!==dest)dest.appendChild(el)};
    ['accountProfileName','accountBusinessName'].forEach(()=>{});
    move('accountModal','accountModalParking');
    const modal=q('accountModal'), account=q('centralAccountSettings'), users=q('centralUserSettings'), subscription=q('centralSubscriptionSettings'), job=q('centralJobSettings');
    if(modal&&account){['account-profile-card','account-email-card','account-preferences-card','account-export-card'].forEach(cls=>{const el=modal.querySelector('.'+cls);if(el)account.appendChild(el)})}
    if(modal&&users){const el=q('teamAccessCard');if(el)users.appendChild(el)}
    if(modal&&subscription){const el=q('subscriptionCard');if(el)subscription.appendChild(el)}
    if(job){const el=q('jc-panel-settings');if(el){el.classList.add('active');job.appendChild(el)}}
    document.querySelectorAll('[data-settings-nav]').forEach(btn=>btn.onclick=()=>window.openCentralSettings?.(btn.dataset.settingsNav));
  }
  window.openCentralSettings=async function(section='account'){
    const allowed=['account','tax','invoicing','payments','job','users','subscription','import'];if(!allowed.includes(section))section='account';
    if(section==='payments'&&!state.profile?.is_super_admin&&!(await hasModule('invoice_payments'))){section='account'}
    document.querySelectorAll('[data-settings-nav]').forEach(b=>b.classList.toggle('active',b.dataset.settingsNav===section));
    document.querySelectorAll('[data-settings-panel]').forEach(p=>p.hidden=p.dataset.settingsPanel!==section);
    if(section==='tax')window.Financials?.refresh?.();
    if(section==='job'){q('jc-panel-settings')?.classList.add('active');window.JobCosting?.onShow?.();}
    if(section==='users'&&['owner','admin'].includes(state.profile?.is_super_admin?'owner':(state.accessRole||'')))renderTeamAccess();
    if(section==='payments')renderInvoicePaymentSettings?.();
    if(section==='subscription')refreshSubscriptionBilling();
    if(section==='import')window.ImportMigration?.onShow?.();
    try{history.replaceState(null,'',`#settings/${section}`)}catch{}
  };

  function setupAccountUI(){
    setupCentralSettingsIA();
    const initials=(state.profile.full_name||state.business.name||'A').split(/\s+/).slice(0,2).map(x=>x[0]||'').join('').toUpperCase();
    if(q('accountInitials'))q('accountInitials').textContent=initials||'A';
    if(q('accountAvatarLarge'))q('accountAvatarLarge').textContent=initials||'A';
    if(q('accountDisplayName'))q('accountDisplayName').textContent=state.profile.full_name||state.business.name||'Account';
    if(q('activeBusinessIndicator'))q('activeBusinessIndicator').textContent=state.business?.name||'Business';
    if(q('accountPopoverEmail'))q('accountPopoverEmail').textContent=state.user.email||'';
    applyAdminVisibility();
    if(q('accountChip'))q('accountChip').onclick=e=>{e.stopPropagation();const pop=q('accountPopover');if(pop)pop.hidden=!pop.hidden};
    if(q('openAccountSettings'))q('openAccountSettings').onclick=()=>openAccountSettings();
    if(q('accountForAccountant'))q('accountForAccountant').onclick=()=>{closeAccountPopover();window.openForMyAccountant?.()};
    if(q('accountAdminNav'))q('accountAdminNav').onclick=openAdminPortal;
    if(q('accountSignOut'))q('accountSignOut').onclick=()=>state.client.auth.signOut();
    if(q('signOutBtn'))q('signOutBtn').onclick=()=>state.client.auth.signOut();
    if(q('manageSubscription'))q('manageSubscription').onclick=showPlans;
    if(q('billingPortalBtn'))q('billingPortalBtn').onclick=()=>openBillingPortal('history',q('billingPortalBtn'));
    if(q('billingResolveBtn'))q('billingResolveBtn').onclick=()=>openBillingPortal('portal',q('billingResolveBtn'));
    if(q('billingPaymentMethodBtn'))q('billingPaymentMethodBtn').onclick=()=>openBillingPortal('payment_method',q('billingPaymentMethodBtn'));
    if(q('cancelSubscriptionBtn'))q('cancelSubscriptionBtn').onclick=()=>openBillingPortal('cancel',q('cancelSubscriptionBtn'));
    if(q('keepSubscriptionBtn'))q('keepSubscriptionBtn').onclick=()=>openBillingPortal('keep',q('keepSubscriptionBtn'));
    if(q('undoPlanChangeBtn'))q('undoPlanChangeBtn').onclick=undoScheduledPlanChange;
    if(q('refreshBillingBtn'))q('refreshBillingBtn').onclick=refreshSubscriptionBilling;
    if(q('closeAccountModal'))q('closeAccountModal').onclick=()=>q('accountModal').classList.remove('open');
    if(q('accountModal'))q('accountModal').onclick=e=>{if(e.target===q('accountModal'))q('accountModal').classList.remove('open')};
    if(q('saveAccountProfile'))q('saveAccountProfile').onclick=saveAccountProfile;
    if(q('saveAccountPreferences'))q('saveAccountPreferences').onclick=saveAccountPreferences;
    if(q('saveAccountEmail'))q('saveAccountEmail').onclick=saveAccountPreferences;
    if(q('exportMyData'))q('exportMyData').onclick=()=>exportBusinessData(state.business.id,state.business.name,q('exportMyData'));
    if(q('refreshTeamAccess'))q('refreshTeamAccess').onclick=renderTeamAccess;
    if(q('inviteTeamUser'))q('inviteTeamUser').onclick=openInviteUserModal;
    if(q('closeInviteUserModal'))q('closeInviteUserModal').onclick=closeInviteUserModal;
    if(q('cancelInviteUser'))q('cancelInviteUser').onclick=closeInviteUserModal;
    if(q('sendInviteUser'))q('sendInviteUser').onclick=sendTeamInvitation;
    if(q('closeCustomAccessModal'))q('closeCustomAccessModal').onclick=closeCustomAccessModal;
    if(q('cancelCustomAccess'))q('cancelCustomAccess').onclick=closeCustomAccessModal;
    if(q('saveCustomAccess'))q('saveCustomAccess').onclick=saveCustomAccess;
    if(q('resetCustomAccess'))q('resetCustomAccess').onclick=resetCustomAccess;
    if(q('rolePermissionsBtn'))q('rolePermissionsBtn').onclick=openRolePermissionsModal;
    if(q('closeRolePermissionsModal'))q('closeRolePermissionsModal').onclick=closeRolePermissionsModal;
    if(q('cancelRolePermissions'))q('cancelRolePermissions').onclick=closeRolePermissionsModal;
    if(q('rolePermissionsRole'))q('rolePermissionsRole').onchange=loadRolePermissions;
    if(q('saveRolePermissions'))q('saveRolePermissions').onclick=saveRolePermissions;
    if(q('resetRolePermissions'))q('resetRolePermissions').onclick=resetRolePermissions;
    if(q('switchBusinessBtn'))q('switchBusinessBtn').onclick=openSwitchBusinessModal;
    if(q('addBusinessBtn'))q('addBusinessBtn').onclick=openAddBusinessModal;
    if(q('switchModalAddBusiness'))q('switchModalAddBusiness').onclick=openAddBusinessModal;
    if(q('closeSwitchBusinessModal'))q('closeSwitchBusinessModal').onclick=()=>q('switchBusinessModal')?.classList.remove('open');
    if(q('closeAddBusinessModal'))q('closeAddBusinessModal').onclick=closeAddBusinessModal;
    if(q('cancelAddBusiness'))q('cancelAddBusiness').onclick=closeAddBusinessModal;
    if(q('confirmAddBusiness'))q('confirmAddBusiness').onclick=createAdditionalBusiness;
    refreshBusinessSwitcher();
    document.addEventListener('click',e=>{const pop=q('accountPopover');if(pop&&!pop.hidden&&!pop.contains(e.target)&&e.target!==q('accountChip')&&!q('accountChip')?.contains(e.target))pop.hidden=true});
    if(q('closePlanModal'))q('closePlanModal').onclick=()=>q('planModal').classList.remove('open');
    setupAdminNavigation();
    if(q('adminRefresh'))q('adminRefresh').onclick=renderAdmin;
    if(q('adminReloadPlans'))q('adminReloadPlans').onclick=renderAdminPlans;
    if(q('adminReloadPayments'))q('adminReloadPayments').onclick=renderPaymentSettings;
    if(q('adminReloadInvoicePayments'))q('adminReloadInvoicePayments').onclick=renderAdminInvoicePayments;
    if(q('adminReloadModules'))q('adminReloadModules').onclick=renderAdminModules;
    if(q('adminAddModule'))q('adminAddModule').onclick=addAdminModule;
    if(q('adminCheckPayrollUpdates'))q('adminCheckPayrollUpdates').onclick=checkAdminPayrollCompliance;
    if(q('adminReloadCountryPayrollRules'))q('adminReloadCountryPayrollRules').onclick=renderAdminCountryPayrollRules;
    if(q('adminAddCountryPayrollRule'))q('adminAddCountryPayrollRule').onclick=addAdminCountryPayrollRule;
    if(q('adminPayrollRuleCountry'))q('adminPayrollRuleCountry').onchange=renderAdminCountryPayrollRules;
    if(q('adminSearch'))q('adminSearch').oninput=renderAdmin;
    if(q('adminStatusFilter'))q('adminStatusFilter').onchange=renderAdmin;
    if(q('adminInvoicePaymentSearch'))q('adminInvoicePaymentSearch').oninput=renderAdminInvoicePayments;
    if(q('adminInvoicePaymentStatus'))q('adminInvoicePaymentStatus').onchange=renderAdminInvoicePayments;
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
    if(['owner','admin'].includes(state.profile?.is_super_admin?'owner':(state.accessRole||'')))await renderTeamAccess();
    applyRoleAccessUI();
    if(typeof window.switchView==='function')window.switchView('settings');
    window.openCentralSettings?.('account');
  }
  function teamRoleLabel(role){return ({owner:'Owner',admin:'Admin',accountant:'Accountant',bookkeeper:'Bookkeeper',staff:'Staff',viewer:'Viewer'})[role]||role||'—'}
  function teamStatusLabel(status){return ({active:'Active',suspended:'Suspended',removed:'Removed'})[status]||status||'—'}
  function roleCanRead(area){
    if(state.profile?.is_super_admin)return true;
    if(state.effectiveAccess?.[area])return !!state.effectiveAccess[area].read;
    const r=state.accessRole||'viewer';
    if(r==='owner'||r==='admin')return true;
    if(area==='core')return ['accountant','bookkeeper','staff','viewer'].includes(r);
    if(area==='expenses'||area==='bank')return ['accountant','bookkeeper'].includes(r);
    if(area==='financials')return ['accountant','bookkeeper'].includes(r);
    if(area==='reports')return ['accountant','bookkeeper','viewer'].includes(r);
    return false;
  }
  function roleCanWrite(area){
    if(state.profile?.is_super_admin)return true;
    if(!['billing','team','business_settings'].includes(area)&&subscriptionReadOnly())return false;
    if(state.effectiveAccess?.[area])return !!state.effectiveAccess[area].write;
    const r=state.accessRole||'viewer';
    if(r==='owner')return true;
    if(r==='admin')return area!=='billing';
    if(area==='core')return ['accountant','bookkeeper','staff'].includes(r);
    if(area==='expenses'||area==='bank')return ['accountant','bookkeeper'].includes(r);
    if(area==='financials')return r==='accountant';
    return false;
  }
  function applyRoleAccessUI(){
    const role=state.profile?.is_super_admin?'owner':(state.accessRole||'viewer');
    const setHidden=(el,hidden)=>{if(el)el.hidden=!!hidden};
    setHidden(document.querySelector('[data-module="invoicing"]'),!roleCanRead('core'));
    setHidden(q('jobCostingNav'),!roleCanRead('core')||q('jobCostingNav')?.dataset.entitlementBlocked==='1');
    setHidden(q('expensesNav'),!roleCanRead('expenses')||q('expensesNav')?.dataset.entitlementBlocked==='1');
    setHidden(q('stockEquipmentNav'),!roleCanRead('expenses')||q('stockEquipmentNav')?.dataset.entitlementBlocked!=='0');
    setHidden(q('bankReconciliationNav'),!roleCanRead('bank')||q('bankReconciliationNav')?.dataset.entitlementBlocked==='1');
    setHidden(q('financialsNav'),!roleCanRead('financials')||q('financialsNav')?.dataset.entitlementBlocked==='1');
    setHidden(q('payrollNav'),!roleCanRead('payroll')||q('payrollNav')?.dataset.entitlementBlocked==='1');
    setHidden(document.querySelector('[data-view="reports"]'),!roleCanRead('reports'));
    if(q('teamAccessCard'))q('teamAccessCard').hidden=!['owner','admin'].includes(role);
    const businessWrite=['owner','admin'].includes(role);
    ['accountBusinessName','accountBusinessPhone','accountBusinessAddress','accountSenderEmail','accountCurrency'].forEach(id=>{const el=q(id);if(el)el.disabled=!businessWrite});
    ['saveAccountEmail','saveAccountPreferences'].forEach(id=>{const el=q(id);if(el)el.hidden=!businessWrite});
    if(q('manageSubscription'))q('manageSubscription').hidden=role!=='owner';
    renderSubscriptionSummary();
    if(q('addBusinessBtn'))q('addBusinessBtn').hidden=role!=='owner';
    document.querySelectorAll('[data-invoice-view="settings"],[data-jc-tab="settings"]').forEach(el=>el.hidden=!businessWrite);
    if(q('exportMyData'))q('exportMyData').hidden=!businessWrite;
    if(q('financialSettingsCard'))q('financialSettingsCard').hidden=!roleCanWrite('financials');
  }
  async function renderTeamAccess(){
    const rows=q('teamAccessRows'),msg=q('teamAccessMessage');if(!rows||!state.business?.id)return;
    rows.innerHTML='<tr><td colspan="5">Loading team…</td></tr>';if(msg)msg.textContent='';
    const {data,error}=await state.client.rpc('v6145_list_business_team',{p_business_id:state.business.id});
    if(error){rows.innerHTML='<tr><td colspan="5">Team & Access is unavailable.</td></tr>';if(msg)msg.textContent=error.message||'';return}
    const team=Array.isArray(data)?data:[];
    const self=team.find(x=>x.is_self),actorRole=self?.role||'';
    rows.innerHTML=team.length?team.map(m=>{
      const protectedOwner=m.role==='owner',selfRow=!!m.is_self,adminProtected=actorRole==='admin'&&m.role==='admin';
      const canManage=!protectedOwner&&!selfRow&&!adminProtected&&(actorRole==='owner'||actorRole==='admin');
      const roleOptions=['admin','accountant','bookkeeper','staff','viewer'].map(r=>`<option value="${r}" ${m.role===r?'selected':''}>${teamRoleLabel(r)}</option>`).join('');
      const statusOptions=['active','suspended','removed'].map(st=>`<option value="${st}" ${m.status===st?'selected':''}>${teamStatusLabel(st)}</option>`).join('');
      return `<tr><td><strong>${escapeHtml(m.full_name||'—')}</strong>${selfRow?' <small>(You)</small>':''}</td><td>${escapeHtml(m.email||'—')}</td><td>${canManage?`<select data-team-role="${m.membership_id}">${roleOptions}</select>`:escapeHtml(teamRoleLabel(m.role))}</td><td>${canManage?`<select data-team-status="${m.membership_id}">${statusOptions}</select>`:escapeHtml(teamStatusLabel(m.status))}</td><td>${canManage?`<button class="secondary" data-team-save="${m.membership_id}" type="button">Save</button> <button class="secondary" data-team-access="${m.membership_id}" data-team-name="${escapeHtml(m.full_name||m.email||'User')}" type="button">Access</button>`:'—'}</td></tr>`;
    }).join(''):'<tr><td colspan="5">No team members found.</td></tr>';
    rows.querySelectorAll('[data-team-save]').forEach(btn=>btn.onclick=()=>saveTeamMember(btn.dataset.teamSave,btn));
    rows.querySelectorAll('[data-team-access]').forEach(btn=>btn.onclick=()=>openCustomAccessModal(btn.dataset.teamAccess,btn.dataset.teamName));
    if(msg)msg.textContent=actorRole==='owner'?'You are the business Owner.':actorRole==='admin'?'You have Admin team-management access.':'Team management is restricted to Owners and Admins.';
    const inviteBtn=q('inviteTeamUser');if(inviteBtn)inviteBtn.hidden=!['owner','admin'].includes(actorRole);
    const roleBtn=q('rolePermissionsBtn');if(roleBtn)roleBtn.hidden=actorRole!=='owner';
    await renderPendingInvites(actorRole);
  }
  const customAccessAreas=[
    ['core','Invoicing, Customers & Job Costing'],['expenses','Expenses & Suppliers'],['bank','Bank Reconciliation'],['financials','Financials'],['payroll','Payroll'],['reports','Reports']
  ];

  function closeRolePermissionsModal(){q('rolePermissionsModal')?.classList.remove('open')}
  async function openRolePermissionsModal(){q('rolePermissionsModal')?.classList.add('open');await loadRolePermissions()}
  async function loadRolePermissions(){
    const role=q('rolePermissionsRole')?.value||'accountant',body=q('rolePermissionsRows'),msg=q('rolePermissionsMessage');if(!body)return;
    body.innerHTML='<tr><td colspan="3">Loading role permissions…</td></tr>';if(msg)msg.textContent='';
    const {data,error}=await state.client.rpc('v6149_list_role_permissions',{p_business_id:state.business.id,p_role:role});
    if(error){body.innerHTML='<tr><td colspan="3">Role permissions are unavailable.</td></tr>';if(msg)msg.textContent=error.message||'';return}
    const map=Object.fromEntries((Array.isArray(data)?data:[]).map(x=>[x.area,x]));
    body.innerHTML=customAccessAreas.map(([area,label])=>{const x=map[area]||{};const level=x.custom_level||'default';const system=x.system_write?'Read & Write':x.system_read?'Read only':'No access';const effective=x.effective_write?'Read & Write':x.effective_read?'Read only':'No access';return `<tr><td><strong>${label}</strong><small>System default: ${system}</small></td><td><select data-role-area="${area}"><option value="default" ${level==='default'?'selected':''}>Use system default</option><option value="none" ${level==='none'?'selected':''}>No access</option><option value="read" ${level==='read'?'selected':''}>Read only</option><option value="write" ${level==='write'?'selected':''}>Read & Write</option></select></td><td>${effective}</td></tr>`}).join('');
    if(msg)msg.textContent='These defaults apply to users with this role unless that individual has a custom Access override.';
  }
  async function saveRolePermissions(){
    const role=q('rolePermissionsRole')?.value||'',btn=q('saveRolePermissions'),sels=[...q('rolePermissionsRows').querySelectorAll('[data-role-area]')];if(btn){btn.disabled=true;btn.textContent='Saving…'}
    for(const el of sels){const {error}=await state.client.rpc('v6149_set_role_permission',{p_business_id:state.business.id,p_role:role,p_area:el.dataset.roleArea,p_level:el.value});if(error){if(q('rolePermissionsMessage'))q('rolePermissionsMessage').textContent=error.message;if(btn){btn.disabled=false;btn.textContent='Save Role Defaults'};return}}
    if(btn){btn.disabled=false;btn.textContent='Save Role Defaults'};await loadRolePermissions();
  }
  async function resetRolePermissions(){
    const role=q('rolePermissionsRole')?.value||'';if(!role||!confirm(`Reset ${teamRoleLabel(role)} to Finlo system defaults? Individual user overrides will not be changed.`))return;
    const {error}=await state.client.rpc('v6149_reset_role_permissions',{p_business_id:state.business.id,p_role:role});if(error){if(q('rolePermissionsMessage'))q('rolePermissionsMessage').textContent=error.message;return}await loadRolePermissions();
  }

  function closeCustomAccessModal(){q('customAccessModal')?.classList.remove('open');state.customAccessMembershipId=null}
  async function openCustomAccessModal(membershipId,name='User'){
    state.customAccessMembershipId=membershipId;if(q('customAccessUserName'))q('customAccessUserName').textContent=name;if(q('customAccessMessage'))q('customAccessMessage').textContent='Loading access…';
    q('customAccessModal')?.classList.add('open');
    const {data,error}=await state.client.rpc('v6148_list_member_access',{p_business_id:state.business.id,p_membership_id:membershipId});
    const body=q('customAccessRows');if(error||!body){if(q('customAccessMessage'))q('customAccessMessage').textContent=error?.message||'Access settings are unavailable.';return}
    const map=Object.fromEntries((Array.isArray(data)?data:[]).map(x=>[x.area,x]));
    body.innerHTML=customAccessAreas.map(([area,label])=>{const x=map[area]||{};const effective=x.effective_write?'write':x.effective_read?'read':'none';const override=x.override_level||'default';const defaultLevel=x.default_write?'Read & Write':x.default_read?'Read only':'No access';return `<tr><td><strong>${label}</strong><small>Role default: ${defaultLevel}</small></td><td><select data-custom-area="${area}"><option value="default" ${override==='default'?'selected':''}>Use role default</option><option value="none" ${override==='none'?'selected':''}>No access</option><option value="read" ${override==='read'?'selected':''}>Read only</option><option value="write" ${override==='write'?'selected':''}>Read & Write</option></select></td><td>${effective==='write'?'Read & Write':effective==='read'?'Read only':'No access'}</td></tr>`}).join('');
    if(q('customAccessMessage'))q('customAccessMessage').textContent='Changes override this user’s role defaults only. Team, billing and business-settings permissions remain protected by role.';
  }
  async function saveCustomAccess(){
    const membershipId=state.customAccessMembershipId,btn=q('saveCustomAccess');if(!membershipId)return;const selects=[...q('customAccessRows').querySelectorAll('[data-custom-area]')];if(btn){btn.disabled=true;btn.textContent='Saving…'}
    for(const el of selects){const {error}=await state.client.rpc('v6148_set_member_access',{p_business_id:state.business.id,p_membership_id:membershipId,p_area:el.dataset.customArea,p_level:el.value});if(error){if(btn){btn.disabled=false;btn.textContent='Save Access'};if(q('customAccessMessage'))q('customAccessMessage').textContent=error.message;return}}
    if(btn){btn.disabled=false;btn.textContent='Save Access'};closeCustomAccessModal();await renderTeamAccess();
  }
  async function resetCustomAccess(){
    const membershipId=state.customAccessMembershipId;if(!membershipId||!confirm('Reset all custom access for this user back to their role defaults?'))return;const {error}=await state.client.rpc('v6148_reset_member_access',{p_business_id:state.business.id,p_membership_id:membershipId});if(error){if(q('customAccessMessage'))q('customAccessMessage').textContent=error.message;return}await openCustomAccessModal(membershipId,q('customAccessUserName')?.textContent||'User');
  }

  function publicAppUrl(){try{const u=new URL(location.href);if(u.protocol==='http:'||u.protocol==='https:'){u.search='';u.hash='';return u.toString()}}catch{}return ''}
  async function inviteApi(body){const result=body?.action==='inspect'?await state.client.functions.invoke('business-invite',{body}):await invokeAuthenticatedFunction('business-invite',body);const {data,error}=result;if(error){let detail=error.message||'Invitation service error';try{const payload=await error.context?.clone?.().json?.();if(payload?.error)detail=payload.error}catch{}return {error:detail}}return data||{}}
  async function prepareInviteMode(){
    if(!state.inviteToken)return;
    const data=await inviteApi({action:'inspect',token:state.inviteToken});
    if(data?.error){message(data.error,'error');state.inviteToken='';return}
    state.inviteInfo=data;
    const note=`${data.businessName} has invited you to join as ${teamRoleLabel(data.role)}. Log in if you already have Finlo, or create an account below.`;
    message(note,'success');
    if(q('loginEmail'))q('loginEmail').value=data.email||'';
    if(q('signupEmail')){q('signupEmail').value=data.email||'';q('signupEmail').readOnly=true}
    ['signupBusiness','signupAddress','signupPhone','signupPlan'].forEach(id=>{const el=q(id);if(el){const lab=el.closest('label');if(lab)lab.hidden=true;el.required=false}});
    const h=q('signupForm')?.querySelector('h1'),p=q('signupForm')?.querySelector('p');if(h)h.textContent='Join '+data.businessName;if(p)p.textContent=`Create your Finlo login to join ${data.businessName} as ${teamRoleLabel(data.role)}.`;
  }
  async function acceptInvitationIfPresent(){
    if(!state.inviteToken)return true;
    const data=await inviteApi({action:'accept',token:state.inviteToken});
    if(data?.error){message(data.error,'error');return false}
    const u=new URL(location.href);u.searchParams.delete('invite');history.replaceState(null,'',u.pathname+(u.searchParams.toString()?('?'+u.searchParams.toString()):'')+u.hash);state.inviteToken='';return true;
  }
  function openInviteUserModal(){
    if(q('inviteUserEmail'))q('inviteUserEmail').value='';if(q('inviteUserRole'))q('inviteUserRole').value='staff';if(q('inviteUserMessage'))q('inviteUserMessage').textContent='';q('inviteUserModal')?.classList.add('open');q('inviteUserEmail')?.focus();
  }
  function closeInviteUserModal(){q('inviteUserModal')?.classList.remove('open')}
  async function sendTeamInvitation(){
    const email=q('inviteUserEmail')?.value.trim()||'',role=q('inviteUserRole')?.value||'staff',btn=q('sendInviteUser'),msg=q('inviteUserMessage');
    if(!email)return msg&&(msg.textContent='Enter an email address.');
    if(!publicAppUrl())return msg&&(msg.textContent='Open Finlo from its deployed Netlify URL before sending invitations. Local file mode cannot create a usable email link.');
    if(btn){btn.disabled=true;btn.textContent='Sending…'};if(msg)msg.textContent='';
    const data=await inviteApi({action:'create',businessId:state.business.id,email,role,redirectUrl:publicAppUrl()});
    if(btn){btn.disabled=false;btn.textContent='Send Invitation'};
    if(data?.error){if(msg)msg.textContent=data.error;return}
    closeInviteUserModal();await renderPendingInvites();
  }
  async function renderPendingInvites(actorRole=''){
    const rows=q('teamInviteRows'),wrap=q('teamPendingWrap');if(!rows||!state.business?.id)return;
    if(actorRole&&!['owner','admin'].includes(actorRole)){if(wrap)wrap.hidden=true;return}if(wrap)wrap.hidden=false;
    rows.innerHTML='<tr><td colspan="4">Loading invitations…</td></tr>';
    const data=await inviteApi({action:'list',businessId:state.business.id});
    if(data?.error){rows.innerHTML='<tr><td colspan="4">Pending invitations are unavailable.</td></tr>';return}
    const invites=data.invites||[];rows.innerHTML=invites.length?invites.map(i=>`<tr><td>${escapeHtml(i.email)}</td><td>${escapeHtml(teamRoleLabel(i.role))}</td><td>${escapeHtml(new Date(i.expires_at).toLocaleDateString())}</td><td><button class="secondary" data-invite-resend="${i.id}" type="button">Resend</button> <button class="danger" data-invite-revoke="${i.id}" type="button">Revoke</button></td></tr>`).join(''):'<tr><td colspan="4">No pending invitations.</td></tr>';
    rows.querySelectorAll('[data-invite-resend]').forEach(b=>b.onclick=()=>manageInvite('resend',b.dataset.inviteResend,b));rows.querySelectorAll('[data-invite-revoke]').forEach(b=>b.onclick=()=>manageInvite('revoke',b.dataset.inviteRevoke,b));
  }
  async function manageInvite(action,id,btn){
    if(action==='revoke'&&!confirm('Revoke this pending invitation?'))return;if(action==='resend'&&!publicAppUrl())return alert('Open Finlo from its deployed Netlify URL before resending invitations.');
    btn.disabled=true;const old=btn.textContent;btn.textContent=action==='resend'?'Sending…':'Revoking…';const data=await inviteApi({action,businessId:state.business.id,inviteId:id,redirectUrl:publicAppUrl()});btn.disabled=false;btn.textContent=old;if(data?.error)return alert(data.error);await renderPendingInvites();
  }
  function openAddBusinessModal(){
    closeAccountPopover();q('switchBusinessModal')?.classList.remove('open');
    if(q('addBusinessName'))q('addBusinessName').value='';if(q('addBusinessCountry'))q('addBusinessCountry').value=String(state.business?.settings?.country||'NZ').toUpperCase();if(q('addBusinessMessage'))q('addBusinessMessage').textContent='';q('addBusinessModal')?.classList.add('open');setTimeout(()=>q('addBusinessName')?.focus(),0);
  }
  function closeAddBusinessModal(){q('addBusinessModal')?.classList.remove('open')}
  async function createAdditionalBusiness(){
    const name=q('addBusinessName')?.value.trim()||'',country=String(q('addBusinessCountry')?.value||'NZ').toUpperCase(),btn=q('confirmAddBusiness'),msg=q('addBusinessMessage');
    if(!name){if(msg)msg.textContent='Enter a business name.';return}if(btn){btn.disabled=true;btn.textContent='Creating…'}if(msg)msg.textContent='';
    const {data,error}=await state.client.rpc('v6169b_add_business',{p_name:name,p_country:country});
    if(error||!data){if(btn){btn.disabled=false;btn.textContent='Create business'}if(msg)msg.textContent=error?.message||'Could not create the business.';return}
    location.reload();
  }

  async function refreshBusinessSwitcher(){
    if(!state.user)return;const data=await inviteApi({action:'my-businesses'});if(data?.error)return;state.businessMemberships=data.businesses||[];const btn=q('switchBusinessBtn');if(btn)btn.hidden=state.businessMemberships.length<=1;if(q('switchBusinessHint'))q('switchBusinessHint').textContent=state.businessMemberships.length>1?`${state.businessMemberships.length} authorised businesses`:'Choose another authorised business';
  }
  async function openSwitchBusinessModal(){
    closeAccountPopover();const list=q('switchBusinessList');if(!list)return;const data=await inviteApi({action:'my-businesses'});if(data?.error)return alert(data.error);const businesses=data.businesses||[];list.innerHTML=businesses.map(b=>`<button class="secondary business-switch-option" data-business-switch="${b.id}" type="button"><span><strong>${escapeHtml(b.name)}</strong><small>${escapeHtml(teamRoleLabel(b.role))}</small></span>${b.id===data.currentBusinessId?'<span>Current</span>':''}</button>`).join('');list.querySelectorAll('[data-business-switch]').forEach(btn=>btn.onclick=()=>switchBusiness(btn.dataset.businessSwitch));q('switchBusinessModal')?.classList.add('open');
  }
  async function switchBusiness(businessId){
    if(!businessId||businessId===state.business?.id){q('switchBusinessModal')?.classList.remove('open');return}
    try{await window.FinloHelper?.endLiveVoice?.('business-switch')}catch{}
    const data=await inviteApi({action:'switch',businessId});if(data?.error)return alert(data.error);location.reload();
  }

  async function saveTeamMember(membershipId,btn){
    const role=q('teamAccessRows')?.querySelector(`[data-team-role="${membershipId}"]`)?.value;
    const status=q('teamAccessRows')?.querySelector(`[data-team-status="${membershipId}"]`)?.value;
    if(!role||!status)return;
    const action=status==='removed'?'remove this user from the business':status==='suspended'?'suspend this user':'save these access changes';
    if(!confirm(`Are you sure you want to ${action}?`))return;
    btn.disabled=true;const old=btn.textContent;btn.textContent='Saving…';
    const {error}=await state.client.rpc('v6145_update_business_member',{p_business_id:state.business.id,p_membership_id:membershipId,p_role:role,p_status:status});
    btn.disabled=false;btn.textContent=old;
    if(error)return alert('Could not update team member: '+error.message);
    await renderTeamAccess();
  }

  async function saveAccountProfile(){
    const full_name=q('accountProfileName')?.value.trim()||'';
    const role=state.profile?.is_super_admin?'owner':(state.accessRole||'viewer');
    const canEditBusiness=['owner','admin'].includes(role);
    const a=await state.client.from('profiles').update({full_name}).eq('id',state.user.id);
    if(a.error)return alert(a.error.message||'Could not save your profile.');
    state.profile.full_name=full_name;
    if(canEditBusiness){
      const name=q('accountBusinessName')?.value.trim()||state.business.name;
      const phone=q('accountBusinessPhone')?.value.trim()||'';
      const address=q('accountBusinessAddress')?.value.trim()||'';
      const {error}=await state.client.from('businesses').update({name,phone,address,updated_at:new Date().toISOString()}).eq('id',state.business.id);
      if(error)return alert(error.message||'Could not save business account details.');
      state.business.name=name;state.business.phone=phone;state.business.address=address;
      if(q('brandCompanyName'))q('brandCompanyName').textContent=(state.business.settings?.company||state.business.settings?.trading||name||'Business');
    }
    setupAccountUI();applyRoleAccessUI();q('accountModal')?.classList.remove('open');
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
    window.invoiceAppHelpers?.updateSettings?.({outboundEmail:senderEmail,currency,_settingsBusinessId:state.business.id});window.invoiceAppHelpers?.resetInvoiceTaxRuntime?.();
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
      expense_audit_log:state.client.from('expense_audit_log').select('*').eq('business_id',businessId).order('created_at'),
      payroll_settings:state.client.from('payroll_settings').select('*').eq('business_id',businessId),
      payroll_country_rules:state.client.from('payroll_country_rules').select('*').eq('business_id',businessId).order('effective_from'),
      payroll_employees:state.client.from('payroll_employees').select('*').eq('business_id',businessId).order('created_at'),
      payroll_document_types:state.client.from('payroll_document_types').select('*').eq('business_id',businessId).order('sort_order'),
      payroll_employee_documents:state.client.from('payroll_employee_documents').select('*').eq('business_id',businessId).order('uploaded_at'),
      payroll_pay_items:state.client.from('payroll_pay_items').select('*').eq('business_id',businessId).order('created_at'),
      payroll_leave_types:state.client.from('payroll_leave_types').select('*').eq('business_id',businessId).order('created_at'),
      payroll_employee_leave:state.client.from('payroll_employee_leave').select('*').eq('business_id',businessId).order('updated_at'),
      payroll_leave_transactions:state.client.from('payroll_leave_transactions').select('*').eq('business_id',businessId).order('transaction_date'),
      payroll_timesheets:state.client.from('payroll_timesheets').select('*').eq('business_id',businessId).order('work_date'),
      payroll_pay_runs:state.client.from('payroll_pay_runs').select('*').eq('business_id',businessId).order('pay_date'),
      payroll_pay_run_employees:state.client.from('payroll_pay_run_employees').select('*').eq('business_id',businessId).order('created_at'),
      payroll_pay_run_lines:state.client.from('payroll_pay_run_lines').select('*').eq('business_id',businessId).order('created_at'),
      payroll_payslips:state.client.from('payroll_payslips').select('*').eq('business_id',businessId).order('generated_at'),
      payroll_financial_transactions:state.client.from('payroll_financial_transactions').select('*').eq('business_id',businessId).order('created_at'),
      payroll_audit_log:state.client.from('payroll_audit_log').select('*').eq('business_id',businessId).order('created_at')
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
    if(q('accountEmail'))q('accountEmail').textContent=state.user.email||'';
    if(q('usageBar')){const pct=limit?Math.min(100,Math.round(used/limit*100)):0;q('usageBar').style.width=pct+'%'}
    renderSubscriptionSummary();
    return {sub,used,limit};
  }

  async function canCreateInvoice(){
    const x=await refreshUsage(); if(!x)return {ok:false,message:'No subscription is attached to this business.'};
    const {sub,used,limit}=x;
    if(subscriptionReadOnly(sub)||['suspended','canceled','past_due'].includes(sub.status))return{ok:false,message:'Your subscription is not active. Open Settings → Subscription & Billing.'};
    if(sub.status==='trialing'&&sub.trial_ends_at&&new Date(sub.trial_ends_at)<new Date())return{ok:false,message:'Your trial has ended. Choose a plan to continue creating invoices.'};
    if(limit!=null&&used>=limit)return{ok:false,message:`You have reached your ${limit}-invoice limit for this period. Upgrade your plan to create more invoices.`};
    return {ok:true};
  }

  async function saveBusinessSettings(s){
    const clean={...stripInfra(s),_settingsBusinessId:state.business.id}; const {error}=await state.client.from('businesses').update({settings:clean,name:clean.company||clean.trading||state.business.name,address:clean.address||state.business.address,phone:clean.phone||state.business.phone,updated_at:new Date().toISOString()}).eq('id',state.business.id);
    if(!error){state.business.settings=clean;writeBusinessSettingsCache(clean,state.business.id);return true} console.warn('Business settings cloud sync failed',error);return false;
  }

  let billingReadyBusiness='',billingLoading=false,billingPrice=null,billingDuplicateSubscriptions=[],billingScheduledChange=null;
  function subscriptionReadOnly(sub=state.subscription){
    if(!sub)return false;
    const end=sub.cancel_at||(sub.cancel_at_period_end?sub.current_period_end:null);
    return sub.status==='canceled'||(!!end&&new Date(end).getTime()<=Date.now())||
      (sub.status==='trialing'&&!!sub.trial_ends_at&&new Date(sub.trial_ends_at).getTime()<=Date.now());
  }
  function billingDateText(value){const d=new Date(value);return value&&Number.isFinite(d.getTime())?d.toLocaleDateString(undefined,{day:'numeric',month:'long',year:'numeric'}):'—'}
  function billingReturnTarget(){return /^https?:$/.test(location.protocol)?location.origin+location.pathname:'https://frindly.co.nz/'}
  function renderSubscriptionSummary(){
    const sub=state.subscription;if(!sub)return;
    const owner=state.accessRole==='owner',canCancel=['owner','bookkeeper'].includes(state.accessRole);
    const duplicates=billingDuplicateSubscriptions.length>1;
    const scheduled=!!(sub.cancel_at_period_end||sub.cancel_at),readOnly=subscriptionReadOnly(sub);
    const active=['active','trialing','past_due'].includes(sub.status)&&!readOnly;
    const end=sub.cancel_at||sub.current_period_end,freeTrial=sub.status==='trialing'&&!sub.stripe_subscription_id;
    const set=(id,text)=>{if(q(id))q(id).textContent=text};
    set('billingBusinessName',state.business?.name||'Subscription');
    set('accountStatus',readOnly?'Read-only':scheduled?'Cancellation scheduled':sub.status==='trialing'?'Trial':human(sub.status||'Unknown'));
    const amount=billingPrice?.businessId===state.business?.id?billingPrice:null;
    const interval=amount?.interval==='year'||sub.billing_interval==='annual'?'year':'month';
    const rate=amount?amount.amount/100:(interval==='year'?sub.plans?.annual_price:sub.plans?.monthly_price);
    set('billingPrice',freeTrial?'Free trial':rate==null?'—':`${invoicePaymentMoney(rate,amount?.currency||'NZD')} / ${interval}`);
    set('billingDateLabel',freeTrial?'Trial ends':scheduled||readOnly?'Access ends':'Next billing date');
    set('billingDate',billingDateText(freeTrial?sub.trial_ends_at:end));
    set('accountPlanHint',freeTrial?'No subscription payment is scheduled. Choose a paid plan to continue after the trial.':
      readOnly?'Your existing records are retained. You can view and export them using your existing permissions. Choose a plan to use paid features again.':
      scheduled?`Cancellation scheduled — access until ${billingDateText(end)}. Your subscription will not renew.`:
      'Your subscription renews automatically. Plan changes show the amount and effective date before confirmation.');
    if(q('billingScheduledChange')){
      const change=billingScheduledChange;
      q('billingScheduledChange').textContent=change?`Your ${change.planName} plan is scheduled for ${billingDateText(change.effectiveAt*1000)} at ${change.amount==null?'the configured price':invoicePaymentMoney(change.amount/100,amount?.currency||'NZD')} / ${change.interval}. Your current plan remains available until then.`:'';
      q('billingScheduledChange').hidden=!change;
    }
    set('billingCancellationHint',freeTrial?'Your free trial ends automatically; there is no paid subscription to cancel.':
      scheduled&&!readOnly?'Changed your mind? Keep your subscription before access ends.':
      active&&sub.stripe_subscription_id?'The owner or bookkeeper can cancel. Access continues until the end of the current paid period.':
      readOnly?'Cancellation does not delete your records or close your connected Stripe account.':'');
    if(q('billingDuplicateWarning')){
      const charges=billingDuplicateSubscriptions.map(p=>p.amount==null?'an active subscription':`${invoicePaymentMoney(p.amount/100,p.currency)} / ${p.interval==='year'?'year':'month'}`).join(' and ');
      q('billingDuplicateWarning').textContent=duplicates?`Stripe has ${billingDuplicateSubscriptions.length} active subscriptions for this business (${charges}). Billing changes are paused until the owner reviews both subscriptions in Stripe. Canceling one will not stop charges for the other.`:'';
      q('billingDuplicateWarning').hidden=!duplicates;
    }
    const show=(id,visible)=>{if(q(id))q(id).hidden=!visible};
    show('manageSubscription',owner&&!duplicates&&!billingScheduledChange);show('undoPlanChangeBtn',owner&&!!billingScheduledChange&&!duplicates);
    show('billingPortalBtn',owner&&!!sub.stripe_customer_id);
    show('billingPaymentMethodBtn',owner&&!!sub.stripe_customer_id&&!duplicates);
    show('billingResolveBtn',owner&&duplicates);
    show('cancelSubscriptionBtn',canCancel&&active&&!!sub.stripe_subscription_id&&!scheduled&&!duplicates);
    show('keepSubscriptionBtn',canCancel&&active&&!!sub.stripe_subscription_id&&scheduled&&!duplicates);
    ['cancelSubscriptionBtn','keepSubscriptionBtn','undoPlanChangeBtn'].forEach(id=>{if(q(id))q(id).disabled=billingLoading||billingReadyBusiness!==state.business?.id});
  }
  async function billingApi(action){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
    try{
      const result=await invokeAuthenticatedFunction('create-portal',{action,returnUrl:billingReturnTarget()},controller.signal);
      if(result.error||result.data?.error)throw result.error||new Error(result.data.error);
      return result.data;
    }finally{clearTimeout(timer)}
  }
  async function refreshSubscriptionBilling(){
    if(billingLoading)return;
    const businessId=state.business?.id;if(!businessId)return;
    billingLoading=true;billingReadyBusiness='';billingPrice=null;billingDuplicateSubscriptions=[];billingScheduledChange=null;
    const messageEl=q('billingMessage'),button=q('refreshBillingBtn');
    if(button)button.disabled=true;if(messageEl)messageEl.textContent='Refreshing billing…';
    renderSubscriptionSummary();
    try{
      await getSubscription();
      if(['owner','bookkeeper'].includes(state.accessRole)&&state.subscription?.stripe_subscription_id){
        const data=await billingApi('status');
        if(state.business?.id!==businessId)return;
        if(data?.price)billingPrice={...data.price,businessId};
        billingDuplicateSubscriptions=Array.isArray(data?.duplicateSubscriptions)?data.duplicateSubscriptions:[];
        billingScheduledChange=data?.scheduledChange||null;
      }
      await refreshUsage();
      const {data:access}=await state.client.rpc('v6148_my_effective_access',{p_business_id:businessId});
      if(state.business?.id!==businessId)return;
      if(Array.isArray(access)){state.effectiveAccess={};access.forEach(x=>{state.effectiveAccess[x.area]={read:!!x.can_read,write:!!x.can_write}})}
      clearModuleAccessCache();
      const {data:modules,error}=await state.client.from('modules').select('slug,name,is_active').eq('is_active',true).order('name');
      if(error)throw error;
      const available=await Promise.all((modules||[]).map(async m=>await hasModule(m.slug)?m:null));
      if(state.business?.id!==businessId)return;
      if(q('billingModules'))q('billingModules').innerHTML=available.filter(Boolean).map(m=>`<span>${escapeHtml(m.name||human(m.slug))}</span>`).join('')||'<span>No additional modules enabled</span>';
      billingReadyBusiness=businessId;
      if(messageEl)messageEl.textContent='';
    }catch(error){if(messageEl)messageEl.textContent=`Could not refresh billing: ${error?.name==='AbortError'?'The request timed out. Please try again.':error?.message||'Please try again.'}`;}
    finally{billingLoading=false;if(button)button.disabled=false;renderSubscriptionSummary()}
  }
  async function openBillingPortal(action='portal',button){
    if(billingLoading)return;
    const canCancel=['owner','bookkeeper'].includes(state.accessRole);
    if(['cancel','keep'].includes(action)?!canCancel:state.accessRole!=='owner')return;
    if(['cancel','keep'].includes(action)){
      await refreshSubscriptionBilling();if(billingReadyBusiness!==state.business?.id)return;
      const sub=state.subscription,scheduled=!!(sub?.cancel_at_period_end||sub?.cancel_at);
      if(subscriptionReadOnly(sub)||!sub?.stripe_subscription_id)return;
      if((action==='cancel'&&scheduled)||(action==='keep'&&!scheduled))return;
      const text=action==='cancel'?`Cancel the Frindly subscription for ${state.business.name}? Access continues until ${billingDateText(sub.cancel_at||sub.current_period_end)}. ${billingScheduledChange?'This will replace your scheduled plan change with a period-end cancellation.':'You will confirm cancellation securely in Stripe.'}`:
        `Keep the Frindly subscription for ${state.business.name}? Automatic renewal will continue at your existing plan price.`;
      if(!confirm(text))return;
    }
    const original=button?.textContent;if(button){button.disabled=true;button.textContent=action==='keep'?'Keeping subscription…':'Opening Stripe…'}
    try{
      const data=await billingApi(action);
      if(action==='keep'){await refreshSubscriptionBilling();if(q('billingMessage'))q('billingMessage').textContent='Your subscription will continue to renew.';return}
      if(action==='cancel'&&data?.canceledAtPeriodEnd){await refreshSubscriptionBilling();if(q('billingMessage'))q('billingMessage').textContent='Cancellation scheduled for the end of your paid period.';return}
      if(!data?.url||!/^https:\/\/billing\.stripe\.com\//.test(data.url))throw new Error('Stripe did not return a billing portal link.');
      location.href=data.url;
    }catch(error){if(q('billingMessage'))q('billingMessage').textContent=error?.message||'Billing is unavailable. Please try again.';}
    finally{if(button){button.disabled=false;button.textContent=original}renderSubscriptionSummary()}
  }

  function showPlanUpgradePrompt({title='Employee limit reached',message='',primaryLabel='Upgrade plan'}={}){
    let modal=document.getElementById('planUpgradePrompt');
    if(!modal){
      modal=document.createElement('div');
      modal.id='planUpgradePrompt';
      modal.className='modal';
      modal.innerHTML=`<div class="modal-card plan-upgrade-prompt-card" role="dialog" aria-modal="true" aria-labelledby="planUpgradePromptTitle">
        <button type="button" class="modal-close" data-plan-upgrade-close aria-label="Close">×</button>
        <div class="plan-upgrade-icon">↑</div>
        <h3 id="planUpgradePromptTitle"></h3>
        <p data-plan-upgrade-message></p>
        <div class="plan-upgrade-actions">
          <button type="button" class="secondary" data-plan-upgrade-close>Not now</button>
          <button type="button" class="primary" data-plan-upgrade-open></button>
        </div>
      </div>`;
      document.body.appendChild(modal);
      modal.addEventListener('click',event=>{
        if(event.target===modal||event.target.closest('[data-plan-upgrade-close]'))modal.classList.remove('open');
        const open=event.target.closest('[data-plan-upgrade-open]');
        if(open){modal.classList.remove('open');showPlans()}
      });
    }
    modal.querySelector('#planUpgradePromptTitle').textContent=title;
    modal.querySelector('[data-plan-upgrade-message]').textContent=message;
    modal.querySelector('[data-plan-upgrade-open]').textContent=primaryLabel;
    modal.classList.add('open');
  }
  window.SAAS=window.SAAS||{};
  window.SAAS.showPlanUpgradePrompt=showPlanUpgradePrompt;

  async function showPlans(){
    if(state.accessRole!=='owner')return alert('Only the Business Owner can change the subscription plan.');
    const [{data:plans},checkoutReady]=await Promise.all([
      state.client.from('plans').select('*').eq('is_public',true).order('sort_order'),
      getCheckoutAvailability(true)
    ]);
    state.plans=plans||[];
    await getSubscription();
    const root=q('customerPlanGrid');
    root.innerHTML=(plans||[]).map(p=>{
      const current=state.plan?.id===p.id&&!subscriptionReadOnly(),ap=annualPricing(p),isTrial=p.slug==='trial';
      const currentMonthly=current&&state.subscription?.billing_interval!=='annual',currentAnnual=current&&state.subscription?.billing_interval==='annual';
      const monthlyConfigured=!!p.stripe_price_id;
      const annualConfigured=ap.annual!=null&&!!p.stripe_annual_price_id;
      const monthlyPurchasable=current||(checkoutReady&&monthlyConfigured);
      const annualPurchasable=current||(checkoutReady&&annualConfigured);
      const annualSaving=ap.annual!=null&&ap.saving>0;
      const monthlyButton=currentMonthly?'Current plan':(!checkoutReady?'Subscriptions unavailable':(!monthlyConfigured?'Monthly not configured':'Choose monthly'));
      const annualButton=currentAnnual?'Current plan':(!checkoutReady?'Subscriptions unavailable':(!annualConfigured?'Annual not configured':'Choose annual'));

      const annualOffer=isTrial?'':(ap.annual==null
        ?`<div class="pricing-annual pricing-annual-unavailable">
            <div><span class="pricing-eyebrow">Annual</span><strong>Not configured</strong></div>
          </div>`
        :`<div class="pricing-annual ${annualSaving?'has-saving':''}">
            <div class="pricing-annual-copy">
              <span class="pricing-eyebrow">Pay annually</span>
              <strong>$${ap.annual.toFixed(2)} <small>/ year</small></strong>
              <span class="pricing-equivalent">$${ap.equivalent.toFixed(2)}/month equivalent</span>
            </div>
            ${annualSaving&&ap.message?`<span class="pricing-save-pill">${escapeHtml(ap.message)}</span>`:''}
          </div>`);

      return `<div class="plan-card pricing-card ${current?'current':''}">
        <div class="pricing-card-head">
          <div><span class="plan-name">${escapeHtml(p.name)}</span><p>${escapeHtml(p.description||'')}</p></div>
          ${current?'<span class="pricing-current-pill">Current</span>':''}
        </div>

        <div class="pricing-monthly">
          <span class="pricing-eyebrow">${isTrial?'Price':'Pay monthly'}</span>
          <div><strong>$${ap.monthly.toFixed(2)}</strong><span>/month</span></div>
        </div>

        ${annualOffer}

        <div class="pricing-divider"></div>
        <div class="pricing-limit">${p.invoice_limit==null?'Unlimited invoices':`${p.invoice_limit} invoices / period`}${(p.included_modules||[]).includes('payroll')&&p.employee_limit!=null?`<span class="pricing-employee-limit"> · Up to ${Number(p.employee_limit)} employees</span>`:''}</div>
        <div class="plan-modules pricing-modules">${(p.included_modules||[]).map(m=>`<span>${escapeHtml(human(m))}</span>`).join('')}</div>

        <div class="plan-purchase-actions pricing-actions ${isTrial?'single':''}">
          <button class="${currentMonthly?'secondary':'primary'}" data-choose-plan="${p.slug}" data-billing-interval="monthly" ${monthlyPurchasable&&monthlyConfigured&&!currentMonthly?'':'disabled'}>${monthlyButton}</button>
          ${isTrial?'':`<button class="secondary pricing-annual-action" data-choose-plan="${p.slug}" data-billing-interval="annual" ${annualPurchasable&&annualConfigured&&!currentAnnual?'':'disabled'}>${annualButton}</button>`}
        </div>
      </div>`;
    }).join('');
    root.querySelectorAll('[data-choose-plan]:not([disabled])').forEach(b=>b.onclick=()=>startCheckout(b.dataset.choosePlan,b,{billingInterval:b.dataset.billingInterval}));
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
    if(btn){btn.disabled=true;btn.textContent='Checking price…'}
    const billingInterval=opts.billingInterval==='annual'?'annual':'monthly';
    try{
      const data=await planBillingAction({planSlug:slug,billingInterval,returnUrl:billingReturnTarget(),action:'start'});
      if(data?.url){location.href=data.url;return true}
      const change=data?.change;
      if(!change)throw new Error('Stripe did not provide a plan change preview.');
      const currency=String(change.currency||'NZD').toUpperCase();
      const due=invoicePaymentMoney(Number(change.amountDue)/100,currency);
      const recurring=invoicePaymentMoney(Number(change.nextAmount)/100,currency);
      const effective=billingDateText(change.effectiveAt*1000);
      const message=change.kind==='downgrade'
        ?`Schedule ${change.planName} for ${effective}? Your current plan stays available until then. Nothing is charged now. From that date the new price is ${recurring} / ${change.interval==='annual'?'year':'month'}. You can undo this before the change takes effect.`
        :`Change to ${change.planName} now? Stripe will charge ${due} now, including any applicable credit or tax, and then ${recurring} / ${change.interval==='annual'?'year':'month'}. ${change.renewsAt?`Your next renewal is ${billingDateText(change.renewsAt*1000)}.`:'Your billing date may change with the new interval.'} If payment fails, your existing plan stays in place.`;
      if(!confirm(message))return false;
      if(btn)btn.textContent=change.kind==='downgrade'?'Scheduling…':'Processing payment…';
      const result=await planBillingAction({planSlug:slug,billingInterval,action:'confirm',quote:change.quote});
      if(!result?.scheduled&&!result?.upgraded)throw new Error('Stripe has not confirmed the change. Refresh billing before retrying.');
      if(q('planModal'))q('planModal').classList.remove('open');
      await refreshSubscriptionBilling();
      const success=result.scheduled?'Your new plan is scheduled for the next renewal.':'Your payment succeeded and your new plan is active.';
      if(q('billingMessage'))q('billingMessage').textContent=success;
      return true;
    }catch(error){
      if(btn){btn.disabled=false;btn.textContent=original}
      const text=error?.message||'Billing is not configured yet.';
      if(!opts.silent)alert(`Checkout unavailable: ${text}`);
      else message(text,'error');
      return false;
    }
    finally{if(btn){btn.disabled=false;btn.textContent=original}}
  }

  async function planBillingAction(body){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
    try{
      const result=await invokeAuthenticatedFunction('create-checkout',body,controller.signal);
      if(result.error||result.data?.error)throw result.error||new Error(result.data.error);
      return result.data;
    }finally{clearTimeout(timer)}
  }

  async function undoScheduledPlanChange(){
    if(state.accessRole!=='owner'||!billingScheduledChange)return;
    const name=billingScheduledChange.planName;
    if(!confirm(`Undo the scheduled change to ${name}? Your current subscription will continue to renew.`))return;
    const btn=q('undoPlanChangeBtn');if(btn)btn.disabled=true;
    try{
      await planBillingAction({action:'undo'});
      await refreshSubscriptionBilling();
      if(q('billingMessage'))q('billingMessage').textContent='The scheduled plan change was undone.';
    }catch(error){if(q('billingMessage'))q('billingMessage').textContent=error?.message||'Could not undo this change.'}
    finally{if(btn)btn.disabled=false}
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
      state.client.from('business_modules').select('module_id,status,trial_ends_at').eq('business_id',businessId),
      state.client.from('subscriptions').select('plans(included_modules)').eq('business_id',businessId).maybeSingle()
    ]);
    const overrides=new Map((enabled||[]).map(x=>[x.module_id,x]));
    const included=new Set(sub?.plans?.included_modules||[]);
    q('moduleModal').dataset.businessId=businessId;q('moduleBusinessName').textContent=businessName;
    q('moduleChecklist').innerHTML=(mods||[]).map(m=>{
      const override=overrides.get(m.id),explicit=override?.status,globallyActive=m.is_active===true;
      const inherited=included.has(m.slug);
      const effective=!globallyActive?'suspended':(explicit||(inherited?'active':'suspended'));
      const source=!globallyActive?'Globally disabled':(explicit==='suspended'?'Blocked for this business':(explicit==='trialing'?'Trial for this business':(explicit==='active'?'Enabled for this business':(inherited?'Included by subscription plan':'Not included'))));
      const trialDate=override?.trial_ends_at?String(override.trial_ends_at).slice(0,10):'';
      return `<div class="module-toggle module-toggle-access"><span><strong>${escapeHtml(m.name)}</strong><small>${escapeHtml(m.description||'')} · ${source}</small></span><select data-module-id="${m.id}" data-module-status ${globallyActive?'':'disabled'}><option value="active" ${effective==='active'?'selected':''}>Enabled</option><option value="trialing" ${effective==='trialing'?'selected':''}>Trial</option><option value="suspended" ${effective==='suspended'?'selected':''}>Disabled</option></select><input type="date" data-module-trial-end="${m.id}" value="${trialDate}" title="Trial end date" ${globallyActive?'':'disabled'}></div>`;
    }).join('')||'<p>No modules have been configured yet.</p>';
    q('moduleModal').classList.add('open');
  }

  async function saveBusinessModules(){
    const bid=q('moduleModal').dataset.businessId;if(!bid)return;const controls=[...q('moduleChecklist').querySelectorAll('[data-module-status]')];
    for(const control of controls){
      const status=control.value,moduleId=control.dataset.moduleId,end=q('moduleChecklist').querySelector(`[data-module-trial-end="${moduleId}"]`)?.value||'';
      let trial_ends_at=null;if(status==='trialing'){const d=end?new Date(end+'T23:59:59'):new Date(Date.now()+14*86400000);trial_ends_at=d.toISOString()}
      const {error}=await state.client.from('business_modules').upsert({business_id:bid,module_id:moduleId,status,trial_ends_at},{onConflict:'business_id,module_id'});
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
    const {data:businesses,error}=await state.client.from('businesses').select('id,name,status,created_at,profiles!profiles_business_id_fkey(id,full_name,email,role),subscriptions(id,status,billing_interval,trial_ends_at,current_period_start,current_period_end,invoice_limit_override,plans(id,name,slug,invoice_limit,monthly_price,annual_price,included_modules)),business_modules(status,modules(slug,name))').order('created_at',{ascending:false});
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
    const formatAdminMoney=value=>`$${Number(value||0).toFixed(2)}`;
    const formatAdminDate=value=>value?new Date(value).toLocaleDateString():'—';
    const activeSubs=(businesses||[]).map(getSub).filter(sub=>sub.status==='active');
    const monthlySubs=activeSubs.filter(sub=>sub.billing_interval!=='annual');
    const annualSubs=activeSubs.filter(sub=>sub.billing_interval==='annual');
    const monthlyTotal=monthlySubs.reduce((total,sub)=>total+Number(sub.plans?.monthly_price||0),0);
    const annualTotal=annualSubs.reduce((total,sub)=>total+Number(sub.plans?.annual_price||0),0);
    q('adminBillingActive').textContent=String(activeSubs.length);
    q('adminBillingActiveDetail').textContent=`${activeSubs.length===1?'Paid subscription':'Paid subscriptions'}`;
    q('adminBillingMonthlyTotal').textContent=formatAdminMoney(monthlyTotal);
    q('adminBillingMonthlyDetail').textContent=`${monthlySubs.length} monthly subscriber${monthlySubs.length===1?'':'s'}`;
    q('adminBillingAnnualTotal').textContent=formatAdminMoney(annualTotal);
    q('adminBillingAnnualDetail').textContent=`${annualSubs.length} annual subscriber${annualSubs.length===1?'':'s'}`;
    q('adminBillingMix').textContent=`${monthlySubs.length} / ${annualSubs.length}`;
    q('adminBillingMixDetail').textContent='Monthly / annual active subscribers';
    const {data:plans,error:planError}=await state.client.from('plans').select('id,name,slug,invoice_limit,monthly_price,annual_price').order('sort_order');
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
      const annualBilling=sub.billing_interval==='annual';
      const subscriptionAmount=annualBilling?plan.annual_price:plan.monthly_price;
      const billingDetail=sub.status==='active'?`${formatAdminMoney(subscriptionAmount)} / ${annualBilling?'annual':'monthly'}`:(sub.status==='trialing'?'Trial':'—');
      const periodDetail=sub.current_period_start||sub.current_period_end?`<small>Start: ${formatAdminDate(sub.current_period_start)}</small><small>End: ${formatAdminDate(sub.current_period_end)}</small>`:'—';
      tr.innerHTML=`<td><strong>${escapeHtml(b.name)}</strong>${duplicateBadge}<small>${formatAdminDate(b.created_at)}</small></td><td>${escapeHtml(owner.full_name||'')}<small>${escapeHtml(owner.email||'')}</small></td><td><select data-admin-plan="${b.id}">${(plans||[]).map(p=>`<option value="${p.id}" ${p.id===plan.id?'selected':''}>${escapeHtml(p.name)}</option>`).join('')}</select><small>${escapeHtml(billingDetail)}</small></td><td><select data-admin-status="${b.id}">${['trialing','active','past_due','suspended','canceled'].map(x=>`<option ${x===sub.status?'selected':''}>${x}</option>`).join('')}</select></td><td>${escapeHtml(billingDetail)}</td><td>${periodDetail}</td><td>${count||0} / ${sub.invoice_limit_override??plan.invoice_limit??'∞'}</td><td>${sub.trial_ends_at?formatAdminDate(sub.trial_ends_at):'—'}</td><td>${mods.join(', ')||'Finlo'}</td><td><div class="row-actions"><button class="secondary" data-admin-save="${b.id}">Save</button><button class="secondary" data-admin-modules="${b.id}" data-business-name="${escapeHtml(b.name)}">Modules</button><button class="secondary" data-admin-trial="${b.id}">+14d trial</button><button class="danger" data-admin-suspend="${b.id}" data-suspended="${sub.status==='suspended'||b.status==='suspended'?'true':'false'}">${sub.status==='suspended'||b.status==='suspended'?'Activate':'Suspend'}</button><button class="secondary" data-admin-export="${b.id}" data-business-name="${escapeHtml(b.name)}">Export</button><button class="danger" data-admin-delete="${b.id}" data-business-name="${escapeHtml(b.name)}">Delete</button></div></td>`;
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
      // Financial and payroll documents live in Supabase Storage, not Postgres.
      // Remove known tenant files first; abort database deletion if storage cleanup fails.
      try{
        const [{data:attachments,error:attachmentError},{data:employeeDocs,error:payrollDocError}]=await Promise.all([
          state.client.from('expense_attachments').select('stored_path').eq('business_id',bid),
          state.client.from('payroll_employee_documents').select('storage_path').eq('business_id',bid)
        ]);
        if(attachmentError)throw attachmentError;if(payrollDocError)throw payrollDocError;
        const cleanup=[
          {bucket:'expense-documents',paths:[...new Set((attachments||[]).map(x=>String(x.stored_path||'').trim()).filter(Boolean))]},
          {bucket:'payroll-documents',paths:[...new Set((employeeDocs||[]).map(x=>String(x.storage_path||'').trim()).filter(Boolean))]}
        ];
        for(const item of cleanup)for(let i=0;i<item.paths.length;i+=100){const {error:storageError}=await state.client.storage.from(item.bucket).remove(item.paths.slice(i,i+100));if(storageError)throw storageError;}
      }catch(storageCleanupError){
        btn.disabled=false;btn.textContent='Delete';
        alert('Could not delete the business because its stored expense/payroll documents could not be removed safely. No database account deletion was performed. '+(storageCleanupError?.message||storageCleanupError));
        return;
      }
      const {data,error}=await state.client.rpc('v36_admin_delete_business',{p_business_id:bid,p_confirmation_name:typed.trim()});
      btn.disabled=false;
      if(error){btn.textContent='Delete';alert('Could not delete account: '+error.message);return}
      alert(`${businessName}, its linked database information and stored expense/payroll documents have been permanently deleted.`);
      await renderAdmin();
    });
    const [{data:dashboardModules},{data:dashboardPlans},{data:dashboardUpdates}]=await Promise.all([state.client.from('modules').select('id,is_active'),state.client.from('plans').select('id'),state.client.from('payroll_compliance_updates').select('id,status').in('status',['review_required','draft_prepared','validated','approved'])]);
    if(q('adminModuleSummary'))q('adminModuleSummary').textContent=`${(dashboardModules||[]).filter(x=>x.is_active).length} active module${(dashboardModules||[]).filter(x=>x.is_active).length===1?'':'s'} in the current catalogue.`;
    if(q('adminPlanSummary'))q('adminPlanSummary').textContent=`${(dashboardPlans||[]).length} subscription plan${(dashboardPlans||[]).length===1?'':'s'} configured.`;
    const attention=(dashboardUpdates||[]).length;if(q('adminPayrollDashboardStatus'))q('adminPayrollDashboardStatus').textContent=attention?`${attention} official payroll update${attention===1?'':'s'} require${attention===1?'s':''} review.`:'NZ Payroll Rules — Up to date';
    renderAdminPlans();
    renderPaymentSettings();
    renderAdminModules();
    renderAdminPayrollCompliance();
    renderAdminCountryPayrollRules();
    window.Referrals?.renderAdmin?.();
  }

  function planEditorCard(p,isNew=false,availableModules=[]){
    const id=isNew?'new':p.id;
    const selected=new Set(Array.isArray(p.included_modules)&&p.included_modules.length?p.included_modules:['invoice_manager']);
    const moduleOptions=(availableModules||[]).map(m=>`<label class="tick-option plan-module-option"><input type="checkbox" data-plan-module="${id}" value="${escapeHtml(m.slug)}" ${selected.has(m.slug)?'checked':''}><span>${escapeHtml(m.name)} <small>${escapeHtml(m.slug)}</small></span></label>`).join('');
    const ap=annualPricing(p);
    const annualSet=ap.annual!=null;
    const savingPositive=annualSet&&ap.saving>0;
    const savingLabel=!annualSet?'Annual rate not set':savingPositive?(p.annual_saving_message||`Save ${Math.round(ap.pct)}% · $${ap.saving.toFixed(2)} per year`):'No annual saving';
    const annualSummary=annualSet?`$${ap.annual.toFixed(2)} / year`:'Not set';
    const equivalent=annualSet?`$${ap.equivalent.toFixed(2)} / month equivalent`:'Add an annual rate below';
    return `<div class="plan-card ${isNew?'new-plan-card':''}" data-plan-card="${id}" data-plan-existing-modules="${escapeHtml((Array.isArray(p.included_modules)?p.included_modules:[]).join(','))}">
      <div class="row-between"><span class="plan-name">${isNew?'Create new plan':escapeHtml(p.name)}</span>${!isNew?`<span class="badge">${p.is_public?'Public':'Hidden'}</span>`:''}</div>
      <div class="subscription-admin-rate-summary wide">
        <div class="subscription-admin-rate-box"><small>MONTHLY</small><strong>$${Number(p.monthly_price||0).toFixed(2)} <span>/ month</span></strong></div>
        <div class="subscription-admin-rate-box"><small>ANNUAL</small><strong>${annualSummary}</strong><span>${equivalent}</span></div>
      </div>
      <div class="wide subscription-admin-saving ${savingPositive?'has-saving':''}" data-plan-saving-highlight="${id}">${escapeHtml(savingLabel)}</div>
      <label>Name<input data-plan-name="${id}" value="${escapeHtml(p.name||'')}" placeholder="Business"></label>
      <label>Slug<input data-plan-slug="${id}" value="${escapeHtml(p.slug||'')}" placeholder="business"></label>
      <label>Description<input data-plan-description="${id}" value="${escapeHtml(p.description||'')}" placeholder="Plan description"></label>
      <label>Monthly price<input type="number" min="0" step="0.01" data-plan-price="${id}" value="${Number(p.monthly_price||0)}"></label>
      <label>Annual price<input type="number" min="0" step="0.01" data-plan-annual-price="${id}" value="${p.annual_price??''}" placeholder="Unset"></label>
      <label class="wide">Annual saving message<input data-plan-annual-message="${id}" value="${escapeHtml(p.annual_saving_message||'')}" placeholder="Leave blank for automatic saving"><small>Optional. Leave blank to automatically show the saving.</small></label>
      <div class="wide hint" data-plan-annual-preview="${id}"></div>
      <label>Invoice limit<input type="number" min="0" data-plan-limit="${id}" value="${p.invoice_limit??''}" placeholder="Blank = unlimited"></label>
      <label>Employee limit<input type="number" min="0" step="1" data-plan-employee-limit="${id}" value="${p.employee_limit??''}" placeholder="Blank = unlimited"><small>Maximum Payroll employees on this plan.</small></label>
      <label>Stripe monthly Price ID<input data-plan-stripe="${id}" value="${escapeHtml(p.stripe_price_id||'')}" placeholder="price_..."></label>
      <label>Stripe annual Price ID<input data-plan-stripe-annual="${id}" value="${escapeHtml(p.stripe_annual_price_id||'')}" placeholder="price_..."></label>
      <div class="plan-module-picker"><span class="plan-module-picker-title">Included modules</span><div class="plan-module-options">${moduleOptions||'<span class="hint">No active modules are configured.</span>'}</div></div>
      <label>Sort order<input type="number" step="1" data-plan-sort="${id}" value="${Number(p.sort_order||0)}"></label>
      <label class="tick-option"><input type="checkbox" data-plan-public="${id}" ${p.is_public?'checked':''}> <span>Visible to customers</span></label>
      <button type="button" class="${isNew?'primary':'secondary'} plan-save-button" data-plan-save="${id}">${isNew?'+ Create plan':'Save plan'}</button>
    </div>`;
  }

  async function savePlanFromCard(id){
    const root=q('adminPlanGrid'),card=root?.querySelector(`[data-plan-card="${id}"]`);if(!card)return;
    const name=card.querySelector(`[data-plan-name="${id}"]`).value.trim();
    const slug=card.querySelector(`[data-plan-slug="${id}"]`).value.trim().toLowerCase().replace(/[^a-z0-9_]+/g,'_').replace(/^_+|_+$/g,'');
    const description=card.querySelector(`[data-plan-description="${id}"]`).value.trim();
    const monthlyPrice=Number(card.querySelector(`[data-plan-price="${id}"]`).value||0);
    const av=card.querySelector(`[data-plan-annual-price="${id}"]`).value;
    const annualPrice=av===''?null:Number(av);
    const annualMessage=card.querySelector(`[data-plan-annual-message="${id}"]`).value.trim();
    const lv=card.querySelector(`[data-plan-limit="${id}"]`).value,elv=card.querySelector(`[data-plan-employee-limit="${id}"]`).value;
    const stripe=card.querySelector(`[data-plan-stripe="${id}"]`).value.trim();
    const stripeAnnual=card.querySelector(`[data-plan-stripe-annual="${id}"]`).value.trim();
    const visibleModuleSlugs=[...card.querySelectorAll(`[data-plan-module="${id}"]`)].map(x=>x.value).filter(Boolean);
    const modules=[...card.querySelectorAll(`[data-plan-module="${id}"]:checked`)].map(x=>x.value).filter(Boolean);
    const existingModules=String(card.dataset.planExistingModules||'').split(',').map(x=>x.trim()).filter(Boolean);
    if(existingModules.includes('invoice_payments')&&!visibleModuleSlugs.includes('invoice_payments'))modules.push('invoice_payments');
    const sortOrder=Number(card.querySelector(`[data-plan-sort="${id}"]`).value||0);
    const isPublic=card.querySelector(`[data-plan-public="${id}"]`).checked;
    if(!name||!slug)return alert('Plan name and slug are required.');
    if(monthlyPrice<0||annualPrice!=null&&annualPrice<0)return alert('Plan prices cannot be negative.');
    if(slug!=='trial'&&monthlyPrice>0&&isPublic&&!stripe){
      if(!confirm('This paid plan has no Stripe monthly Price ID. Customers can see it but monthly checkout will not work until you add one. Save anyway?'))return;
    }
    const btn=card.querySelector(`[data-plan-save="${id}"]`);
    const original=btn?.textContent||'Save plan';
    if(btn){btn.disabled=true;btn.classList.add('is-saving');btn.textContent=id==='new'?'Creating…':'Saving…'}
    try{
      const {error}=await state.client.rpc('v6175_admin_upsert_plan',{p_id:id==='new'?null:id,p_slug:slug,p_name:name,p_description:description||null,p_monthly_price:monthlyPrice,p_annual_price:annualPrice,p_annual_saving_message:annualMessage||null,p_invoice_limit:lv===''?null:Number(lv),p_employee_limit:elv===''?null:Number(elv),p_included_modules:modules.length?modules:['invoice_manager'],p_stripe_monthly_price_id:stripe||null,p_stripe_annual_price_id:stripeAnnual||null,p_is_public:isPublic,p_sort_order:sortOrder});
      if(error)throw error;
      if(q('adminPlanMessage')){q('adminPlanMessage').textContent=id==='new'?`${name} created.`:`${name} updated.`;q('adminPlanMessage').className='admin-inline-message success'}
      await renderAdminPlans(); await loadSignupPlans();
    }catch(error){
      if(btn){btn.disabled=false;btn.classList.remove('is-saving');btn.textContent=original}
      alert('Could not save plan: '+(error?.message||'Unknown error'));
    }
  }

  async function renderAdminPlans(){
    if(!state.profile?.is_super_admin||!q('adminPlanGrid'))return;
    const renderSequence=++adminPlanRenderSequence;
    const [{data:plans,error},{data:availableModules,error:moduleError}]=await Promise.all([
      state.client.from('plans').select('*').order('sort_order'),
      state.client.from('modules').select('id,slug,name,is_active').eq('is_active',true).order('name')
    ]);
    // A reload can overlap a save or another reload. Only the newest response
    // may replace the editor, otherwise an older response can make a saved
    // module checkbox appear to disappear intermittently.
    if(renderSequence!==adminPlanRenderSequence)return;
    if(error||moduleError){if(q('adminPlanMessage')){q('adminPlanMessage').textContent='Could not load plans: '+(error?.message||moduleError?.message||'Unknown error');q('adminPlanMessage').className='admin-inline-message error'}return}
    q('adminPlanGrid').innerHTML=planEditorCard({name:'',slug:'',description:'',monthly_price:0,annual_price:null,annual_saving_message:'',invoice_limit:null,employee_limit:null,included_modules:['invoice_manager'],stripe_price_id:null,stripe_annual_price_id:null,is_public:true,sort_order:40},true,availableModules)+(plans||[]).map(p=>planEditorCard(p,false,availableModules)).join('');

    // V61.74A: one delegated handler remains reliable after the plan grid re-renders.
    if(!q('adminPlanGrid').dataset.planHandlersBound){
      q('adminPlanGrid').dataset.planHandlersBound='1';
      q('adminPlanGrid').addEventListener('click',event=>{
        const btn=event.target.closest('[data-plan-save]');
        if(!btn||btn.disabled)return;
        event.preventDefault();
        savePlanFromCard(btn.dataset.planSave);
      });
    }

    q('adminPlanGrid').querySelectorAll('[data-plan-card]').forEach(card=>{
      const id=card.dataset.planCard,mp=card.querySelector(`[data-plan-price="${id}"]`),ap=card.querySelector(`[data-plan-annual-price="${id}"]`),msg=card.querySelector(`[data-plan-annual-message="${id}"]`),preview=card.querySelector(`[data-plan-annual-preview="${id}"]`),highlight=card.querySelector(`[data-plan-saving-highlight="${id}"]`);
      const update=()=>{
        const monthly=Number(mp?.value||0),annual=ap?.value===''?null:Number(ap?.value),normal=monthly*12,saving=annual==null?null:normal-annual,pct=normal>0&&saving>0?saving/normal*100:0,customer=(msg?.value||'').trim()||(pct>0?`Save ${Math.round(pct)}% · $${saving.toFixed(2)} per year`:'No annual saving');
        preview.textContent=annual==null?'Annual rate not set':`Annual $${annual.toFixed(2)} · $${(annual/12).toFixed(2)}/month equivalent`;
        if(highlight){highlight.textContent=annual==null?'Annual rate not set':customer;highlight.classList.toggle('has-saving',pct>0)}
      };
      [mp,ap,msg].forEach(x=>x?.addEventListener('input',update));update();
    });
  }

  async function renderAdminModules(){
    if(!state.profile?.is_super_admin||!q('adminModuleGrid'))return;
    const {data:mods}=await state.client.from('modules').select('*').order('name');
    q('adminModuleGrid').innerHTML=(mods||[]).map(m=>`<div class="plan-card"><span class="plan-name">${escapeHtml(m.name)}</span><label>Name<input data-module-name="${m.id}" value="${escapeHtml(m.name)}"></label><label>Slug<input data-module-slug="${m.id}" value="${escapeHtml(m.slug)}"></label><label>Monthly price<input type="number" step="0.01" data-module-price="${m.id}" value="${Number(m.monthly_price||0)}"></label><label>Stripe Price ID<input data-module-stripe="${m.id}" value="${escapeHtml(m.stripe_price_id||'')}" placeholder="price_..."></label><label>Description<input data-module-description="${m.id}" value="${escapeHtml(m.description||'')}"></label><label class="tick-option"><input type="checkbox" data-module-active="${m.id}" ${m.is_active?'checked':''}> Active</label><button class="secondary" data-module-save="${m.id}">Save module</button></div>`).join('');
    q('adminModuleGrid').querySelectorAll('[data-module-save]').forEach(btn=>btn.onclick=async()=>{const id=btn.dataset.moduleSave,root=q('adminModuleGrid');await state.client.from('modules').update({name:root.querySelector(`[data-module-name="${id}"]`).value.trim(),slug:root.querySelector(`[data-module-slug="${id}"]`).value.trim().toLowerCase().replace(/[^a-z0-9_]+/g,'_'),monthly_price:Number(root.querySelector(`[data-module-price="${id}"]`).value||0),stripe_price_id:root.querySelector(`[data-module-stripe="${id}"]`).value.trim()||null,description:root.querySelector(`[data-module-description="${id}"]`).value.trim(),is_active:root.querySelector(`[data-module-active="${id}"]`).checked}).eq('id',id);btn.textContent='Saved';setTimeout(()=>btn.textContent='Save module',900)});
  }

  async function addAdminModule(){
    const name=q('adminModuleName').value.trim(),slug=q('adminModuleSlug').value.trim().toLowerCase().replace(/[^a-z0-9_]+/g,'_'),description=q('adminModuleDescription').value.trim(),monthly_price=Number(q('adminModulePrice').value||0),stripe_price_id=q('adminModuleStripe').value.trim()||null;if(!name||!slug)return alert('Enter a module name and slug.');
    const {error}=await state.client.from('modules').insert({name,slug,description,monthly_price,stripe_price_id,is_active:false});if(error)return alert(error.message);['adminModuleName','adminModuleSlug','adminModuleDescription','adminModuleStripe'].forEach(id=>q(id).value='');q('adminModulePrice').value='0';renderAdminModules();
  }

  function complianceDate(v){if(!v)return '—';try{return new Date(v).toLocaleString('en-NZ',{dateStyle:'medium',timeStyle:'short'})}catch{return String(v)}}
  function complianceStatusLabel(s){return ({never_checked:'Not checked',no_change:'Up to date',change_detected:'Review required',check_error:'Check error',review_required:'Review required',draft_prepared:'Draft pending',validated:'Validated',approved:'Approved',activated:'Activated',dismissed_no_payroll_impact:'No payroll impact',draft:'Draft',active:'Active'}[s]||String(s||'—').replaceAll('_',' '))}
  async function renderAdminPayrollCompliance(){
    if(!state.profile?.is_super_admin||!q('adminPayrollComplianceStatus'))return;
    const [sr,ur,rr]=await Promise.all([state.client.from('payroll_compliance_sources').select('*').order('country_code'),state.client.from('payroll_compliance_updates').select('*').order('detected_at',{ascending:false}).limit(20),state.client.from('payroll_rulesets').select('*').order('created_at',{ascending:false}).limit(20)]);
    const err=sr.error||ur.error||rr.error;if(err){q('adminPayrollComplianceStatus').textContent='Could not load payroll compliance status: '+err.message;q('adminPayrollComplianceStatus').className='admin-inline-message error';return}
    const sources=sr.data||[],updates=ur.data||[],rulesets=rr.data||[],needs=updates.filter(x=>['review_required','draft_prepared','validated','approved'].includes(x.status));
    q('adminPayrollComplianceStatus').textContent=needs.length?`${needs.length} payroll compliance update${needs.length===1?'':'s'} require attention.`:(sources.some(x=>x.last_check_status==='check_error')?'Official source check error. Current approved payroll rules remain unchanged.':'No unreviewed official payroll source changes.');q('adminPayrollComplianceStatus').className='admin-inline-message '+(needs.length||sources.some(x=>x.last_check_status==='check_error')?'error':'success');
    q('adminPayrollComplianceSources').innerHTML=`<div class="table-scroll"><table><thead><tr><th>Country</th><th>Official source</th><th>Last checked</th><th>Status</th><th>Official reference</th></tr></thead><tbody>${sources.map(x=>`<tr><td>${escapeHtml(x.country_code)}</td><td>${escapeHtml(x.source_name)}<small>${escapeHtml(x.purpose||'')}</small></td><td>${escapeHtml(complianceDate(x.last_checked_at))}<small>${x.last_error?escapeHtml(x.last_error):''}</small></td><td>${escapeHtml(complianceStatusLabel(x.last_check_status))}</td><td>${x.last_source_reference?`<a href="${escapeHtml(x.last_source_reference)}" target="_blank" rel="noopener noreferrer">Open Official Source</a>`:`<a href="${escapeHtml(x.source_url)}" target="_blank" rel="noopener noreferrer">Open IRD</a>`}</td></tr>`).join('')||'<tr><td colspan="5">No compliance sources configured.</td></tr>'}</tbody></table></div>`;
    q('adminPayrollComplianceUpdates').innerHTML=`<h3>Detected Updates</h3><div class="table-scroll"><table><thead><tr><th>Detected</th><th>Country / Version</th><th>Status</th><th>Review</th></tr></thead><tbody>${updates.map(x=>`<tr><td>${escapeHtml(complianceDate(x.detected_at))}</td><td>${escapeHtml(x.country_code)}<small>${escapeHtml(x.source_version||'Version not identified')}</small></td><td>${escapeHtml(complianceStatusLabel(x.status))}<small>${escapeHtml(x.summary||'')}</small></td><td><div class="row-actions">${x.source_reference?`<a class="secondary compact-btn" href="${escapeHtml(x.source_reference)}" target="_blank" rel="noopener noreferrer">Official Source</a>`:''}${x.status==='review_required'?`<button class="secondary compact-btn" data-compliance-draft="${x.id}">Create Draft Ruleset</button><button class="secondary compact-btn" data-compliance-dismiss="${x.id}">No Payroll Impact</button>`:''}</div></td></tr>`).join('')||'<tr><td colspan="4">No detected official-source changes.</td></tr>'}</tbody></table></div>`;
    q('adminPayrollRulesets').innerHTML=`<h3>Rulesets</h3><div class="table-scroll"><table><thead><tr><th>Country</th><th>Ruleset</th><th>Effective</th><th>Status</th><th>Actions</th></tr></thead><tbody>${rulesets.map(x=>`<tr><td>${escapeHtml(x.country_code)}</td><td>${escapeHtml(x.name)}<small>${escapeHtml(x.version)}</small></td><td>${escapeHtml(x.effective_from)}<small>to ${escapeHtml(x.effective_to||'Open')}</small></td><td>${escapeHtml(complianceStatusLabel(x.status))}</td><td><div class="row-actions">${x.status==='draft'?`<button class="secondary compact-btn" data-ruleset-edit="${x.id}">Edit Draft</button><button class="secondary compact-btn" data-ruleset-validate="${x.id}">Validate</button>`:''}${x.status==='validated'?`<button class="secondary compact-btn" data-ruleset-approve="${x.id}">Approve</button>`:''}${x.status==='approved'?`<button class="primary compact-btn" data-ruleset-activate="${x.id}">Activate</button>`:''}</div></td></tr>`).join('')||'<tr><td colspan="5">No draft or approved rulesets yet.</td></tr>'}</tbody></table></div>`;
    q('adminPayrollComplianceUpdates').querySelectorAll('[data-compliance-draft]').forEach(b=>b.onclick=()=>createComplianceDraft(b.dataset.complianceDraft));q('adminPayrollComplianceUpdates').querySelectorAll('[data-compliance-dismiss]').forEach(b=>b.onclick=()=>dismissComplianceUpdate(b.dataset.complianceDismiss));q('adminPayrollRulesets').querySelectorAll('[data-ruleset-edit]').forEach(b=>b.onclick=()=>openRulesetEditor(b.dataset.rulesetEdit));q('adminPayrollRulesets').querySelectorAll('[data-ruleset-validate]').forEach(b=>b.onclick=()=>setRulesetStatus(b.dataset.rulesetValidate,'validated'));q('adminPayrollRulesets').querySelectorAll('[data-ruleset-approve]').forEach(b=>b.onclick=()=>setRulesetStatus(b.dataset.rulesetApprove,'approved'));q('adminPayrollRulesets').querySelectorAll('[data-ruleset-activate]').forEach(b=>b.onclick=()=>activateRuleset(b.dataset.rulesetActivate));
  }
  async function checkAdminPayrollCompliance(){const b=q('adminCheckPayrollUpdates');try{b.disabled=true;b.textContent='Checking…';const {data,error}=await state.client.functions.invoke('check-payroll-compliance-sources',{body:{}});if(error)throw error;if(data?.results?.some(x=>x.status==='check_error'))alert('Official source check completed with an error. Current approved payroll rules remain unchanged.');await renderAdminPayrollCompliance()}catch(e){alert('Could not check official payroll updates: '+(e.message||e))}finally{b.disabled=false;b.textContent='Check for Official Updates'}}
  async function createComplianceDraft(id){const name=prompt('Draft ruleset name','NZ Payroll Rules'),version=prompt('Draft version','v1.0'),from=prompt('Effective from (YYYY-MM-DD)','2027-04-01'),to=prompt('Effective to (YYYY-MM-DD, optional)','2028-03-31');if(!name||!version||!from)return;const {error}=await state.client.rpc('v6168a_create_draft_ruleset',{p_update_id:id,p_name:name,p_version:version,p_effective_from:from,p_effective_to:to||null});if(error)return alert(error.message);await renderAdminPayrollCompliance()}
  async function dismissComplianceUpdate(id){const notes=prompt('Review notes (optional)','');if(!confirm('Mark this official-source change as reviewed with no payroll impact?'))return;const {error}=await state.client.rpc('v6168a_mark_update_no_impact',{p_update_id:id,p_notes:notes||null});if(error)return alert(error.message);await renderAdminPayrollCompliance()}
  async function openRulesetEditor(id){const box=q('adminPayrollDraftEditor');const {data,error}=await state.client.from('payroll_ruleset_rules').select('*').eq('ruleset_id',id).order('rule_type').order('rule_key');if(error)return alert(error.message);box.innerHTML=`<h3>Edit Draft Rules</h3><p class="hint">These are staging values only. Saving here does not change production payroll.</p><div class="table-scroll"><table><thead><tr><th>Rule</th><th>Value</th><th>Source / note</th><th></th></tr></thead><tbody>${(data||[]).map(r=>`<tr><td>${escapeHtml(r.rule_type)}<small>${escapeHtml(r.rule_key)}</small></td><td><select data-draft-kind="${r.id}"><option value="numeric" ${r.numeric_value!=null?'selected':''}>Number</option><option value="json" ${r.json_value!=null?'selected':''}>JSON</option><option value="text" ${r.text_value!=null?'selected':''}>Text</option></select><textarea rows="2" data-draft-value="${r.id}">${escapeHtml(r.numeric_value!=null?String(r.numeric_value):r.json_value!=null?JSON.stringify(r.json_value):r.text_value||'')}</textarea></td><td><input data-draft-source="${r.id}" value="${escapeHtml(r.source_note||'')}"></td><td><button class="secondary compact-btn" data-draft-save="${r.id}">Save</button></td></tr>`).join('')}</tbody></table></div><div class="head-actions"><button class="secondary" data-draft-add="${id}">+ Add Draft Rule</button><button class="secondary" data-draft-close>Close</button></div>`;box.querySelectorAll('[data-draft-save]').forEach(b=>b.onclick=()=>saveDraftRule(b.dataset.draftSave));box.querySelector('[data-draft-add]').onclick=()=>addDraftRule(id);box.querySelector('[data-draft-close]').onclick=()=>box.innerHTML=''}
  async function saveDraftRule(id){const kind=document.querySelector(`[data-draft-kind="${id}"]`).value,raw=document.querySelector(`[data-draft-value="${id}"]`).value.trim(),source=document.querySelector(`[data-draft-source="${id}"]`).value.trim(),payload={numeric_value:null,text_value:null,json_value:null,source_note:source||null,updated_at:new Date().toISOString()};if(kind==='numeric'){const n=Number(raw);if(!Number.isFinite(n))return alert('Enter a valid number.');payload.numeric_value=n}else if(kind==='json'){try{payload.json_value=JSON.parse(raw)}catch{return alert('Enter valid JSON.')}}else payload.text_value=raw;const {error}=await state.client.from('payroll_ruleset_rules').update(payload).eq('id',id);if(error)return alert(error.message);alert('Draft rule saved. Production payroll is unchanged.')}
  async function addDraftRule(rulesetId){const type=prompt('Rule type (for example paye)');if(!type)return;const key=prompt('Rule key');if(!key)return;const kind=prompt('Value type: numeric, json or text','numeric');if(!['numeric','json','text'].includes(kind))return alert('Value type must be numeric, json or text.');const raw=prompt('Value');if(raw===null)return;const source=prompt('Official source / review note','')||'';const payload={ruleset_id:rulesetId,rule_type:type.trim().toLowerCase(),rule_key:key.trim().toLowerCase(),numeric_value:null,text_value:null,json_value:null,source_note:source||null};if(kind==='numeric'){const n=Number(raw);if(!Number.isFinite(n))return alert('Enter a valid number.');payload.numeric_value=n}else if(kind==='json'){try{payload.json_value=JSON.parse(raw)}catch{return alert('Enter valid JSON.')}}else payload.text_value=raw;const {error}=await state.client.from('payroll_ruleset_rules').insert(payload);if(error)return alert(error.message);await openRulesetEditor(rulesetId)}
  async function setRulesetStatus(id,status){const wording=status==='approved'?'Approve this validated ruleset? Approval alone does not activate it.':'Mark this Draft ruleset as validated?';if(!confirm(wording))return;const {error}=await state.client.rpc('v6168a_set_ruleset_status',{p_ruleset_id:id,p_status:status});if(error)return alert(error.message);await renderAdminPayrollCompliance()}
  async function activateRuleset(id){if(!confirm('Activate this APPROVED ruleset for production payroll according to its effective dates? This is the explicit human approval gate.'))return;const {error}=await state.client.rpc('v6168a_activate_ruleset',{p_ruleset_id:id});if(error)return alert(error.message);await Promise.all([renderAdminPayrollCompliance(),renderAdminCountryPayrollRules()])}

  function payrollRuleValue(r){if(r.numeric_value!=null)return String(r.numeric_value);if(r.json_value!=null)return JSON.stringify(r.json_value);return r.text_value??''}
  function payrollRuleValueType(r){return r.numeric_value!=null?'numeric':r.json_value!=null?'json':'text'}
  async function renderAdminCountryPayrollRules(){
    if(!state.profile?.is_super_admin||!q('adminCountryPayrollRuleRows'))return;
    const {data,error}=await state.client.from('country_payroll_rules').select('*').order('country_code').order('rule_type').order('rule_key').order('effective_from',{ascending:false});
    if(error){q('adminPayrollRuleMessage').textContent='Could not load country payroll rules: '+error.message;q('adminCountryPayrollRuleRows').innerHTML='';return}
    const countries=[...new Set((data||[]).map(r=>String(r.country_code||'').toUpperCase()).filter(Boolean))];if(!countries.includes('NZ'))countries.unshift('NZ');
    const select=q('adminPayrollRuleCountry'),selected=select.value||countries[0]||'NZ';select.innerHTML=countries.map(c=>`<option value="${escapeHtml(c)}" ${c===selected?'selected':''}>${escapeHtml(c)}</option>`).join('');
    if(q('adminPayrollRuleNewCountry')&&!q('adminPayrollRuleNewCountry').value)q('adminPayrollRuleNewCountry').value=select.value||'NZ';const country=select.value;const rows=(data||[]).filter(r=>!country||String(r.country_code).toUpperCase()===country);
    q('adminCountryPayrollRuleRows').innerHTML=rows.map(r=>`<tr data-country-rule-row="${r.id}"><td>${escapeHtml(r.country_code)}</td><td>${escapeHtml(r.rule_type)}<small>${escapeHtml(r.rule_key)}</small></td><td>${escapeHtml(r.effective_from||'')}<small>to ${escapeHtml(r.effective_to||'Open')}</small></td><td><code>${escapeHtml(payrollRuleValue(r))}</code><small>${escapeHtml(r.source_note||'')}</small></td><td><span class="status-pill ${r.active?'sent':'draft'}">${r.active?'Active':'Inactive'}</span></td><td><span class="hint">Managed via approved rulesets</span></td></tr>`).join('')||'<tr><td colspan="6">No approved production rules for this country.</td></tr>';
    q('adminPayrollRuleMessage').textContent=rows.length?`${rows.length} rule version${rows.length===1?'':'s'} shown.`:'No rules configured for this country.';
  }
  function countryRulePayload(idPrefix='adminPayrollRule'){
    const find=sel=>document.querySelector(sel),country=(idPrefix==='adminPayrollRule'?q('adminPayrollRuleNewCountry').value:find(`[data-cr-country="${idPrefix}"]`).value).trim().toUpperCase();
    const type=idPrefix==='adminPayrollRule'?q('adminPayrollRuleType').value.trim().toLowerCase():find(`[data-cr-type="${idPrefix}"]`).value.trim().toLowerCase(),key=idPrefix==='adminPayrollRule'?q('adminPayrollRuleKey').value.trim().toLowerCase():find(`[data-cr-key="${idPrefix}"]`).value.trim().toLowerCase(),from=idPrefix==='adminPayrollRule'?q('adminPayrollRuleFrom').value:find(`[data-cr-from="${idPrefix}"]`).value,to=idPrefix==='adminPayrollRule'?q('adminPayrollRuleTo').value:find(`[data-cr-to="${idPrefix}"]`).value,valueType=idPrefix==='adminPayrollRule'?q('adminPayrollRuleValueType').value:find(`[data-cr-value-type="${idPrefix}"]`).value,raw=(idPrefix==='adminPayrollRule'?q('adminPayrollRuleValue').value:find(`[data-cr-value="${idPrefix}"]`).value).trim(),source=(idPrefix==='adminPayrollRule'?q('adminPayrollRuleSource').value:find(`[data-cr-source="${idPrefix}"]`).value).trim(),active=idPrefix==='adminPayrollRule'?true:find(`[data-cr-active="${idPrefix}"]`).checked;
    if(!/^[A-Z]{2}$/.test(country))throw new Error('Country must be a 2-letter code such as NZ or AU.');if(!type||!key||!from)throw new Error('Country, rule type, rule key and effective-from date are required.');if(to&&to<from)throw new Error('Effective-to date cannot be before effective-from date.');
    const payload={country_code:country,rule_type:type,rule_key:key,effective_from:from,effective_to:to||null,numeric_value:null,text_value:null,json_value:null,active,source_note:source||null,updated_at:new Date().toISOString()};if(valueType==='numeric'){const n=Number(raw);if(!Number.isFinite(n))throw new Error('Enter a valid numeric value.');payload.numeric_value=n}else if(valueType==='json'){try{payload.json_value=JSON.parse(raw)}catch{throw new Error('JSON value is not valid JSON.')}}else payload.text_value=raw;return payload
  }
  async function addAdminCountryPayrollRule(){try{const payload=countryRulePayload();const {error}=await state.client.from('country_payroll_rules').insert({...payload,created_at:new Date().toISOString()});if(error)throw error;q('adminPayrollRuleCountry').value=payload.country_code;['adminPayrollRuleType','adminPayrollRuleKey','adminPayrollRuleFrom','adminPayrollRuleTo','adminPayrollRuleValue','adminPayrollRuleSource'].forEach(id=>q(id).value='');q('adminPayrollRuleMessage').textContent='Rule version added.';await renderAdminCountryPayrollRules()}catch(e){alert(e.message||e)}}
  async function saveAdminCountryPayrollRule(id){try{const payload=countryRulePayload(id);const {error}=await state.client.from('country_payroll_rules').update(payload).eq('id',id);if(error)throw error;q('adminPayrollRuleMessage').textContent='Rule saved.';await renderAdminCountryPayrollRules()}catch(e){alert(e.message||e)}}

  const moduleAccessCache={key:'',expires:0,promise:null,values:null};
  function clearModuleAccessCache(){moduleAccessCache.key='';moduleAccessCache.expires=0;moduleAccessCache.promise=null;moduleAccessCache.values=null}
  async function moduleAccessValues(){
    const businessId=state.business?.id||'',key=`${businessId}:${state.subscription?.id||''}`,now=Date.now();
    if(moduleAccessCache.key===key&&moduleAccessCache.values&&moduleAccessCache.expires>now)return moduleAccessCache.values;
    if(moduleAccessCache.key===key&&moduleAccessCache.promise)return moduleAccessCache.promise;
    moduleAccessCache.key=key;
    moduleAccessCache.promise=(async()=>{
      const values=new Map(),{data,error}=await state.client.from('business_modules').select('status,trial_ends_at,modules!inner(slug,is_active)').eq('business_id',businessId);
      if(!error)(data||[]).forEach(row=>{const slug=row.modules?.slug;if(!slug)return;const globallyActive=row.modules?.is_active===true;const active=globallyActive&&(row.status==='active'||(row.status==='trialing'&&(!row.trial_ends_at||new Date(row.trial_ends_at)>=new Date())));values.set(slug,active)});
      moduleAccessCache.values=values;moduleAccessCache.expires=Date.now()+15000;moduleAccessCache.promise=null;return values
    })().catch(error=>{clearModuleAccessCache();throw error});
    return moduleAccessCache.promise;
  }
  async function hasModule(slug){
    if(slug==='invoice_manager')return true;
    const values=await moduleAccessValues();
    if(values.has(slug))return values.get(slug);
    const {data:module}=await state.client.from('modules').select('is_active').eq('slug',slug).maybeSingle();
    if(module?.is_active!==true)return false;
    const sub=state.subscription||await getSubscription();
    const subscriptionActive=sub?.status==='active'||(sub?.status==='trialing'&&(!sub?.trial_ends_at||new Date(sub.trial_ends_at)>=new Date()));
    const archiveAccess=slug!=='invoice_payments'&&subscriptionReadOnly(sub);
    return (subscriptionActive||archiveAccess)&&Array.isArray(sub?.plans?.included_modules)&&sub.plans.included_modules.includes(slug);
  }

  async function invoicePaymentsRequest(body){
    const controller=new AbortController();
    const timer=setTimeout(()=>controller.abort(),15000);
    try{return await invokeAuthenticatedFunction('invoice-payments',body,controller.signal)}
    catch(error){
      const message=error?.name==='AbortError'?'Stripe payment setup timed out. Please refresh and try again.':(error?.message||'Stripe payment setup is unavailable.');
      return {data:null,error:new Error(message)}
    }finally{clearTimeout(timer)}
  }

  function invoicePaymentMoney(value,currency='NZD'){
    try{return new Intl.NumberFormat('en-NZ',{style:'currency',currency:String(currency||'NZD').toUpperCase()}).format(Number(value||0))}catch{return `${String(currency||'NZD').toUpperCase()} ${Number(value||0).toFixed(2)}`}
  }

  function invoicePaymentStatusLabel(status){return ({not_started:'Not connected',pending:'Setup in progress',active:'Ready to accept payments',restricted:'Action required',disabled:'Disabled'}[status]||human(status||'Not connected'))}

  async function renderInvoicePaymentSettings(){
    const root=q('invoicePaymentSettingsRoot');if(!root)return;
    if(state.profile?.is_super_admin===true){root.innerHTML='<div class="card"><p class="hint">Open Super Admin → Modules to enable Online Invoice Payments for this business, then grant it through a plan or business override.</p></div>';return}
    root.innerHTML='<div class="card"><p class="hint">Loading Stripe payment setup…</p></div>';
    const {data,error}=await invoicePaymentsRequest({action:'status'});
    if(error||data?.error){root.innerHTML=`<div class="card"><p class="hint">${escapeHtml(data?.error||error?.message||'Online payment setup is unavailable.')}</p></div>`;return}
    const settings=data?.settings||{};
    const accountReady=settings.connect_status==='active'&&settings.card_payments_status==='active';
    const canManage=state.accessRole==='owner';
    const requirements=Array.isArray(settings.requirements?.currently_due)?settings.requirements.currently_due:[];
    const setupLabel=!settings.stripe_account_id?'Connect Stripe and set up bank account':accountReady?'Manage Stripe account and bank details':'Continue Stripe setup';
    root.innerHTML=`<div class="card invoice-payment-settings-card"><div class="card-title"><div><h3>Stripe Connect</h3><p class="hint">Stripe collects the business identity and bank details. Frindly stores the connected-account ID and setup status only.</p></div><span class="gateway-status ${accountReady?'enabled':settings.connect_status==='restricted'?'warning':'ready'}">${escapeHtml(invoicePaymentStatusLabel(settings.connect_status))}</span></div><div class="invoice-payment-connect-summary"><div><span>Card payments</span><strong>${escapeHtml(human(settings.card_payments_status||'not_requested'))}</strong></div><div><span>Partial payments</span><strong>${settings.allow_partial_payments===false?'Off':'On'}</strong></div><div><span>Fee handling</span><strong>${settings.fee_mode==='pass'?'Pass to customer':settings.fee_mode==='split'?'Split estimate':'Business absorbs'}</strong></div></div>${requirements.length?`<div class="admin-inline-message warning">Stripe still needs: ${requirements.map(escapeHtml).join(', ')}</div>`:''}<div class="actions"><button class="primary" type="button" id="invoicePaymentConnectBtn" ${canManage?'':'disabled'}>${setupLabel}</button></div><p class="hint">The button opens Stripe’s hosted onboarding. Complete the business verification and bank-account steps there before sending invoices with Pay Now.</p></div><div class="card"><div class="card-title"><div><h3>Customer payment options</h3><p class="hint">The original invoice amount stays unchanged. Any online processing charge is shown separately at checkout.</p></div></div><div class="form-grid compact"><label>Processing fee<select id="invoicePaymentFeeMode" ${canManage?'':'disabled'}><option value="bear" ${settings.fee_mode==='bear'?'selected':''}>Business absorbs the Stripe fee</option><option value="split" ${settings.fee_mode==='split'?'selected':''}>Split the estimated fee 50 / 50</option><option value="pass" ${settings.fee_mode==='pass'?'selected':''}>Pass the estimated fee to the customer</option></select><small>Stripe’s actual fee is recorded separately; this setting controls the estimated fee shown before Checkout.</small></label><label class="tick-option"><input id="invoicePaymentPartial" type="checkbox" ${settings.allow_partial_payments!==false?'checked':''} ${canManage?'':'disabled'}><span>Allow customers to make partial payments</span></label></div><div class="actions"><button class="primary" type="button" id="saveInvoicePaymentSettings" ${canManage?'':'disabled'}>Save payment settings</button></div><p class="hint" id="invoicePaymentSettingsMessage"></p></div>`;
    q('invoicePaymentConnectBtn')?.addEventListener('click',async()=>{
      const button=q('invoicePaymentConnectBtn');if(!button||!canManage)return;button.disabled=true;button.textContent=settings.stripe_account_id?'Opening Stripe setup…':'Creating Stripe account…';
      try{
        let result;
        if(!settings.stripe_account_id){result=await invoicePaymentsRequest({action:'create-account'});if(result.error||result.data?.error)throw result.error||new Error(result.data.error);}
        result=await invoicePaymentsRequest({action:'create-account-link'});if(result.error||result.data?.error)throw result.error||new Error(result.data.error);if(!result.data?.url)throw new Error('Stripe did not return an onboarding link.');location.href=result.data.url;
      }catch(e){button.disabled=false;button.textContent=setupLabel;alert(e?.message||'Stripe setup could not be opened.')}
    });
    q('saveInvoicePaymentSettings')?.addEventListener('click',async()=>{
      const button=q('saveInvoicePaymentSettings'),messageEl=q('invoicePaymentSettingsMessage');if(!button||!canManage)return;button.disabled=true;button.textContent='Saving…';
      const {data:saveData,error:saveError}=await invoicePaymentsRequest({action:'save-settings',fee_mode:q('invoicePaymentFeeMode')?.value||'bear',allow_partial_payments:!!q('invoicePaymentPartial')?.checked});button.disabled=false;button.textContent='Save payment settings';if(saveError||saveData?.error){messageEl.textContent=saveData?.error||saveError?.message||'Could not save payment settings.';messageEl.className='hint error';return}messageEl.textContent='Payment settings saved.';messageEl.className='hint success';
    });
  }

  async function renderAdminInvoicePayments(){
    if(!state.profile?.is_super_admin||!q('adminInvoicePaymentRows'))return;
    const rowsEl=q('adminInvoicePaymentRows');rowsEl.innerHTML='<tr><td colspan="7">Loading invoice payments…</td></tr>';
    const search=String(q('adminInvoicePaymentSearch')?.value||'').trim().toLowerCase(),status=q('adminInvoicePaymentStatus')?.value||'';
    let query=state.client.from('invoice_payment_transactions').select('id,business_id,invoice_id,amount,gross_amount,customer_fee_amount,stripe_fee_amount,currency,status,payment_date,created_at,stripe_checkout_session_id,stripe_payment_intent_id,businesses(name),invoices(invoice_number,customer_name)').order('created_at',{ascending:false}).limit(500);
    if(status)query=query.eq('status',status);
    const {data,error}=await query;
    if(error){rowsEl.innerHTML=`<tr><td colspan="7">${escapeHtml(error.message||'Invoice payment monitoring is unavailable until the payment migration is applied.')}</td></tr>`;return}
    const all=data||[],filtered=search?all.filter(row=>[row.businesses?.name,row.invoices?.invoice_number,row.stripe_checkout_session_id,row.stripe_payment_intent_id].join(' ').toLowerCase().includes(search)):all;
    const succeeded=all.filter(row=>row.status==='succeeded');
    const received=succeeded.reduce((sum,row)=>sum+Number(row.gross_amount||0),0),fees=succeeded.reduce((sum,row)=>sum+Number(row.stripe_fee_amount||0),0),review=all.filter(row=>row.status==='needs_review').length;
    if(q('adminInvoicePaymentsReceived'))q('adminInvoicePaymentsReceived').textContent=invoicePaymentMoney(received);
    if(q('adminInvoicePaymentsFees'))q('adminInvoicePaymentsFees').textContent=invoicePaymentMoney(fees);
    if(q('adminInvoicePaymentsSucceeded'))q('adminInvoicePaymentsSucceeded').textContent=String(succeeded.length);
    if(q('adminInvoicePaymentsReview'))q('adminInvoicePaymentsReview').textContent=String(review);
    const date=value=>value?new Date(value).toLocaleString('en-NZ'):'—';
    rowsEl.innerHTML=filtered.map(row=>`<tr><td>${escapeHtml(row.businesses?.name||'—')}</td><td><strong>${escapeHtml(row.invoices?.invoice_number||'—')}</strong><small>${escapeHtml(row.invoices?.customer_name||'')}</small></td><td>${invoicePaymentMoney(row.amount,row.currency)}</td><td>${invoicePaymentMoney(row.customer_fee_amount,row.currency)}</td><td><span class="status-pill ${row.status==='succeeded'?'sent':row.status==='needs_review'?'error':'draft'}">${escapeHtml(invoicePaymentStatusLabel(row.status))}</span></td><td>${escapeHtml(date(row.payment_date||row.created_at))}</td><td><small>${escapeHtml(row.stripe_payment_intent_id||row.stripe_checkout_session_id||'—')}</small></td></tr>`).join('')||'<tr><td colspan="7">No invoice payments found.</td></tr>';
  }


  async function getScheduleAccess(){
    const businessId=state.business?.id||null;
    if(!businessId)return {businessId:null,entitled:false,allowed:false,role:'viewer'};
    const role=state.profile?.is_super_admin?'owner':(state.accessRole||'viewer');
    const entitled=state.profile?.is_super_admin===true||await hasModule('schedule');
    return {businessId,entitled,allowed:!!entitled&&['owner','admin'].includes(role),role};
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
    clearModuleAccessCache();
    if(biz?.status)state.business.status=biz.status;
    const locked=biz?.status==='suspended'||biz?.status==='closed'||sub?.status==='suspended';
    const lock=ensureAccountLock();
    if(locked){
      const reason=(biz?.status==='suspended'||sub?.status==='suspended')?'This business account has been suspended by the platform administrator.':'This business account is not active.';
      q('accountAccessMessage').textContent=reason+' Please contact the platform owner if you believe this is an error.';
      lock.hidden=false;document.body.classList.add('account-suspended');
    }else{lock.hidden=true;document.body.classList.remove('account-suspended')}
    if(q('scheduleNav')){
      const access=await getScheduleAccess(),{entitled,allowed}=access;
      q('scheduleNav').dataset.entitlementBlocked=entitled?'0':'1';q('scheduleNav').hidden=!allowed;
      if(!allowed && document.getElementById('view-schedule')?.classList.contains('active') && window.switchView)window.switchView('dashboard');
      window.Schedule?.setAccess?.({entitled,allowed});
    }
    if(q('jobCostingNav')){
      const entitled=await hasModule('job_costing'),allowed=entitled&&roleCanRead('core');
      q('jobCostingNav').dataset.entitlementBlocked=entitled?'0':'1';q('jobCostingNav').hidden=!allowed;
      if(!allowed && document.getElementById('view-jobcosting')?.classList.contains('active') && window.switchView)window.switchView('create');
      if(allowed)window.JobCosting?.init?.();
    }
    if(q('expensesNav')){
      const entitled=await hasModule('expenses'),allowed=entitled&&roleCanRead('expenses');
      q('expensesNav').dataset.entitlementBlocked=entitled?'0':'1';q('expensesNav').hidden=!allowed;
      if(!allowed && document.getElementById('view-expenses')?.classList.contains('active') && window.switchView)window.switchView('create');
      if(allowed)window.Expenses?.init?.();
    }
    if(q('stockEquipmentNav')){
      const entitled=await hasModule('stock_equipment'),allowed=entitled&&roleCanRead('expenses');
      q('stockEquipmentNav').dataset.entitlementBlocked=entitled?'0':'1';q('stockEquipmentNav').hidden=!allowed;
      const view=q('view-stock-equipment');if(view)view.hidden=!allowed;
      if(!allowed&&view?.classList.contains('active'))window.switchView?.('create');
      if(allowed)window.StockEquipment?.onShow?.();
    }
    if(q('payrollNav')){
      const entitled=await hasModule('payroll'),allowed=entitled&&roleCanRead('payroll');
      q('payrollNav').dataset.entitlementBlocked=entitled?'0':'1';q('payrollNav').hidden=!allowed;
      if(q('payrollReportTab'))q('payrollReportTab').hidden=!allowed;
      if(q('payrollSettingsCard'))q('payrollSettingsCard').hidden=!allowed;
      if(!allowed && document.getElementById('view-payroll')?.classList.contains('active') && window.switchView)window.switchView('create');
      if(allowed)window.Payroll?.init?.();
    }
    if(q('financialsNav')){
      const entitled=await hasModule('financials'),allowed=entitled&&roleCanRead('financials');
      q('financialsNav').dataset.entitlementBlocked=entitled?'0':'1';q('financialsNav').hidden=!allowed;
      if(q('financialSettingsCard'))q('financialSettingsCard').hidden=!allowed;
      if(!allowed && document.getElementById('view-financials')?.classList.contains('active') && window.switchView)window.switchView('create');
      if(allowed)window.Financials?.init?.();
    }
    if(q('bankReconciliationNav')){
      const entitled=await hasModule('bank_reconciliation'),allowed=entitled&&roleCanRead('bank');
      q('bankReconciliationNav').dataset.entitlementBlocked=entitled?'0':'1';q('bankReconciliationNav').hidden=!allowed;
      const view=document.getElementById('view-bankreconciliation');if(view)view.hidden=!allowed;
      if(!allowed && view?.classList.contains('active') && window.switchView)window.switchView('create');
      if(allowed)window.BankReconciliation?.init?.();
    }
    if(q('onlinePaymentsSettingsNav')){
      const entitled=await hasModule('invoice_payments'),allowed=entitled&&['owner','admin'].includes(state.profile?.is_super_admin?'owner':(state.accessRole||''));
      q('onlinePaymentsSettingsNav').dataset.entitlementBlocked=entitled?'0':'1';q('onlinePaymentsSettingsNav').hidden=!allowed;
      const panel=q('view-settings')?.querySelector('[data-settings-panel="payments"]');if(panel&&!allowed)panel.hidden=true;
      if(!allowed&&location.hash==='#settings/payments')window.openCentralSettings?.('account');
      if(allowed&&document.querySelector('[data-settings-panel="payments"]')?.hidden===false)renderInvoicePaymentSettings?.();
    }
    applyRoleAccessUI();
  }

  async function bindAfterAppLoad(){
    if(q('adminNav')) q('adminNav').onclick=openAdminPortal;
    if(q('adminBackToApp'))q('adminBackToApp').onclick=closeAdminPortal;
    if(q('saveSettings')) q('saveSettings').addEventListener('click',()=>setTimeout(()=>saveBusinessSettings(appSettings()),100));
    if(q('scheduleNav')){const access=await getScheduleAccess();q('scheduleNav').dataset.entitlementBlocked=access.entitled?'0':'1';q('scheduleNav').hidden=!access.allowed;window.Schedule?.setAccess?.(access);}
    if(q('jobCostingNav')){const entitled=state.profile?.is_super_admin||await hasModule('job_costing');q('jobCostingNav').dataset.entitlementBlocked=entitled?'0':'1';const allowed=entitled&&roleCanRead('core');q('jobCostingNav').hidden=!allowed;if(allowed)window.JobCosting?.init?.()}
    if(q('expensesNav')){const entitled=state.profile?.is_super_admin||await hasModule('expenses');q('expensesNav').dataset.entitlementBlocked=entitled?'0':'1';const allowed=entitled&&roleCanRead('expenses');q('expensesNav').hidden=!allowed;if(allowed)window.Expenses?.init?.()}
    if(q('payrollNav')){const entitled=state.profile?.is_super_admin||await hasModule('payroll');q('payrollNav').dataset.entitlementBlocked=entitled?'0':'1';const allowed=entitled&&roleCanRead('payroll');q('payrollNav').hidden=!allowed;if(allowed)window.Payroll?.init?.()}
    if(q('financialsNav')){const entitled=state.profile?.is_super_admin||await hasModule('financials');q('financialsNav').dataset.entitlementBlocked=entitled?'0':'1';const allowed=entitled&&roleCanRead('financials');q('financialsNav').hidden=!allowed;if(q('financialSettingsCard'))q('financialSettingsCard').hidden=!allowed||!roleCanWrite('financials');if(allowed)window.Financials?.init?.()}
    if(q('bankReconciliationNav')){const entitled=state.profile?.is_super_admin||await hasModule('bank_reconciliation');q('bankReconciliationNav').dataset.entitlementBlocked=entitled?'0':'1';const allowed=entitled&&roleCanRead('bank');q('bankReconciliationNav').hidden=!allowed;const view=document.getElementById('view-bankreconciliation');if(view)view.hidden=!allowed;if(allowed)window.BankReconciliation?.init?.()}
    if(q('onlinePaymentsSettingsNav')){const entitled=state.profile?.is_super_admin||await hasModule('invoice_payments');const allowed=entitled&&['owner','admin'].includes(state.profile?.is_super_admin?'owner':(state.accessRole||''));q('onlinePaymentsSettingsNav').dataset.entitlementBlocked=entitled?'0':'1';q('onlinePaymentsSettingsNav').hidden=!allowed}
    await refreshEntitlements();
    applyRoleAccessUI();
    if(typeof window.switchView==='function')window.switchView('dashboard');
    window.FinloHelper?.init?.();
    await window.FinloOnboarding?.init?.();
    let entitlementTimer=0;
    const recheck=()=>{const now=Date.now();if(now-entitlementTimer<2500)return;entitlementTimer=now;refreshEntitlements().catch(console.warn)};
    window.addEventListener('focus',recheck);
    document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')recheck()});
    // Keep infrastructure config automatic and hidden from customers.
    if(q('sSupabaseUrl'))q('sSupabaseUrl').value=C.supabaseUrl;if(q('sSupabaseKey'))q('sSupabaseKey').value=C.supabaseKey;
  }


  async function invokeAuthenticatedFunction(functionName,body,signal){
    if(!state.client)throw new Error('Email requires Supabase setup.');
    let session=null;
    try{const {data}=await state.client.auth.getSession();session=data?.session||null}catch{}
    let accessToken=session?.access_token||state.session?.access_token||'';
    if(accessToken){
      try{const {data,error}=await state.client.auth.getUser(accessToken);if(error||!data?.user)accessToken=''}catch{accessToken=''}
    }
    if(!accessToken){
      try{const {data,error}=await state.client.auth.refreshSession();if(!error&&data?.session){session=data.session;state.session=session;state.user=session.user;accessToken=session.access_token||''}}catch{}
    }
    if(!accessToken)throw new Error('Not authenticated. Please sign out and sign in again.');
    const url=`${String(C.supabaseUrl||'').replace(/\/$/,'')}/functions/v1/${encodeURIComponent(functionName)}`;
    const response=await fetch(url,{method:'POST',headers:{Authorization:`Bearer ${accessToken}`,apikey:C.supabaseKey,'Content-Type':'application/json'},body:JSON.stringify(body||{}),signal});
    let data=null;try{data=await response.clone().json()}catch{try{data={error:await response.clone().text()}}catch{data=null}}
    if(!response.ok){const err=new Error(data?.error||data?.message||`Edge Function returned ${response.status}`);err.context=response;return {data:null,error:err}}
    return {data,error:null};
  }

  function human(s){return String(s||'').replace(/_/g,' ').replace(/\b\w/g,c=>c.toUpperCase())}
  function escapeHtml(s){return String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]))}

  window.SAAS={state,config:C,client:()=>state.client,currentBusinessId:()=>state.business?.id||null,invokeAuthenticatedFunction,canCreateInvoice,refreshUsage,saveBusinessSettings,renderAdmin,showPlans,hasModule,getScheduleAccess,canWriteArea:roleCanWrite};
  init().catch(err=>{console.error(err);q('authShell')?.classList.add('open');message(err.message||'Unable to start application.','error')});
})();
