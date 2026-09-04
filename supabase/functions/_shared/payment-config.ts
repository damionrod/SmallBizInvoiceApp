export async function getStripeConfig(admin:any, requireEnabled=false){
  const {data:row,error:rowError}=await admin
    .from('payment_provider_settings')
    .select('provider,enabled,mode,public_config')
    .eq('provider','stripe')
    .maybeSingle();

  if(rowError && !String(rowError.message||'').includes('payment_provider_settings')) throw rowError;

  const {data:secretText,error:secretError}=await admin.rpc('v34_get_payment_provider_secret',{p_provider:'stripe'});
  let stored:any={};
  if(!secretError && secretText){
    try{stored=JSON.parse(secretText)}catch{stored={}}
  }

  const secretKey=stored.secret_key||Deno.env.get('STRIPE_SECRET_KEY')||'';
  const webhookSecret=stored.webhook_secret||Deno.env.get('STRIPE_WEBHOOK_SECRET')||'';
  const publishableKey=row?.public_config?.publishable_key||'';
  const enabled=row ? row.enabled===true : !!secretKey;
  if(requireEnabled && !enabled) throw new Error('Stripe payments are disabled in Super Admin → Payment gateway settings.');
  if(!secretKey) throw new Error('Stripe secret key is not configured. Add it in Super Admin → Payment gateway settings.');
  return {secretKey,webhookSecret,publishableKey,enabled,mode:row?.mode||'test'};
}
