import assert from 'node:assert/strict';
import * as jit from '../Jit.js';

const REG=16,FLAGS=144,RIP=152,BASE=256,PC=4096;
function Owner(shared=false) {
  const memory=new WebAssembly.Memory(shared?{initial:32,maximum:32,shared:true}:{initial:32}),
    view=new DataView(memory.buffer);
  view.setBigUint64(RIP,BigInt(PC),true);
  return {memory,view};
}
function Attach(owner) {
  jit.jitState(REG,FLAGS,RIP,BASE,owner.memory,()=>0n,()=>{});
}
let count=0;
for(const shared of [false,true]) {
  const prior=Owner(shared),next=Owner(shared),code=[0x48,0xFF,0xC0,0xF4];
  for(const [owner,value] of [[prior,10n],[next,50n]]) {
    new Uint8Array(owner.memory.buffer).set(code,BASE+PC);
    owner.view.setBigUint64(REG,value,true);
  }
  Attach(prior);
  assert.equal(jit.jitCompile(PC),1);assert.equal(jit.jitRun(PC),1);
  assert.equal(prior.view.getBigUint64(REG,true),11n);
  const before=new Uint8Array(prior.memory.buffer).slice();
  Attach(next);
  assert.equal(jit.jitRun(PC),0,'Attaching an owner discards modules importing earlier memory.');
  assert.equal(jit.jitDispatch(8),0);
  assert.deepEqual(new Uint8Array(prior.memory.buffer),before);
  assert.equal(next.view.getBigUint64(REG,true),50n);
  assert.equal(jit.jitCompile(PC),1);assert.equal(jit.jitRun(PC),1);
  assert.equal(next.view.getBigUint64(REG,true),51n);
  jit.jitReset();assert.equal(jit.jitRun(PC),0);
  assert.equal(jit.jitCompile(PC),1);assert.equal(jit.jitRun(PC),1);
  assert.equal(next.view.getBigUint64(REG,true),52n,'Code-only reset retains current owner bindings.');
  count++;
}
for(const shared of [false,true])for(const code of [
  [0x64,0x48,0x8B,0x03],[0x65,0x48,0x8B,0x03],
  [0x0F,0x31],[0xD9,0xE8],[0xD9,0x3B],[0x0F,0xAE,0x03]
]) {
  const prior=Owner(shared),next=Owner(shared);
  Attach(prior);
  jit.jitX87(2048,2112,2120);jit.jitSeg(2136,2144,2152,2160,2176,2304);
  Attach(next);
  if(code[1]===0x3B||code[1]===0xAE)jit.jitX87(3072,3136,3144);
  new Uint8Array(next.memory.buffer).set([...code,0xF4],BASE+PC);
  next.view.setBigUint64(REG+24,64n,true);
  next.view.setBigUint64(BASE+64,0x1234n,true);
  next.view.setBigUint64(BASE+80,0xBADn,true);
  next.view.setBigUint64(2136,16n,true);next.view.setBigUint64(2144,16n,true);
  if(code[0]===0x64||code[0]===0x65) {
    assert.equal(jit.jitCompile(PC),0,'Unknown FS/GS bases require interpreter execution.');
    const prefix=[0x48,0xFF,0xC0];
    new Uint8Array(next.memory.buffer).set([...prefix,...code,0xF4],BASE+PC);
    jit.jitReset();next.view.setBigUint64(REG,10n,true);
    assert.equal(jit.jitCompile(PC),1);assert.equal(jit.jitRun(PC),1);
    assert.equal(next.view.getBigUint64(REG,true),11n);
    assert.equal(next.view.getBigUint64(RIP,true),BigInt(PC+prefix.length));
    for(const base of [0n,16n]) {
      new Uint8Array(next.memory.buffer).set([...code,0xF4],BASE+PC);
      next.view.setBigUint64(2136,base,true);next.view.setBigUint64(2144,base,true);
      jit.jitSeg(2136,2144,0,0,0,0);jit.jitReset();
      assert.equal(jit.jitCompile(PC),1);assert.equal(jit.jitRun(PC),1);
      assert.equal(next.view.getBigUint64(REG,true),base?0xBADn:0x1234n,
        'A registered base is used even when its value is zero.');
    }
  } else {
    assert.equal(jit.jitCompile(PC),0,'Missing optional CPU bindings retain the interpreter fallback.');
  }
  count++;
}
//APs share RAM with core zero, but never its compiled function table.
const ap=await import('../Jit.js?application-core-owner'),owner=Owner(true),
  u8=new Uint8Array(owner.memory.buffer),view=owner.view,
  apReg=2048,apFlags=2176,apRip=2184,tables=0x20000,counts=0xA0000,
  fast=0x120000,gate=0x130000,slot=(PC^(PC>>>16))&65535,
  Put=(at,value)=>view.setBigUint64(at,BigInt(value),true),
  Get=at=>view.getBigUint64(at,true);
