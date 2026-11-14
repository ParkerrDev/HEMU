import assert from "node:assert/strict";
import {GuestHarness} from "./GuestHarness.mjs";

const h=await GuestHarness({exports:["CodeProbe","CodeSteps"],extraSource:`
I64 code_steps;
I64 CodeSteps() {return code_steps;}
U64 CodeProbe(U64 fn,I64 mode)
{
  CCpuState saved;
  U64 res,stack,old;
  I64 slot;
  MemCpy(&saved,&g_cpu_st[0],sizeof(CCpuState));
  stack=reg[4]-256;old=RdMem(stack,8);
  reg[0]=0;reg[4]=stack;rip=fn;rfl=0x202;halted=0;
  WrMem(reg[4],8,g_gc_sentinel);
  code_steps=0;
  if (!mode) {
    while (rip!=g_gc_sentinel && code_steps<8 && !halted) {
      Step;
      code_steps++;
    }
  } else {
    if (mode==1) {
      slot=(fn^fn>>16)&0xFFFF;
      g_jit_rip[slot]=fn;
      g_jit_n[slot]=__jit_compile(fn);
    }
    code_steps=__jit_dispatch(8);
  }
  res=reg[0];
  WrMem(stack,8,old);
  MemCpy(&g_cpu_st[0],&saved,sizeof(CCpuState));
  return res;
}
`}),{ex,gx,Name}=h;
const functions=[['DCBlotColor8',2],['DCBlotColor4',4],['GrHLine',6],
  ['GrVLine',6],['GrFillPoly3',3],['GrFillTri0',4],['GrUpdateLine64',4],['GrUpdateLine64FlushCache',4]];
let cases=0;
for(const [name,argc] of functions) {
  const at=Number(ex.GuestFun(Name(name)));
  assert.ok(at>0,name+" is the actual guest function");
  const original=gx.rdBytes(at,8).slice();
  function Patch(value) {
    const bytes=new Uint8Array(8),view=new DataView(bytes.buffer);
    bytes[0]=0xB8;view.setUint32(1,value,true);
    bytes[5]=0xC2;view.setUint16(6,argc*8,true);
    new Uint8Array(ex.memory.buffer,h.base+at,8).set(bytes);
  }
  try {
    Patch(0x12345678);
    assert.equal(ex.CodeProbe(BigInt(at),0n),0x12345678n,name+" executes its guest instructions");
    assert.equal(ex.CodeSteps(),2n,name+" executes MOV and RET");
    assert.equal(ex.CodeProbe(BigInt(at),1n),0x12345678n,name+" executes translated guest instructions");
    assert.equal(ex.CodeSteps(),2n);
    Patch(0x76543210);
    assert.equal(ex.CodeProbe(BigInt(at),2n),0n,name+" rejects stale translated code");
    assert.equal(ex.CodeSteps(),0n,"byte guard exits before any stale instruction executes");
    assert.equal(ex.CodeProbe(BigInt(at),0n),0x76543210n,name+" executes changed instructions");
    assert.equal(ex.CodeProbe(BigInt(at),1n),0x76543210n,name+" translates changed instructions");
    assert.equal(ex.CodeSteps(),2n);
    cases++;
  } finally {
    new Uint8Array(ex.memory.buffer,h.base+at,original.length).set(original);
  }
}
await h.Run(5);
console.log(`${cases} original drawing entry points execute modified x86 bodies in the interpreter and JIT; stale translations execute zero instructions.`);
