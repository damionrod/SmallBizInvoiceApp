(() => {
  const C = window.APP_CONFIG || {};
  const q = id => document.getElementById(id);
  const state = { client:null, session:null, user:null, profile:null, business:null, subscription:null, plan:null, loadedApp:false };

  function message(text, kind=''){
    const el=q('authMessage'); if(!el)return; el.textContent=text||''; el.className='auth-message '+kind;
  }
  function appSettings(){ try{return JSON.parse(localStorage.getItem('invoice_app_settings')||'{}')||{}}catch{return{}} }
  function stripInfra(s){ const x={...(s||{})}; delete x.supabaseUrl; delete x.supabaseKey; return x }
  function injectInfra(s={}){ return {...s,supabaseUrl:C.supabaseUrl||'',supabaseKey:C.supabaseKey||''} }
  function meaningfulLegacySettings(s){ return !!(s.company||s.trading||s.address||s.phone||s.email||s.gstNumber||s.logoData||((s.products||[]).some(p=>p&&p.name&&!['Service','Product','Other'].includes(p.name)))) }

  async function init(){
    document.body.classList.add('auth-locked');
    if(!C.supabaseUrl || !C.supabaseKey || !window.supabase){
      q('authShell').classList.add('open'); message('Application cloud configuration is missing.','error'); return;
    }
    state.client=window.supabase.createClient(C.supabaseUrl,C.supabaseKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
    bindAuthUI();
    const {data:{session}}=await state.client.auth.getSession();
    if(session) await enter(session); else q('authShell').classList.add('open');
    state.client.auth.onAuthStateChange(async (event,session)=>{
      if(event==='SIGNED_OUT'){location.reload();return}
      if((event==='SIGNED_IN'||event==='TOKEN_REFRESHED')&&session&&!state.loadedApp) await enter(session);
    });
  }

  function bindAuthUI(){
    document.querySelectorAll('[data-auth-tab]').forEach(btn=>btn.onclick=()=>{
      document.querySelectorAll('[data-auth-tab]').forEach(x=>x.classList.toggle('active',x===btn));
      q('loginForm').hidden=btn.dataset.authTab!=='login'; q('signupForm').hidden=btn.dataset.authTab!=='signup'; message('');
    });
    q('loginForm').onsubmit=async e=>{
      e.preventDefault(); message('Logging in…');
      const {error}=await state.client.auth.signInWithPassword({email:q('loginEmail').value.trim(),password:q('loginPassword').value});
      if(error)message(error.message,'error');
    };
    q('signupForm').onsubmit=async e=>{
      e.preventDefault(); message('Creating your account…');
      const email=q('signupEmail').value.trim();
      const {data,error}=await state.client.auth.signUp({
        email,password:q('signupPassword').value,
        options:{data:{full_name:q('signupName').value.trim(),business_name:q('signupBusiness').value.trim(),business_address:q('signupAddress').value.trim(),phone:q('signupPhone').value.trim()}}
      });
      if(error){message(error.message,'error');return}
      if(data.session){message('Account created. Loading your business…','success');await enter(data.session)}
      else message('Account created. Check your email to confirm your address, then log in.','success');
    };
    q('forgotPasswordBtn').onclick=async()=>{
      const email=q('loginEmail').value.trim(); if(!email)return message('Enter your email address first.','error');
      const {error}=await state.client.auth.resetPasswordForEmail(email,{redirectTo:location.origin});
      message(error?error.message:'Password reset email sent.',error?'error':'success');
    };
  }

  async function enter(session){
    state.session=session; state.user=session.user;
    const ok=await loadAccount(); if(!ok){q('authShell').classList.add('open');return}
    await loadBusinessSettings();
    await migrateLegacyLocalData();
    q('authShell').classList.remove('open'); document.body.classList.remove('auth-locked');
    setupAccountUI();
    if(!state.loadedApp){
      state.loadedApp=true;
      const s=document.createElement('script'); s.src='app.js?v=25'; s.onload=()=>{const j=document.createElement('script');j.src='job-costing.js?v=25';j.onload=async()=>{await bindAfterAppLoad();refreshUsage();const mw=Number(localStorage.getItem('v22_migration_warning')||0);if(mw){setTimeout(()=>alert(`${mw} existing record${mw===1?'':'s'} could not be migrated to the cloud yet. Your original browser data has not been deleted. Reload after checking the v22 database migration.`),300)}};document.body.appendChild(j)}; document.body.appendChild(s);
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
    const cloud=state.business?.settings||{}; const local=appSettings();
    let chosen=cloud;
    if(!cloud||Object.keys(cloud).length===0){
      chosen=meaningfulLegacySettings(local)?stripInfra(local):{company:state.business?.name||'',trading:state.business?.name||'',address:state.business?.address||'',phone:state.business?.phone||'',email:state.user?.email||'',invoicePrefix:'INV'};
      await state.client.from('businesses').update({settings:chosen,updated_at:new Date().toISOString()}).eq('id',state.business.id);
      state.business.settings=chosen;
    }
    localStorage.setItem('invoice_app_settings',JSON.stringify(injectInfra(chosen||{})));
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

  function setupAccountUI(){
    const initials=(state.profile.full_name||state.business.name||'A').split(/\s+/).slice(0,2).map(x=>x[0]||'').join('').toUpperCase();
    if(q('accountInitials'))q('accountInitials').textContent=initials||'A';
    if(q('adminNav'))q('adminNav').hidden=!state.profile.is_super_admin;
    if(q('accountChip'))q('accountChip').onclick=()=>{ if(window.switchView)window.switchView('settings'); else q('view-settings')?.scrollIntoView() };
    if(q('signOutBtn'))q('signOutBtn').onclick=()=>state.client.auth.signOut();
    if(q('manageSubscription'))q('manageSubscription').onclick=showPlans;
    if(q('billingPortalBtn'))q('billingPortalBtn').onclick=openBillingPortal;
    if(q('closePlanModal'))q('closePlanModal').onclick=()=>q('planModal').classList.remove('open');
    if(q('adminRefresh'))q('adminRefresh').onclick=renderAdmin;
    if(q('adminReloadPlans'))q('adminReloadPlans').onclick=renderAdminPlans;
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
    const clean=stripInfra(s); const {error}=await state.client.from('businesses').update({settings:clean,name:clean.company||clean.trading||state.business.name,address:clean.address||state.business.address,phone:clean.phone||state.business.phone,updated_at:new Date().toISOString()}).eq('id',state.business.id);
    if(!error){state.business.settings=clean;return true} console.warn('Business settings cloud sync failed',error);return false;
  }

  async function openBillingPortal(){
    const {data,error}=await state.client.functions.invoke('create-portal',{body:{returnUrl:location.origin}});
    if(error||!data?.url)return alert(error?.message||data?.error||'Billing portal is not available yet.');
    location.href=data.url;
  }

  async function showPlans(){
    const {data:plans}=await state.client.from('plans').select('*').eq('is_public',true).order('sort_order'); await getSubscription();
    const root=q('customerPlanGrid'); root.innerHTML=(plans||[]).map(p=>`<div class="plan-card ${state.plan?.id===p.id?'current':''}"><span class="plan-name">${escapeHtml(p.name)}</span><strong>$${Number(p.monthly_price||0).toFixed(0)}<small>/month</small></strong><p>${escapeHtml(p.description||'')}</p><div class="plan-limit">${p.invoice_limit==null?'Unlimited':p.invoice_limit} invoices / period</div><div class="plan-modules">${(p.included_modules||[]).map(m=>`<span>${escapeHtml(human(m))}</span>`).join('')}</div><button class="${state.plan?.id===p.id?'secondary':'primary'}" data-choose-plan="${p.slug}" ${state.plan?.id===p.id?'disabled':''}>${state.plan?.id===p.id?'Current plan':'Choose '+escapeHtml(p.name)}</button></div>`).join('');
    root.querySelectorAll('[data-choose-plan]').forEach(b=>b.onclick=()=>startCheckout(b.dataset.choosePlan,b)); q('planModal').classList.add('open');
  }

  async function startCheckout(slug,btn){
    btn.disabled=true;btn.textContent='Opening checkout…';
    const {data,error}=await state.client.functions.invoke('create-checkout',{body:{planSlug:slug,returnUrl:location.origin}});
    if(error||!data?.url){btn.disabled=false;btn.textContent='Choose plan';alert((error?.message||data?.error||'Billing is not configured yet.')+'\n\nThe SaaS app is ready; configure Stripe keys and price IDs to activate purchases.');return}
    location.href=data.url;
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
    const [{data:mods},{data:enabled}]=await Promise.all([state.client.from('modules').select('*').order('name'),state.client.from('business_modules').select('module_id,status').eq('business_id',businessId)]);
    const on=new Map((enabled||[]).map(x=>[x.module_id,x.status]));q('moduleModal').dataset.businessId=businessId;q('moduleBusinessName').textContent=businessName;
    q('moduleChecklist').innerHTML=(mods||[]).map(m=>`<label class="module-toggle"><span><strong>${escapeHtml(m.name)}</strong><small>${escapeHtml(m.description||'')}</small></span><input type="checkbox" data-module-id="${m.id}" ${['active','trialing'].includes(on.get(m.id))?'checked':''}></label>`).join('')||'<p>No modules have been configured yet.</p>';
    q('moduleModal').classList.add('open');
  }

  async function saveBusinessModules(){
    const bid=q('moduleModal').dataset.businessId;if(!bid)return;const boxes=[...q('moduleChecklist').querySelectorAll('[data-module-id]')];
    for(const box of boxes){if(box.checked)await state.client.from('business_modules').upsert({business_id:bid,module_id:box.dataset.moduleId,status:'active'},{onConflict:'business_id,module_id'});else await state.client.from('business_modules').delete().eq('business_id',bid).eq('module_id',box.dataset.moduleId)}
    q('moduleModal').classList.remove('open');await renderAdmin();
  }

  async function renderAdmin(){
    if(!state.profile?.is_super_admin)return;
    const {data:businesses,error}=await state.client.from('businesses').select('id,name,status,created_at,profiles(id,full_name,email,role),subscriptions(id,status,trial_ends_at,current_period_start,current_period_end,invoice_limit_override,plans(id,name,slug,invoice_limit)),business_modules(status,modules(slug,name))').order('created_at',{ascending:false});
    if(error){console.warn(error);return}
    const qtxt=(q('adminSearch')?.value||'').toLowerCase(),sf=q('adminStatusFilter')?.value||'';
    let rows=(businesses||[]).filter(b=>{const owner=(b.profiles||[]).find(p=>p.role==='owner')||b.profiles?.[0]||{};const sub=b.subscriptions?.[0]||{};return(!qtxt||[b.name,owner.full_name,owner.email].join(' ').toLowerCase().includes(qtxt))&&(!sf||sub.status===sf)});
    q('adminBusinessCount').textContent=(businesses||[]).length;q('adminUserCount').textContent=(businesses||[]).reduce((n,b)=>n+(b.profiles?.length||0),0);q('adminActiveCount').textContent=(businesses||[]).filter(b=>b.subscriptions?.[0]?.status==='active').length;q('adminTrialCount').textContent=(businesses||[]).filter(b=>b.subscriptions?.[0]?.status==='trialing').length;
    const {data:plans}=await state.client.from('plans').select('id,name,slug,invoice_limit').order('sort_order');
    const body=q('adminBusinessRows'); body.innerHTML='';
    for(const b of rows){
      const owner=(b.profiles||[]).find(p=>p.role==='owner')||b.profiles?.[0]||{}, sub=b.subscriptions?.[0]||{}, plan=sub.plans||{}, mods=(b.business_modules||[]).filter(x=>x.status==='active'||x.status==='trialing').map(x=>x.modules?.name).filter(Boolean);
      let countQ=state.client.from('invoices').select('id',{count:'exact',head:true}).eq('business_id',b.id);if(sub.current_period_start)countQ=countQ.gte('created_at',sub.current_period_start);if(sub.current_period_end)countQ=countQ.lt('created_at',sub.current_period_end);const {count}=await countQ;
      const tr=document.createElement('tr'); tr.innerHTML=`<td><strong>${escapeHtml(b.name)}</strong><small>${new Date(b.created_at).toLocaleDateString()}</small></td><td>${escapeHtml(owner.full_name||'')}<small>${escapeHtml(owner.email||'')}</small></td><td><select data-admin-plan="${b.id}">${(plans||[]).map(p=>`<option value="${p.id}" ${p.id===plan.id?'selected':''}>${escapeHtml(p.name)}</option>`).join('')}</select></td><td><select data-admin-status="${b.id}">${['trialing','active','past_due','suspended','canceled'].map(x=>`<option ${x===sub.status?'selected':''}>${x}</option>`).join('')}</select></td><td>${count||0} / ${sub.invoice_limit_override??plan.invoice_limit??'∞'}</td><td>${sub.trial_ends_at?new Date(sub.trial_ends_at).toLocaleDateString():'—'}</td><td>${mods.join(', ')||'Invoice Manager'}</td><td><div class="row-actions"><button class="secondary" data-admin-save="${b.id}" data-sub="${sub.id||''}">Save</button><button class="secondary" data-admin-modules="${b.id}" data-business-name="${escapeHtml(b.name)}">Modules</button><button class="secondary" data-admin-trial="${b.id}" data-sub="${sub.id||''}">+14d trial</button><button class="danger" data-admin-suspend="${b.id}" data-sub="${sub.id||''}">${sub.status==='suspended'?'Activate':'Suspend'}</button></div></td>`; body.appendChild(tr);
    }
    body.querySelectorAll('[data-admin-save]').forEach(btn=>btn.onclick=async()=>{const bid=btn.dataset.adminSave,sid=btn.dataset.sub,planId=body.querySelector(`[data-admin-plan="${bid}"]`).value,status=body.querySelector(`[data-admin-status="${bid}"]`).value;await state.client.from('subscriptions').update({plan_id:planId,status,updated_at:new Date().toISOString()}).eq('id',sid);btn.textContent='Saved';setTimeout(()=>btn.textContent='Save',900)});
    body.querySelectorAll('[data-admin-modules]').forEach(btn=>btn.onclick=()=>openModuleManager(btn.dataset.adminModules,btn.dataset.businessName));
    body.querySelectorAll('[data-admin-trial]').forEach(btn=>btn.onclick=async()=>{const d=new Date();d.setDate(d.getDate()+14);await state.client.from('subscriptions').update({status:'trialing',trial_ends_at:d.toISOString(),current_period_start:new Date().toISOString(),current_period_end:d.toISOString(),updated_at:new Date().toISOString()}).eq('id',btn.dataset.sub);renderAdmin()});
    body.querySelectorAll('[data-admin-suspend]').forEach(btn=>btn.onclick=async()=>{const current=body.querySelector(`[data-admin-status="${btn.dataset.adminSuspend}"]`)?.value;await state.client.from('subscriptions').update({status:current==='suspended'?'active':'suspended',updated_at:new Date().toISOString()}).eq('id',btn.dataset.sub);renderAdmin()});
    renderAdminPlans();
    renderAdminModules();
  }

  async function renderAdminPlans(){
    if(!state.profile?.is_super_admin||!q('adminPlanGrid'))return;const {data:plans}=await state.client.from('plans').select('*').order('sort_order');
    q('adminPlanGrid').innerHTML=(plans||[]).map(p=>`<div class="plan-card"><span class="plan-name">${escapeHtml(p.name)}</span><label>Monthly price<input type="number" step="0.01" data-plan-price="${p.id}" value="${Number(p.monthly_price||0)}"></label><label>Invoice limit<input type="number" min="0" data-plan-limit="${p.id}" value="${p.invoice_limit??''}" placeholder="Blank = unlimited"></label><label>Stripe Price ID<input data-plan-stripe="${p.id}" value="${escapeHtml(p.stripe_price_id||'')}" placeholder="price_..."></label><label>Included modules<input data-plan-modules="${p.id}" value="${escapeHtml((p.included_modules||[]).join(', '))}" placeholder="invoice_manager, job_costing"></label><button class="secondary" data-plan-save="${p.id}">Save plan</button></div>`).join('');
    q('adminPlanGrid').querySelectorAll('[data-plan-save]').forEach(btn=>btn.onclick=async()=>{const id=btn.dataset.planSave,price=Number(q('adminPlanGrid').querySelector(`[data-plan-price="${id}"]`).value||0),lv=q('adminPlanGrid').querySelector(`[data-plan-limit="${id}"]`).value,stripe=q('adminPlanGrid').querySelector(`[data-plan-stripe="${id}"]`).value.trim(),mods=q('adminPlanGrid').querySelector(`[data-plan-modules="${id}"]`).value.split(',').map(x=>x.trim()).filter(Boolean);await state.client.from('plans').update({monthly_price:price,invoice_limit:lv===''?null:Number(lv),stripe_price_id:stripe||null,included_modules:mods,updated_at:new Date().toISOString()}).eq('id',id);btn.textContent='Saved';setTimeout(()=>btn.textContent='Save plan',900)});
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
    if(data&&['active','trialing'].includes(data.status))return true;
    const sub=state.subscription||await getSubscription();
    return Array.isArray(sub?.plans?.included_modules)&&sub.plans.included_modules.includes(slug);
  }

  async function bindAfterAppLoad(){
    if(q('adminNav')) q('adminNav').onclick=()=>{ if(window.switchView)window.switchView('admin'); renderAdmin() };
    if(q('saveSettings')) q('saveSettings').addEventListener('click',()=>setTimeout(()=>saveBusinessSettings(appSettings()),100));
    if(q('jobCostingNav')){const allowed=state.profile?.is_super_admin||await hasModule('job_costing');q('jobCostingNav').hidden=!allowed;if(allowed)window.JobCosting?.init?.()}
    // Keep infrastructure config automatic and hidden from customers.
    if(q('sSupabaseUrl'))q('sSupabaseUrl').value=C.supabaseUrl;if(q('sSupabaseKey'))q('sSupabaseKey').value=C.supabaseKey;
  }

  function human(s){return String(s||'').replace(/_/g,' ').replace(/\b\w/g,c=>c.toUpperCase())}
  function escapeHtml(s){return String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]))}

  window.SAAS={state,client:()=>state.client,canCreateInvoice,refreshUsage,saveBusinessSettings,renderAdmin,showPlans,hasModule};
  init().catch(err=>{console.error(err);q('authShell')?.classList.add('open');message(err.message||'Unable to start application.','error')});
})();
