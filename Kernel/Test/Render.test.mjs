import assert from "node:assert/strict";
import {GuestHarness} from "./GuestHarness.mjs";

const h=await GuestHarness({exports:["VideoBlot4","VideoLine","VideoOff","VideoOn","VideoCount","VideoRegs","RenderProbe","RenderCodeInfo","RenderCodeOk","RenderInit","RenderFs"],
  extraSource:`U0 VideoOff(){RenderFastSet(FALSE);}
U0 VideoOn(){RenderFastSet(TRUE);}
I64 VideoCount(){return video_calls;}
U0 VideoRegs(U64 fn,U64 stack,U64 output) {
  CCpuState saved;
  I64 i;
  MemCpy(&saved,&g_cpu_st[0],sizeof(CCpuState));
  for(i=0;i<16;i++) reg[i]=0x1234567800000000+i;
  reg[4]=stack;rip=fn;rfl=0x202;halted=0;
  WrMem(stack,8,0x7FF0);
  RunTo(0x7FF0,10000000);
  MemCpy(mem+output,&reg[0],128);
  WrMem(output+128,8,rfl);
  MemCpy(&g_cpu_st[0],&saved,sizeof(CCpuState));
}
U64 RenderFs() {return msr_fsbase;}
U64 RenderCodeInfo(I64 index,I64 field)
{
  if (!field) return render_code[index].addr;
  if (field==1) return render_code[index].size;
  return render_calls[index];
}
I64 RenderProbe(U64 fn,U64 stack,U64 output,I64 mode,U64 flags)
{
  CCpuState saved;
  I64 i,res,slot;
  MemCpy(&saved,&g_cpu_st[0],sizeof(CCpuState));
  for (i=0;i<16;i++) reg[i]=0x1234567800000000+i;
  reg[4]=stack;rip=fn;rfl=flags;halted=0;
  WrMem(stack,8,0x7FF0);
  if (mode==1) {
    slot=(fn^fn>>16)&0xFFFF;
    g_jit_rip[slot]=fn;g_jit_n[slot]=__jit_compile(fn);
  }
  if (mode) res=__jit_dispatch(1000000);
  else res=RenderTry;
  MemCpy(mem+output,&reg[0],128);
  WrMem(output+128,8,rfl);WrMem(output+136,8,rip);
  MemCpy(&g_cpu_st[0],&saved,sizeof(CCpuState));
  return res;
}`});
const {ex,gx,base,Name}=h,u8=new Uint8Array(ex.memory.buffer),area=gx.scratch.base+0x800000,
  src=area,dst=area+0x10000,cache=area+0x20000,vga=area+0x30000,args=area+0x40000,
  blot=Number(ex.GuestFun(Name("DCBlotColor4"))),line=Number(ex.GuestFun(Name("GrUpdateLine64"))),
  flush=Number(ex.GuestFun(Name("GrUpdateLine64FlushCache")));
