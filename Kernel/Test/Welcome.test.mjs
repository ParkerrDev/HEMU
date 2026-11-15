import assert from "node:assert/strict";
import {HemuBoot,ReadyWait,FramesWait,TextRow} from "./WorkerHost.mjs";

function Text(frame)
{
  return Array.from({length:60},(_,row)=>TextRow(frame.buf,640,row)).join("\n");
}

for (const cores of [1,4]) {
  const h=await HemuBoot({smp:cores===4?4:0,keep_buf:true});
  try {
    assert.equal((await ReadyWait(h,20000)).ok,true);
    if (!h.frames.length) await FramesWait(h,1,10000);
    const first=Text(h.frames[0]);
    assert.match(first,/Public Domain Operating System/);
    assert.match(first,/Trivial Solutions/);
    assert.match(first,/Take Tour\(y or n\)\?/);
    for (let y=104;y<192;y++)
      for (let x=408;x<472;x++)
        assert.equal(h.frames[0].buf[y*640+x],15,
          "Welcome's blank right margin covers AutoComplete in their overlap.");
    h.Post({cmd:"input",x:8,y:470,b:0});
    await FramesWait(h,3,5000);
    assert.match(Text(h.last),/God on Tap!/);
    h.Post({cmd:"input",keys:[0x2A,0x01,0x81,0xAA]});
    await FramesWait(h,12,5000);
    const closed=Text(h.last);
    assert.doesNotMatch(closed,/Trivial Solutions/);
    assert.match(closed,/Take Tour\(y or n\)\?/);
    assert.ok(!h.msgs.some(m=>m.cmd==="guestPatch" || m.cmd==="error"));
    console.log(cores+" cores: Welcome covers AutoComplete in the first completed frame; Tour remains visible and Shift-Esc closes only Welcome.");
  } finally {await h.Stop();}
}
