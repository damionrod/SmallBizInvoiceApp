/* Optional bill item review: the phone scan supplies draft items; Expenses keeps the bill. */
(()=>{'use strict';
const api=()=>window.SAAS?.client?.(),bid=()=>window.SAAS?.state?.business?.id;
const E=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&quot;',"'":'&#39;'}[c]));
const money=n=>`$${Number(n||0).toLocaleString('en-NZ',{minimumFractionDigits:2,maximumFractionDigits:2})}`;
const cents=n=>Math.round(Number(n)*100),cash=n=>(n/100).toFixed(2);
const allowed=new Set(['image/jpeg','image/png','image/webp','application/pdf']);
const uses=[['regular','Normal expense'],['stock','Stock to sell'],['supplies','Consumables / used on jobs'],['equipment','CapEx equipment'],['low_value_equipment','Small tools'],['discount','Discount / credit']];
const signedMoney=n=>Number(n)<0?`−${money(-n)}`:money(n);
const isDiscount=x=>/\b(discount|rebate)\b|\bcredit\s*$/i.test(String(x.description||''))&&!/\bcredit card\b/i.test(String(x.description||''));
const state={tenant:null,bills:[],categories:[],reviews:new Map(),scans:new Map(),drafts:new Map(),expanded:new Set(),search:'',page:0,nonce:0,busy:null};
const panel=()=>document.getElementById('expense-panel-review'),list=()=>document.getElementById('purchaseReviewBills');
const text=(id,value)=>{const el=document.getElementById(id);if(el)el.textContent=value};
function categoryFor(bill,description){
 if(bill.category_id)return bill.category_id;
 const lines=bill.expense_lines||[],matches=lines.filter(l=>String(l.description||'').trim().toLowerCase()===String(description||'').trim().toLowerCase());
 if(matches.length===1)return matches[0].category_id||'';
 const unique=[...new Set(lines.map(x=>x.category_id).filter(Boolean))];return unique.length===1?unique[0]:'';
}
// Suggest only figures supported by item prices AND the recorded bill totals. No mixed-tax guess.
function allocations(items,bill){
 const amounts=items.map(x=>x.amount==null?NaN:(isDiscount(x)?-Math.abs(cents(x.amount)):cents(x.amount))),valid=amounts.length>0&&amounts.every(Number.isFinite);
 const sum=valid?amounts.reduce((n,x)=>n+x,0):NaN,ex=cents(bill.ex_gst),gst=cents(bill.gst_amount),gross=cents(bill.total_amount);
 const fullEx=sum===ex,fullGross=sum===gross;
 const rate=Number(bill.gst_rate??(String(window.SAAS?.state?.business?.settings?.country||'NZ').toUpperCase()==='NZ'?15:NaN))/100;
 const basis=items.map(x=>['ex_gst','incl_gst'].includes(x.amount_basis)?x.amount_basis:fullEx?'ex_gst':fullGross?'incl_gst':'unknown');
 const homogeneous=(fullEx||fullGross)&&gst>0&&Number.isFinite(rate)&&rate>0&&
   items.every(x=>x.gst_treatment!=='no_gst')&&
   Math.abs(amounts.reduce((n,a)=>n+Math.sign(a)*Math.round(Math.abs(fullEx?a*rate:a*rate/(1+rate))),0)-gst)<=1;
 const rows=items.map((item,i)=>{
  const amount=amounts[i],mode=basis[i],known=item.printed_gst==null?null:cents(item.printed_gst);
  const treatment=known!=null?'printed':gst===0?'no_gst':item.gst_treatment==='no_gst'?'no_gst':item.gst_treatment==='taxable'||homogeneous?'taxable':'unknown';
  let tax=null,net=null;
  if(Number.isFinite(amount)&&mode!=='unknown'){
   if(known!=null&&Number.isFinite(known))tax=amount<0?-Math.abs(known):known;
   else if(treatment==='no_gst')tax=0;
   else if(treatment==='taxable'&&Number.isFinite(rate)&&rate>0)tax=Math.sign(amount)*Math.round(Math.abs(mode==='ex_gst'?amount*rate:amount*rate/(1+rate)));
   if(tax!=null&&mode==='incl_gst'&&Math.abs(tax)<=Math.abs(amount))net=amount-tax;
   if(tax!=null&&mode==='ex_gst')net=amount;
  }
  const discount=amount<0||isDiscount(item),prior=items.slice(0,i).filter(x=>!isDiscount(x)&&Number(x.amount)>0),usesBefore=new Set(prior.map(x=>x.suggested_use||'regular')),target=discount&&usesBefore.size===1?items.slice(0,i).findLastIndex(x=>!isDiscount(x)&&Number(x.amount)>0):-1;
  return{description:item.description||'',kind:discount?'discount':uses.some(([k])=>k===item.suggested_use)?item.suggested_use:item.suggested_use==='depreciable_equipment'?'equipment':'regular',discount_target_index:target>=0?target:'',category_id:categoryFor(bill,item.description),quantity:discount?1:item.quantity||1,ex_gst:net==null?'':cash(net),gst:tax==null||net==null?'':cash(tax),page_number:item.page_number,reason:item.classification_reason||'',confidence:item.classification_confidence||'low',printed_gst:item.printed_gst};
 });
 if(rows.length&&rows.every(x=>x.ex_gst!==''&&x.gst!=='')){
  const totalEx=rows.reduce((n,x)=>n+cents(x.ex_gst),0),totalGst=rows.reduce((n,x)=>n+cents(x.gst),0);
  // Suppliers sometimes round their invoice GST once rather than each line.
  const difference=gst-totalGst;
  if(Math.abs(difference)===1&&totalEx===ex+(fullGross?difference:0)){
   const i=rows.findLastIndex((x,j)=>Number(x.gst)>0&&items[j].printed_gst==null);
   if(i>=0){rows[i].gst=cash(cents(rows[i].gst)+difference);if(fullGross)rows[i].ex_gst=cash(cents(rows[i].ex_gst)-difference)}
  }
 }
 return rows;
}
function baseRows(bill){const saved=state.reviews.get(bill.id);if(saved)return (saved.rows||[]).map(x=>({...x}));const record=state.scans.get(bill.id),ids=(bill.expense_attachments||[]).map(x=>x.id);
 const current=record&&ids.length===record.attachment_ids?.length&&ids.every(id=>record.attachment_ids.includes(id));
 if(current&&Array.isArray(record.proposals)&&record.proposals.length)return allocations(record.proposals,bill);
 if(bill.is_split&&bill.expense_lines?.length)return bill.expense_lines.map(x=>({description:x.description||'',kind:'regular',category_id:x.category_id||'',quantity:1,ex_gst:x.ex_gst,gst:x.gst_amount}));
 return[{description:'',kind:'regular',category_id:categoryFor(bill,''),quantity:1,ex_gst:'',gst:''}];
}
function rowHtml(r,i,allRows=[r]){
 const kind=uses.map(([key,label])=>`<option value="${key}" ${key===r.kind?'selected':''}>${label}</option>`).join('');
 const targets=allRows.map((x,j)=>x.kind==='discount'||j>=i?'':`<option value="${j}" ${String(r.discount_target_index)===String(j)?'selected':''}>#${j+1} ${E(x.description||'Item')}</option>`).join('');
 const categories=state.categories.map(c=>`<option value="${E(c.id)}" ${String(c.id)===String(r.category_id)?'selected':''}>${E(c.name)}</option>`).join('');
 const gross=r.ex_gst!==''&&r.gst!==''?signedMoney(Number(r.ex_gst)+Number(r.gst)):'—';
 return `<div class="pr-item" data-pr-row ${r.kind==='discount'?'data-pr-discount':''}><button type="button" class="pr-mobile-summary" data-pr-edit aria-label="Edit item ${i+1}"><span>${E(r.description||`Item ${i+1}`)}</span><small>${E(uses.find(x=>x[0]===r.kind)?.[1]||'Use?')} · ${E(state.categories.find(x=>String(x.id)===String(r.category_id))?.name||'Category?')}</small><strong>${gross}</strong></button><span class="pr-num">${i+1}</span><label class="pr-description"><span>Item</span><input name="description" aria-label="Item ${i+1}" value="${E(r.description||'')}" maxlength="500" required title="${E(r.description||'')}"></label><label class="pr-category"><span>Category</span><select name="category_id" aria-label="Category for item ${i+1}" required><option value="">Choose</option>${categories}</select></label><label class="pr-use-select"><span>Use</span><select name="kind" aria-label="Use for item ${i+1}">${kind}</select></label><label class="pr-qty"><span>${r.kind==='discount'?'Against':'Qty'}</span><input name="quantity" type="number" min="0.001" step="any" value="${E(r.kind==='discount'?1:r.quantity??1)}" required ${r.kind==='discount'?'hidden':''}><select name="discount_target_index" aria-label="Charge discounted by item ${i+1}" ${r.kind==='discount'?'':'hidden disabled'}><option value="">Select charge</option>${targets}</select></label><label class="pr-amount"><span>Ex GST</span><input name="ex_gst" type="number" step="0.01" inputmode="decimal" value="${E(r.ex_gst??'')}" required></label><label class="pr-amount"><span>GST</span><input name="gst" type="number" step="0.01" inputmode="decimal" value="${E(r.gst??'')}" required></label><span class="pr-gross"><small>Incl GST</small><output>${gross}</output></span><button type="button" data-pr-remove="${i}" class="pr-remove" aria-label="Remove item ${i+1}">×</button><div class="pr-asset" ${r.kind==='equipment'?'':'hidden'}><label>Ready to use<input name="available_on" type="date" value="${E(r.available_on||'')}"></label><label>Useful life (months)<input name="life_months" type="number" min="1" max="1200" value="${E(r.life_months||'')}"></label><label>Book method<select name="book_method"><option value="">Choose</option><option value="SL" ${r.book_method==='SL'?'selected':''}>Straight line</option><option value="DV" ${r.book_method==='DV'?'selected':''}>Diminishing value</option></select></label><label>Residual value<input name="residual_value" type="number" min="0" step="0.01" value="${E(r.residual_value??0)}"></label></div></div>`;
}
function readRows(card){return [...card.querySelectorAll('[data-pr-row]')].map(node=>{const v=n=>node.querySelector(`[name="${n}"]`)?.value??'';return{description:v('description').trim(),kind:v('kind'),category_id:v('category_id'),quantity:v('quantity'),discount_target_index:v('discount_target_index'),ex_gst:v('ex_gst'),gst:v('gst'),available_on:v('available_on'),life_months:v('life_months'),book_method:v('book_method'),residual_value:v('residual_value')}})}
function captureDrafts(){list()?.querySelectorAll('[data-pr-bill]').forEach(card=>{if(!state.reviews.has(card.dataset.prBill)||!card.querySelector('[data-pr-items]')?.hidden)state.drafts.set(card.dataset.prBill,readRows(card))})}
function balance(card){const bill=state.bills.find(x=>x.id===card.dataset.prBill);if(!bill)return false;const rows=readRows(card);
 const sumEx=rows.reduce((n,x)=>n+Number(x.ex_gst||0),0),sumGst=rows.reduce((n,x)=>n+Number(x.gst||0),0);
 rows.forEach((x,i)=>{const node=card.querySelectorAll('[data-pr-row]')[i],asset=node.querySelector('.pr-asset'),equipment=x.kind==='equipment';asset.hidden=!equipment;asset.querySelectorAll('[name="available_on"],[name="life_months"],[name="book_method"]').forEach(f=>f.required=equipment);const discount=x.kind==='discount',qty=node.querySelector('[name=quantity]'),target=node.querySelector('[name=discount_target_index]');qty.hidden=discount;qty.value=discount?'1':qty.value;target.hidden=!discount;target.disabled=!discount;node.toggleAttribute('data-pr-discount',discount);const gross=x.ex_gst!==''&&x.gst!==''?signedMoney(Number(x.ex_gst)+Number(x.gst)):'—';node.querySelector('output').textContent=gross;node.querySelector('.pr-mobile-summary strong').textContent=gross;node.querySelector('.pr-mobile-summary span').textContent=x.description||`Item ${i+1}`;node.querySelector('.pr-mobile-summary small').textContent=`${uses.find(a=>a[0]===x.kind)?.[1]||'Use?'} · ${state.categories.find(c=>String(c.id)===String(x.category_id))?.name||'Category?'}`});
 const complete=rows.length>0&&rows.every((x,i)=>{const target=rows[Number(x.discount_target_index)];return x.description&&x.kind&&x.category_id&&Number(x.quantity)>0&&x.ex_gst!==''&&x.gst!==''&&Number.isFinite(Number(x.ex_gst))&&Number.isFinite(Number(x.gst))&&(x.kind==='discount'?x.ex_gst<0&&x.gst<=0&&Number.isInteger(Number(x.discount_target_index))&&x.discount_target_index!==''&&Number(x.discount_target_index)<i&&target&&target.kind!=='discount'&&target.category_id===x.category_id:Number(x.ex_gst)>=0&&Number(x.gst)>=0)&&(!(x.kind==='equipment')||(x.available_on&&Number(x.life_months)>0&&x.book_method))})&&rows.every((x,i)=>x.kind==='discount'||cents(x.ex_gst)+rows.reduce((n,d)=>n+(d.kind==='discount'&&Number(d.discount_target_index)===i?cents(d.ex_gst):0),0)>=0&&cents(x.gst)+rows.reduce((n,d)=>n+(d.kind==='discount'&&Number(d.discount_target_index)===i?cents(d.gst):0),0)>=0);
 const match=cents(sumEx)===cents(bill.ex_gst)&&cents(sumGst)===cents(bill.gst_amount);
 const status=card.querySelector('[data-pr-balance]');if(status)status.textContent=`Items ${money(sumEx)} ex GST + ${money(sumGst)} GST = ${money(sumEx+sumGst)}. ${match?'Matches the recorded bill.':`Check the bill: remaining ${signedMoney(Number(bill.ex_gst)-sumEx)} ex GST and ${signedMoney(Number(bill.gst_amount)-sumGst)} GST. Discounts must be negative and linked to a charge.`}`;
 const save=card.querySelector('[data-pr-save]');if(save)save.disabled=state.busy===bill.id||!complete||!match;
 return complete&&match;
}
function cardHtml(bill){const reviewed=state.reviews.get(bill.id),expanded=state.expanded.has(bill.id),rows=state.drafts.get(bill.id)||baseRows(bill),attachments=bill.expense_attachments||[];
 const scan=state.scans.get(bill.id),preloaded=!reviewed&&scan?.proposals?.length>0&&attachments.length===scan.attachment_ids?.length&&attachments.every(x=>scan.attachment_ids.includes(x.id));
 const note=reviewed?'Reviewed':preloaded?`${rows.length} scanned items ready to check`:'Item details need a scan or manual entry';
 return `<section class="pr-invoice" data-pr-bill="${E(bill.id)}"><div class="pr-invoice-head"><div><strong>${E(bill.expense_number||'Bill')} · ${E(bill.supplier_name||'Supplier')}</strong><small>${E(bill.invoice_date||'')} · ${money(bill.ex_gst)} ex GST + ${money(bill.gst_amount)} GST = <b>${money(bill.total_amount)} incl GST</b></small><small class="pr-state">${E(note)}</small></div><button type="button" class="secondary" data-pr-toggle="${E(bill.id)}" aria-expanded="${expanded}">${reviewed?expanded?'Collapse':'View reviewed items':expanded?'Collapse':'Review items'}</button></div><div data-pr-items ${expanded?'':'hidden'}><div class="pr-documents">${attachments.map((a,i)=>`<button type="button" data-pr-view="${E(a.id)}">Page ${i+1}: ${E(a.original_filename||'Invoice')}</button>`).join('')}${reviewed?'':`<label class="pr-upload">Add page<input type="file" data-pr-file accept="image/jpeg,image/png,image/webp,application/pdf" multiple hidden></label><button type="button" data-pr-scan>${preloaded?'Rescan pages':'Scan pages'}</button>`}</div><div class="pr-items"><div class="pr-column-head"><span>#</span><span>Item</span><span>Category</span><span>Use</span><span>Qty</span><span>Ex GST</span><span>GST</span><span>Incl GST</span><span></span></div><div data-pr-rows>${rows.map((r,i)=>rowHtml(r,i,rows)).join('')}</div></div><div class="pr-invoice-footer"><button type="button" class="secondary" data-pr-add>Add item</button><span data-pr-balance role="status"></span>${reviewed?'<label class="pr-correction">Correction reason<input name="correction_reason" required maxlength="300" placeholder="Why are these items changing?"></label>':''}<button type="button" class="primary" data-pr-save>${reviewed?'Save correction':'Save all items'}</button></div><p class="pr-message" data-pr-message role="alert" hidden></p></div></section>`;
}
function render(){const el=list();if(!el)return;el.innerHTML=state.bills.map(cardHtml).join('')||'<p class="hint">No recorded bills match. Item review is optional.</p>';
 el.querySelectorAll('[data-pr-bill]').forEach(card=>{card.querySelector('[data-pr-toggle]').onclick=()=>{captureDrafts();const id=card.dataset.prBill;state.expanded.has(id)?state.expanded.delete(id):state.expanded.add(id);render()};
 card.querySelectorAll('[data-pr-row]').forEach(row=>row.querySelector('[data-pr-edit]').onclick=()=>row.classList.toggle('editing'));
 card.querySelectorAll('[data-pr-remove]').forEach(btn=>btn.onclick=()=>{captureDrafts();const rows=state.drafts.get(card.dataset.prBill);if(rows.length>1){rows.splice(Number(btn.dataset.prRemove),1);render()}});
 card.querySelector('[data-pr-add]')?.addEventListener('click',()=>{captureDrafts();state.drafts.get(card.dataset.prBill).push({description:'',kind:'regular',category_id:state.bills.find(x=>x.id===card.dataset.prBill)?.category_id||'',quantity:1,ex_gst:'',gst:''});render()});
 card.querySelector('[data-pr-save]')?.addEventListener('click',()=>save(card));card.querySelector('[data-pr-scan]')?.addEventListener('click',()=>scan(card.dataset.prBill));card.querySelector('[data-pr-file]')?.addEventListener('change',e=>{void addPages(card.dataset.prBill,e.target.files);e.target.value=''});
 card.querySelectorAll('[data-pr-view]').forEach(button=>button.onclick=()=>viewPage(card.dataset.prBill,button.dataset.prView));card.addEventListener('input',()=>balance(card));card.addEventListener('change',()=>balance(card));if(!card.querySelector('[data-pr-items]').hidden)balance(card)
 });
}
async function showList(){const tenant=bid(),request=++state.nonce;if(!tenant||!api())return;state.tenant=tenant;
 const all=(window.Expenses?.reviewBills?.()||[]).filter(b=>b.business_id===tenant),search=document.getElementById('purchaseReviewSearch')?.value.trim().toLocaleLowerCase()||'';
 const filtered=all.filter(b=>!search||`${b.expense_number||''} ${b.supplier_name||''} ${b.supplier_reference||''}`.toLocaleLowerCase().includes(search));state.page=Math.min(state.page,Math.max(0,Math.ceil(filtered.length/10)-1));state.bills=filtered.slice(state.page*10,state.page*10+10);list().innerHTML='<p class="hint">Loading invoice items…</p>';
 text('purchaseReviewCount',`${filtered.length?state.page*10+1:0}–${Math.min((state.page+1)*10,filtered.length)} of ${filtered.length} bills`);
 document.getElementById('purchaseReviewPrevious').disabled=state.page===0;document.getElementById('purchaseReviewNext').disabled=(state.page+1)*10>=filtered.length;
 const notice=document.getElementById('purchaseReviewListError');notice.hidden=true;
 try{const ids=state.bills.map(x=>x.id);if(ids.length){const c=api(),[cats,scans]=await Promise.all([c.from('expense_categories').select('id,name,group_name').eq('business_id',tenant).eq('archived',false).order('name'),c.from('purchase_document_items').select('expense_id,attachment_ids,proposals').eq('business_id',tenant).in('expense_id',ids)]);if(cats.error||scans.error)throw cats.error||scans.error;
  const reviews=[];for(let offset=0;;offset+=500){const page=await c.from('purchase_invoice_reviews').select('expense_id,revision,rows').eq('business_id',tenant).in('expense_id',ids).order('revision',{ascending:false}).range(offset,offset+499);if(page.error)throw page.error;reviews.push(...page.data||[]);if((page.data||[]).length<500)break}
  if(request!==state.nonce||bid()!==tenant)return;state.categories=cats.data||[];state.scans=new Map((scans.data||[]).map(x=>[x.expense_id,x]));state.reviews=new Map();for(const x of reviews)if(!state.reviews.has(x.expense_id))state.reviews.set(x.expense_id,x);
 }else{state.reviews=new Map();state.scans=new Map()}
 if(request!==state.nonce||bid()!==tenant)return;state.expanded=new Set(state.bills.filter(b=>!state.reviews.has(b.id)).map(b=>b.id));state.drafts=new Map();render();
 }catch(err){if(request!==state.nonce||bid()!==tenant)return;list().innerHTML='';notice.textContent='Cannot load item suggestions. Try again: '+(err.message||String(err));notice.hidden=false}
}
async function save(card){const bill=state.bills.find(x=>x.id===card.dataset.prBill),existing=state.reviews.get(bill?.id);if(!bill||state.busy||!balance(card))return;
 const reason=card.querySelector('[name="correction_reason"]')?.value.trim()||'';if(existing&&!reason){showMessage(card,'Enter a reason for changing reviewed items.');return}
 const rows=readRows(card).map((x,i,all)=>x.kind==='discount'?{...x,discount_for:all[Number(x.discount_target_index)]?.kind}:x);state.busy=bill.id;balance(card);
 try{const {error}=await api().rpc('v6190_review_purchase',{p_business_id:state.tenant,p_expense_id:bill.id,p_expected_revision:existing?.revision||0,p_rows:rows.map(x=>({...x,quantity:Number(x.quantity),ex_gst:Number(x.ex_gst),gst:Number(x.gst)})),p_reason:reason||null});if(error)throw error;if(bid()!==state.tenant)return;
 state.reviews.set(bill.id,{revision:(existing?.revision||0)+1,rows});state.drafts.delete(bill.id);state.expanded.delete(bill.id);render();window.Financials?.refresh?.();window.AccountantCentre?.refresh?.();
 }catch(err){showMessage(card,err.message||String(err))}finally{state.busy=null;const live=list()?.querySelector(`[data-pr-bill="${bill.id}"]`);if(live&&!live.querySelector('[data-pr-items]').hidden)balance(live)}
}
function showMessage(card,message){const el=card?.querySelector('[data-pr-message]');if(el){el.textContent=message;el.hidden=false}}
async function viewPage(id,attachment){const bill=state.bills.find(x=>x.id===id),page=bill?.expense_attachments?.find(x=>x.id===attachment);if(!page)return;const {data,error}=await api().storage.from('expense-documents').createSignedUrl(page.stored_path,120);if(error)return showMessage(list()?.querySelector(`[data-pr-bill="${id}"]`),error.message||String(error));window.open(data.signedUrl,'_blank','noopener')}
const toBase64=file=>new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result).split(',')[1]);reader.onerror=()=>reject(reader.error);reader.readAsDataURL(file)});
async function scan(id){const bill=state.bills.find(x=>x.id===id),card=list().querySelector(`[data-pr-bill="${id}"]`);if(!bill||state.reviews.has(id)||state.busy)return;const pages=[...(bill.expense_attachments||[])],prior=state.scans.get(id)?.attachment_ids;if(prior?.length)pages.sort((a,b)=>(prior.indexOf(a.id)<0?999:prior.indexOf(a.id))-(prior.indexOf(b.id)<0?999:prior.indexOf(b.id)));if(!pages.length)return showMessage(card,'Add a bill image or enter the items manually.');if(pages.length>12)return showMessage(card,'Scan up to 12 pages together.');state.busy=id;showMessage(card,'Reading all invoice pages…');
 try{const docs=[];for(const page of pages){const {data:file,error}=await api().storage.from('expense-documents').download(page.stored_path);if(error)throw error;if(!allowed.has(page.mime_type))throw Error('Use JPG, PNG, WEBP or PDF pages');docs.push({filename:page.original_filename,mime_type:page.mime_type,file_base64:await toBase64(file)})}if(docs.reduce((n,d)=>n+Math.floor(d.file_base64.length*3/4),0)>10*1024*1024)throw Error('The invoice pages exceed the 10 MB scan limit.');const {data,error}=await api().functions.invoke('scan-expense-document',{body:{business_id:state.tenant,review_category_id:bill.category_id,documents:docs}});if(error||!data?.ok)throw error||Error(data?.error||'Could not scan this invoice');if(!data.result?.line_items?.length)throw Error('No item prices were readable. Enter them manually or take clearer photos.');if(bid()!==state.tenant)throw Error('Business changed while scanning');const items=data.result.line_items;
 const saved=await api().rpc('v6190_save_purchase_scan',{p_business_id:state.tenant,p_expense_id:id,p_attachment_ids:pages.map(x=>x.id),p_items:items});if(saved.error)throw saved.error;state.scans.set(id,{attachment_ids:pages.map(x=>x.id),proposals:items});state.drafts.set(id,allocations(items,bill));state.expanded.add(id);render();const live=list().querySelector(`[data-pr-bill="${id}"]`);showMessage(live,data.result.page_warning||'Suggestions refreshed. Check each item and the recorded bill total before saving.');
 }catch(err){showMessage(card,err.message||String(err))}finally{state.busy=null}
}
async function addPages(id,files){const bill=state.bills.find(x=>x.id===id),card=list().querySelector(`[data-pr-bill="${id}"]`);if(!bill||!files?.length||state.reviews.has(id)||state.busy)return;const selected=[...files];if(selected.length+(bill.expense_attachments?.length||0)>12)return showMessage(card,'Up to 12 pages per bill.');state.busy=id;
 try{for(const file of selected){if(!allowed.has(file.type)||file.size>10*1024*1024)throw Error('Use JPG, PNG, WEBP or PDF files under 10 MB each');const path=`${state.tenant}/${id}/${crypto.randomUUID()}-${file.name.replace(/[^a-z0-9._-]/gi,'-').slice(0,70)}`;const {error:up}=await api().storage.from('expense-documents').upload(path,file,{contentType:file.type,upsert:false});if(up)throw up;const {data,error}=await api().from('expense_attachments').insert({business_id:state.tenant,expense_id:id,original_filename:file.name,stored_path:path,mime_type:file.type,file_size:file.size}).select('id,original_filename,stored_path,mime_type').single();if(error){await api().storage.from('expense-documents').remove([path]);throw error}bill.expense_attachments=[...(bill.expense_attachments||[]),data]}
 state.scans.delete(id);state.drafts.delete(id);state.busy=null;render();await scan(id);
 }catch(err){showMessage(list()?.querySelector(`[data-pr-bill="${id}"]`),err.message||String(err))}finally{state.busy=null}
}
async function open(id){window.Expenses?.switchTab?.('review');const bill=window.Expenses?.reviewBills?.().find(x=>x.id===id&&x.business_id===bid());if(!bill)return;document.getElementById('purchaseReviewSearch').value=bill.expense_number;state.page=0;await showList();state.expanded.add(id);render();list()?.querySelector(`[data-pr-bill="${id}"]`)?.scrollIntoView?.({block:'nearest'})}
document.getElementById('purchaseReviewSearch')?.addEventListener('input',()=>{state.page=0;void showList()});
document.getElementById('purchaseReviewPrevious')?.addEventListener('click',()=>{if(state.page>0){state.page--;void showList()}});
document.getElementById('purchaseReviewNext')?.addEventListener('click',()=>{state.page++;void showList()});
window.PurchaseReview={showList,open};
})();
