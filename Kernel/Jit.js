import {JIT_WASM} from "./JitCode.js";

let core,config,input,output,memory,bytes,read,write,table,dispatch,render;
const blocks=new Map(),functions=new Array(65536).fill(null),
  addresses=new Int32Array(65536).fill(-1),
  budget=new WebAssembly.Global({value:"i64",mutable:true},0x7FFFFFFFn);

function Core()
{
  if (core) return;
  const code=atob(JIT_WASM),raw=new Uint8Array(code.length);
  for (let i=0;i<code.length;i++) raw[i]=code.charCodeAt(i);
  core=new WebAssembly.Instance(new WebAssembly.Module(raw),{env:{
    __rt_init_failed:function () {throw Error("HolyC JIT initialization failed");}
  }}).exports;
  core.__main();
  config=new BigInt64Array(core.memory.buffer,Number(core.JitConfig()),24);
  input=Number(core.JitInput());output=Number(core.JitOutput());
}

function Slot(pc)
{
  return (pc^(pc>>>16))&65535;
}

export function jitImports(getExports)
{
  return {
    __jit_state(reg,flags,pc) {
      const ex=getExports();
      jitState(reg,flags,pc,ex.RamBase(),ex.memory,ex.RdMem,ex.WrMem);
      return 1n;
    },
    __jit_compile:pc=>BigInt(jitCompile(Number(pc))),
    __jit_run:pc=>BigInt(jitRun(Number(pc))),
    __jit_dispatch:count=>BigInt(jitDispatch(Number(count))),
    __jit_x87:jitX87,
    __jit_chain:(pcs,counts,fast=0,gate=0)=>
      jitChain(pcs,counts,fast,gate,getExports().RenderTry),
    __jit_seg:jitSeg
  };
}

export function jitState(reg,flags,pc,base,mem,rd,wr)
{
  Core();jitReset();config.fill(0n);
  config.set([BigInt(reg),BigInt(flags),BigInt(pc),BigInt(base)]);
  config[13]=BigInt(typeof SharedArrayBuffer!=="undefined" &&
    mem.buffer instanceof SharedArrayBuffer);
  memory=mem;bytes=new Uint8Array(mem.buffer);read=rd;write=wr;
  table=dispatch=render=null;
}

export function jitSeg(fs=0,gs=0,tsc=0,cw=0,xlo=0,xhi=0)
{
  Core();config.set([fs,gs,tsc,cw,xlo,xhi].map(BigInt),4);
}

export function jitX87(fpr=0,fsp=0,sw=0)
{
  Core();config.set([fpr,fsp,sw].map(BigInt),10);
}

export function jitReset()
{
  table=dispatch=null;
  blocks.clear();functions.fill(null);addresses.fill(-1);
}

export function jitInspect(pc)
{
  const block=blocks.get(pc);
  return {cached:!!block,failed:!!block&&!block.fn,
    ninstr:block?block.ninstr:-1,slotRip:addresses[Slot(pc)]};
}

function Install(length)
{
  return new WebAssembly.Instance(new WebAssembly.Module(
    new Uint8Array(core.memory.buffer,output,Number(length))),
    {env:{mem:memory,RdMem:read,WrMem:write,CodeChanged:CodeChanged,
      budget,RenderTry:render}}).exports;
}

export function jitChain(pcs,counts,fast=0,gate=0,renderTry=null)
{
  Core();config.set([pcs,counts,fast,gate].map(BigInt),14);
  render=renderTry;config[18]=BigInt(!!(fast&&gate&&render));
  table=dispatch=null;
  if (!config[2]||!config[14]||!memory) return;
  const length=core.JitDispatch();
  if (!length) throw Error("HolyC JIT dispatcher exceeded its output buffer");
  const ex=Install(length);table=ex.tbl;dispatch=ex.dispatch;
}

function CodeMatches(pc,code)
{
  if (bytes.buffer!==memory.buffer) bytes=new Uint8Array(memory.buffer);
  const start=Number(config[3])+pc;
  for (let i=0;i<code.length;i++) if (bytes[start+i]!==code[i]) return false;
  return true;
}

function CodeChanged(pc)
{
  pc=Number(pc);blocks.delete(pc);
  const slot=Slot(pc);
  if (addresses[slot]===pc) {
    functions[slot]=null;addresses[slot]=-1;
    if (table) table.set(slot,null);
  }
  if (config[14]&&config[15]) {
    const view=new DataView(memory.buffer);
    if (Number(view.getBigUint64(Number(config[14])+slot*8,true))===pc)
      view.setBigInt64(Number(config[15])+slot*8,-1n,true);
  }
}

function Bind(pc,block)
{
  const slot=Slot(pc);
  functions[slot]=block.fn;addresses[slot]=pc;
  if (table) table.set(slot,block.fn);
}

export function jitCompile(pc,noFprCache=false,noTopLoop=false)
{
  const cached=blocks.get(pc);
  if (cached&&CodeMatches(pc,cached.bytes)) {
    if (cached.fn) Bind(pc,cached);
    return cached.ninstr;
  }
  if (cached) CodeChanged(pc);
  if (bytes.buffer!==memory.buffer) bytes=new Uint8Array(memory.buffer);
  const start=Number(config[3])+pc,count=Math.min(8192,bytes.length-start);
  if (count<0) return 0;
  new Uint8Array(core.memory.buffer,input,count).set(bytes.subarray(start,start+count));
  const length=core.JitBuild(BigInt(pc),BigInt(count),BigInt(noFprCache),
    BigInt(noTopLoop),BigInt(!!globalThis.__NOLOOP),BigInt(!!globalThis.__NOREP));
  if (globalThis.__JITSTATS&&config[22]>=0n) {
    const opcode=Number(config[22]),key=(opcode&256?"0F ":"")+(opcode&255).toString(16);
    globalThis.__JITSTATS[key]=(globalThis.__JITSTATS[key]||0)+1;
  }
  let fn=null,ninstr=0,span=16;
  if (length) {
    try {
      fn=Install(length).run;ninstr=Number(config[21]);span=Number(config[20]);
    } catch {
      //The interpreter resumes this address if the browser rejects a block.
    }
  }
  const block={fn,ninstr,bytes:bytes.slice(start,start+span)};
  blocks.set(pc,block);
  if (fn) Bind(pc,block);
  return ninstr;
}

export function jitRun(pc)
{
  budget.value=0x7FFFFFFFn;
  const block=blocks.get(pc);
  return (block?.fn?.()||0)&0x3FFFFFFF;
}

export function jitDispatch(count)
{
  if (dispatch) return dispatch(count);
  if (!memory) return 0;
  if (bytes.buffer!==memory.buffer) bytes=new Uint8Array(memory.buffer);
  const pc=new Int32Array(memory.buffer,Number(config[2]),1),
    stopOnIf=count<0,limit=Math.abs(count);
  let ran=0;
  while (ran<limit) {
    const address=pc[0],slot=Slot(address);
    if (config[16]&&config[17]&&bytes[Number(config[16])]&&
        bytes[Number(config[17])+(address&65535)]&&render&&render()) ran++;
    else {
      const block=blocks.get(address),fn=functions[slot];
      if (addresses[slot]!==address||!fn||block.ninstr>limit-ran) break;
      budget.value=BigInt(limit-ran);
      const value=fn(),done=value&0x3FFFFFFF;
      ran+=done;
      if (!done||stopOnIf&&value&0x40000000) break;
    }
  }
  return ran;
}
