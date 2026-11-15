import assert from "node:assert/strict";
import {readFileSync,writeFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {pathToFileURL} from "node:url";
import {compileHolyC} from "../../holyc-wasm/src/compiler.js";
import {createHost} from "../../holyc-wasm/src/runtime/host.js";

const probe=readFileSync(new URL("DiskNative.HC",import.meta.url)),source=readFileSync(new URL("../Disk.HC",import.meta.url)),
  hash=bytes=>createHash("sha256").update(bytes).digest("hex"),file=new URL("DiskNative.json",import.meta.url);
if(process.argv.includes("--record")) {
  const module=process.env.HOLYC_QEMU_ORACLE;
  if(!module)throw Error("Set HOLYC_QEMU_ORACLE to HolyC-wasm/tests/oracle/Qemu.mjs.");
  const {QemuRun}=await import(pathToFileURL(module)),code=Buffer.from('Option(OPTf_WARN_PAREN,ON);\n'+
    probe.toString("latin1").replace('#include "Disk"',source.toString("latin1")),"latin1"),
    result=await QemuRun([code],{timeout:120}),row=result.results[0];
  assert.equal(row.except,"");assert.match(row.out,/^[0-9A-F \n]+$/);
  writeFileSync(file,JSON.stringify({backend:result.backend,probeHash:hash(probe),sourceHash:hash(source),out:row.out},null,2)+"\n");
  console.log("Native disk module:",result.evidence);
}
const expected=JSON.parse(readFileSync(file,"utf8"));
assert.equal(hash(probe),expected.probeHash,"regenerate native fixture after changing probe");
assert.equal(hash(source),expected.sourceHash,"regenerate native fixture after changing disk module");
const compiled=compileHolyC(probe.toString("latin1"),{filename:"DiskNative.HC",lenient:false,
  includeResolver:name=>name==="Disk"?source.toString("latin1"):null});
assert.deepEqual(compiled.warnings,[]);
let output="";
const host=createHost({onText:text=>output+=text}),{instance}=await WebAssembly.instantiate(compiled.bytes,{env:host.env});
host.attach(instance);instance.exports.__rt_init();instance.exports.__main();
assert.equal(output,expected.out);
console.log("Disk algorithms match native V5.03: qcow2 mappings, FAT32 long names, allocation, replacement, directory extension and every disk byte.");
