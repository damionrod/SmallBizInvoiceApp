/* Finlo shared frontend primitives — V61.72A
   Intentionally small: only behaviour-neutral utilities with identical semantics belong here. */
(()=>{
  'use strict';
  if(window.FinloCore)return;
  const byId=id=>document.getElementById(id);
  const num=value=>Number(value)||0;
  const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,ch=>({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'
  }[ch]));
  const toast=(message,{id='toast',duration=2600,error=false}={})=>{
    const el=document.getElementById(id);
    if(!el){alert(message);return}
    el.textContent=message;
    el.classList.toggle('error',!!error);
    el.classList.add('show');
    setTimeout(()=>el.classList.remove('show'),duration);
  };
  const money=(value,{currency='NZD',locale='en-NZ',currencyDisplay='symbol',minimumFractionDigits=2,maximumFractionDigits=2}={})=>{
    const code=String(currency||'NZD').toUpperCase();
    try{return new Intl.NumberFormat(locale||'en-NZ',{style:'currency',currency:code,currencyDisplay,minimumFractionDigits,maximumFractionDigits}).format(num(value))}
    catch{return `${code} ${num(value).toFixed(maximumFractionDigits)}`}
  };
  const csvCell=value=>{
    let text=String(value??'');
    if(/^[=+@]/.test(text)||(/^-/).test(text)&&!/^-[0-9.]+$/.test(text))text="'"+text;
    return `"${text.replace(/"/g,'""')}"`;
  };
  const rowsToCsv=(rows,{bom=false,newline='\r\n'}={})=>(bom?'\ufeff':'')+(rows||[]).map(row=>(row||[]).map(csvCell).join(',')).join(newline);
  const downloadBlob=(name,blob,{revokeDelay=1500}={})=>{
    const anchor=document.createElement('a'),url=URL.createObjectURL(blob);
    anchor.href=url;anchor.download=name;document.body.appendChild(anchor);anchor.click();anchor.remove();
    setTimeout(()=>URL.revokeObjectURL(url),revokeDelay);
  };
  const downloadCsvRows=(name,rows,options={})=>downloadBlob(name,new Blob([rowsToCsv(rows,options)],{type:'text/csv;charset=utf-8'}),options);
  const parseCsv=(text)=>{
    const rows=[];let row=[],cell='',quoted=false;
    for(let i=0;i<String(text||'').length;i++){
      const ch=text[i],next=text[i+1];
      if(quoted){if(ch==='"'&&next==='"'){cell+='"';i++}else if(ch==='"')quoted=false;else cell+=ch}
      else if(ch==='"')quoted=true;
      else if(ch===','){row.push(cell);cell=''}
      else if(ch==='\n'){row.push(cell.replace(/\r$/,''));rows.push(row);row=[];cell=''}
      else if(ch!=='\r')cell+=ch;
    }
    if(cell||row.length){row.push(cell);rows.push(row)}
    return rows;
  };
  const loadScript=(src)=>new Promise((resolve,reject)=>{
    const script=document.createElement('script');
    script.src=src;
    script.onload=()=>resolve(script);
    script.onerror=()=>reject(new Error(`Unable to load ${src}`));
    document.body.appendChild(script);
  });
  const loadScriptsSequentially=async(sources)=>{
    await Promise.all((sources||[]).map(loadScript));
  };
  Object.freeze(window.FinloCore={
    dom:Object.freeze({byId}),
    value:Object.freeze({num}),
    format:Object.freeze({money}),
    text:Object.freeze({escapeHtml}),
    ui:Object.freeze({toast}),
    csv:Object.freeze({csvCell,rowsToCsv,downloadCsvRows,parseCsv,downloadBlob}),
    loader:Object.freeze({loadScript,loadScriptsSequentially})
  });
})();
