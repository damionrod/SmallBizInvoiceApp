import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { PDFDocument, StandardFonts } from 'https://esm.sh/pdf-lib@1.17.1';
import { platformFrom, corsHeaders, enforceRateLimit, clientIp } from '../_shared/email-sender.ts';
const cors=corsHeaders();
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}});
const safe=(s:unknown)=>String(s??'').replace(/[\r\n<>]/g,' ').slice(0,250);
const escapeHtml=(s:unknown)=>safe(s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const email=/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;
Deno.serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  if(req.method!=='POST')return json({error:'Method not allowed'},405);
  try{
    const url=Deno.env.get('SUPABASE_URL'),anon=Deno.env.get('SUPABASE_ANON_KEY'),service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),resend=Deno.env.get('RESEND_API_KEY');
    if(!url||!anon||!service||!resend)return json({error:'Email service is not configured'},503);
    const bearer=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'').trim();
    if(!bearer)return json({error:'Sign in required'},401);
    const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:{user},error:authError}=await admin.auth.getUser(bearer);
    if(authError||!user)return json({error:'Sign in required'},401);
    const body=await req.json().catch(()=>({})),id=String(body.purchaseOrderId||'');
    if(!uuid.test(id))return json({error:'Invalid purchase order'},400);
    const {data:po,error:poError}=await admin.from('purchase_orders').select('id,business_id,po_number,supplier_id,supplier_name,order_date,expected_date,notes,status,currency').eq('id',id).maybeSingle();
    if(poError||!po)return json({error:'Purchase order not found'},404);
    const {data:member}=await admin.from('business_memberships').select('role,status').eq('business_id',po.business_id).eq('user_id',user.id).eq('status','active').maybeSingle();
    const {data:profile}=await admin.from('profiles').select('is_super_admin').eq('id',user.id).maybeSingle();
    if(!profile?.is_super_admin&&!member)return json({error:'No access to this business'},403);
    // Sending requires the same business write permission used by the application.
    if(!profile?.is_super_admin){
      const {data:allowed,error:permissionError}=await createClient(url,anon,{global:{headers:{Authorization:`Bearer ${bearer}`}}}).rpc('v6147_can_write_area',{p_business_id:po.business_id,p_area:'expenses'});
      if(permissionError||!allowed)return json({error:'Purchase order send permission denied'},403);
    }
    if(!po.supplier_id)return json({error:'Link an existing supplier before emailing'},400);
    const {data:supplier}=await admin.from('suppliers').select('id,email,supplier_name').eq('business_id',po.business_id).eq('id',po.supplier_id).eq('archived',false).maybeSingle();
    if(!supplier||!email.test(String(supplier.email||'')))return json({error:'Supplier email is missing or invalid'},400);
    await enforceRateLimit(admin,'send-purchase-order:user',user.id||clientIp(req),20,3600);
    await enforceRateLimit(admin,'send-purchase-order:po',po.id,10,3600);
    const {data:lines,error:linesError}=await admin.from('purchase_order_lines').select('description,qty,unit_price').eq('business_id',po.business_id).eq('purchase_order_id',po.id).order('line_order');
    if(linesError||!lines?.length)return json({error:'Purchase order has no lines'},400);
    const {data:biz}=await admin.from('businesses').select('name').eq('id',po.business_id).maybeSingle();
    const document=await PDFDocument.create();let page=document.addPage([595,842]);const font=await document.embedFont(StandardFonts.Helvetica),bold=await document.embedFont(StandardFonts.HelveticaBold);
    let y=792;const line=(label:string,emphasis=false)=>{if(y<65){page=document.addPage([595,842]);y=790}page.drawText(label.replace(/[^\x20-\x7E]/g,'?').slice(0,92),{x:45,y,size:emphasis?14:10,font:emphasis?bold:font});y-=emphasis?29:19};
    line(`PURCHASE ORDER ${safe(po.po_number)}`,true);line(`From: ${safe(biz?.name||'Business')}`);line(`To: ${safe(supplier.supplier_name)}`);line(`Order date: ${safe(po.order_date)}`);if(po.expected_date)line(`Expected date: ${safe(po.expected_date)}`);
    y-=15;line('Description                                        Qty       Unit price       Total',true);
    let total=0;for(const item of lines){const qty=Number(item.qty)||0,price=Number(item.unit_price)||0;total+=qty*price;line(`${safe(item.description).slice(0,44).padEnd(45)} ${qty.toFixed(2).padStart(7)}  ${price.toFixed(2).padStart(12)}  ${(qty*price).toFixed(2).padStart(12)}`)}
    y-=10;line(`Total (${safe(po.currency||'NZD')}): ${total.toFixed(2)}`,true);
    if(po.notes){y-=10;line('Notes:');for(const part of String(po.notes).match(/.{1,90}/g)||[])line(safe(part))}
    const pdf=await document.save();
    const b64=btoa(Array.from(pdf,b=>String.fromCharCode(b)).join(''));
    const subject=`Purchase Order ${safe(po.po_number)} from ${safe(biz?.name||'Frindly customer')}`;
    const payload={from:platformFrom(safe(biz?.name||'Frindly')+' Purchasing'),to:[supplier.email],subject,html:`<p>Hello ${escapeHtml(supplier.supplier_name)},</p><p>Please find attached purchase order <strong>${escapeHtml(po.po_number)}</strong> from ${escapeHtml(biz?.name||'our business')}.</p><p>Kind regards,<br>${escapeHtml(biz?.name||'Frindly')}</p>`,attachments:[{filename:`purchase-order-${safe(po.po_number).replace(/[^a-zA-Z0-9_-]/g,'_')}.pdf`,content:b64}]};
    const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json'},body:JSON.stringify(payload)});
    const result=await response.json().catch(()=>({}));if(!response.ok)return json({error:'Email provider could not send the purchase order'},502);
    const {error:eventError}=await admin.from('purchase_order_events').insert({business_id:po.business_id,purchase_order_id:po.id,event_type:'emailed',note:`Sent to ${supplier.email}; provider ID ${result.id||'unavailable'}`,created_by:user.id});
    if(eventError)console.error('PO email sent but event logging failed',eventError.message);
    return json({success:true});
  }catch(err){console.error('PO email failed',err);return json({error:'Unable to send purchase order. Please try again.'},500)}
});