ex.VideoOff();
let seed=0x7C14A22,cases=0;
const Rand=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed>>>24;};
function Init(count,pattern) {
  for(let i=0;i<count*8;i++) u8[base+src+i]=pattern===0?i&15:pattern===1?Rand()&15:Rand();
  u8.fill(0xA7,base+dst,base+dst+count*8+16);
  u8.fill(0x34,base+cache,base+cache+count*8+16);
  u8.fill(0x71,base+vga,base+vga+count*8+16);
  if(pattern===3)for(let i=0;i<count;i+=2)u8.copyWithin(base+cache+i*8,base+src+i*8,base+src+i*8+8);
}
async function Native(fn,params) {
  const before=ex.VideoCount();await h.Call(fn,params,10000000);
  assert.equal(ex.VideoCount(),before,"native video oracle cannot call HLE");
}
for(const count of [1,2,7,80,512])for(let pattern=0;pattern<4;pattern++) {
  Init(count,pattern);const initial=u8.slice(base+area,base+area+0x50000);
  await Native(blot,[dst,src,cache,count]);
  const expected=u8.slice(base+area,base+area+0x50000);
  u8.set(initial,base+area);ex.VideoBlot4(BigInt(dst),BigInt(src),BigInt(cache),BigInt(count));
  assert.deepEqual(u8.slice(base+area,base+area+0x50000),expected,"planar conversion/cache guards");
  u8.set(initial,base+area);ex.VideoOn();let calls=ex.VideoCount();
  await h.Call(blot,[dst,src,cache,count]);
  assert.ok(ex.VideoCount()>calls);ex.VideoOff();
  assert.deepEqual(u8.slice(base+area,base+area+0x50000),expected,"named planar HLE dispatch");cases++;
  for(const doFlush of [0,1]) {
    Init(count,pattern);if(pattern===3)u8.copyWithin(base+dst,base+cache,base+cache+count*8);
    gx.wr64(args,vga);gx.wr64(args+8,src);gx.wr64(args+16,dst);
    const before=u8.slice(base+area,base+area+0x50000);
    await Native(doFlush?flush:line,[args,args+8,count,args+16]);
    const after=u8.slice(base+area,base+area+0x50000);
    u8.set(before,base+area);ex.VideoLine(BigInt(args),BigInt(args+8),BigInt(count),BigInt(args+16),BigInt(doFlush));
    assert.deepEqual(u8.slice(base+area,base+area+0x50000),after,"screen image, bit lookup, VGA writes and pointer increments");
    u8.set(before,base+area);ex.VideoOn();calls=ex.VideoCount();
    await h.Call(doFlush?flush:line,[args,args+8,count,args+16]);
    assert.ok(ex.VideoCount()>calls);ex.VideoOff();
    assert.deepEqual(u8.slice(base+area,base+area+0x50000),after,"named line HLE dispatch");cases++;
  }
}
//Instruction-level register and flag results must match the original assembly.
for(const fn of [blot,line,flush])for(let pattern=0;pattern<4;pattern++) {
  const count=7,stack=area+0x180000,out=stack+0x100;
  Init(count,pattern);if(pattern===3)u8.copyWithin(base+dst,base+cache,base+cache+count*8);
  gx.wr64(args,vga);gx.wr64(args+8,src);gx.wr64(args+16,dst);
  const params=fn===blot?[dst,src,cache,count]:[args,args+8,count,args+16];
  params.forEach((v,i)=>gx.wr64(stack+8+i*8,v));
  const before=u8.slice(base+area,base+area+0x50000);
  ex.VideoOff();ex.VideoRegs(BigInt(fn),BigInt(stack),BigInt(out));
  const expected=u8.slice(base+out,base+out+136);
  u8.set(before,base+area);ex.VideoOn();ex.VideoRegs(BigInt(fn),BigInt(stack),BigInt(out));
  assert.deepEqual(u8.slice(base+out,base+out+136),expected,"native registers and flags: "+fn+" pattern "+pattern);
}
//Aliased compositor buffers retain the exact native access order.
for(const aliasDst of [src,src+1,cache+8]) {
  const count=7,stack=area+0x180000,out=stack+0x100;
  Init(count,2);[aliasDst,src,cache,count].forEach((v,i)=>gx.wr64(stack+8+i*8,v));
  const before=u8.slice(base+area,base+area+0x50000);
  ex.VideoOff();ex.VideoRegs(BigInt(blot),BigInt(stack),BigInt(out));
  const expected=u8.slice(base+area,base+area+0x50000);
  u8.set(before,base+area);ex.VideoOn();const calls=ex.VideoCount();
  ex.VideoRegs(BigInt(blot),BigInt(stack),BigInt(out));
  assert.equal(ex.VideoCount(),calls,"overlapping buffers run their native implementation");
  assert.deepEqual(u8.slice(base+area,base+area+0x50000),expected);
}
ex.VideoOff();

