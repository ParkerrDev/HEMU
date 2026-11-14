import assert from "node:assert/strict";
import {readFileSync,writeFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {pathToFileURL} from "node:url";
import {GuestHarness} from "./GuestHarness.mjs";

const source=readFileSync(new URL("./TriangleNative.HC",import.meta.url)),
  hash=createHash("sha256").update(source).digest("hex"),
  file=new URL("./TriangleNative.json",import.meta.url),
  fields=["case","changed","seed","pixels","depth","collisions","nearest",
    "min_x","max_x","min_y","max_y","transforms","vertices"],
  cases=640;
if(process.argv.includes("--record")) {
  assert.ok(process.env.HOLYC_QEMU_ORACLE,"Set HOLYC_QEMU_ORACLE to HolyC-wasm/tests/oracle/Qemu.mjs");
  const {QemuRun}=await import(pathToFileURL(process.env.HOLYC_QEMU_ORACLE)),
    result=await QemuRun([source],{timeout:120}),row=result.results[0];
  assert.equal(row.except,"");
  assert.equal(row.out.trim().split("\n").length,cases,row.out);
  writeFileSync(file,JSON.stringify({backend:result.backend,sourceHash:hash,out:row.out},null,2)+"\n");
  console.log("Native triangles:",result.evidence);
}
const expected=JSON.parse(readFileSync(file,"utf8")),
  rows=expected.out.trim().split("\n").map(line=>line.trim().split(/\s+/));
assert.equal(hash,expected.sourceHash,"regenerate original V5.03 evidence after changing the probe");
assert.equal(rows.length,cases);
const h=await GuestHarness({exports:["TriangleFastCount"],extraSource:
  "I64 TriangleFastCount(){return render_calls[8];}"}),{ex,gx,base,Name}=h;
for(const fast of [false,true]) {
  ex.RenderFastSet(BigInt(fast));
  const before=ex.TriangleFastCount();
  await h.Exec(fast?"TriangleNative;":source.toString("latin1"));
  const accelerated=ex.TriangleFastCount()-before;
  if(fast)assert.ok(accelerated>=432n,"supported native fixtures must accelerate triangles");
  else assert.equal(accelerated,0n,"original mode executes every triangle");
  const ptr=Number(ex.GuestVar(Name("triangle_res"))),
    count=gx.rd64(Number(ex.GuestVar(Name("triangle_cnt")))),view=new DataView(ex.memory.buffer);
  assert.equal(count,cases);
  for(let i=0;i<cases;i++)for(let j=0;j<fields.length;j++) {
    const value=view.getBigUint64(base+ptr+(i*fields.length+j)*8,true)
      .toString(16).toUpperCase().padStart(16,"0");
    assert.equal(value,rows[i][j],"native triangle "+i+" "+fields[j]+" fast="+fast);
  }
}
for(let shape=0;shape<8;shape++) {
  const before=ex.TriangleFastCount();
  await h.Exec("triangle_cnt=0;TriangleDepth("+shape+",0);");
  assert.equal(ex.TriangleFastCount()-before,shape<5?1n:0n,
    "large-depth triangle "+shape+" acceleration eligibility");
  const ptr=Number(ex.GuestVar(Name("triangle_res"))),view=new DataView(ex.memory.buffer);
  for(let j=1;j<fields.length;j++) {
    const value=view.getBigUint64(base+ptr+j*8,true).toString(16).toUpperCase().padStart(16,"0");
    assert.equal(value,rows[592+shape*6][j],"large-depth triangle "+shape+" "+fields[j]);
  }
}
console.log("Triangles: 640 original QEMU/KVM cases match both graphics modes: edge orders, winding, degeneracy, clipping, large depths/spreads, raster modes, RNG, extents and guest polygon transforms; high-depth eligibility and fallback are explicit.");
