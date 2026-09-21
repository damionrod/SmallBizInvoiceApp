const fs=require('fs');
const path=require('path');
const root=path.join(__dirname,'..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const checks=[];
const assert=(name,condition)=>{checks.push([name,!!condition]);if(!condition)throw new Error(name)};

const shared=read('supabase/functions/_shared/payment-config.ts');
const checkout=read('supabase/functions/create-checkout/index.ts');
const portal=read('supabase/functions/create-portal/index.ts');
const webhook=read('supabase/functions/stripe-webhook/index.ts');
const tester=read('supabase/functions/test-payment-provider/index.ts');

assert('shared Stripe API version is current',shared.includes("2026-07-29.dahlia"));
assert('checkout uses Vault-backed shared config',checkout.includes("../_shared/payment-config.ts"));
assert('checkout uses subscription mode',checkout.includes("f.set('mode','subscription')"));
assert('checkout sends integration identifier',checkout.includes("integration_identifier"));
assert('checkout does not hardcode payment method types',!checkout.includes('payment_method_types'));
assert('portal uses shared config',portal.includes("../_shared/payment-config.ts"));
assert('webhook verifies Stripe signature',webhook.includes('constructEventAsync'));
assert('webhook uses current Stripe API version',webhook.includes('STRIPE_API_VERSION'));
assert('connection test uses current Stripe headers',tester.includes('stripeHeaders'));
for(const [name] of checks)console.log('PASS',name);
console.log(`${checks.length}/${checks.length} PASS`);
