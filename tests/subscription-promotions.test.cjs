'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {stripTypeScriptTypes}=require('node:module');
const source=name=>fs.readFileSync('supabase/functions/'+name,'utf8').replace(/^import .*;\s*$/gm,'').replace(/^export /gm,'');
const offer={id:'offer-fixture',code:'WELCOME20',percent_off:20,duration:'once',billing_interval:'both',expires_at:null,enabled:true};
function harness(options={}){
 const calls=[],network=[],created=[],state={settings:{enabled:true,revision:1},offer:{...offer},...options};let handler;
 const tables={profiles:{email:'test@example.invalid'},plans:{id:'plan-a',monthly_price:50,annual_price:500,stripe_price_id:'price_month',stripe_annual_price_id:'price_year'},subscriptions:{},subscription_promotion_settings:state.settings,subscription_promotion_codes:state.offer};
 const db={auth:{getUser:async()=>({data:{user:state.user===false?null:{id:'user-a',email:'test@example.invalid'}}})},rpc:async name=>({data:name==='current_business_id'?'business-a':state.role||'owner'}),from(table){calls.push(table);let filters={};return{select(){return this},eq(k,v){filters[k]=v;return this},async single(){return this.maybeSingle()},async maybeSingle(){if(table==='subscription_promotion_settings'&&state.settingsError)return {error:Error('database unavailable')};return{data:table==='subscription_promotion_codes'&&filters.code!==state.offer.code?null:tables[table]}}}}};
 const context=vm.createContext({Request,Response,URL,URLSearchParams,AbortSignal,Date,console,
  stripeHeaders:()=>({}),corsHeaders:()=>({}),clientIp:()=>'',enforceRateLimit:async()=>{},randomIntegrationSuffix:()=> 'fixture',
  createClient:()=>db,getStripeConfig:async()=>({secretKey:'fixture'}),refereeCheckoutDiscount:async()=>state.reward||null,
  activeBillingSubscriptions:async()=>[],billingSubscription:async()=>state.subscription,
  billingRequest:async(_key,path)=>{network.push(path);return{}},
  Deno:{serve:fn=>handler=fn,env:{get:key=>key==='SUPABASE_URL'?'https://market-fixture.supabase.co':key}},
  async fetch(url,init={}){
   network.push(url);const path=new URL(url).pathname;
   if(path.startsWith('/v1/prices/'))return Response.json({id:path.endsWith('year')?'price_year':'price_month',active:true,unit_amount:path.endsWith('year')?50000:5000,currency:'nzd',recurring:{interval:path.endsWith('year')?'year':'month'},product:'prod_fixture'});
   if(path==='/v1/coupons'&&init.method==='POST'){
    const f=init.body;created.push(f);const c={id:f.get('id'),valid:true,percent_off:Number(f.get('percent_off')),duration:f.get('duration'),redeem_by:f.has('redeem_by')?Number(f.get('redeem_by')):null,applies_to:{products:[f.get('applies_to[products][0]')]},metadata:{frindly_promotion_id:f.get('metadata[frindly_promotion_id]'),frindly_project:f.get('metadata[frindly_project]')}};
    return Response.json(state.badCoupon?{...c,percent_off:99}:c);
   }
   if(path.startsWith('/v1/coupons/'))return Response.json(state.existingCoupon||{error:{code:'resource_missing'}},{status:state.existingCoupon?200:404});
   if(path==='/v1/checkout/sessions'){created.push(init.body);if(state.disableAfterSession)state.settings.enabled=false;return Response.json({id:'cs_fixture',url:'https://checkout.stripe.com/c/pay/fixture'});}
   throw Error('Unexpected network request '+url);
  }
 });
 vm.runInContext(stripTypeScriptTypes(source('_shared/subscription-promotions.ts')),context);
 vm.runInContext(stripTypeScriptTypes(source('create-checkout/index.ts')),context);
 const api=vm.runInContext('({normaliseSubscriptionCode,subscriptionPromotion,subscriptionPromotionCoupon})',context);
 return{api,db,state,tables,calls,network,created,send:body=>handler(new Request('https://market-fixture.supabase.co/functions/v1/create-checkout',{method:'POST',headers:{origin:'https://example.invalid'},body:JSON.stringify({planSlug:'pro',returnUrl:'https://example.invalid',promoCode:'WELCOME20',...body})}))};
}
test('codes normalise without accepting objects, oversized input or provider IDs',()=>{const {api}=harness();assert.equal(api.normaliseSubscriptionCode(' welcome20 '),'WELCOME20');for(const code of [{percent_off:100},'a'.repeat(33),'bad<script>'])assert.throws(()=>api.normaliseSubscriptionCode(code));});
for(const interval of ['monthly','annual'])for(const duration of ['once','forever'])test(`${interval} ${duration}: approved percentage passed to Stripe; client discount fields ignored`,async()=>{const h=harness({offer:{...offer,duration}}),r=await h.send({billingInterval:interval,percent_off:100,couponId:'coupon_attacker'});assert.equal(r.status,200,JSON.stringify(await r.clone().json()));const [coupon,session]=h.created;assert.equal(coupon.get('percent_off'),'20');assert.equal(coupon.get('duration'),duration);assert.equal(session.get('line_items[0][price]'),interval==='annual'?'price_year':'price_month');assert.equal(session.get('discounts[0][coupon]'),coupon.get('id'));assert.equal(session.get('allow_promotion_codes'),null);assert.equal(session.get('subscription_data[metadata][subscription_promotion_id]'),offer.id);assert.ok(Number(session.get('expires_at'))<=Date.now()/1000+1860);});
for(const [name,options] of [['global disabled',{settings:{enabled:false}}],['code disabled',{offer:{...offer,enabled:false}}],['expired',{offer:{...offer,expires_at:'2020-01-01T00:00:00Z'}}],['near expiry',{offer:{...offer,expires_at:new Date(Date.now()+60000).toISOString()}}],['wrong interval',{offer:{...offer,billing_interval:'annual'}}],['settings error',{settingsError:true}],['invalid terms',{offer:{...offer,percent_off:101}}]])test(`${name}: no coupon or checkout created`,async()=>{const h=harness(options);assert.notEqual((await h.send()).status,200);assert.equal(h.created.length,0);});
test('unrecognised code is rejected before creating a discount',async()=>{const h=harness();assert.equal((await h.send({promoCode:'WRONG'})).status,400);assert.equal(h.created.length,0);});
test('referral reward is preserved and cannot stack with a code',async()=>{const h=harness({reward:{couponId:'referral',referralId:'ref-a'}});assert.equal((await h.send()).status,409);assert.equal(h.created.length,0);const r=await h.send({promoCode:''});assert.equal(r.status,200);assert.equal(h.created.at(-1).get('discounts[0][coupon]'),'referral');});
test('ordinary checkout never reads the optional promotion schema',async()=>{const h=harness({settingsError:true});assert.equal((await h.send({promoCode:''})).status,200);assert.ok(!h.calls.includes('subscription_promotion_settings'));assert.equal(h.created.at(-1).get('discounts[0][coupon]'),null);});
test('only authenticated business owner can reach discount issuance',async()=>{for(const options of [{user:false},{role:'admin'},{role:'viewer'}]){const h=harness(options);assert.ok([401,403].includes((await h.send()).status));assert.equal(h.created.length,0);}});
test('codes cannot mutate an existing subscription or be used during confirmation',async()=>{const h=harness();assert.equal((await h.send({action:'confirm'})).status,400);h.tables.subscriptions={stripe_subscription_id:'sub_fixture'};h.state.subscription={id:'sub_fixture',status:'active'};assert.equal((await h.send()).status,409);assert.equal(h.created.length,0);});
test('provider coupon mismatch fails closed',async()=>{const h=harness({badCoupon:true});assert.equal((await h.send()).status,400);assert.equal(h.created.length,1);});
test('coupon terms and product binding are stable across retries',async()=>{const h=harness();await h.send();const f=h.created[0];h.state.existingCoupon={id:f.get('id'),valid:true,percent_off:20,duration:'once',redeem_by:null,applies_to:{products:['prod_fixture']},metadata:{frindly_promotion_id:offer.id,frindly_project:'market-fixture'}};const count=h.created.length;assert.equal((await h.send()).status,200);assert.equal(h.created.length,count+1);});
test('disable during provider creation expires the session before exposing its URL',async()=>{const h=harness({disableAfterSession:true}),r=await h.send();assert.equal(r.status,400);assert.ok(h.network.includes('checkout/sessions/cs_fixture/expire'));assert.equal((await r.json()).url,undefined);});

