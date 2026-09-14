import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS"
};
const out=(x:any,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,"Content-Type":"application/json"}});
const MAX_BYTES=10*1024*1024;
const ALLOWED=new Set(['image/jpeg','image/png','image/webp','application/pdf']);

const schema={
  type:'object',additionalProperties:false,
  properties:{
    document_type:{type:'string',enum:['invoice','receipt','credit_note','other']},
    supplier_name:{type:['string','null']},
    supplier_gst_number:{type:['string','null']},
    invoice_number:{type:['string','null']},
    invoice_date:{type:['string','null']},
    due_date:{type:['string','null']},
    currency:{type:['string','null']},
    subtotal:{type:['number','null']},
    gst:{type:['number','null']},
    total:{type:['number','null']},
    description:{type:['string','null']},
    expense_category:{type:['string','null']},
    payment_status:{type:['string','null']},
    payment_method:{type:['string','null']},
    line_items:{type:'array',items:{type:'object',additionalProperties:false,properties:{description:{type:['string','null']},quantity:{type:['number','null']},unit_price:{type:['number','null']},amount:{type:['number','null']}},required:['description','quantity','unit_price','amount']}},
    confidence:{type:'object',additionalProperties:false,properties:{supplier_name:{type:'string',enum:['high','medium','low']},invoice_number:{type:'string',enum:['high','medium','low']},invoice_date:{type:'string',enum:['high','medium','low']},subtotal:{type:'string',enum:['high','medium','low']},gst:{type:'string',enum:['high','medium','low']},total:{type:'string',enum:['high','medium','low']},expense_category:{type:'string',enum:['high','medium','low']}},required:['supplier_name','invoice_number','invoice_date','subtotal','gst','total','expense_category']}
  },
  required:['document_type','supplier_name','supplier_gst_number','invoice_number','invoice_date','due_date','currency','subtotal','gst','total','description','expense_category','payment_status','payment_method','line_items','confidence']
};

function base64Bytes(value:string){
  try{return Math.floor((value.length*3)/4)-(value.endsWith('==')?2:value.endsWith('=')?1:0)}catch{return Number.MAX_SAFE_INTEGER}
}
function normalise(v:any){return String(v||'').toLowerCase().replace(/\b(limited|ltd|the|nz|new zealand)\b/g,' ').replace(/[^a-z0-9]+/g,' ').trim()}
function similarity(a:any,b:any){
  const x=normalise(a),y=normalise(b);if(!x||!y)return 0;if(x===y)return 1;if(x.includes(y)||y.includes(x))return .9;
  const ax=new Set(x.split(/\s+/)),by=new Set(y.split(/\s+/));let same=0;for(const t of ax)if(by.has(t))same++;
  return same/Math.max(ax.size,by.size,1);
}
function extractText(payload:any){
  for(const item of payload?.output||[])for(const c of item?.content||[])if(c?.type==='output_text'&&c?.text)return c.text;
  return '';
}
function cleanDate(v:any){const s=String(v||'').trim();return /^\d{4}-\d{2}-\d{2}$/.test(s)?s:null}

