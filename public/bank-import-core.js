(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.BankImportCore=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';

  const norm=value=>String(value??'').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim();
  const cleanCell=value=>String(value??'').normalize('NFKC').replace(/\s+/g,' ').trim().toLowerCase();

  function exactIndex(headers,names){
    const wanted=new Set(names.map(norm));
    return headers.findIndex(header=>wanted.has(norm(header)));
  }

  function containsIndex(headers,names){
    const wanted=names.map(norm);
    return headers.findIndex(header=>wanted.some(name=>name&&norm(header).includes(name)));
  }

  function preferredIndex(headers,exactNames,containsNames=exactNames){
    const exact=exactIndex(headers,exactNames);
    return exact>=0?exact:containsIndex(headers,containsNames);
  }

  function autoMap(headers){
    const amount=preferredIndex(headers,['amount','value']);
    let reference=preferredIndex(headers,['reference','transaction reference','bank reference'],['reference']);
    if(reference<0)reference=preferredIndex(headers,['ref'],[' ref ','ref']);
    if(reference<0)reference=exactIndex(headers,['code']);
    return {
      date:preferredIndex(headers,['date','transaction date','posted date'],['transaction date','posted','date']),
      amount,
      debit:amount>=0?-1:preferredIndex(headers,['debit','withdrawal','money out']),
      credit:amount>=0?-1:preferredIndex(headers,['credit','deposit','money in']),
      description:preferredIndex(headers,['description','details','memo','particulars','particular'],['description','details','memo','particular']),
      reference,
      payee:preferredIndex(headers,['payee','name','merchant'],['payee','merchant','name']),
      id:preferredIndex(headers,['transaction id','bank transaction id','bank id','unique id']),
      batch:preferredIndex(headers,['batch number','batch no','batch']),
      serial:preferredIndex(headers,['serial','serial number']),
      transactionCode:preferredIndex(headers,['transaction code','tran code']),
      processedDate:preferredIndex(headers,['processed date','processing date']),
      transactionType:preferredIndex(headers,['tran type','transaction type']),
    };
  }

  function parseDate(value){
    const v=String(value??'').trim();let match;
    if((match=v.match(/^(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})/)))return `${match[1]}-${match[2].padStart(2,'0')}-${match[3].padStart(2,'0')}`;
    if((match=v.match(/^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2,4})/))){let year=match[3];if(year.length===2)year='20'+year;return `${year}-${match[2].padStart(2,'0')}-${match[1].padStart(2,'0')}`}
    const date=new Date(v);return Number.isNaN(date.getTime())?'':date.toISOString().slice(0,10);
  }

  function numberValue(value){
    const parsed=Number(String(value??'').replace(/[$, ]/g,''));
    return Number.isFinite(parsed)?parsed:0;
  }

  function legacyFingerprint(row){
    const raw=[row.transaction_date,numberValue(row.amount).toFixed(2),norm(row.reference),norm(row.description),norm(row.payee),norm(row.bank_transaction_id)].join('|');
    let hash=2166136261;
    for(let index=0;index<raw.length;index++){hash^=raw.charCodeAt(index);hash=Math.imul(hash,16777619)}
    return (hash>>>0).toString(16).padStart(8,'0')+'-'+raw.length;
  }

  function sourcePayload(headers,row,rowNumber){
    const payload={_frindly_csv_row:rowNumber};
    const used=new Map();
    headers.forEach((header,index)=>{
      const base=String(header??'').trim()||`Column ${index+1}`;
      const count=(used.get(base)||0)+1;used.set(base,count);
      payload[count===1?base:`${base} (${count})`]=String(row[index]??'');
    });
    return payload;
  }

  function canonicalSourceRow(headers,row){
    const pairs=headers.map((header,index)=>[norm(header)||`column ${index+1}`,cleanCell(row[index])]);
    return JSON.stringify({version:2,source:'csv',columns:pairs});
  }

  async function sha256Hex(value){
    const text=String(value);
    if(globalThis.crypto?.subtle&&typeof TextEncoder!=='undefined'){
      const digest=await globalThis.crypto.subtle.digest('SHA-256',new TextEncoder().encode(text));
      return Array.from(new Uint8Array(digest),byte=>byte.toString(16).padStart(2,'0')).join('');
    }
    if(typeof require==='function')return require('node:crypto').createHash('sha256').update(text,'utf8').digest('hex');
    throw new Error('Secure transaction fingerprinting is unavailable in this browser.');
  }

  async function buildMappedRows(headers,csvRows,mapping){
    const mapped=await Promise.all(csvRows.map(async(row,index)=>{
      let amount=mapping.amount>=0?numberValue(row[mapping.amount]):0;
      if(mapping.amount<0){
        const credit=mapping.credit>=0?numberValue(row[mapping.credit]):0;
        const debit=mapping.debit>=0?numberValue(row[mapping.debit]):0;
        amount=credit-debit;
      }
      const result={
        row:index+2,
        row_key:`csv-row-${index+2}`,
        transaction_date:parseDate(row[mapping.date]),
        amount,
        description:mapping.description>=0?String(row[mapping.description]??''):'',
        reference:mapping.reference>=0?String(row[mapping.reference]??''):'',
        payee:mapping.payee>=0?String(row[mapping.payee]??''):'',
        bank_transaction_id:mapping.id>=0?String(row[mapping.id]??''):'',
        source_payload:sourcePayload(headers,row,index+2),
      };
      result.legacy_fingerprint=legacyFingerprint(result);
      result.import_fingerprint='v2:'+await sha256Hex(canonicalSourceRow(headers,row));
      return result;
    }));
    return mapped.filter(row=>row.transaction_date&&row.amount);
  }

  return {norm,autoMap,parseDate,numberValue,legacyFingerprint,sourcePayload,canonicalSourceRow,sha256Hex,buildMappedRows};
});