let renderCalls=0,accept=true;
u8.set([0x48,0xFF,0xC0,0xF4],BASE+PC);
Attach(owner);jit.jitChain(tables,counts);
assert.equal(jit.jitCompile(PC),1);Put(tables+slot*8,PC);Put(counts+slot*8,1);Put(REG,50);
ap.jitState(apReg,apFlags,apRip,BASE,owner.memory,()=>0n,()=>{});
ap.jitChain(tables,counts); //Rebinding must also discard a previous dispatcher.
ap.jitChain(0,0,fast,gate,()=>{
  renderCalls++;if(!accept)return 0n;
  Put(apReg,Get(apReg)+10n);Put(apRip,PC+3);return 1n;
});
Put(apRip,PC);Put(apReg,0);u8[gate+(PC&65535)]=1;
assert.equal(ap.jitDispatch(1),0,'A BSP cache hit cannot execute in an AP with no local block.');
assert.equal(Get(REG),50n);assert.equal(ap.jitCompile(PC),1);
for(const [enabled,value,hits]of [[0,1n,0],[1,11n,1],[0,12n,1],[1,22n,2]]) {
  u8[fast]=enabled;Put(apRip,PC);
  assert.equal(ap.jitDispatch(1),1);
  assert.equal(Get(apReg),value,'Live mode changes precede warm AP instructions.');
  assert.equal(renderCalls,hits);assert.equal(Get(REG),50n);
}
u8[fast]=1;accept=false;Put(apRip,PC);
assert.equal(ap.jitDispatch(1),1);assert.equal(Get(apReg),23n,'Refused acceleration executes the private original block.');
u8[BASE+PC+2]=0xC8;Put(apRip,PC);
assert.equal(ap.jitDispatch(1),0);assert.equal(Get(apReg),23n);
assert.equal(ap.jitInspect(PC).cached,false,'Changed guest bytes invalidate the AP block.');
assert.equal(Get(counts+slot*8),1n,'AP invalidation does not write BSP cache metadata.');
assert.equal(ap.jitCompile(PC),1);assert.equal(ap.jitDispatch(1),1);assert.equal(Get(apReg),22n);
u8[PC&65535]=1;Put(apRip,PC);const callsBefore=renderCalls;
ap.jitChain(0,0,fast,0,()=>{renderCalls++;return 1n;});
assert.equal(ap.jitDispatch(1),1);assert.equal(renderCalls,callsBefore,'An incomplete rendering binding cannot use low memory as a gate.');
assert.equal(Get(apReg),21n);
const grown=new WebAssembly.Memory({initial:32,maximum:64});
ap.jitState(apReg,apFlags,apRip,BASE,grown,()=>0n,()=>{});
ap.jitChain(0,0,fast,gate,()=>{
  new DataView(grown.buffer).setBigUint64(apRip,BigInt(PC+3),true);return 1n;
});
grown.grow(1);
new DataView(grown.buffer).setBigUint64(apRip,BigInt(PC),true);
new Uint8Array(grown.buffer)[fast]=1;new Uint8Array(grown.buffer)[gate+(PC&65535)]=1;
assert.equal(ap.jitDispatch(1),1,'A private dispatch refreshes its mode/gate view after memory growth.');
count++;
for (const shared of [false,true]) {
  const current=Owner(shared),data=new Uint8Array(current.memory.buffer),
    view=current.view;
  data.set([0x48,0xFF,0xC0,0xF4],BASE+PC);
  Attach(current);jit.jitChain(tables,counts);
  assert.equal(jit.jitCompile(PC),1);
  view.setBigInt64(tables+slot*8,BigInt(PC),true);
  view.setBigInt64(counts+slot*8,1n,true);
  const before=data.slice();
  jit.jitReset();
  assert.equal(jit.jitDispatch(1),0,'Reset cannot call a cleared native table slot.');
  assert.deepEqual(data,before,'Reset discards compiled code without writing guest memory.');
  assert.equal(jit.jitCompile(PC),1);assert.equal(jit.jitDispatch(1),1);
  assert.equal(view.getBigInt64(REG,true),1n);
  count++;
}
console.log(`${count} JIT ownership cases preserve memory, private AP caches, live modes and optional CPU bindings.`);
