import assert from "node:assert/strict";
import {compileHemu} from "../Compile.js";
import {createHemuHost,CpuFaultText} from "../Host.js";
import * as jit from "../Jit.js";

const compiled=compileHemu({exports:["InitMem","Run","RunTo","IoIn","IoOut",
  "CaptureFrom","VideoCapture","TimeFrame","SurfaceInit","SurfaceState","SurfaceCapture","SurfaceJit"],extraSource:`
U0 SurfaceInit(I64 flags=0,I64 pc=4096)
{
  Reset;
  rip=pc;rfl=flags;reg[4]=32768;
  g_gc_sentinel=12288;mem[g_gc_sentinel]=0xF4;
  g_jit_on=CoreAttach;
}
U64 SurfaceState(I64 which)
{
  switch (which) {
    case 0: return icount;
    case 1: return rip;
    case 2: return reg[0];
    case 3: return reg[3];
    case 4: return g_win_start;
    case 5: return tsc;
  }
  return 0;
}
U0 SurfaceCapture(U64 pc)
{
  g_capture_rip=g_capture_text=pc;
  g_capture_gate[pc&0xFFFF]=1;
  guest.gr_dc2=video_image=8192;
  of_dc.body=0;of_dc.width_internal=8;of_dc.height=12;
  *(mem+8192)(U64 *)=8320;
  *(mem+8320)(U64 *)=16384;
  *(mem+8328)(U32 *)=640;
  *(mem+8332)(U32 *)=480;
}
I64 SurfaceJit(U64 pc)
{
  I64 slot=(pc^(pc>>16))&0xFFFF;
  g_jit_rip[slot]=pc;
  return g_jit_n[slot]=__jit_compile(pc);
}
`});
assert.deepEqual(compiled.warnings,[]);
assert.deepEqual(compiled.diagnostics,[]);
const port=[0xBA,0x47,0x50,0,0],acquire=[...port,0xFA,0xEC],
  release=[0x31,0xC0,0xEE];
