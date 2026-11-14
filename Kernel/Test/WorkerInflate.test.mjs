import assert from "node:assert/strict";
import {HemuBoot,ReadyWait,FramesWait,TextRow} from "./WorkerHost.mjs";
import {BUS_VERSION} from "../CoreBus.js";

for (const cores of [1,4]) {
  const h=await HemuBoot({smp:cores===4?4:0,rate:60,webWorker:false,keep_buf:true,
    ...(cores===4?{busProtocol:BUS_VERSION}:{})});
  try {
    assert.equal((await ReadyWait(h,20000)).ok,true);
    if (!h.frames.length) await FramesWait(h,1,10000);
    const ram=h.msgs.find(m=>m.cmd==="ramReady"),
      text=Array.from({length:60},(_,row)=>TextRow(h.frames[0].buf,640,row)).join("\n");
    assert.ok(ram && Number.isFinite(ram.ms));
    assert.match(text,/Trivial Solutions/);
    assert.match(text,/Take Tour\(y or n\)\?/);
    assert.ok(!h.msgs.some(m=>m.cmd==="guestPatch" || m.cmd==="error"));
    console.log(cores+" cores: compressed sparse RAM resumes its prepared desktop without nested workers.");
  } finally {await h.Stop();}
}
