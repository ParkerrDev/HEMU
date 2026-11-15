import assert from "node:assert/strict";
import {compileHemu} from "../Compile.js";
import {HemuBoot,ReadyWait,Sleep} from "./WorkerHost.mjs";

function Request(h,message,pred,ms=15000)
{
  const result=h.Wait(pred,ms);
  h.Post(message);
  return result;
}
for (const smp of [0,4]) {
  const compiled=compileHemu({smp:!!smp}),
    Addr=function (name) {return Number(compiled.globals.get(name).addr);},
    ranges=[[Addr("g_cpu_st"),Addr("g_ncore")-Addr("g_cpu_st")],
      [Addr("g_xmm_lo"),1024],[Addr("g_win_surface"),1]],
    h=await HemuBoot({smp,busProtocol:1,rate:30,keep:2});
  try {
    assert.equal((await ReadyWait(h,20000)).ok,true);
    if (!h.msgs.some(function (m) {return m.cmd=="diskInfo" && m.ok;}))
      await h.Wait(function (m) {return m.cmd=="diskInfo" && m.ok;},30000);
    if (smp && !h.msgs.some(function (m) {return m.cmd=="smpReady";}))
      await h.Wait(function (m) {return m.cmd=="smpReady";},10000);
    const stopped=h.Wait(function (m) {
      return m.cmd=="error" && m.msg.includes("native window drawing transaction");
    },20000),paused=h.Wait(function (m) {return m.cmd=="paused" && m.value;},20000),
      submitted=await Request(h,{cmd:"osExec",id:"surface-fault",target:"adam",src:`
U0 SurfaceFaultTask()
{
  Sleep(200);
  while (TRUE) {
    PUSHFD
    CLI
    if (InU8(0x5047)) {
      asm {
        DU8 0xD9,0xD1;
      }
    }
    POPFD
    Sleep(20);
  }
}
Spawn(&SurfaceFaultTask,,,-1);
`},function (m) {return m.cmd=="fileResult" && m.id=="surface-fault";});
    assert.equal(submitted.ok,true,JSON.stringify(submitted));
    const [error]=await Promise.all([stopped,paused]);
    assert.equal(error.retained,true);assert.equal(error.paused,true);
    await Sleep(100);
    const before=await Request(h,{cmd:"__peek",ranges},function (m) {return m.cmd=="__peek";}),
      frames=h.nframes;
    assert.equal(before.fault,"4");
    assert.deepEqual([...before.ranges.at(-1)],[1],"the surface remains held after the fault");
    let generation=0;
    if (smp) generation=Atomics.load(h.ctrl,2);
    function BarrierCheck()
    {
      if (smp) {
        assert(generation>0);
        assert.equal(Atomics.load(h.ctrl,2),generation,"commands cannot release or replace the retained barrier");
        for (let core=1;core<4;core++)
          assert.equal(Atomics.load(h.ctrl,4+core),generation);
        assert.equal(Atomics.load(h.ctrl,12),0);
        assert.equal(Atomics.load(h.ctrl,13),0);
      }
    }
    BarrierCheck();
    const resume=await Request(h,{cmd:"pause",value:false},function (m) {
      return m.cmd=="error" && m.msg.includes("before resuming");
    });
    assert.equal(resume.retained,true);assert.equal(resume.paused,true);
    BarrierCheck();
    const settings=await Request(h,{cmd:"set",fast:false,rate:60,repeat:true},
      function (m) {return m.cmd=="settings";});
    assert.equal(settings.ok,false);assert.match(settings.msg,/Restart before changing settings/);
    BarrierCheck();
    for (const cmd of ["exportSnapshot","exportDisk"]) {
      const result=await Request(h,{cmd},function (m) {return m.cmd=="exportResult";});
      assert.equal(result.ok,false);assert.match(result.msg,/Restart before saving/);
      assert.equal(result.buf,undefined);
      BarrierCheck();
    }
    await Request(h,{cmd:"pause",value:true},function (m) {return m.cmd=="paused" && m.value;});
    await Sleep(150);
    const after=await Request(h,{cmd:"__peek",ranges},function (m) {return m.cmd=="__peek";});
    assert.equal(after.fault,"4");assert.equal(after.faultPc,before.faultPc);
    assert.deepEqual(after.ranges,before.ranges,"all CPU/FPU states and the held surface remain frozen");
    assert.equal(h.nframes,frames);
    BarrierCheck();
    console.log((smp || 1)+"-core surface fault: resume, settings and snapshot/disk export retain the same barrier and frozen CPUs.");
  } finally {await h.Stop();}
}