async function Machine(code,{allow=true,jitted=false,flags=0}={})
{
  let instance,locks=0,unlocks=0,locked=false;
  const host=createHemuHost({onText:function () {},
    captureLock:function () {locks++;if (allow) locked=true;return allow;},
    captureUnlock:function () {
      assert(locked,"only the barrier owner may unlock");
      locked=false;unlocks++;
    }});
  if (jitted) Object.assign(host.env,jit.jitImports(function () {return instance.exports;}));
  ({instance}=await WebAssembly.instantiate(compiled.bytes,{env:host.env}));
  host.attach(instance);
  const ex=instance.exports;
  ex.__rt_init();ex.InitMem(400000n);ex.SurfaceInit(BigInt(flags),4096n);
  function Put(bytes,at=4096)
  {
    new Uint8Array(ex.memory.buffer,Number(ex.RamBase())+at,bytes.length).set(bytes);
  }
  Put(code);
  return {ex,Put,Trace:function () {return {locks,unlocks,locked};}};
}
{
  const m=await Machine([...acquire,0x89,0xC3,0xEE,0xEC,0xEE,0x90]),ex=m.ex;
  ex.SurfaceCapture(4103n);
  ex.TimeFrame(500n,3n);
  ex.Run(3n);
  assert.equal(ex.SurfaceState(5n),500n,"draining cannot invent additional frame time");
  assert.equal(ex.SurfaceState(0n),7n,"only the held transaction drains past the frame budget");
  assert.equal(ex.SurfaceState(1n),4108n,"release retires before returning to the host");
  assert.equal(ex.SurfaceState(3n),1n,"first IN acquires");
  assert.equal(ex.SurfaceState(2n),0n,"nested IN refuses without another lock");
  assert.equal(ex.WinSurfaceActive(),0n);
  assert.deepEqual(m.Trace(),{locks:1,unlocks:1,locked:false},
    "screen capture hooks and a nonzero OUT cannot release the surface hold");
  ex.IoOut(0x5047n,0n);
  assert.equal(m.Trace().unlocks,1,"an unmatched OUT does not release somebody else's barrier");
  ex.Run(8n);
  assert.equal(ex.SurfaceState(0n),8n,"ordinary execution returns to the original budget rule");
}
{
  const m=await Machine([...acquire,0x90,...release],{allow:false});
  m.ex.Run(3n);
  assert.equal(m.ex.SurfaceState(0n),3n);
  assert.equal(m.ex.WinSurfaceActive(),0n);
  assert.deepEqual(m.Trace(),{locks:1,unlocks:0,locked:false});
}
for (const core of [0,1]) {
  let flags=512;
  if (core) flags=0;
  const m=await Machine([...port,0xEC,0x90],{flags});
  m.ex.__core.value=BigInt(core);
  if (core) m.ex.SurfaceInit(0n,4096n);
  m.ex.Run(2n);
  assert.equal(m.ex.SurfaceState(2n),0n,"IF=1 and nonzero cores cannot acquire");
  assert.deepEqual(m.Trace(),{locks:0,unlocks:0,locked:false});
}
{
  const m=await Machine([...acquire,0x90,...release]);
  m.ex.RunTo(0xFFFFn,3n);
  assert.equal(m.ex.WinSurfaceActive(),0n,"RunTo refuses guest lock spans");
  assert.deepEqual(m.Trace(),{locks:0,unlocks:0,locked:false});
}
for (const pending of [false,true]) {
  let flags=512;
  if (pending) flags=0;
  const m=await Machine([...port,0xEC,0xC3],{flags});
  if (pending) {
    m.Put([0xFB,0xF4],6144);
    m.ex.SurfaceInit(0n,6144n);
  }
  m.ex.GuestCallPost(4096n,0n,0n,1000n);
  if (pending) m.ex.Run(16n);
  assert.equal(m.ex.GuestCallState(),3n);
  assert.equal(m.ex.GuestCallRes(),0n,"injected guest calls cannot hold the capture barrier");
  assert.deepEqual(m.Trace(),{locks:0,unlocks:0,locked:false});
}
for (const jitted of [false,true]) {
  const m=await Machine([...acquire,0xFB,0xFA,...release,0xF4],{jitted}),ex=m.ex;
  if (jitted) {
    assert(ex.SurfaceJit(4103n)>0n);
    assert(ex.SurfaceJit(4104n)>0n);
  }
  ex.Run(64n);
  assert.equal(ex.CpuFault(0n),4n,"STI then CLI cannot hide an IF opening in the acquisition batch");
  assert.equal(ex.SurfaceState(1n),4104n,"the fault precedes the following CLI and OUT");
  assert.deepEqual(m.Trace(),{locks:1,unlocks:0,locked:true});
}
for (const tail of [[0xD9,0xD1],[0xF4],[0xFB],[0xEB,0xFE]]) {
  const bound=tail[0]==0xEB,m=await Machine([...acquire,...tail],{jitted:bound}),ex=m.ex;
  ex.Run(3n);
  assert.equal(ex.CpuFault(0n),4n,"a fault, HLT, IF opening or expired span retains reason 4");
  assert.equal(ex.WinSurfaceActive(),1n);
  const count=ex.SurfaceState(0n),pc=ex.SurfaceState(1n);
  if (bound) assert.equal(count-ex.SurfaceState(4n),32000000n,
    "even a hot JIT loop cannot exceed the fixed transaction cap");
  for (let i=0;i<3;i++) ex.Run(count+1000n);
  ex.IoOut(0x5047n,0n);
  ex.CaptureFrom(16384n);ex.VideoCapture();ex.RunTo(0xFFFFn,1000n);
  assert.equal(ex.SurfaceState(0n),count);
  assert.equal(ex.SurfaceState(1n),pc);
  assert.equal(ex.WinSurfaceActive(),1n);
  assert.deepEqual(m.Trace(),{locks:1,unlocks:0,locked:true},
    "faulted partial state never resumes application CPUs");
  assert.match(CpuFaultText(ex),/native window drawing transaction.*Restore/);
}
console.log("Window surface: one IN/OUT barrier pair, ordinary-budget drain, nested capture refusal, IF/core/call admission, fixed 32M JIT bound and retained fault barriers.");
