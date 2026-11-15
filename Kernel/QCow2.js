export const DISK_CHUNK=131072;
let pending,ex,current,output;
const Bytes=()=>new Uint8Array(ex.memory.buffer);
const Words=(ptr,count)=>Array.from(new BigInt64Array(ex.memory.buffer,Number(ptr),count),Number);
function Text(ptr,wide=false) {
  const bytes=Bytes(),view=new DataView(bytes.buffer),out=[];
  for(let at=Number(ptr),ch;ch=wide?view.getUint16(at,true):bytes[at];at+=wide?2:1)out.push(ch);
  return String.fromCharCode(...out);
}
async function Ready() {
  return pending??=Promise.resolve().then(async()=>{
    const url=new URL("../build/disk.wasm",import.meta.url),[{createHost},bytes]=await Promise.all([
      import("../holyc-wasm/src/runtime/host.js"),url.protocol==="file:"?
        (await import("node:fs/promises")).readFile(url):fetch(url).then(response=>{
          if(!response.ok)throw Error("Disk helper fetch "+response.status);
          return response.arrayBuffer();
        })]),host=createHost();
    Object.assign(host.env,{
      DskNameEq:(a,b)=>BigInt(Text(a,true).toUpperCase()===Text(b,true).toUpperCase()),
      DskFail:ptr=>{throw Error("Invalid or unsupported disk image: "+Text(ptr));},
      DskImageRead:(off,size,dst)=>Bytes().set(current.base.subarray(Number(off),Number(off+size)),Number(dst)),
      DskSectorRead:(lba,count,dst)=>current.readInto(Number(lba),Number(count),Bytes(),Number(dst)),
      DskSectorWrite:(lba,count,src)=>current.writeInto(Number(lba),Number(count),Bytes(),Number(src)),
      DskEntry:(name,attr,clus,size,off)=>output.push({name:Text(name,true),attr:Number(attr),clus:Number(clus),size:Number(size),off:Number(off)}),
      DskResult:(ptr,size)=>{output=Bytes().slice(Number(ptr),Number(ptr+size));}
    });
    const {instance}=await WebAssembly.instantiate(bytes,{env:host.env});
    ex=instance.exports;host.attach(instance);ex.__rt_init();
  }).catch(error=>{pending=null;throw error;});
}
function Use(disk,Run) {
  const prev=current,sp=ex.__sp.value;current=disk;
  try {return Run();}
  finally {current=prev;ex.__sp.value=sp;if(!prev){ex.DskTmpDel();output=null;}}
}
function StringPut(value) {
  const ptr=ex.DskTmp(BigInt((value.length+1)*2)),out=new Uint16Array(ex.memory.buffer,Number(ptr),value.length+1);
  for(let i=0;i<value.length;i++)out[i]=value.charCodeAt(i);
  out[value.length]=0;return ptr;
}
function Disk(base,virtualSize,bits=0,l1=0,chunks=null) {
  const size=2**bits,offsets=new Map();
  function Offset(pos) {
    const cluster=Math.floor(pos/size);
    let off=offsets.get(cluster);
    if(off===undefined) {
      if(offsets.size===65536)offsets.clear();
      offsets.set(cluster,off=Use(disk,()=>Number(ex.DskOffset(BigInt(cluster*size),BigInt(bits),BigInt(l1)))));
    }
    return off<0?-1:off+pos%size;
  }
  function Read(lba,count,dst,at) {
    for(let i=0;i<count;i++) {
      const pos=(lba+i)*512,changed=overlay.get(lba+i),off=changed?0:bits&&pos<virtualSize?Offset(pos):pos,
        source=changed||base||chunks?.get(Math.floor(pos/DISK_CHUNK)),from=changed?0:base?off:pos%DISK_CHUNK;
      if(source&&off>=0&&pos<virtualSize)dst.set(source.subarray(from,from+512),at+i*512);
      else dst.fill(0,at+i*512,at+(i+1)*512);
    }
  }
  const overlay=new Map(),disk={base,virtualSize,overlay,
    readInto:Read,
    writeInto(lba,count,src,at) {
      if(!Number.isSafeInteger(lba)||lba<0||!Number.isSafeInteger(count)||count<0||
          (lba+count)*512>virtualSize||at<0||at+count*512>src.length)
        throw Error("Disk write outside its sectors");
      for(let i=0;i<count;i++)overlay.set(lba+i,src.slice(at+i*512,at+(i+1)*512));
    }};
  return disk;
}

export async function makeDisk(base) {
  await Ready();
  const dimensions=Use({base},()=>Words(ex.DskInfo(BigInt(base.length)),3));
  return Disk(base,...dimensions);
}
export async function makeQcow2(base) {
  if(base.length<4||new DataView(base.buffer,base.byteOffset,base.length).getUint32(0)!==0x514649fb)
    throw Error("Invalid or unsupported qcow2 image: wrong magic");
  return makeDisk(base);
}
export async function makeRaw(base) {
  await Ready();
  if(base.length<512||base.length%512)throw Error("A raw disk image must contain complete 512-byte sectors.");
  return Disk(base,base.length);
}
export async function makeSparse(virtualSize,chunks) {
  await Ready();
  return Disk(null,virtualSize,0,0,chunks);
}
export function fat32List(disk,path="Home") {
  return Use(disk,()=>{output=[];ex.FatLst(BigInt(disk.virtualSize),StringPut(path));return output;});
}
export function fat32Read(disk,path,filename) {
  return Use(disk,()=>{
    output=null;ex.FatRead(BigInt(disk.virtualSize),StringPut(path),StringPut(filename));return output;
  });
}
export function fat32Upload(disk,filename,bytes,path="Home") {
  return Use(disk,()=>{
    const p=StringPut(path),name=StringPut(filename),buf=ex.DskTmp(BigInt(bytes.length));
    Bytes().set(bytes,Number(buf));
    const [clus,clusters]=Words(ex.FatWrite(BigInt(disk.virtualSize),p,name,buf,BigInt(bytes.length)),2);
    return {clus,clusters};
  });
}
