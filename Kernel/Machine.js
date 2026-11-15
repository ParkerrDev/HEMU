import {BusStop,BUS_VERSION} from "./CoreBus.js";
import {StockManifest} from "./Stock.js";
import {GuestRequests} from "./GuestRqsts.js";

const Asset=name=>new URL("../build/"+name,import.meta.url).href;
async function Bytes(url) {
  const r=await fetch(url);
  if(!r.ok)throw new Error(url+": HTTP "+r.status);
  return r.arrayBuffer();
}
function WorkerNew(ap=false) {
  return new Worker(new URL(ap?"./HemuSmpWorker.js":"./HemuWorker.js",import.meta.url),{type:"module"});
}
function Dispose(group) {
  if(!group)return;
  clearTimeout(group.watchdog);
  if(group.ctrl)BusStop(new Int32Array(group.ctrl));
  group.bsp?.terminate();
  for(const ap of group.aps)ap.terminate();
}

export function Machine({message,error,earlyWorker=null})
{//The host owns the boot bytes. This owns workers, RAM and request lifetimes.
  let group=null,spare=null,generation=0;
  const requests=GuestRequests(Post);
  function SpareTake(cores) {
    const s=spare;spare=null;
    if(s?.cores===cores)return s;
    Dispose(s);return null;
  }
  function Warm(cores) {
    SpareTake(null);
    const wasmUrl=Asset(cores===4?"hemu-smp.wasm":"hemu.wasm");
    spare={cores,aps:[],bsp:null,wasm:Bytes(wasmUrl),manifest:StockManifest(),
      sc:cores===4?Bytes(Asset("hemu-smp.json")).then(b=>JSON.parse(new TextDecoder().decode(b))):null};
    for(const p of [spare.wasm,spare.manifest,spare.sc])p?.catch(()=>{});
    try {
      spare.bsp=earlyWorker||WorkerNew();earlyWorker=null;
      for(let k=1;k<cores;k++)spare.aps.push(WorkerNew(true));
    } catch {
      Dispose(spare);spare.bsp=null;spare.aps=[];
    }
  }
  function Stop(msg="OS stopped during the request.") {
    generation++;
    Dispose(group);group=null;SpareTake(null);
    earlyWorker?.terminate();earlyWorker=null;
    requests.Reset(msg);requests.Fail(msg);
  }
  function Post(m,transfer=[]) {
    if(group?.restart&&m.cmd==="set") {
      const {cmd,...settings}=m;
      Object.assign(group.restart,settings);
    }
    if(!group?.initialized) {
      if(group&&m.cmd==="set") {
        const {cmd,...settings}=m;
        group.settings={...group.settings,...settings};
      }
      return;
    }
    if((group.hostLost||group.busFailed)&&["exportSnapshot","exportDisk"].includes(m.cmd)) {
      message({cmd:"exportResult",kind:m.cmd==="exportSnapshot"?"snapshot":"disk",ok:false,
        msg:group.hostLost?"The main worker was lost. This machine cannot be exported; restart TempleOS.":
          "Shared RAM coordination failed. This stopped machine cannot be exported; restart TempleOS."});
      return;
    }
    if(group.hostLost) {
      if(m.cmd==="flushDisk")throw Error("The main worker was lost; only previously saved C: data can be restored.");
      return;
    }
    group.bsp.postMessage(m,transfer);
  }
  async function Start(boot,resumeDisk=false) {
    const {gz,cores=1,saved=null,...options}=boot,s=saved?SpareTake(null):SpareTake(cores);
    //Requests queued before the first boot wait for it; replacements cancel them.
    if(generation||group){Stop();requests.Reset();}
    else {generation++;earlyWorker?.terminate();earlyWorker=null;}
    const current=generation,g=group={cores,bsp:s?.bsp||null,aps:s?.aps||[],ctrl:null,
      alive:false,initialized:false,busFailed:false,hostLost:false,watchdog:null};
    const Current=()=>current===generation&&group===g;
    function Failed(msg,retained=false,coordination=false) {
      if(!Current())return;
      clearTimeout(g.watchdog);
      const started=g.alive;
      retained=retained||started;
      if(retained) {
        if(coordination&&g.ctrl){g.busFailed=true;BusStop(new Int32Array(g.ctrl));}
        if(coordination||g.hostLost)g.capture={ready:false,msg};
        requests.Fail(msg+" Restart TempleOS before running programs or writing files.");
      } else Stop(msg);
      error({msg,retained,started,cores,busFailed:g.busFailed});
    }
    function HostLost(msg) {
      if(!Current())return;
      g.hostLost=true;requests.Reset(msg);
      g.bsp.terminate();
      Failed(msg+" The main worker was lost. Restart restores the last saved C:; unsaved changes in that worker cannot be recovered.",false,true);
    }
    function Receive(m) {
      if(!Current())return;
      if(m.cmd==="error") {
        Failed(m.msg,!!m.retained,!!(g.ctrl&&(Atomics.load(new Int32Array(g.ctrl),1)||!m.retained)));
        return;
      }
      requests.Receive(m);
      if(m.cmd==="captureState"&&!g.hostLost&&!g.busFailed)g.capture=m;
      if(m.cmd==="frame") {
        g.alive=true;clearTimeout(g.watchdog);
        g.bsp.postMessage({cmd:"ack"});
      }
      message(m);
    }
    try {
      if(![1,4].includes(cores))throw Error("A saved machine must have one or four CPUs");
      if(saved&&saved.meta.cores!==cores)throw Error("Snapshot core count does not match the worker topology");
      if(cores===4&&!globalThis.crossOriginIsolated)throw Error("Four cores need a cross-origin isolated server");
      const wasmUrl=Asset(cores===4?"hemu-smp.wasm":"hemu.wasm");
      let wasmBytes,manifest,sc;
      if(saved) {
        wasmBytes=saved.wasm;sc={ncore:cores,globals:{g_ipi_pending:saved.meta.ipiAddr}};
      } else {
        [wasmBytes,manifest,sc]=await Promise.all([s?.wasm||Bytes(wasmUrl),s?.manifest||StockManifest(),
          cores===4?(s?.sc||Bytes(Asset("hemu-smp.json")).then(b=>JSON.parse(new TextDecoder().decode(b)))):null]);
        if(sc)sc.ncore=cores;
      }
      if(!Current())return false;
      g.bsp??=WorkerNew();
      g.bsp.onmessage=e=>Receive(e.data);
      g.bsp.onerror=e=>HostLost(e.message||"Main worker failed");
      g.bsp.onmessageerror=()=>HostLost("The main worker sent an unreadable message");
      const init={cmd:"init",gz,wasmUrl,...options,...g.settings,
        wasmBytes:saved?undefined:wasmBytes,manifest,resumeDisk};
      if(cores===4) {
        const mem=new WebAssembly.Memory({initial:512,maximum:8192,shared:true});
        g.ctrl=new SharedArrayBuffer(64);
        for(let core=1;core<cores;core++) {
          const ap=g.aps[core-1]??(g.aps[core-1]=WorkerNew(true));
          ap.onmessage=e=>{
            if(e.data.cmd==="error")Receive({...e.data,msg:"AP"+core+": "+e.data.msg});
            else if(Current()&&e.data.cmd==="log")message(e.data);
          };
          ap.onerror=e=>Failed("AP"+core+" worker error: "+(e.message||""),false,true);
          ap.onmessageerror=()=>Failed("AP"+core+" sent an unreadable message",false,true);
          ap.postMessage({cmd:"init",role:"ap",core,mem,ctrl:g.ctrl,sc,wasmBytes,
            heapAbi:saved?.meta.heapAbi,busProtocol:BUS_VERSION,requiredBusProtocol:saved?.meta.requiredBusProtocol});
        }
        init.smp={mem,ctrl:g.ctrl,ipiAddr:sc.globals.g_ipi_pending,ncore:cores,busProtocol:BUS_VERSION};
      }
      g.bsp.postMessage(init,[options.diskBytes,...(!saved&&cores===1?[wasmBytes]:[])].filter(Boolean));
      g.initialized=true;
      g.watchdog=setTimeout(()=>Failed("No frame in "+(cores===4?15:10)+"s"),cores===4?15000:10000);
      return true;
    } catch(e) {Failed(String(e.message||e));return false;}
  }
  async function Restart(boot) {
    const current=generation,previous=group,next={...boot};
    requests.Fail("OS restarted during the request.");
    if(previous)previous.restart=next;
    try {
      if(group?.initialized&&!group.hostLost) {
        const result=await requests.Request({cmd:"flushDisk"});
        if(current!==generation)return false;
        if(!result.ok&&!group.hostLost){requests.Fail(result.msg);throw Error(result.msg);}
      }
    } finally {
      if(previous)delete previous.restart;
    }
    SpareTake(null);requests.Reset();
    return Start(next,true);
  }
  return {Warm,Start,Restart,Stop,post:Post,Request:requests.Request,
    get capture(){return group?.capture||{ready:false,msg:"Wait for TempleOS and C: to finish loading."};},
    get kind(){return group?(group.cores===4?"smp":"worker"):null;},
    get busFailed(){return !!group?.busFailed;}};
}
