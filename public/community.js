(()=>{'use strict';
if(window.Community)return;
const $=id=>document.getElementById(id),core=()=>window.FinloCore||{},esc=v=>(core().text?.escapeHtml?core().text.escapeHtml(v):String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]))),toast=(m,o)=>core().ui?.toast?core().ui.toast(m,o):alert(m);
const state={ready:false,loading:false,profile:null,posts:[],comments:{},ads:[],packages:[],admin:false,activePost:null,conversation:null,filters:{region:'',industry:'',category:''}};
const categories=[['need_workers','Need Workers'],['business_advice','Business Advice'],['recommendation','Recommendation'],['equipment_supplies','Equipment / Supplies'],['general','General Discussion']];
const placements=[['top','Top strip'],['feed','Feed card'],['sidebar','Sidebar'],['inbox','Inbox']];
function client(){return window.SAAS?.client?.()}
function biz(){return window.SAAS?.state?.business}
function user(){return window.SAAS?.state?.user}
function isAdmin(){return window.SAAS?.state?.profile?.is_super_admin===true}
function money(v,c='NZD'){try{return new Intl.NumberFormat('en-NZ',{style:'currency',currency:c}).format(Number(v||0))}catch{return `${c} ${Number(v||0).toFixed(2)}`}}
function today(){return new Date().toISOString().slice(0,10)}
function catLabel(v){return (categories.find(x=>x[0]===v)||[])[1]||'General Discussion'}
function placeLabel(v){return (placements.find(x=>x[0]===v)||[])[1]||v}
function defaultName(){const b=biz(),u=user();return String(b?.settings?.trading||b?.name||u?.user_metadata?.full_name||'Frindly Member').slice(0,60)}
function publicName(p=state.profile){return p?.display_name||defaultName()}
function region(){return state.profile?.region||biz()?.settings?.region||biz()?.address?.split(',').pop()?.trim()||''}
function industry(){return state.profile?.industry||biz()?.settings?.industry||''}
async function ensureProfile(){
  if(!client()||!biz()?.id||!user()?.id)return null;
  let {data,error}=await client().from('community_profiles').select('*').eq('user_id',user().id).eq('business_id',biz().id).maybeSingle();
  if(error&&error.code!=='42P01')throw error;
  if(error?.code==='42P01')throw new Error('Community tables are not installed yet. Run the V61.106 Community Supabase migration first.');
  if(!data){
    const row={user_id:user().id,business_id:biz().id,display_name:defaultName(),region:region(),industry:industry(),show_business_name:true,show_region:true,show_industry:true,private_messages_enabled:true};
    const res=await client().from('community_profiles').insert(row).select('*').single();
    if(res.error)throw res.error;data=res.data;
  }
  state.profile=data;return data;
}
function activeFilters(){const f=state.filters;return {region:f.region||region(),industry:f.industry||'',category:f.category||''}}
async function load(){
  if(state.loading)return;state.loading=true;
  try{
    await ensureProfile();
    const f=activeFilters();
    let q=client().from('community_posts').select('*,community_profiles(display_name,show_business_name,show_region,show_industry,region,industry,business_id,businesses(name))').eq('status','active').order('created_at',{ascending:false}).limit(50);
    if(f.region)q=q.or(`region.eq.${f.region},region.is.null`);
    if(f.industry)q=q.eq('industry',f.industry);
    if(f.category)q=q.eq('category',f.category);
    const [{data:posts,error:postError},{data:ads,error:adError},{data:packages,error:packageError}]=await Promise.all([q,eligibleAds(),client().from('community_ad_packages').select('*').eq('active',true).order('price')]);
    if(postError)throw postError;if(adError)throw adError;if(packageError)throw packageError;
    state.posts=posts||[];state.ads=ads||[];state.packages=packages||[];await loadCommentCounts();render();
  }catch(e){renderError(e.message||e)}finally{state.loading=false}
}
async function eligibleAds(){
  const f=activeFilters(),now=new Date().toISOString();
  let q=client().from('community_ad_campaigns').select('*').eq('status','active').lte('starts_at',now).gte('ends_at',now).order('priority',{ascending:false}).order('updated_at',{ascending:false});
  if(f.region)q=q.or(`target_region.eq.${f.region},target_region.is.null`);
  if(f.industry)q=q.or(`target_industry.eq.${f.industry},target_industry.is.null`);
  return q.limit(20);
}
async function loadCommentCounts(){
  state.comments={};if(!state.posts.length)return;
  const ids=state.posts.map(p=>p.id);
  const {data}=await client().from('community_comments').select('post_id,id').in('post_id',ids).eq('status','active');
  (data||[]).forEach(x=>state.comments[x.post_id]=(state.comments[x.post_id]||0)+1);
}
function adFor(place,offset=0){const rows=state.ads.filter(a=>a.placement===place);return rows.length?rows[offset%rows.length]:null}
async function recordAd(id,kind){
  if(!id||!client())return;
  await client().from(kind==='click'?'community_ad_clicks':'community_ad_impressions').insert({campaign_id:id,business_id:biz()?.id||null,user_id:user()?.id||null}).select('id').maybeSingle().catch?.(()=>{});
}
function adCard(a,cls=''){
  if(!a)return '';
  setTimeout(()=>recordAd(a.id,'impression'),0);
  return `<article class="community-ad ${cls}"><span>Sponsored</span><div><strong>${esc(a.title)}</strong><p>${esc(a.body||'')}</p></div>${a.sponsor_name?`<b>${esc(a.sponsor_name)}</b>`:''}${a.destination_url?`<button class="primary compact-btn" data-community-ad-click="${esc(a.id)}">Learn More</button>`:''}</article>`;
}
function authorLabel(p){
  const cp=p.community_profiles||{},business=cp.show_business_name?cp.businesses?.name:'';
  const bits=[];if(cp.show_region&&cp.region)bits.push(cp.region);if(cp.show_industry&&cp.industry)bits.push(cp.industry);
  return `<strong>${esc(cp.display_name||'Frindly Member')}</strong>${business?`<small>${esc(business)}</small>`:''}<em>${esc(bits.join(' | '))}</em>`;
}
function postCard(p,i){
  const ad=i===2?adCard(adFor('feed'),'feed-ad'):'';
  return `${ad}<article class="community-post" data-post="${esc(p.id)}"><div class="community-post-head"><div class="community-avatar">${esc(String(p.community_profiles?.display_name||'F').slice(0,2).toUpperCase())}</div><div>${authorLabel(p)}</div><span class="community-badge">${esc(catLabel(p.category))}</span></div><h3>${esc(p.title||'Community post')}</h3><p>${esc(p.body||'')}</p><div class="community-post-actions"><button class="secondary compact-btn" data-community-comment="${esc(p.id)}">Reply publicly</button><span>${state.comments[p.id]||0} replies</span><button class="secondary compact-btn" data-community-message="${esc(p.author_profile_id)}">Message privately</button><button class="secondary compact-btn" data-community-report-post="${esc(p.id)}">Report</button></div><div class="community-comments" id="community-comments-${esc(p.id)}" hidden></div></article>`;
}
function render(){
  const root=$('communityRoot');if(!root)return;
  const top=adFor('top'),side=state.ads.filter(a=>a.placement==='sidebar').slice(0,2);
  root.innerHTML=`<div class="page-head community-head"><div><h1>Frindly Community</h1><p>Connect with other Frindly businesses near you.</p></div><div class="head-actions"><button class="secondary" data-community-open-inbox>Messages</button><button class="secondary" data-community-refresh>Refresh</button></div></div>
    <div class="community-filterbar card"><label>Search<input id="communitySearch" placeholder="Search posts, keywords or businesses"></label><label>Region<input id="communityRegionFilter" value="${esc(state.filters.region||region())}" placeholder="All regions"></label><label>Industry<input id="communityIndustryFilter" value="${esc(state.filters.industry)}" placeholder="All industries"></label><label>Post Type<select id="communityCategoryFilter"><option value="">All posts</option>${categories.map(c=>`<option value="${c[0]}" ${state.filters.category===c[0]?'selected':''}>${c[1]}</option>`).join('')}</select></label><button class="primary" data-community-apply>Apply</button></div>
    ${adCard(top,'top-ad')}
    <div class="community-layout"><main><section class="card community-composer"><div class="community-compose-top"><strong>Post to the community</strong><select id="communityPostAs"><option>${esc(publicName())}</option></select><span>Business name: ${state.profile?.show_business_name?'On':'Off'}</span><span>Text only</span></div><div class="form-grid compact"><label>Post type<select id="communityPostCategory">${categories.map(c=>`<option value="${c[0]}">${c[1]}</option>`).join('')}</select></label><label>Title<input id="communityPostTitle" maxlength="140" placeholder="What do you want to ask or share?"></label><label class="wide">Message<textarea id="communityPostBody" rows="3" maxlength="2000" placeholder="Share a question, opportunity or update with the community..."></textarea></label></div><div class="actions"><button class="primary" data-community-post>Post</button></div></section>${state.posts.map(postCard).join('')||'<div class="card"><p class="hint">No community posts match these filters yet.</p></div>'}</main><aside><section class="card community-sidebar"><h3>Sponsored Partners</h3>${side.map(a=>adCard(a,'side-ad')).join('')||'<p class="hint">No active sponsor banners for this view.</p>'}</section>${profileCard()}${sponsorCard()}<section class="card"><h3>Community Guidelines</h3><p class="hint">Be respectful, keep posts relevant, and support other small businesses. Posts and private messages are text-only.</p></section></aside></div>`;
  bind();
}
function profileCard(){return `<section class="card community-profile-card"><h3>Community Profile</h3><label>Display name<input id="communityDisplayName" maxlength="60" value="${esc(state.profile?.display_name||defaultName())}"></label><label>Region<input id="communityProfileRegion" maxlength="80" value="${esc(state.profile?.region||'')}"></label><label>Industry<input id="communityProfileIndustry" maxlength="80" value="${esc(state.profile?.industry||'')}"></label><label class="tick-option"><input id="communityShowBusiness" type="checkbox" ${state.profile?.show_business_name?'checked':''}><span>Show business name</span></label><label class="tick-option"><input id="communityPmEnabled" type="checkbox" ${state.profile?.private_messages_enabled?'checked':''}><span>Allow private messages</span></label><button class="secondary" data-community-save-profile>Save community profile</button></section>`}
function sponsorCard(){return `<section class="card community-sponsor-card"><h3>Promote in Community</h3><p class="hint">Paid banners appear only on the Frindly Community screen and require admin approval after Stripe payment.</p>${state.packages.length?`<label>Package<select id="communityBannerPackage">${state.packages.map(p=>`<option value="${p.id}">${esc(p.name)} - ${money(p.price,p.currency)} / ${p.duration_days} days</option>`).join('')}</select></label><label>Sponsor name<input id="communityBannerSponsor" maxlength="120" value="${esc(biz()?.name||'')}"></label><label>Banner title<input id="communityBannerTitle" maxlength="140"></label><label>Message<input id="communityBannerMessage" maxlength="500"></label><label>Website link<input id="communityBannerUrl" placeholder="https://"></label><button class="secondary" data-community-buy-banner>Pay with Stripe</button>`:'<p class="hint">No banner packages are active yet.</p>'}</section>`}
function renderError(msg){const root=$('communityRoot');if(root)root.innerHTML=`<div class="page-head"><div><h1>Frindly Community</h1><p>Connect with other Frindly businesses near you.</p></div></div><div class="notice">${esc(msg)}</div>`}
function bind(){
  const root=$('communityRoot');if(!root)return;
  root.querySelector('[data-community-refresh]')?.addEventListener('click',load);
  root.querySelector('[data-community-apply]')?.addEventListener('click',()=>{state.filters.region=$('communityRegionFilter').value.trim();state.filters.industry=$('communityIndustryFilter').value.trim();state.filters.category=$('communityCategoryFilter').value;load()});
  root.querySelector('[data-community-post]')?.addEventListener('click',savePost);
  root.querySelector('[data-community-save-profile]')?.addEventListener('click',saveProfile);
  root.querySelector('[data-community-open-inbox]')?.addEventListener('click',openInbox);
  root.querySelector('[data-community-buy-banner]')?.addEventListener('click',buyBanner);
  root.querySelectorAll('[data-community-comment]').forEach(b=>b.onclick=()=>toggleComments(b.dataset.communityComment));
  root.querySelectorAll('[data-community-message]').forEach(b=>b.onclick=()=>startMessage(b.dataset.communityMessage));
  root.querySelectorAll('[data-community-report-post]').forEach(b=>b.onclick=()=>report('post',b.dataset.communityReportPost));
  root.querySelectorAll('[data-community-ad-click]').forEach(b=>b.onclick=async()=>{const a=state.ads.find(x=>x.id===b.dataset.communityAdClick);await recordAd(a?.id,'click');if(a?.destination_url)window.open(a.destination_url,'_blank','noopener,noreferrer')});
}
async function saveProfile(){
  const patch={display_name:$('communityDisplayName').value.trim()||defaultName(),region:$('communityProfileRegion').value.trim(),industry:$('communityProfileIndustry').value.trim(),show_business_name:$('communityShowBusiness').checked,private_messages_enabled:$('communityPmEnabled').checked,updated_at:new Date().toISOString()};
  const {data,error}=await client().from('community_profiles').update(patch).eq('id',state.profile.id).select('*').single();
  if(error)return toast(error.message,{error:true});state.profile=data;toast('Community profile saved.');render();
}
async function savePost(){
  const title=$('communityPostTitle').value.trim(),body=$('communityPostBody').value.trim();
  if(!title||!body)return toast('Add a title and message.',{error:true});
  const row={author_profile_id:state.profile.id,business_id:biz().id,title,body,category:$('communityPostCategory').value,region:state.profile.region||null,industry:state.profile.industry||null,status:'active'};
  const {error}=await client().from('community_posts').insert(row);if(error)return toast(error.message,{error:true});
  toast('Posted to the community.');await load();
}
async function buyBanner(){
  const body={packageId:$('communityBannerPackage')?.value,sponsorName:$('communityBannerSponsor')?.value,title:$('communityBannerTitle')?.value,message:$('communityBannerMessage')?.value,destinationUrl:$('communityBannerUrl')?.value,targetRegion:state.profile?.region||'',targetIndustry:state.profile?.industry||'',returnUrl:location.origin+location.pathname+'#community'};
  if(!body.packageId||!body.sponsorName||!body.title||!body.destinationUrl)return toast('Choose a package and enter sponsor, title and website link.',{error:true});
  try{
    const {data,error}=await client().functions.invoke('create-community-ad-checkout',{body});
    if(error||data?.error)throw new Error(data?.error||error?.message||'Could not open Stripe checkout.');
    location.href=data.url;
  }catch(e){toast(e.message||e,{error:true})}
}
async function toggleComments(id){
  const box=$(`community-comments-${id}`);if(!box)return;
  if(!box.hidden){box.hidden=true;return}
  const {data,error}=await client().from('community_comments').select('*,community_profiles(display_name,show_business_name,show_region,show_industry,region,industry,business_id,businesses(name))').eq('post_id',id).eq('status','active').order('created_at');
  if(error)return toast(error.message,{error:true});
  box.hidden=false;box.innerHTML=`<div class="community-comment-list">${(data||[]).map(c=>`<div class="community-comment"><div>${authorLabel(c)}</div><p>${esc(c.body)}</p><button class="secondary compact-btn" data-community-report-comment="${esc(c.id)}">Report</button></div>`).join('')||'<p class="hint">No public replies yet.</p>'}</div><div class="community-comment-compose"><textarea rows="2" maxlength="1200" placeholder="Reply publicly..."></textarea><button class="primary compact-btn">Reply publicly</button></div>`;
  box.querySelector('button.primary').onclick=async()=>{const body=box.querySelector('textarea').value.trim();if(!body)return;const {error}=await client().from('community_comments').insert({post_id:id,author_profile_id:state.profile.id,body,status:'active'});if(error)return toast(error.message,{error:true});await toggleComments(id);await toggleComments(id);await loadCommentCounts();};
  box.querySelectorAll('[data-community-report-comment]').forEach(b=>b.onclick=()=>report('comment',b.dataset.communityReportComment));
}
async function startMessage(profileId){
  if(!profileId||profileId===state.profile.id)return toast('Choose another community member to message.',{error:true});
  const {data,error}=await client().from('community_conversations').insert({created_by_profile_id:state.profile.id,participant_profile_ids:[state.profile.id,profileId],status:'active'}).select('*').single();
  if(error&&error.code!=='23505')return toast(error.message,{error:true});
  const conversation=data||await findConversation(profileId);openConversation(conversation);
}
async function findConversation(profileId){
  const {data}=await client().from('community_conversations').select('*').contains('participant_profile_ids',[state.profile.id,profileId]).limit(1).maybeSingle();
  return data;
}
async function openInbox(){
  const {data,error}=await client().from('community_conversations').select('*').contains('participant_profile_ids',[state.profile.id]).order('updated_at',{ascending:false}).limit(30);
  if(error)return toast(error.message,{error:true});
  modal('Community Messages',`<div class="community-inbox">${(data||[]).map(c=>`<button class="secondary" data-open-conversation="${esc(c.id)}">Conversation started ${new Date(c.created_at).toLocaleDateString()}</button>`).join('')||'<p class="hint">No private messages yet.</p>'}</div>`);
  document.querySelectorAll('[data-open-conversation]').forEach(b=>b.onclick=async()=>{const {data}=await client().from('community_conversations').select('*').eq('id',b.dataset.openConversation).single();openConversation(data)});
}
async function openConversation(c){
  if(!c)return;state.conversation=c;
  const {data,error}=await client().from('community_messages').select('*,community_profiles(display_name)').eq('conversation_id',c.id).eq('status','active').order('created_at');
  if(error)return toast(error.message,{error:true});
  modal('Private message',`<div class="community-message-thread">${(data||[]).map(m=>`<div class="community-message ${m.author_profile_id===state.profile.id?'mine':''}"><strong>${esc(m.community_profiles?.display_name||'Member')}</strong><p>${esc(m.body)}</p><button class="secondary compact-btn" data-community-report-message="${esc(m.id)}">Report</button></div>`).join('')||'<p class="hint">Start the conversation. Messages stay inside Frindly.</p>'}</div><div class="community-comment-compose"><textarea id="communityPrivateMessage" rows="3" maxlength="1200" placeholder="Text-only private message..."></textarea><button class="primary" data-send-private-message>Send</button></div>`);
  document.querySelector('[data-send-private-message]').onclick=sendPrivateMessage;
  document.querySelectorAll('[data-community-report-message]').forEach(b=>b.onclick=()=>report('message',b.dataset.communityReportMessage));
}
async function sendPrivateMessage(){
  const body=$('communityPrivateMessage').value.trim();if(!body)return;
  const {error}=await client().from('community_messages').insert({conversation_id:state.conversation.id,author_profile_id:state.profile.id,body,status:'active'});
  if(error)return toast(error.message,{error:true});openConversation(state.conversation);
}
async function report(kind,id){
  const reason=prompt('Why are you reporting this?','');if(reason===null)return;
  const {error}=await client().from('community_reports').insert({reporter_profile_id:state.profile.id,target_type:kind,target_id:id,reason,status:'open'});
  if(error)return toast(error.message,{error:true});toast('Thanks. The Frindly team will review this.');
}
function modal(title,body){
  const m=$('invoiceModal'),c=$('modalContent');if(!m||!c)return alert(title);
  c.innerHTML=`<div class="page-head compact-head"><div><h2>${esc(title)}</h2></div></div>${body}`;m.classList.add('open');
}
async function renderAdmin(){
  const root=$('adminCommunityRoot');if(!root||!isAdmin())return;
  state.admin=true;
  root.innerHTML='<div class="card"><p class="hint">Loading Community controls...</p></div>';
  try{
    const [pkg,ads,reports,words]=await Promise.all([
      client().from('community_ad_packages').select('*').order('created_at',{ascending:false}),
      client().from('community_ad_campaigns').select('*').order('updated_at',{ascending:false}).limit(80),
      client().from('community_reports').select('*').order('created_at',{ascending:false}).limit(50),
      client().from('community_blocked_words').select('*').order('word')
    ]);
    if(pkg.error)throw pkg.error;if(ads.error)throw ads.error;if(reports.error)throw reports.error;if(words.error)throw words.error;
    state.packages=pkg.data||[];
    root.innerHTML=adminHtml(pkg.data||[],ads.data||[],reports.data||[],words.data||[]);
    bindAdmin(root);
  }catch(e){root.innerHTML=`<div class="notice">${esc(e.message||e)}</div>`}
}
function adminHtml(packages,ads,reports,words){
  return `<div class="summary-grid"><div class="metric"><span>Ad packages</span><strong>${packages.length}</strong></div><div class="metric"><span>Active banners</span><strong>${ads.filter(x=>x.status==='active').length}</strong></div><div class="metric"><span>Pending review</span><strong>${ads.filter(x=>['pending_review','paid'].includes(x.status)).length}</strong></div><div class="metric"><span>Open reports</span><strong>${reports.filter(x=>x.status==='open').length}</strong></div></div>
  <div class="community-admin-grid"><section class="card"><h3>Banner Packages</h3><div class="form-grid compact"><label>Name<input id="caPkgName" placeholder="Community banner - 30 days"></label><label>Price<input id="caPkgPrice" type="number" min="0" step="0.01" value="99"></label><label>Currency<input id="caPkgCurrency" maxlength="3" value="NZD"></label><label>Duration days<input id="caPkgDays" type="number" min="1" value="30"></label><label>Placement<select id="caPkgPlacement">${placements.map(p=>`<option value="${p[0]}">${p[1]}</option>`).join('')}</select></label><label class="tick-option"><input id="caPkgActive" type="checkbox" checked><span>Active</span></label></div><button class="primary" data-ca-save-package>Add package</button><div class="table-scroll"><table><thead><tr><th>Name</th><th>Price</th><th>Placement</th><th>Duration</th><th>Status</th></tr></thead><tbody>${packages.map(p=>`<tr><td>${esc(p.name)}</td><td>${money(p.price,p.currency)}</td><td>${esc(placeLabel(p.placement))}</td><td>${p.duration_days} days</td><td>${p.active?'Active':'Paused'}</td></tr>`).join('')||'<tr><td colspan="5">No packages yet.</td></tr>'}</tbody></table></div></section>
  <section class="card"><h3>Manual Sponsor Banner</h3><p class="hint">For external sponsors such as banks, accountants or suppliers. Payment can be Stripe checkout or manual invoice.</p><div class="form-grid compact"><label>Sponsor<input id="caSponsor"></label><label>Title<input id="caTitle"></label><label class="wide">Message<input id="caBody"></label><label>Website<input id="caUrl" placeholder="https://"></label><label>Placement<select id="caPlacement">${placements.map(p=>`<option value="${p[0]}">${p[1]}</option>`).join('')}</select></label><label>Price charged<input id="caPrice" type="number" min="0" step="0.01"></label><label>Starts<input id="caStart" type="date" value="${today()}"></label><label>Ends<input id="caEnd" type="date"></label><label>Region<input id="caRegion" placeholder="Optional"></label><label>Industry<input id="caIndustry" placeholder="Optional"></label></div><button class="primary" data-ca-save-campaign>Create manual banner</button></section></div>
  <section class="card"><h3>Campaigns</h3><div class="table-scroll"><table><thead><tr><th>Sponsor</th><th>Title</th><th>Placement</th><th>Dates</th><th>Payment</th><th>Status</th><th>Actions</th></tr></thead><tbody>${ads.map(a=>`<tr><td>${esc(a.sponsor_name)}</td><td>${esc(a.title)}<small>${esc(a.destination_url||'')}</small></td><td>${esc(placeLabel(a.placement))}</td><td>${new Date(a.starts_at).toLocaleDateString()} - ${new Date(a.ends_at).toLocaleDateString()}</td><td>${esc(a.payment_status||'manual')}</td><td>${esc(a.status)}</td><td><div class="row-actions"><button class="secondary compact-btn" data-ca-status="${a.id}" data-status="active">Approve/Activate</button><button class="secondary compact-btn" data-ca-status="${a.id}" data-status="paused">Pause</button><button class="danger compact-btn" data-ca-status="${a.id}" data-status="rejected">Reject</button></div></td></tr>`).join('')||'<tr><td colspan="7">No campaigns yet.</td></tr>'}</tbody></table></div></section>
  <div class="community-admin-grid"><section class="card"><h3>Blocked Words</h3><div class="form-grid compact"><label>Word or phrase<input id="caBlockedWord"></label><label>Severity<select id="caSeverity"><option>block</option><option>review</option></select></label></div><button class="secondary" data-ca-add-word>Add blocked word</button><div class="blocked-word-list">${words.map(w=>`<span>${esc(w.word)} <button data-ca-delete-word="${w.id}" type="button">x</button></span>`).join('')||'<p class="hint">No blocked words configured.</p>'}</div></section><section class="card"><h3>Reports</h3><div class="table-scroll"><table><thead><tr><th>Type</th><th>Reason</th><th>Status</th><th>Action</th></tr></thead><tbody>${reports.map(r=>`<tr><td>${esc(r.target_type)}</td><td>${esc(r.reason||'')}</td><td>${esc(r.status)}</td><td><button class="secondary compact-btn" data-ca-close-report="${r.id}">Close</button></td></tr>`).join('')||'<tr><td colspan="4">No reports.</td></tr>'}</tbody></table></div></section></div>`;
}
function bindAdmin(root){
  $('adminCommunityRefresh')?.addEventListener('click',renderAdmin);
  root.querySelector('[data-ca-save-package]').onclick=savePackage;
  root.querySelector('[data-ca-save-campaign]').onclick=saveCampaign;
  root.querySelector('[data-ca-add-word]').onclick=addWord;
  root.querySelectorAll('[data-ca-status]').forEach(b=>b.onclick=()=>setCampaignStatus(b.dataset.caStatus,b.dataset.status));
  root.querySelectorAll('[data-ca-delete-word]').forEach(b=>b.onclick=()=>deleteWord(b.dataset.caDeleteWord));
  root.querySelectorAll('[data-ca-close-report]').forEach(b=>b.onclick=()=>closeReport(b.dataset.caCloseReport));
}
async function savePackage(){
  const row={name:$('caPkgName').value.trim(),price:Number($('caPkgPrice').value||0),currency:$('caPkgCurrency').value.trim().toUpperCase()||'NZD',duration_days:Number($('caPkgDays').value||30),placement:$('caPkgPlacement').value,active:$('caPkgActive').checked};
  if(!row.name)return alert('Enter a package name.');
  const {error}=await client().from('community_ad_packages').insert(row);if(error)return alert(error.message);renderAdmin();
}
async function saveCampaign(){
  const start=$('caStart').value||today(),end=$('caEnd').value||new Date(Date.now()+30*86400000).toISOString().slice(0,10);
  const row={sponsor_type:'external',sponsor_name:$('caSponsor').value.trim(),title:$('caTitle').value.trim(),body:$('caBody').value.trim(),destination_url:$('caUrl').value.trim()||null,placement:$('caPlacement').value,price_charged:Number($('caPrice').value||0),currency:'NZD',starts_at:new Date(start+'T00:00:00').toISOString(),ends_at:new Date(end+'T23:59:59').toISOString(),target_region:$('caRegion').value.trim()||null,target_industry:$('caIndustry').value.trim()||null,payment_status:'manual',status:'active'};
  if(!row.sponsor_name||!row.title)return alert('Enter sponsor and title.');
  const {error}=await client().from('community_ad_campaigns').insert(row);if(error)return alert(error.message);renderAdmin();
}
async function setCampaignStatus(id,status){const {error}=await client().from('community_ad_campaigns').update({status,approved_at:status==='active'?new Date().toISOString():null,updated_at:new Date().toISOString()}).eq('id',id);if(error)return alert(error.message);renderAdmin()}
async function addWord(){const word=$('caBlockedWord').value.trim();if(!word)return;const {error}=await client().from('community_blocked_words').insert({word,severity:$('caSeverity').value,active:true});if(error)return alert(error.message);renderAdmin()}
async function deleteWord(id){const {error}=await client().from('community_blocked_words').delete().eq('id',id);if(error)return alert(error.message);renderAdmin()}
async function closeReport(id){const {error}=await client().from('community_reports').update({status:'closed',reviewed_at:new Date().toISOString()}).eq('id',id);if(error)return alert(error.message);renderAdmin()}
function init(){if(state.ready)return;state.ready=true;$('adminCommunityRefresh')?.addEventListener('click',renderAdmin)}
function onShow(){init();load()}
window.Community={init,onShow,renderAdmin,load};
})();
