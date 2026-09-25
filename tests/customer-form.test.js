const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../public/app.js'),'utf8');
const take=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
let sequence=0;
function fixture(record){
  const elements={};
  const element=id=>elements[id]??=( {value:'',dataset:{},classList:{add(){},remove(){}},querySelectorAll(){return []},querySelector(){return null},innerHTML:'',textContent:''} );
  const saved=[];
  const context={
    $:element, esc:s=>String(s).replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;'),
    customerCategories:()=>['Residential','Commercial'],renderCustomDraft(){},makeLocalId:()=>`draft-${++sequence}`,
    normalizeCustomer:c=>({customer_type:'individual',category:'',name:'',address:'',dob:'',contacts:[],custom_fields:[],...c}),
    customerNo:()=> 'C0042',allCustomers:async()=>record?[record]:[],customerContactsDraft:[],customerCustomDraft:[],editingCustomerId:null,
    persistCustomer:async(c,edit)=>{saved.push({c,edit});return c},refreshCustomerPickers:async()=>{},renderCustomers:async()=>{},toast:()=>{},
    window:{dispatchEvent(){}},CustomEvent:class{constructor(name,init){this.name=name;this.detail=init.detail}}
  };
  vm.createContext(context);
  vm.runInContext(take('function customerFormHtml(c){','function renderCustomDraft()'),context);
  vm.runInContext(take('async function openCustomerEditor(','window.openCustomerEditor=openCustomerEditor;'),context);
  vm.runInContext(take('async function saveCustomerEditor(){','async function openCustomerProfile('),context);
  const fill=(c)=>{element('cfName').value=c.name;element('cfType').value=c.customer_type;element('cfCategory').value=c.category;element('cfAddress').value=c.address;element('cfDob').value=c.dob};
  return {context,element,saved,fill};
}
test('form presents compact core fields, optional per-contact DOB and collapsed extra information',async()=>{
  const f=fixture();await f.context.openCustomerEditor();
  const form=f.element('customerFormArea').innerHTML;
  const contacts=f.element('cfContacts').innerHTML;
  assert.match(form,/id="cfType"/);assert.match(form,/id="cfCategory"/);
  assert.match(form,/id="cfAddress" rows="1"/);assert.match(form,/id="cfDob" type="hidden"/);
  assert.match(form,/<details class="customer-more-details"/);
  assert.match(contacts,/<h3>Primary contact<\/h3>/);
  assert.match(contacts,/Date of birth \(optional\)<input type="date" data-ci="0" data-ck="dob"/);
  assert.doesNotMatch(contacts,/class="contact-card"/);
  f.fill({name:'New customer',customer_type:'individual',category:'Residential',address:'Long address',dob:''});
  await f.context.saveCustomerEditor();
  assert.equal(f.saved[0].c.contacts.length,0,'untouched primary placeholder is not persisted');
});
test('individual customer saves filled primary contact and its DOB',async()=>{
  const f=fixture();await f.context.openCustomerEditor();
  f.fill({name:'Person',customer_type:'individual',category:'Residential',address:'14 Example Road',dob:''});
  Object.assign(f.context.customerContactsDraft[0],{name:'First contact',email:'first@example.com',mobile:'0211234567',dob:'1990-05-04'});
  await f.context.saveCustomerEditor();
  assert.equal(f.saved[0].c.contacts[0].dob,'1990-05-04');
  assert.equal(f.saved[0].c.contacts[0].billing,true);
  assert.equal(f.saved[0].c.contacts[0]._draftOnly,undefined);
});
test('business edit retains customer DOB, per-contact DOBs, custom fields and chosen billing contact',async()=>{
  const old={id:'existing',customer_number:'C0010',customer_type:'business',category:'Commercial',name:'Company',address:'One Road',dob:'1970-01-01',custom_fields:[{label:'Code',value:'ABC'}],contacts:[{id:'one',name:'Alice',email:'a@example.com',dob:'1985-01-01',billing:false},{id:'two',name:'Bob',email:'b@example.com',dob:'1986-02-02',billing:true}]};
  const f=fixture(old);await f.context.openCustomerEditor('existing');
  const html=f.element('cfContacts').innerHTML;
  assert.match(html,/value="1985-01-01"/);assert.match(html,/value="1986-02-02"/);
  assert.match(html,/<details class="customer-contact-extra" data-contact-index="1" >/);
  assert.match(f.element('customerFormArea').innerHTML,/id="cfDob" type="hidden" value="1970-01-01"/);
  f.fill(old);f.context.customerContactsDraft[1].dob='1986-02-03';
  await f.context.saveCustomerEditor();
  const {c,edit}=f.saved[0];assert.equal(edit,true);
  assert.equal(c.dob,'1970-01-01');assert.equal(c.contacts[0].dob,'1985-01-01');assert.equal(c.contacts[1].dob,'1986-02-03');
  assert.deepEqual(Array.from(c.contacts,x=>x.billing),[false,true]);
  assert.equal(c.custom_fields[0].value,'ABC');
});
test('additional contact starts expanded and can be selected for billing',async()=>{
  const f=fixture();await f.context.openCustomerEditor();
  f.element('cfAddContact').onclick();
  assert.match(f.element('cfContacts').innerHTML,/<details class="customer-contact-extra" data-contact-index="1" open>/);
  f.fill({name:'Multi',customer_type:'business',category:'Commercial',address:'Two Road',dob:''});
  Object.assign(f.context.customerContactsDraft[0],{name:'Primary',dob:'1991-07-08',billing:false});
  Object.assign(f.context.customerContactsDraft[1],{name:'Billing',dob:'1992-07-08',billing:true});
  await f.context.saveCustomerEditor();
  assert.equal(f.saved[0].c.contacts.length,2);
  assert.deepEqual(Array.from(f.saved[0].c.contacts,x=>x.dob),['1991-07-08','1992-07-08']);
  assert.deepEqual(Array.from(f.saved[0].c.contacts,x=>x.billing),[false,true]);
});
