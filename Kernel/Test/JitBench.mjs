import assert from "node:assert/strict";
import {pathToFileURL} from "node:url";

const module=process.argv[2]?pathToFileURL(process.argv[2]):new URL("../Jit.js",import.meta.url),
  jit=await import(module),memory=new WebAssembly.Memory({initial:32,maximum:8192}),
  bytes=new Uint8Array(memory.buffer),view=new DataView(memory.buffer),base=65536,
  start=performance.now();
jit.jitState(0,128,136,base,memory,()=>0n,()=>{});
jit.jitX87(256,320,328);jit.jitSeg(336,344,352,360,368,496);
const attach_ms=performance.now()-start,patterns=[
  [0x48,0x83,0xC0,1,0x48,0x83,0xE8,1,0x90],
  [0x48,0x39,0xC1,0x74,3,0x48,0xFF,0xC0,0x90],
  [0x48,0xF7,0xE1,0x48,0xFF,0xC2],
  [0x48,0xF7,0xF9],
  [0x0F,0xAE,0x03,0x0F,0xAE,0x0B],
  [0xD9,0xE8,0xD9,0xE0,0xD9,0xFC,0xDF,0x38],
  [0xF3,0x48,0xA5],
  [0x48,0xFF,0xC0,0x48,0xFF,0xC9,0x75,0xF8]
],compile_ms=[],execute_ms=[];
for (let trial=0;trial<7;trial++) {
  jit.jitReset();
  for (let i=0;i<400;i++) bytes.set([...patterns[i%patterns.length],0xCC],base+4096+i*64);
  const before=performance.now();
  for (let i=0;i<400;i++) assert.ok(jit.jitCompile(4096+i*64)>0);
  compile_ms.push(performance.now()-before);
}
jit.jitReset();const pc=4096;
bytes.set([...patterns[7],0xCC],base+pc);assert.equal(jit.jitCompile(pc),3);
for (let trial=0;trial<7;trial++) {
  const before=performance.now();
  for (let i=0;i<5000;i++) {
    view.setBigInt64(8,1000n,true);
    assert.equal(jit.jitRun(pc),3000);
  }
  execute_ms.push(performance.now()-before);
}
console.log(JSON.stringify({module:String(module),attach_ms,compile_400_ms:compile_ms,
  execute_15000000_instructions_ms:execute_ms},null,2));
