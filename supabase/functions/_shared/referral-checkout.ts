import { stripeHeaders } from './payment-config.ts';

/** A referee's signup discount is tied to their registered business and immutable campaign version. */
export async function refereeCheckoutDiscount(admin:any, stripe:string, businessId:string,
  plan:any, interval:'monthly'|'annual', price:any) {
  const {data:r,error:refError}=await admin.from('referrals')
    .select('id,status,campaign_version_id,referee_checkout_coupon_id')
    .eq('referred_business_id',businessId).maybeSingle();
  if(refError)throw refError;
  if(!r || !['signed_up','pending_qualification'].includes(r.status) || r.referee_checkout_coupon_id)return null;
  const {data:v,error:versionError}=await admin.from('referral_campaign_versions')
    .select('referee_reward_enabled,referee_reward_type,referee_reward_value')
    .eq('id',r.campaign_version_id).single();
  if(versionError)throw versionError;
  if(!v?.referee_reward_enabled || v.referee_reward_type==='none')return null;
  const value=Number(v.referee_reward_value);
  const months=v.referee_reward_type==='free_months'?value:1;
  const monthly=Number(plan.monthly_price);
  if(!Number.isFinite(monthly)||monthly<=0||!Number.isFinite(value)||value<0)throw new Error('Referral reward is not configured correctly.');
  const currency=String(price.currency||'nzd').toLowerCase();
  const couponId=`frindly-referee-${r.id}-${plan.id}-${interval}`;
  const form=new URLSearchParams();
  form.set('id',couponId);
  form.set('name','Frindly referral welcome reward');
  form.set('max_redemptions','1');
  form.set('metadata[referral_id]',r.id);
  form.set('metadata[campaign_version_id]',r.campaign_version_id);
  if(interval==='monthly' && ['free_months','month_equivalent'].includes(v.referee_reward_type)) {
    if(!Number.isInteger(months)||months<1||months>12)throw new Error('Free months must be a whole number between 1 and 12.');
    form.set('percent_off','100');
    form.set('duration','repeating');
    form.set('duration_in_months',String(months));
  } else {
    let amount=v.referee_reward_type==='fixed_credit'?value:
      v.referee_reward_type==='percent_month'?monthly*value/100:monthly*months;
    amount=Math.min(Number(price.unit_amount),Math.round(amount*100))/100;
    if(!Number.isFinite(amount)||amount<=0)return null;
    form.set('amount_off',String(Math.round(amount*100)));
    form.set('currency',currency);
    form.set('duration','once');
  }
  // A stable ID plus Stripe idempotency makes abandoned Checkout sessions safe to retry.
  const response=await fetch('https://api.stripe.com/v1/coupons',{
    method:'POST',headers:{...stripeHeaders(stripe,true),'Idempotency-Key':couponId},body:form
  });
  const created=await response.json();
  if(!response.ok && created?.error?.code!=='resource_already_exists')
    throw new Error(created?.error?.message||'Unable to create the referral offer.');
  if(!response.ok){
    const existing=await fetch('https://api.stripe.com/v1/coupons/'+encodeURIComponent(couponId),{headers:stripeHeaders(stripe)});
    const coupon=await existing.json();
    if(!existing.ok||coupon.metadata?.referral_id!==r.id||coupon.valid!==true)
      throw new Error('The referral reward coupon cannot be reused.');
  }
  return {referralId:r.id,couponId};
}
