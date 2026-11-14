import {RamExpand} from "../Ram.js";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {gzipSync,gunzipSync} from "node:zlib";
import {resolve} from "node:path";
import {compileHemu,HEMU_SRC} from "../Compile.js";
import {makeDisk} from "../QCow2.js";
import {StockIdentify,StockInflate,StockManifestCheck,StockModuleCheck,StockOverlayApply} from "../Stock.js";
import {RegsRead,RegsSource} from "../../Misc/Regs.mjs";

const packed=Buffer.alloc(24+4096);
packed.write("HMRAM001");packed.writeUInt32LE(12288,8);packed.writeUInt32LE(1,12);
packed.writeUInt32LE(4096,16);packed.writeUInt32LE(4096,20);
packed.fill(0xA5,24);
const expanded=RamExpand(packed,12288);
assert.ok(expanded.subarray(0,4096).every(b=>b===0));
assert.ok(expanded.subarray(4096,8192).every(b=>b===0xA5));
assert.ok(expanded.subarray(8192).every(b=>b===0),"omitted pages start zero");
for (const [offset,value] of [[8,8192],[12,2],[16,1],[16,12288],[20,0],[20,8192]]) {
  const bad=Buffer.from(packed);bad.writeUInt32LE(value,offset);
  assert.throws(()=>RamExpand(bad,12288),/packed RAM/);
}
assert.throws(()=>RamExpand(packed.subarray(0,-1),12288),/packed RAM/);
assert.throws(()=>RamExpand(Buffer.concat([packed,Buffer.from([0])]),12288),/packed RAM/);
const overlapping=Buffer.alloc(32+8192);
packed.copy(overlapping,0,0,24);overlapping.writeUInt32LE(2,12);
overlapping.writeUInt32LE(4096,24);overlapping.writeUInt32LE(4096,28);
assert.throws(()=>RamExpand(overlapping,12288),/packed RAM/);

const root=resolve(HEMU_SRC,".."),manifest=StockManifestCheck(JSON.parse(readFileSync(resolve(root,"stock.json")))),
  hash=b=>createHash("sha256").update(b).digest("hex"),
  base=readFileSync(resolve(HEMU_SRC,"../templeos-hd.qcow2.gz"));
assert.equal(hash(base),manifest.base.gzipSha256);
const decoded=gunzipSync(base),baseDisk=makeDisk(decoded),chunk=new Uint8Array(131072),baseHash=createHash("sha256");
for(let off=0;off<baseDisk.virtualSize;off+=chunk.length){baseDisk.readInto(off/512,chunk.length/512,chunk,0);baseHash.update(chunk);}
assert.equal(baseHash.digest("hex"),manifest.base.rawSha256);
for(const capture of manifest.captures) {
  const registers=readFileSync(resolve(root,capture.registers),"utf8"),
    source=readFileSync(resolve(HEMU_SRC,capture.cores===4?"SnapRegsSmp.HC":"SnapRegs.HC"),"utf8");
  assert.equal(hash(registers),capture.registerSha256);
  assert.equal(hash(source),capture.sourceSha256);
  assert.equal(RegsSource(RegsRead(registers,capture.cores)),source,"captured registers regenerate the compiled source exactly");
  const gz=readFileSync(resolve(root,capture.ram)),found=await StockIdentify(gz,capture.cores,manifest);
  assert.equal(found.capture,capture);assert.equal(found.ram,undefined,"known compression does not allocate a second RAM copy during preflight");
  assert.equal(hash(RamExpand(gunzipSync(gz))),capture.ramSha256);
  const module=new WebAssembly.Module(compileHemu({smp:capture.cores===4}).bytes);
  StockModuleCheck(module,capture,manifest);
  assert.throws(()=>StockModuleCheck(module,manifest.captures.find(c=>c!==capture),manifest),/does not match/);
  await assert.rejects(()=>StockIdentify(gz,capture.cores===1?4:1,manifest),/topology/);
  const patch=readFileSync(resolve(root,capture.overlay));
  assert.equal(hash(patch),capture.overlaySha256);
  const disk=makeDisk(decoded),bad=Buffer.from(patch);
  bad.writeUInt32LE(0xFFFFFFFF,0);
  assert.throws(()=>StockOverlayApply(disk,bad,capture),/out-of-range/);
  assert.equal(disk.overlay.size,0,"reject before applying even the first malformed sector");
  StockOverlayApply(disk,patch,capture);
  const actual=createHash("sha256");
  for(let off=0;off<disk.virtualSize;off+=chunk.length){disk.readInto(off/512,chunk.length/512,chunk,0);actual.update(chunk);}
  assert.equal(actual.digest("hex"),capture.diskSha256,"base plus tiny overlay reconstructs every captured disk byte");
}
assert.throws(()=>StockModuleCheck(new WebAssembly.Module(Uint8Array.of(0,97,115,109,1,0,0,0)),manifest.captures[0],manifest),/no matching captured CPU/);
await assert.rejects(()=>StockIdentify(gzipSync(new Uint8Array(64)),1,manifest),/size/);
await assert.rejects(()=>StockInflate(gzipSync(new Uint8Array(65)),64),/larger/);
await assert.rejects(()=>StockInflate(gzipSync(new Uint8Array(64)).subarray(0,12),64));
assert.throws(()=>StockManifestCheck({...manifest,version:2}),/unsupported/);
console.log("Stock capture identities: exact1/4 RAM and complete disk reconstruction, CPU-module pairing, topology and pre-mutation corruption refusal.");
