import assert from "node:assert/strict";
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {gzipSync,gunzipSync} from "node:zlib";
import {execFileSync} from "node:child_process";
import {createHash} from "node:crypto";
import {makeDisk,makeRaw,makeSparse,DISK_CHUNK,fat32Upload,fat32Read,fat32List} from "../QCow2.js";

const raw=new Uint8Array(256*1024),
  hash=bytes=>createHash("sha256").update(bytes).digest("hex"),
  fixture=new URL("DiskImages.json",import.meta.url);
for(let off=0;off<raw.length;off++)if((off>>>16)%3!==1)raw[off]=(off*37+(off>>>9))&255;
if(process.argv.includes("--record")) {
  const temp=mkdtempSync(join(tmpdir(),"hemu-disk-")),images={
    backend:execFileSync("qemu-img",["--version"],{encoding:"utf8"}).split("\n")[0],
    sourceSha256:hash(raw),cases:[]};
  try {
    writeFileSync(join(temp,"raw"),raw);
    for(const compat of ["0.10","1.1"])for(const cluster of [512,65536]) {
      const name=`disk-${compat}-${cluster}.qcow2`,command=["convert","-f","raw","-O","qcow2","-o",`compat=${compat},cluster_size=${cluster}`,"raw",name];
      execFileSync("qemu-img",command,{cwd:temp});
      const bytes=readFileSync(join(temp,name));
      images.cases.push({compat,cluster,command,sha256:hash(bytes),gzip:gzipSync(bytes,{level:9}).toString("base64")});
    }
    writeFileSync(fixture,JSON.stringify(images,null,2)+"\n");
  } finally {rmSync(temp,{recursive:true,force:true});}
}
const images=JSON.parse(readFileSync(fixture,"utf8"));
assert.equal(images.sourceSha256,hash(raw),"regenerate qemu-img fixtures after changing reference raw bytes");
for(const {compat,cluster,gzip,sha256} of images.cases) {
    const bytes=gunzipSync(Buffer.from(gzip,"base64"));
    assert.equal(hash(bytes),sha256,"recorded qemu-img image is intact");
    const disk=await makeDisk(bytes),actual=new Uint8Array(raw.length);
    disk.readInto(0,actual.length/512,actual,0);
    assert.equal(hash(actual),hash(raw),"qemu-img qcow2 conversion reads every byte identically");
    const sector=new Uint8Array(512).fill(0xA5);
    disk.writeInto(128,1,sector,0);disk.readInto(128,1,actual,0);
    assert.deepEqual(actual.slice(0,512),sector,"overlay replaces an unallocated qcow2 cluster");
    for(const [offset,size,value] of [[4,4,7n],[20,4,8n],[24,8,513n],[8,8,512n],
      [32,4,1n],[36,4,0n],[40,8,BigInt(bytes.length)],[40,8,1n]]) {
      const bad=Uint8Array.from(bytes),view=new DataView(bad.buffer);
      if(size===8)view.setBigUint64(offset,value);else view.setUint32(offset,Number(value));
      await assert.rejects(()=>makeDisk(bad),/disk image/);
    }
    const l1=Number(new DataView(bytes.buffer,bytes.byteOffset,bytes.length).getBigUint64(40));
    for(const flag of [1n<<62n,1n<<61n,1n<<63n]) {
      const bad=Uint8Array.from(bytes);new DataView(bad.buffer).setBigUint64(l1,flag);
      await assert.rejects(()=>makeDisk(bad),/cluster/);
    }
    if(compat==="1.1") {
      const bad=Uint8Array.from(bytes);new DataView(bad.buffer).setBigUint64(72,1n);
      await assert.rejects(()=>makeDisk(bad),/feature/);
    }
  }
  for(const bytes of [new Uint8Array(0),new Uint8Array(511),new Uint8Array(513)])
    await assert.rejects(()=>makeDisk(bytes),/sector/);
  const chunk=new Uint8Array(DISK_CHUNK).fill(0x5A),sparse=await makeSparse(DISK_CHUNK*3,new Map([[1,chunk]])),out=new Uint8Array(DISK_CHUNK*3);
  sparse.readInto(0,out.length/512,out,0);
  assert.ok(out.slice(0,DISK_CHUNK).every(b=>!b));
  assert.ok(out.slice(DISK_CHUNK,DISK_CHUNK*2).every(b=>b===0x5A));
  assert.ok(out.slice(DISK_CHUNK*2).every(b=>!b));
  sparse.writeInto(0,1,new Uint8Array(512).fill(7),0);sparse.readInto(0,1,out,0);
  assert.ok(out.slice(0,512).every(b=>b===7));
  assert.throws(()=>sparse.writeInto(-1,1,out,0),/outside/);

  const large=new Uint8Array(131072),header=new DataView(large.buffer);
  for(const [off,value] of [[0,0x514649FB],[4,3],[20,16],[36,2048],[100,104]])header.setUint32(off,value);
  header.setBigUint64(24,1n<<40n);header.setBigUint64(40,65536n);
  const empty=await makeDisk(large),sector=new Uint8Array(512);
  sector.fill(7);empty.writeInto(128,1,sector,0);
  for(let cluster=0;cluster<70000;cluster++) {
    sector.fill(0xA5);empty.readInto(cluster*128,1,sector,0);
    assert.ok(sector.every(value=>value===(cluster===1?7:0)),"large sparse qcow2 images need no complete virtual-disk allocation");
  }
  empty.readInto(128,1,sector,0);
  assert.ok(sector.every(value=>value===7),"overlay bytes survive mapping cache turnover");
  empty.readInto(0,1,sector,0);assert.ok(sector.every(value=>!value));

  const fat=new Uint8Array(65536),view=new DataView(fat.buffer);
  view.setUint16(11,512,true);fat[13]=1;view.setUint16(14,1,true);fat[16]=1;
  for(const [at,value] of [[32,128],[36,1],[44,2],[512,0xFFFFFF8],[516,0xFFFFFFF],[520,0xFFFFFFF]])view.setUint32(at,value,true);
  view.setUint16(510,0xAA55,true);
  const disk=await makeRaw(fat),files=new Map();
  for(let i=0;i<28;i++) {
    const name=`Long name ${i} λ.HC`,bytes=Uint8Array.from({length:i*57},(_,at)=>(at*11+i)&255);
    files.set(name,bytes);fat32Upload(disk,name,bytes,"");
  }
  const long="x".repeat(240)+".HC",longBytes=new Uint8Array(999).fill(0x82);
  files.set(long,longBytes);fat32Upload(disk,long,longBytes,"");
  assert.equal(fat32List(disk,"").length,files.size,"directory extension keeps every name visible");
  for(const [name,bytes] of files)assert.deepEqual(fat32Read(disk,"",name.toUpperCase()),bytes);
  for(const length of [5000,0,32]) {
    const bytes=new Uint8Array(length).fill(0xF3);fat32Upload(disk,"Long name 0 λ.HC",bytes,"");
    assert.deepEqual(fat32Read(disk,"","Long name 0 λ.HC"),bytes);
  }
  const before=new Map(disk.overlay);
  assert.throws(()=>fat32Upload(disk,"TOOBIG.BIN",new Uint8Array(65536),""),/disk full/);
  assert.deepEqual(disk.overlay,before,"failed allocation never commits partial FAT/data writes");
  for(const change of [bad=>bad[13]=0,bad=>new DataView(bad.buffer).setUint32(520,2,true),
      bad=>new DataView(bad.buffer).setUint32(520,999,true)]) {
    const bad=Uint8Array.from(fat);change(bad);
    const broken=await makeRaw(bad);assert.throws(()=>fat32List(broken,""),/FAT32/);
  }
  assert.equal(fat32List(disk,"").length,files.size,"format errors leave later helper calls usable");
  const rawSave=new Uint8Array(fat.length);disk.readInto(0,rawSave.length/512,rawSave,0);
  const reopened=await makeDisk(rawSave);
  assert.equal(fat32List(reopened,"").length,files.size);
  assert.deepEqual(fat32Read(reopened,"","Long name 0 λ.HC"),new Uint8Array(32).fill(0xF3));
  console.log("Disk: qemu-img v2/v3 and 512/64K clusters, sparse/overlay bytes, malformed images, native FAT directory growth/replacement and transactional refusal pass.");
