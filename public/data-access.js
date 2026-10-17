(function(root,factory){
  'use strict';const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;else root.FrindlyData=api;
})(typeof window==='object'?window:globalThis,function(){
  'use strict';
  // Every caller supplies its own tenant/permission filters. The cursor is a
  // stable primary key; short pages are not evidence that the server is done.
  async function readAll(factory,{guard=()=>{},pageSize=500}={}){
    if(!Number.isInteger(pageSize)||pageSize<1||pageSize>1000)throw new Error('Invalid page size.');
    const rows=[],seen=new Set();let cursor=null;
    for(;;){
      guard();let query=factory().order('id',{ascending:true}).limit(pageSize);
      if(cursor!==null)query=query.gt('id',cursor);
      const {data,error}=await query;guard();if(error)throw error;
      if(!Array.isArray(data))throw new Error('The requested records could not be verified.');
      if(!data.length)return rows;
      for(const row of data){
        if(row.id===null||row.id===undefined||seen.has(String(row.id)))throw new Error('Records changed or pagination did not advance. Please retry.');
        seen.add(String(row.id));rows.push(row);
      }
      cursor=data[data.length-1].id;
    }
  }
  return Object.freeze({readAll});
});