await h.Exec("U8 *render_test_stack=MAlloc(4096);");
const view=new DataView(ex.memory.buffer),member=n=>Number(ex.GuestMember(Name("CDC"),Name(n,0x7100))),
  stack=gx.rd64(Number(ex.GuestVar(Name("render_test_stack"))))+2048,out=area+0x180100,srcDc=area+0x240000,dstDc=srcDc+0x1000,
  src8=area+0x200000,dst8=area+0x220000,depth=area+0x300000,body=area+0x310000,
  blit8=Number(ex.RenderCodeInfo(0n,0n)),
  count=index=>ex.RenderCodeInfo(BigInt(index),2n),
  CallArgs=params=>params.forEach((v,i)=>gx.wr64(stack+8+i*8,v)),
  Probe=(fn,mode=0,flags=0x202)=>ex.RenderProbe(BigInt(fn),BigInt(stack),BigInt(out),BigInt(mode),BigInt(flags));
function Context(at,pixels,width,height) {
  u8.fill(0,base+at,base+at+0x1000);gx.wr64(at+member("body"),pixels);
  for(const key of ["width","width_internal"])view.setInt32(base+at+member(key),width,true);
  view.setInt32(base+at+member("height"),height,true);
}
for(const width of [1,7,65537])for(const pattern of [0,1,2]) {
  Context(srcDc,src8,width,1);Context(dstDc,dst8,width,1);
  for(let i=0;i<width;i++)u8[base+src8+i]=pattern===0?255:pattern===1?i&15:Rand();
  u8.fill(0xAC,base+dst8,base+dst8+width+16);CallArgs([dstDc,srcDc]);
  ex.VideoOff();ex.VideoRegs(BigInt(blit8),BigInt(stack),BigInt(out));
  const pixels=u8.slice(base+dst8,base+dst8+width+16),regs=u8.slice(base+out,base+out+136);
  u8.fill(0xAC,base+dst8,base+dst8+width+16);ex.VideoOn();const before=count(0);
  ex.VideoRegs(BigInt(blit8),BigInt(stack),BigInt(out));
  assert.equal(count(0),before+1n,"eligible compositor calls accelerate");
  assert.deepEqual(u8.slice(base+dst8,base+dst8+width+16),pixels,"full-width compositor pixels");
  assert.deepEqual(u8.slice(base+out,base+out+136),regs,"compositor registers and flags");cases++;
}
Init(7,1);gx.wr64(args,vga);gx.wr64(args+8,src);gx.wr64(args+16,dst);
CallArgs([args,args+8,7,args+16]);
ex.VideoOff();assert.ok(Probe(line,1)>1n,"original entry is compiled");let before=count(2);
ex.VideoOn();assert.equal(Probe(line,2),1n);assert.equal(count(2),before+1n,"fast mode precedes a warm original block");
ex.VideoOff();before=count(2);assert.ok(Probe(line,2)>1n);assert.equal(count(2),before,"original mode reuses warm instructions");
ex.VideoOn();assert.equal(Probe(line,2),1n);assert.equal(count(2),before+1n);
Context(srcDc,src8,16,1);Context(dstDc,dst8,16,1);CallArgs([dstDc,srcDc]);
//A refused acceleration must not change a register or any guest memory.
function Refused(fn,label,flags=0x202) {
  ex.VideoOff();assert.equal(Probe(fn,0,flags),0n);const regs=u8.slice(base+out,base+out+144),
    memory=u8.slice(base+area,base+area+0x320000);
  ex.VideoOn();assert.equal(Probe(fn,0,flags),0n,label);
  assert.deepEqual(u8.slice(base+out,base+out+144),regs,label+" registers");
  assert.deepEqual(u8.slice(base+area,base+area+0x320000),memory,label+" memory");
}
function VideoArgs(fn) {
  Init(7,1);gx.wr64(args,vga);gx.wr64(args+8,src);gx.wr64(args+16,dst);
  CallArgs(fn===blot?[dst,src,cache,7]:[args,args+8,7,args+16]);
}
for(const fn of [blot,line,flush]) {
  VideoArgs(fn);ex.VideoOn();assert.equal(Probe(fn),1n,"forward string case is eligible");
  VideoArgs(fn);Refused(fn,"reverse string direction",0x602);
}
for(const fn of [blot,line,flush]) {
  VideoArgs(fn);
  if(fn===blot)CallArgs([dst,stack-16,cache,7]);
  else gx.wr64(args+8,stack-16);
  Refused(fn,"source aliases native prologue writes");
}
CallArgs([dstDc,srcDc]);gx.wr64(srcDc+member("body"),stack-16);
Refused(blit8,"compositor source aliases native prologue writes");
gx.wr64(srcDc+member("body"),src8);
CallArgs([dstDc,srcDc]);
view.setInt32(base+srcDc+member("width_internal"),-1,true);
Refused(blit8,"signed negative width");
view.setInt32(base+srcDc+member("width_internal"),16,true);
gx.wr64(srcDc+member("body"),419430396);Refused(blit8,"source beyond RAM");
gx.wr64(srcDc+member("body"),src8);
const span=Number(ex.RenderCodeInfo(4n,0n));
Context(dstDc,body,16,2);gx.wr64(dstDc+member("depth_buf"),depth);
for(let i=0;i<64;i++)view.setInt32(base+depth+i*4,0x7FFFFFFF,true);
CallArgs([dstDc,0,7,1,0,0]);before=count(4);assert.equal(Probe(span),1n);assert.equal(count(4),before+1n);
view.setInt32(base+dstDc+member("width"),5000,true);
view.setUint32(base+dstDc+member("flags"),0x10800,true);
Refused(span,"unsupported span refuses before extents or nearest writes");
view.setInt32(base+dstDc+member("width"),16,true);
view.setUint32(base+dstDc+member("flags"),0,true);
for(const address of [span,Number(ex.RenderCodeInfo(6n,0n)),stack-128]) {
  gx.wr64(dstDc+member("body"),address);
  const untouched=u8.slice(base+address,base+address+64);
  Refused(span,"span output aliases code/helper/native frame");
  assert.deepEqual(u8.slice(base+address,base+address+64),untouched);
}
gx.wr64(dstDc+member("body"),body);
CallArgs([dstDc,srcDc]);gx.wr64(dstDc+member("body"),blit8);
Refused(blit8,"compositor output aliases its code");gx.wr64(dstDc+member("body"),body);
CallArgs([dstDc,0,7,1,0,0]);
for(const index of [4,6,7]) {
  const fn=Number(ex.RenderCodeInfo(BigInt(index),0n)),length=Number(ex.RenderCodeInfo(BigInt(index),1n));
  assert.ok(length>8,"complete code range exists");
  u8[base+fn+length-1]^=1;
  try {
    Refused(span,"changed full body/helper "+index);
    ex.RenderInit();ex.SnapshotResume();
    Refused(span,"resume cannot recapture modified body/helper "+index);
  } finally {u8[base+fn+length-1]^=1;}
}
for(let index=0;index<4;index++) {
  const fn=Number(ex.RenderCodeInfo(BigInt(index),0n)),length=Number(ex.RenderCodeInfo(BigInt(index),1n));
  if(index)VideoArgs(fn);else CallArgs([dstDc,srcDc]);
  ex.VideoOn();assert.equal(Probe(fn),1n,"original compositor/video body is eligible");
  u8[base+fn+length-1]^=1;
  try {Refused(fn,"changed video/compositor body "+index);}
  finally {u8[base+fn+length-1]^=1;}
}
const reverse=Number(ex.GuestVar(Name("rev_bits_table"))),table=gx.rd64(reverse),savedTable=u8.slice(base+table,base+table+256);
for(const fn of [line,flush]) {
  try {
    Init(2,0);gx.wr64(reverse,table);gx.wr64(args+8,src);gx.wr64(args+16,dst);
    CallArgs([reverse,args+8,2,args+16]);
    ex.VideoOff();ex.VideoRegs(BigInt(fn),BigInt(stack),BigInt(out));
    const expected=u8.slice(base+out,base+out+136),pixels=u8.slice(base+table,base+table+256),next=gx.rd64(reverse);
    u8.set(savedTable,base+table);Init(2,0);gx.wr64(reverse,table);gx.wr64(args+8,src);gx.wr64(args+16,dst);
    ex.VideoOn();ex.VideoRegs(BigInt(fn),BigInt(stack),BigInt(out));
    assert.deepEqual(u8.slice(base+out,base+out+136),expected,"lookup-table pointer alias preserves entry RBX");
    assert.deepEqual(u8.slice(base+table,base+table+256),pixels);
    assert.equal(gx.rd64(reverse),next);cases++;
  } finally {gx.wr64(reverse,table);u8.set(savedTable,base+table);}
}
//Coverage reads precede the first random draw, even when those inputs alias.
const task=Number(ex.RenderFs()),taskMember=n=>Number(ex.GuestMember(Name("CTask"),Name(n,0x7100))),
  seedAt=task+taskMember("rand_seed"),flagsAt=task+taskMember("task_flags"),
  oldSeed=view.getBigUint64(base+seedAt,true),oldFlags=view.getBigUint64(base+flagsAt,true),win=area+0x350000,
  coverage=Number(ex.GuestVar(Name("gr")))+Number(ex.GuestMember(Name("CGrGlbls"),Name("win_z_buf",0x7100))),
  oldCoverage=gx.rd64(coverage);
