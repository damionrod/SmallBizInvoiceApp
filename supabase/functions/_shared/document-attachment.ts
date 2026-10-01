export const DOCUMENT_BUCKET = "frindly-documents";

export function storedDocumentPath(businessId:string, kind:"invoice"|"quote"|"payslip", recordId:string){
  return `${businessId}/${kind}/${recordId}.pdf`;
}

function bytesToBase64(bytes:Uint8Array){
  let binary="";
  const chunk=0x8000;
  for(let i=0;i<bytes.length;i+=chunk){
    binary+=String.fromCharCode(...bytes.subarray(i,Math.min(i+chunk,bytes.length)));
  }
  return btoa(binary);
}

export async function storedPdfAttachment(admin:any,businessId:string,kind:"invoice"|"quote"|"payslip",recordId:string,filename:string){
  const path=storedDocumentPath(businessId,kind,recordId);
  const {data,error}=await admin.storage.from(DOCUMENT_BUCKET).download(path);
  if(error||!data) throw new Error("The PDF could not be prepared for email. Please try sending again.");
  const bytes=new Uint8Array(await data.arrayBuffer());
  if(!bytes.length) throw new Error("The stored PDF is empty. Please try sending again.");
  return {filename,content:bytesToBase64(bytes)};
}


export async function storePdfAndAttachment(admin:any,businessId:string,kind:"invoice"|"quote"|"payslip",recordId:string,file:File,filename:string){
  if(!(file instanceof File) || file.size < 1) throw new Error("The PDF could not be prepared for email. Please try sending again.");
  if(file.size > 10 * 1024 * 1024) throw new Error("The PDF is too large to email.");
  const type=String(file.type||"").toLowerCase();
  if(type && type!=="application/pdf") throw new Error("The email attachment must be a PDF.");
  const bytes=new Uint8Array(await file.arrayBuffer());
  if(bytes.length < 5 || new TextDecoder().decode(bytes.subarray(0,5))!=="%PDF-") throw new Error("The email attachment is not a valid PDF.");
  const path=storedDocumentPath(businessId,kind,recordId);
  const {error}=await admin.storage.from(DOCUMENT_BUCKET).upload(path,bytes,{contentType:"application/pdf",upsert:true,cacheControl:"3600"});
  if(error) throw new Error(`The PDF could not be stored for email: ${error.message||"Storage error"}`);
  return {filename,content:bytesToBase64(bytes)};
}
