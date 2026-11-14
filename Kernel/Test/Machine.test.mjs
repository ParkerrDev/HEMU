import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {Machine} from "../Machine.js";

const manifest=await readFile(new URL("../../stock.json",import.meta.url)),workers=[],events=[],errors=[];
let held=null;
globalThis.crossOriginIsolated=true;
globalThis.fetch=async url=>{
  if(String(url).endsWith("hemu.wasm")&&held)await held;
  return new Response(String(url).endsWith("stock.json")?manifest:
    String(url).endsWith(".json")?JSON.stringify({globals:{g_ipi_pending:64}}):new Uint8Array([0]));
};
globalThis.Worker=class {
  constructor(url){this.url=String(url);this.sent=[];workers.push(this);}
  postMessage(m){this.sent.push(m);}
  terminate(){this.stopped=true;}
  Receive(m){this.onmessage?.({data:m});}
};
const machine=Machine({message:m=>events.push(m),error:e=>errors.push(e)}),boot={gz:new ArrayBuffer(4),cores:1};
try {
  let release;held=new Promise(resolve=>release=resolve);
  machine.Warm(1);
  const pending=machine.Start(boot);
  machine.Stop();held=null;release();
  assert.equal(await pending,false);
  assert.ok(workers.every(w=>w.stopped));
  assert.equal(workers.flatMap(w=>w.sent).length,0,"Canceled asset fetch cannot initialize a worker.");

  held=new Promise(resolve=>release=resolve);
  const starting=machine.Start({...boot,fast:true,rate:30});
  machine.post({cmd:"set",fast:false,rate:60});
  machine.post({cmd:"set",repeat:true});
  held=null;release();
  await starting;
  let bsp=workers.at(-1);
  assert.equal(bsp.sent[0].fast,false,"Settings changed while fetching apply before the first frame.");
  assert.equal(bsp.sent[0].rate,60);
  assert.equal(bsp.sent[0].repeat,true);
  assert.equal(bsp.sent[0].resumeDisk,false);
  const restarting=machine.Restart(boot);
  assert.equal(bsp.sent.at(-1).cmd,"flushDisk","Restart flushes even before guest/disk readiness.");
  const flushId=bsp.sent.at(-1).id;
  machine.post({cmd:"set",fast:false,rate:120});
  bsp.Receive({cmd:"fileResult",id:flushId,ok:true});
  assert.equal(await restarting,true);assert.equal(bsp.stopped,true);
  bsp=workers.at(-1);assert.equal(bsp.sent[0].resumeDisk,true);
  assert.equal(bsp.sent[0].fast,false,"Changes during the disk flush reach the replacement machine.");
  assert.equal(bsp.sent[0].rate,120);

  bsp.Receive({cmd:"frame",buf:new ArrayBuffer(0)});
  bsp.Receive({cmd:"error",msg:"CPU 0 stopped",retained:true});
  assert.equal(errors.at(-1).retained,true);assert.ok(!bsp.stopped);
  assert.match((await machine.Request({cmd:"osExec",src:""})).msg,/CPU 0 stopped/);
  const failedFlush=machine.Restart(boot),flush=bsp.sent.at(-1);
  assert.equal(flush.cmd,"flushDisk","Faulted guest still accepts host disk flush.");
  bsp.Receive({cmd:"fileResult",id:flush.id,ok:false,msg:"Disk transaction failed"});
  await assert.rejects(failedFlush,/Disk transaction failed/);
  assert.ok(!bsp.stopped,"Failed persistence leaves the old machine available for backup.");

  const saved={meta:{cores:4,ipiAddr:64},wasm:new Uint8Array([0])};
  await machine.Start({...boot,cores:4,saved});
  const group=workers.filter(w=>!w.stopped);assert.equal(group.length,4);
  bsp=group.find(w=>w.url.endsWith("/HemuWorker.js"));
  const init=bsp.sent[0],ctrl=new Int32Array(init.smp.ctrl);
  assert.equal(init.resumeDisk,false,"Explicit import replaces C: from its saved machine.");
  bsp.Receive({cmd:"frame",buf:new ArrayBuffer(0)});
  group.find(w=>w!==bsp).onerror({message:"AP lost"});
  assert.equal(Atomics.load(ctrl,1),1);
  machine.post({cmd:"exportSnapshot"});
  assert.equal(events.at(-1).ok,false);assert.match(events.at(-1).msg,/coordination failed/);
  const restored=machine.Restart({...boot,cores:4,saved}),savedFlush=bsp.sent.at(-1);
  assert.equal(savedFlush.cmd,"flushDisk");
  bsp.Receive({cmd:"fileResult",id:savedFlush.id,ok:true});
  await restored;
  bsp=workers.filter(w=>!w.stopped).find(w=>w.url.endsWith("/HemuWorker.js"));
  assert.equal(bsp.sent[0].resumeDisk,true,"Saved-session restart keeps the latest persisted C:.");
  machine.Stop();assert.ok(workers.every(w=>w.stopped));
  console.log("Machine cancellation, pre-ready/faulted disk flush, failed flush retention, imported/restarted C: policy and SMP export/teardown pass.");
} finally {machine.Stop();}
