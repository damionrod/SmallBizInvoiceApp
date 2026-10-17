'use strict';
// Offline checks only. This script never invokes the authenticated HTTP/RLS suite.
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const focused=['market-migration-context.test.cjs','market-assets.test.cjs','market-isolation.test.cjs','v6185-stripe-account-revisit.test.js','v6186-stripe-subscription-sync.test.js','v6190h-invoice-address.test.js','v6190u-auth-signin.test.js','v6221-planning-data.test.cjs','customer-form.test.js','v6220-email-banking.test.js','v6220-issued-sales.test.js','v6220-reminder-auth.test.js'];
function run(args){const out=spawnSync(process.execPath,args,{cwd:root,stdio:'inherit'});if(out.error)throw out.error;if(out.status!==0)process.exit(out.status||1)}
const js=fs.readdirSync(path.join(root,'public')).filter(x=>x.endsWith('.js'));
for(const file of js)run(['--check',path.join('public',file)]);
console.log(`Frontend syntax: ${js.length} files passed.`);
const full=process.argv.includes('--full');
const tests=full?fs.readdirSync(path.join(root,'tests')).filter(x=>/\.test\.(js|cjs)$/.test(x)&&x!=='v6179e-authenticated-http.test.js'):focused;
console.log(full?'Running the complete offline regression suite. Authenticated HTTP tests are a separate Market gate.':'Running the focused Market reliability checks. This is not the complete legacy suite.');
run(['--test','--test-reporter=tap',...tests.map(x=>path.join('tests',x))]);
