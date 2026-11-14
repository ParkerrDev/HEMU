const MAGIC="HMRAM001";

export function RamParts(bytes,size=402653184)
{//Only nonzero page runs are stored. All omitted RAM starts zero.
  if (bytes.length==size) return [[0,0,size]];
  let view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),n,at,end=0,res=[];
  if (bytes.length<16 || String.fromCharCode(...bytes.subarray(0,8))!=MAGIC ||
      view.getUint32(8,true)!=size) throw Error("Invalid packed RAM header");
  n=view.getUint32(12,true);at=16+n*8;
  if (at>bytes.length || n>size/64) throw Error("Invalid packed RAM ranges");
  for (let i=0;i<n;i++) {
    let start=view.getUint32(16+i*8,true),len=view.getUint32(20+i*8,true);
    if (!len || start%64 || len%64 || start<end || start+len>size || at+len>bytes.length)
      throw Error("Invalid packed RAM range");
    res.push([at,start,len]);at+=len;end=start+len;
  }
  if (at!=bytes.length) throw Error("Unexpected packed RAM data");
  return res;
}

export function RamExpand(bytes,size=402653184)
{
  let parts=RamParts(bytes,size),ram=new Uint8Array(size);
  for (let [off,start,len] of parts) ram.set(bytes.subarray(off,off+len),start);
  return ram;
}
