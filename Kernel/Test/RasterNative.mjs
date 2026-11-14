import assert from "node:assert/strict";
import {readFileSync,writeFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {pathToFileURL} from "node:url";
import {GuestHarness} from "./GuestHarness.mjs";

const source=readFileSync(new URL("./RasterNative.HC",import.meta.url)),
  hash=createHash("sha256").update(source).digest("hex"),
  file=new URL("./RasterNative.json",import.meta.url);
if(process.argv.includes("--record")) {
  assert.ok(process.env.HOLYC_QEMU_ORACLE,"Set HOLYC_QEMU_ORACLE to HolyC-wasm/tests/oracle/Qemu.mjs");
  const {QemuRun}=await import(pathToFileURL(process.env.HOLYC_QEMU_ORACLE)),
    result=await QemuRun([source],{timeout:120}),row=result.results[0];
  assert.equal(row.except,"");
  assert.equal(row.out.trim().split("\n").length,200,row.out);
  writeFileSync(file,JSON.stringify({backend:result.backend,sourceHash:hash,out:row.out},null,2)+"\n");
  console.log("Native raster:",result.evidence);
}
const expected=JSON.parse(readFileSync(file,"utf8"));
assert.equal(hash,expected.sourceHash,"regenerate original V5.03 evidence after changing the probe");
const h=await GuestHarness(),{ex,gx,base,Name}=h;
await h.Exec(source.toString("latin1"));
const ptr=Number(ex.GuestVar(Name("raster_res"))),
  cnt=gx.rd64(Number(ex.GuestVar(Name("raster_cnt")))),dv=new DataView(ex.memory.buffer),rows=[];
assert.equal(cnt,200);
for(let i=0;i<cnt;i++) {
  const values=[];
  for(let j=0;j<11;j++)values.push(dv.getBigUint64(base+ptr+(i*11+j)*8,true).toString(16).toUpperCase().padStart(16,"0"));
  rows.push(values.join(" ")+" ");
}
assert.equal(rows.join("\n")+"\n",expected.out,"original QEMU/KVM raster parity");
console.log(`Raster: 200 original QEMU/KVM cases match emulated guest pixels, depth, counts, extents, nearest distance and random seed.`);
