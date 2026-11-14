import {CaptureWait} from "./CoreBarrier.js";
import {CoreBus,BusStop,BUS_VERSION} from "./CoreBus.js";
import {createHemuHost,CpuFaultText} from "./Host.js";
import * as jit from "./Jit.js";
//The modules the ones above import, asked for at once (see HemuWorker.js).
import "../holyc-wasm/src/runtime/host.js";
import "../holyc-wasm/src/runtime/lex.js";
import "../holyc-wasm/src/runtime/console.js";
import "../holyc-wasm/src/runtime/files.js";
import "../holyc-wasm/src/runtime/heap.js";
import "../holyc-wasm/src/abi.js";
import "../holyc-wasm/src/wasm/emitter.js";

onmessage=e=>{
  if(e.data.cmd!=="init")return;
  RunAp(e.data)
    .catch(err=>{
      const m=e.data,ctrl=m.ctrl&&new Int32Array(m.ctrl),valid=ctrl?.length>=16,
        retained=m.busProtocol===BUS_VERSION&&valid&&Number.isInteger(m.core)&&m.core>=1&&m.core<=3&&!!Atomics.load(ctrl,8+m.core);
      if(m.busProtocol===BUS_VERSION&&valid)BusStop(ctrl);
      postMessage({cmd:"error",msg:String(err.message||err),...(retained?{retained:true,core:m.core}:{})});
    });
};

async function RunAp({core,mem,ctrl:control,wasmBytes,heapAbi,busProtocol,requiredBusProtocol,sc}) {
  if(!Number.isInteger(core)||core<1||core>3)throw new Error("Invalid application core");
  if(requiredBusProtocol!==undefined&&requiredBusProtocol!==0&&
      (requiredBusProtocol!==BUS_VERSION||busProtocol!==requiredBusProtocol))
    throw new Error("Saved machine requires shared RAM protocol "+requiredBusProtocol);
  const ctrl=new Int32Array(control),hot=new Map();
  if(busProtocol!==undefined&&busProtocol!==BUS_VERSION)throw new Error("Unsupported shared bus protocol");
  const bus=busProtocol===BUS_VERSION?CoreBus(ctrl,core,sc?.ncore):null;
  let inst;
  const host=createHemuHost({...(heapAbi===undefined?{}:{heapAbi}),onText:s=>{if(s.includes("BADOP"))postMessage({cmd:"log",msg:`core${core} ${s.trim()}`});}});
  Object.assign(host.env,{
    mem,
    ...jit.jitImports(()=>inst.exports),
    __ap_run:(rip,budget)=>{
      const address=Number(rip);
      if(!jit.jitInspect(address).cached){
        const n=(hot.get(address)||0)+1;hot.set(address,n);
        if(n<=2)return 0n;jit.jitCompile(address);
      }
      return BigInt(jit.jitDispatch(Number(budget)));
    }
  });
  if(bus)Object.assign(host.env,bus.Imports());
  const mod=await WebAssembly.compile(wasmBytes);
  inst=await WebAssembly.instantiate(mod,{env:host.env});
  inst.exports.__core.value=BigInt(core);
  inst.exports.__sp.value=BigInt(0x1000000-core*0x100000);
  if(bus)inst=bus.Attach(inst,mod);
  host.attach(inst);
  Atomics.store(ctrl,8+core,1);Atomics.notify(ctrl,8+core);
  while(!Atomics.load(ctrl,0)&&!Atomics.load(ctrl,1))Atomics.wait(ctrl,0,0,100);
  if(Atomics.load(ctrl,1))return;
  inst.exports.CoreAttach();
  postMessage({cmd:"log",msg:`AP${core} parallel`});
  let spins=0,faulted=false;
  while(!Atomics.load(ctrl,1)){
    if(CaptureWait(ctrl,core))continue;
    if(faulted){await new Promise(r=>setTimeout(r,10));continue;}
    const did=Number(inst.exports.RunCore(2000000n));
    if(did<0&&!faulted){faulted=true;postMessage({cmd:"error",msg:CpuFaultText(inst.exports,core<<8|-did),retained:true,core});}
    if(!did&&typeof Atomics.waitAsync==="function") {
      const wake=Atomics.waitAsync(ctrl,2,0,4);
      if(wake.async)await wake.value;
      spins=0;continue;
    }
    if((did<1000&&++spins>4)||spins>100){await new Promise(r=>setTimeout(r,0));spins=0;}
    else if(did>=1000)spins++;
  }
}
