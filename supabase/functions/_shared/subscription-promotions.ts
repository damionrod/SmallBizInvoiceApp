import { stripeHeaders } from './payment-config.ts';

// Only subscription Checkout uses these offers. Customers submit a code, never a
// percentage, price, coupon ID or privilege flag. Terms cannot be edited after creation.
export function normaliseSubscriptionCode(raw:any):string {
  if(raw===undefined||raw===null||raw==='')return '';
  if(typeof raw!=='string')throw new Error('Enter a valid promo code.');
  const code=raw.trim().toUpperCase();
  if(!code)return '';
  if(!/^[A-Z0-9][A-Z0-9_-]{2,31}$/.test(code))throw new Error('Enter a valid promo code.');
  return code;
}

export async function subscriptionPromotion(admin:any,code:string,interval:string,now=Date.now()) {
  const {data:settings,error:settingsError}=await admin.from('subscription_promotion_settings').select('enabled,revision').eq('singleton',true).single();
  if(settingsError||settings?.enabled!==true)throw new Error('Promo codes are currently unavailable. Remove the code to continue at the normal price.');
  const {data:offer,error}=await admin.from('subscription_promotion_codes').select('*').eq('code',code).maybeSingle();
  if(error)throw new Error('Could not check this promo code. Please try again.');
  if(!offer||offer.enabled!==true||!['monthly','annual'].includes(interval)||
    !['both',interval].includes(offer.billing_interval))throw new Error('This promo code is not available for the selected billing option.');
  const expiry=offer.expires_at===null?null:Date.parse(offer.expires_at);
  // Stripe requires at least 30 minutes. Leave one minute for request latency.
  if(expiry!==null&&(!Number.isFinite(expiry)||expiry<=now+31*60*1000))
    throw new Error('This promo code has expired or is too close to expiry to start checkout.');
  if(!Number.isInteger(offer.percent_off)||offer.percent_off<1||offer.percent_off>100||!['once','forever'].includes(offer.duration))
    throw new Error('This promo code needs an administrator review.');
  return {...offer,settingsRevision:settings.revision};
}

export async function subscriptionPromotionCoupon(secret:string,offer:any,price:any,projectRef:string) {
  const product=typeof price.product==='string'?price.product:price.product?.id;
  if(!/^prod_[A-Za-z0-9]+$/.test(product||'')||!Number.isSafeInteger(price.unit_amount)||price.unit_amount<=0)
    throw new Error('The subscription price cannot safely use this offer.');
  const id=`frindly-promo-${projectRef}-${offer.id}-${product}`;
  const headers=stripeHeaders(secret);
  const read=await fetch('https://api.stripe.com/v1/coupons/'+encodeURIComponent(id),{headers,signal:AbortSignal.timeout(15000)});
  let coupon=await read.json();
  if(read.status===404){
    const form=new URLSearchParams({id,name:`${offer.code} · ${offer.percent_off}% off`,percent_off:String(offer.percent_off),duration:offer.duration,
      'applies_to[products][0]':product,'metadata[frindly_promotion_id]':offer.id,'metadata[frindly_project]':projectRef});
    if(offer.expires_at)form.set('redeem_by',String(Math.floor(Date.parse(offer.expires_at)/1000)));
    const created=await fetch('https://api.stripe.com/v1/coupons',{method:'POST',headers:{...stripeHeaders(secret,true),'Idempotency-Key':id},body:form,signal:AbortSignal.timeout(15000)});
    coupon=await created.json();
    if(!created.ok&&coupon?.error?.code==='resource_already_exists'){
      const retry=await fetch('https://api.stripe.com/v1/coupons/'+encodeURIComponent(id),{headers,signal:AbortSignal.timeout(15000)});
      coupon=await retry.json();if(!retry.ok)throw new Error('Could not verify the subscription offer.');
    }else if(!created.ok)throw new Error('Could not prepare the subscription offer. Please try again.');
  }else if(!read.ok)throw new Error('Could not check the subscription offer. Please try again.');
  if(coupon.id!==id||coupon.valid!==true||coupon.deleted||Number(coupon.percent_off)!==offer.percent_off||coupon.amount_off!=null||
    coupon.duration!==offer.duration||coupon.metadata?.frindly_promotion_id!==offer.id||coupon.metadata?.frindly_project!==projectRef||
    coupon.applies_to?.products?.length!==1||coupon.applies_to.products[0]!==product||
    (coupon.redeem_by??null)!==(offer.expires_at?Math.floor(Date.parse(offer.expires_at)/1000):null))
    throw new Error('The stored subscription offer does not match its approved terms. Contact support.');
  return id;
}
