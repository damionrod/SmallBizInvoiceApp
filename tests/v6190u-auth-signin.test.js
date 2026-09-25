const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

const source=fs.readFileSync(path.join(__dirname,'../public/saas.js'),'utf8');
function harness(fail=false){
  const events=[],messages=[],elements={};
  const q=id=>elements[id]??=(id==='authShell'?{classList:{add(){},remove(){}}}:{value:''});
  q('loginEmail').value='example@example.com';q('loginPassword').value='password';
  let listener,release,entries=0,reloads=0;
  const unlocked=new Promise(resolve=>{release=resolve});
  const session={user:{id:'signed-in-user'}};
  const auth={
    getSession:async()=>({data:{session:null}}),
    onAuthStateChange:callback=>{listener=callback},
    signInWithPassword:async()=>{
      if(fail)return{error:new Error('Invalid login credentials')};
      // Model the auth lock: the library waits for its listener to return
      // before the account's next authenticated request can complete.
      await listener('SIGNED_IN',session);
      release();
      return{data:{session}};
    }
  };
  const state={client:null,loadedApp:false,referralCode:'',inviteToken:''};
  const context={state,q,C:{supabaseUrl:'https://example.supabase.co',supabaseKey:'public'},
    window:{supabase:{createClient:()=>({auth})}},document:{body:{classList:{add(){}}},querySelectorAll:()=>[]},
    location:{reload:()=>{reloads++}},setTimeout,console:{error:()=>{}},
    loadSignupPlans:async()=>{},prepareInviteMode:async()=>{},switchAuthTab:()=>{},
    message:(msg)=>messages.push(msg),enter:async()=>{entries++;await unlocked;state.loadedApp=true}
  };
  const initSource=source.slice(source.indexOf('  async function init(){'),source.indexOf('  function switchAuthTab('));
  const formSource=source.slice(source.indexOf('  function bindAuthUI(){'),source.indexOf("    q('signupForm').onsubmit=async e=>"))+'  }';
  assert.ok(initSource.includes('function enterOnce(session)'));
  vm.runInNewContext('let accountEntry=null;\n'+initSource+'\n'+formSource,context);
  return{context,state,q,events,messages,get entries(){return entries},get reloads(){return reloads},get listener(){return listener}};
}
test('successful sign-in completes after listener returns and enters the account exactly once',async()=>{
  const h=harness();await h.context.init();h.context.bindAuthUI();
  const submit=h.q('loginForm').onsubmit({preventDefault(){}});
  await Promise.race([submit,new Promise((_,reject)=>setTimeout(()=>reject(new Error('Login deadlocked inside the auth callback')),400))]);
  await new Promise(resolve=>setTimeout(resolve,10));
  assert.equal(h.entries,1);
  assert.equal(h.state.loadedApp,true);
  assert.equal(h.messages.at(-1),'Logging in…');
  assert.equal(h.reloads,0);
});
test('failed sign-in displays the auth error instead of leaving Logging in on screen',async()=>{
  const h=harness(true);await h.context.init();h.context.bindAuthUI();
  await h.q('loginForm').onsubmit({preventDefault(){}});
  assert.equal(h.messages.at(-1),'Invalid login credentials');
  assert.equal(h.entries,0);
});