const frontend=fs.readFileSync('public/saas.js','utf8');
test('promo entry is hidden and cleared when switched off or availability fails',async()=>{
 for(const response of [{data:false},{error:Error('unavailable')},null]){
  const nodes={field:{hidden:false},input:{value:'STALECODE'}},state={client:{rpc:async()=>{if(response===null)throw Error('offline');return response;}}};
  const ctx=vm.createContext({state,q:id=>nodes[id]});
  vm.runInContext(frontend.slice(frontend.indexOf('async function loadPromotionEntry'),frontend.indexOf('async function renderAdminPromotions')),ctx);
  await ctx.loadPromotionEntry('field','input');assert.equal(nodes.field.hidden,true);assert.equal(nodes.input.value,'');
 }
});
test('selected promo code travels with the plan to the existing checkout endpoint',async()=>{
 const calls=[],location={href:''},ctx=vm.createContext({getCheckoutAvailability:async()=>true,planBillingAction:async b=>{calls.push(b);return{url:'https://checkout.stripe.com/fixture'}},billingReturnTarget:()=> 'https://example.invalid',location,alert:()=>assert.fail('unexpected error')});
 vm.runInContext(frontend.slice(frontend.indexOf('async function startCheckout'),frontend.indexOf('async function planBillingAction')),ctx);
 assert.equal(await ctx.startCheckout('pro',null,{billingInterval:'annual',promoCode:'WELCOME20'}),true);
 assert.equal(calls[0].promoCode,'WELCOME20');assert.equal(calls[0].billingInterval,'annual');assert.equal(calls[0].action,'start');assert.equal(location.href,'https://checkout.stripe.com/fixture');
});
test('signup resume preserves a code but refuses another signed-in account',async()=>{
 let calls=0;const state={user:{id:'u',email:'u@example.invalid'}},pending={userId:'u',email:'u@example.invalid',planSlug:'pro',billingInterval:'annual',promoCode:'WELCOME20'},ctx=vm.createContext({URLSearchParams,location:{search:''},state,readPendingSignupCheckout:()=>pending,clearPendingSignupCheckout:()=>{},getSubscription:async()=>({status:'trialing'}),startCheckout:async(_slug,_btn,opts)=>{calls++;assert.equal(opts.promoCode,'WELCOME20');return true}});
 vm.runInContext(frontend.slice(frontend.indexOf('async function maybeContinueSignupCheckout'),frontend.indexOf('async function openAdminPortal')),ctx);
 assert.equal(await ctx.maybeContinueSignupCheckout(),true);state.user={id:'other',email:'other@example.invalid'};assert.equal(await ctx.maybeContinueSignupCheckout(),false);assert.equal(calls,1);
});
