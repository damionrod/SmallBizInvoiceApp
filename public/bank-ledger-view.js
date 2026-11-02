/* Shared bank display grouping. Original posted journal accounts remain unchanged. */
(()=>{
 'use strict';
 function group(accounts,banks,aliases=[]){
  const byId=new Map(accounts.map(a=>[a.id,a])),banksById=new Map(banks.map(b=>[b.id,b]));
  const linked=new Set(banks.map(b=>b.accounting_account_id).filter(Boolean));
  const destinations=new Map();
  for(const link of aliases){
   const bank=banksById.get(link.bank_account_id),source=byId.get(link.accounting_account_id),target=byId.get(bank?.accounting_account_id);
   if(!bank||!source||!target)throw new Error('Historical bank mapping is incomplete');
   if(destinations.has(source.id)&&destinations.get(source.id).id!==bank.id)throw new Error('Historical bank mapping is ambiguous');
   destinations.set(source.id,bank);
  }
  const codeMap=new Map(),names=new Map();
  for(const a of accounts){
   const key=a.system_account_key||'',other=a.system_key||'';
   if(a.account_type!=='bank'&&!linked.has(a.id)&&!destinations.has(a.id)&&!['bank','cash','cash_on_hand','bank_main'].includes(key)&&!['bank','cash','cash_on_hand','bank_main'].includes(other))continue;
   const primary=banks.filter(b=>b.accounting_account_id===a.id);
   const bank=destinations.get(a.id)||(primary.length===1?primary[0]:null);
   const target=bank?byId.get(bank.accounting_account_id):a;
   if(!target)throw new Error('Bank ledger mapping is incomplete');
   const code=String(target.account_code);codeMap.set(String(a.account_code),code);
   names.set(code,bank?(bank.name||target.account_name||code):(a.account_name||code));
  }
  return {codeMap,names};
 }
 window.FrindlyBankLedger={group};
})();