Deno.serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  if(req.method!=='POST')return out({ok:false,error:'Method not allowed'},405);
  const url=Deno.env.get('SUPABASE_URL');
  const anon=Deno.env.get('SUPABASE_ANON_KEY');
  const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const openai=Deno.env.get('OPENAI_API_KEY');
  if(!url||!anon||!service)return out({ok:false,error:'Server configuration is incomplete'},500);
  if(!openai)return out({ok:false,error:'AI scanning is temporarily unavailable: OPENAI_API_KEY is not configured'},503);
  const auth=req.headers.get('Authorization')||'';
  const client=createClient(url,anon,{global:{headers:{Authorization:auth}}});
  const admin=createClient(url,service);
  let logId:string|null=null;
  try{
    const {data:{user}}=await client.auth.getUser();
    if(!user)return out({ok:false,error:'Not authenticated'},401);
    const body=await req.json();
    const requestedBusinessId=String(body?.business_id||'').trim();
    const {data:currentBusinessId,error:businessError}=await client.rpc('current_business_id');
    if(businessError||!currentBusinessId)return out({ok:false,error:'No active business context found'},403);
    const businessId=requestedBusinessId||currentBusinessId;
    // Confirm the authenticated caller can actually see the requested tenant. This
    // also makes super-admin testing use the business currently open in Finlo.
    const {data:allowedBusiness,error:allowedBusinessError}=await client.from('businesses').select('id').eq('id',businessId).maybeSingle();
    if(allowedBusinessError||!allowedBusiness)return out({ok:false,error:'Business account not available'},403);

    const filename=String(body?.filename||'document').slice(0,180);
    const mime=String(body?.mime_type||'').toLowerCase();
    const fileBase64=String(body?.file_base64||'').replace(/\s/g,'');
    if(!ALLOWED.has(mime))return out({ok:false,error:'Please upload a JPG, PNG, WEBP or PDF.'},400);
    if(!fileBase64)return out({ok:false,error:'No document data received'},400);
    if(base64Bytes(fileBase64)>MAX_BYTES)return out({ok:false,error:'This file is too large. Please choose a smaller file.'},413);

    // Soft abuse protection: 60 scans per user/business per rolling hour.
    try{
      const since=new Date(Date.now()-60*60*1000).toISOString();
      const {count}=await admin.from('expense_ai_scans').select('id',{count:'exact',head:true}).eq('business_id',businessId).eq('user_id',user.id).gte('created_at',since);
      if((count||0)>=60)return out({ok:false,error:'AI scan limit reached for the last hour. Please try again shortly or enter the expense manually.'},429);
    }catch{/* Logging table may not exist during staged deployment. */}

    const [cats,sups]=await Promise.all([
      client.from('expense_categories').select('id,name,group_name').eq('business_id',businessId).eq('archived',false).order('sort_order').order('name'),
      client.from('suppliers').select('id,supplier_name,trading_name,tax_number').eq('business_id',businessId).eq('archived',false).order('supplier_name')
    ]);
    if(cats.error)throw cats.error;if(sups.error)throw sups.error;
    const categories=(cats.data||[]);
    const suppliers=(sups.data||[]);

    try{
      const {data}=await admin.from('expense_ai_scans').insert({business_id:businessId,user_id:user.id,status:'processing',filename,mime_type:mime}).select('id').single();
      logId=data?.id||null;
    }catch{/* Optional telemetry only. */}

    const categoryList=categories.map((c:any)=>`${c.name}${c.group_name?` (${c.group_name})`:''}`).join('\n- ');
    const instruction=`Extract expense data from this New Zealand business receipt/invoice. Never invent data. Return null when a field cannot be confidently determined. Dates must be YYYY-MM-DD. Distinguish invoice date from due date. Carefully identify subtotal, GST and final total, including GST-inclusive documents. Keep document amounts exactly as shown rather than silently correcting them. Generate a short useful expense description. Choose exactly one expense_category from the supplied category names; do not create a new category. If none clearly applies, choose Other if it exists, otherwise return null. Payment status should be paid only when the document clearly indicates payment/receipt completion.\n\nAvailable expense categories:\n- ${categoryList||'Other'}\n\nThe business currency is generally NZD, but use the document currency when clearly shown.`;
    const content:any[]=[{type:'input_text',text:instruction}];
    if(mime==='application/pdf')content.push({type:'input_file',filename,file_data:`data:${mime};base64,${fileBase64}`});
    else content.push({type:'input_image',image_url:`data:${mime};base64,${fileBase64}`,detail:'high'});

    const model=Deno.env.get('OPENAI_EXPENSE_MODEL')||'gpt-5.6-luna';
    const response=await fetch('https://api.openai.com/v1/responses',{
      method:'POST',
      headers:{Authorization:`Bearer ${openai}`,'Content-Type':'application/json'},
      body:JSON.stringify({model,input:[{role:'user',content}],text:{format:{type:'json_schema',name:'finlo_expense_scan',strict:true,schema}},max_output_tokens:1800})
    });
    const payload=await response.json();
    if(!response.ok){
      const apiMessage=payload?.error?.message||'OpenAI request failed';
      console.error('OpenAI Responses API error',{status:response.status,statusText:response.statusText,error:payload?.error||payload});
      throw new Error(`OpenAI ${response.status}: ${apiMessage}`);
    }
    const text=extractText(payload);if(!text)throw new Error('The AI returned no structured result');
    const result=JSON.parse(text);
    result.invoice_date=cleanDate(result.invoice_date);result.due_date=cleanDate(result.due_date);
    if(result.currency)result.currency=String(result.currency).toUpperCase().slice(0,3);

    // Use the AI-selected category when it matches an existing category. If it does
    // not, fall back to the tenant's existing "Other" category so category never
    // blocks a scanned expense from being saved.
    let category=categories.find((c:any)=>normalise(c.name)===normalise(result.expense_category));
    if(!category)category=categories.find((c:any)=>normalise(c.name)==='other');
    result.matched_category_id=category?.id||null;
    if(category)result.expense_category=category.name;

    // Match an existing supplier first. GST/tax number is an exact identifier when
    // available; otherwise keep the existing fuzzy-name matching behaviour.
    let best:any=null,bestScore=0;
    const gstKey=String(result.supplier_gst_number||'').replace(/\D/g,'');
    if(gstKey){
      best=suppliers.find((s:any)=>String(s.tax_number||'').replace(/\D/g,'')===gstKey)||null;
      if(best)bestScore=1;
    }
    if(!best){
      for(const s of suppliers){const score=Math.max(similarity(result.supplier_name,s.supplier_name),similarity(result.supplier_name,s.trading_name));if(score>bestScore){best=s;bestScore=score}}
    }
    result.matched_supplier_id=bestScore>=0.72?best?.id||null:null;
    result.supplier_match_score=Number(bestScore.toFixed(2));

    // If the supplier genuinely does not exist yet, create the minimum supplier
    // record automatically and return its id. The normal RLS/business defaults are
    // preserved because this uses the authenticated tenant client.
    if(!result.matched_supplier_id&&String(result.supplier_name||'').trim()){
      const supplierRow:any={
        business_id:businessId,
        supplier_name:String(result.supplier_name).trim(),
        tax_number:String(result.supplier_gst_number||'').trim()||null,
        default_gst_treatment:Number(result.gst)>0?'gst':'no_gst',
        updated_by:user.id
      };
      const created=await client.from('suppliers').insert(supplierRow).select('id,supplier_name,trading_name,tax_number').single();
      if(created.error)throw created.error;
      result.matched_supplier_id=created.data?.id||null;
      result.supplier_match_score=1;
      result.supplier_created=true;
    }else{
      result.supplier_created=false;
    }

    try{if(logId)await admin.from('expense_ai_scans').update({status:'success',model,openai_response_id:payload?.id||null,input_tokens:payload?.usage?.input_tokens||null,output_tokens:payload?.usage?.output_tokens||null,completed_at:new Date().toISOString()}).eq('id',logId)}catch{}
    return out({ok:true,result});
  }catch(e){
    console.error(e);
    try{if(logId)await admin.from('expense_ai_scans').update({status:'failed',error_message:String(e instanceof Error?e.message:e).slice(0,500),completed_at:new Date().toISOString()}).eq('id',logId)}catch{}
    return out({ok:false,error:e instanceof Error?e.message:'AI scan failed'},400);
  }
});