try {
  Context(dstDc,body,16,2);gx.wr64(dstDc+member("depth_buf"),depth);
  view.setUint32(base+dstDc+member("flags"),0x4000,true);
  view.setUint32(base+dstDc+member("color"),0x8004000C,true);
  gx.wr64(dstDc+member("dither_probability_u16"),32768);
  gx.wr64(dstDc+member("win_task"),win);u8.fill(0,base+win,base+win+0x2000);
  gx.wr64(win+taskMember("pix_right"),15);gx.wr64(win+taskMember("pix_bottom"),1);
  gx.wr64(coverage,seedAt);gx.wr64(flagsAt,BigInt(oldFlags)|0x4000n);
  CallArgs([dstDc,0,1,0,0,0]);
  const Reset=()=>{CallArgs([dstDc,0,1,0,0,0]);gx.wr64(seedAt,0);u8.fill(7,base+body,base+body+32);for(let i=0;i<32;i++)view.setInt32(base+depth+i*4,0x7FFFFFFF,true);};
  Reset();ex.VideoOff();ex.VideoRegs(BigInt(span),BigInt(stack),BigInt(out));
  const pixels=u8.slice(base+body,base+body+32),nextSeed=view.getBigUint64(base+seedAt,true),result=gx.rd64(out);
  Reset();ex.VideoOn();before=count(4);ex.VideoRegs(BigInt(span),BigInt(stack),BigInt(out));
  assert.equal(count(4),before+1n,"coverage/seed alias remains eligible");
  assert.deepEqual(u8.slice(base+body,base+body+32),pixels,"coverage precedes probability dither");
  assert.equal(view.getBigUint64(base+seedAt,true),nextSeed);assert.equal(gx.rd64(out),result);cases++;
} finally {gx.wr64(seedAt,oldSeed);gx.wr64(flagsAt,oldFlags);gx.wr64(coverage,oldCoverage);}
const tri=Number(ex.RenderCodeInfo(8n,0n)),points=area+0x340000;
function TriangleArgs(z=0) {
  Context(dstDc,body,32,32);gx.wr64(dstDc+member("depth_buf"),depth);
  view.setUint32(base+dstDc+member("color"),12,true);
  u8.fill(7,base+body,base+body+32*33);
  for(let i=0;i<32*33;i++)view.setInt32(base+depth+i*4,0x7FFFFFFF,true);
  [2,2,z,10,2,z+20,2,10,z+30].forEach((v,i)=>view.setInt32(base+points+i*4,v,true));
  CallArgs([dstDc,points,points+12,points+24]);
}
for(const z of [0,0x40000000-60,0x40000000+46]) {
  TriangleArgs(z);ex.VideoOn();before=count(8);assert.equal(Probe(tri),1n);
  assert.equal(count(8),before+1n,"bounded triangle with ordinary or large common depth accelerates");
}
for(const index of [8,4,5,6,7]) {
  TriangleArgs();const fn=Number(ex.RenderCodeInfo(BigInt(index),0n)),length=Number(ex.RenderCodeInfo(BigInt(index),1n));
  u8[base+fn+length-1]^=1;
  try {Refused(tri,"changed triangle body or bypassed helper "+index);}
  finally {u8[base+fn+length-1]^=1;}
}
for(const address of [body,depth,dstDc+member("cur_x"),seedAt,stack-16]) {
  TriangleArgs();const saved=u8.slice(base+address,base+address+12);
  try {
    [2,2,0].forEach((v,i)=>view.setInt32(base+address+i*4,v,true));
    CallArgs([dstDc,address,points+12,points+24]);
    Refused(tri,"triangle vertex aliases output, context, seed or native frame");
    assert.deepEqual(u8.slice(base+address,base+address+12),new Uint8Array(new Int32Array([2,2,0]).buffer));
  } finally {u8.set(saved,base+address);}
}
TriangleArgs();view.setInt32(base+points,0x100001,true);
Refused(tri,"triangle edge work exceeds coordinate bound");
TriangleArgs();view.setInt32(base+points+20,0x100001,true);
Refused(tri,"triangle depth difference exceeds fixed-point bound");
TriangleArgs();gx.wr64(dstDc+member("depth_buf"),0);
Refused(tri,"triangle without depth buffer remains native");
TriangleArgs(0x7FEFFFFF-30);view.setUint32(base+dstDc+member("flags"),0x4000,true);
gx.wr64(dstDc+member("win_task"),win);gx.wr64(win+taskMember("scroll_z"),1);
Refused(tri,"scrolled triangle depth retains signed fixed-point headroom");
gx.wr64(win+taskMember("scroll_z"),0);
TriangleArgs();CallArgs([dstDc,0,7,1,0,0]);const oldSelf=gx.rd64(task);
try {
  gx.wr64(task,win);Refused(span,"modified FS task self-pointer");
} finally {gx.wr64(task,oldSelf);}
for(const slot of [coverage,Number(ex.GuestVar(Name("sys_winmgr_task")))]) {
  TriangleArgs();view.setUint32(base+dstDc+member("flags"),0x4000,true);
  gx.wr64(dstDc+member("win_task"),win);
  gx.wr64(dstDc+member("body"),slot);CallArgs([dstDc,0,7,1,0,0]);
  const saved=u8.slice(base+slot,base+slot+8);
  Refused(span,"span output aliases a coverage control pointer");
  assert.deepEqual(u8.slice(base+slot,base+slot+8),saved);
}
ex.VideoOff();ex.SnapshotResume();assert.equal(ex.RenderFastSet(-1n),0n,"saved original mode survives resume");
ex.VideoOn();ex.SnapshotResume();assert.equal(ex.RenderFastSet(-1n),1n,"saved fast mode survives resume");
for(let index=0;index<9;index++) {
  const fn=Number(ex.RenderCodeInfo(BigInt(index),0n)),length=Number(ex.RenderCodeInfo(BigInt(index),1n));
  assert.equal(ex.RenderCodeOk(BigInt(index)),1n,"unchanged full range "+index);
  for(let offset=0;offset<length;offset++) {
    u8[base+fn+offset]^=1;
    try {assert.equal(ex.RenderCodeOk(BigInt(index)),0n,"changed byte "+index+":"+offset);}
    finally {u8[base+fn+offset]^=1;}
  }
}
console.log(`${cases} fast video/compositor comparisons match original pixels, registers and flags; warm-cache toggles, complete body/helper guards, refusals and saved modes pass.`);
