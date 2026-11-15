import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {GuestHarness} from "./GuestHarness.mjs";
import {GuestWindows} from "../GuestWindows.js";

const h=await GuestHarness(),messages=[],gx=h.gx;
let paused=false;
const bridge=GuestWindows({gx,exec:src=>h.Exec(src),post:m=>messages.push(m),
  paused:()=>paused,source:()=>readFileSync(new URL("../GuestWin.HC",import.meta.url),"latin1")});
assert.equal((await bridge.Request({op:"enable"})).ok,true);
const w=await bridge.Request({op:"host",host:"test",title:"Native test",cols:30,rows:10,
  x:80,y:80,doc:'Native text\n$BT-X,"Action",LE=7$'});
assert.equal(w.ok,true);
await h.Run(10);
assert(gx.rd64(w.task+gx.memberFind("CTask","put_doc"))>0,"native host document exists");
await h.Exec(`
public I64 web_test_draws=0;
U0 WebTestDraw(CTask *,CDC *dc)
{
  web_test_draws++;
  dc->color=RED;
  GrRect(dc,24,48,40,16);
}
DocClear(DocBorder(${w.task}),TRUE);
`);
await h.Run(30);
const gr=gx.varFind("gr"),body=gx.memberFind("CDC","body"),
  grDc=gx.memberFind("CGrGlbls","dc2"),
  flag=gx.memberFind("CTask","display_flags");
bridge.Tick(true);
let win=messages.at(-1).windows.find(v=>v.task===w.task);
assert(win && !win.detached,"native proxy is on the desktop");
function Crop(addr)
{
  const buf=new Uint8Array(win.w*win.h);
  for (let y=0;y<win.h;y++)
    buf.set(gx.rdBytes(addr+(win.y+y)*640+win.x,win.w),y*win.w);
  return buf;
}
const before=Crop(gx.rd64(gx.rd64(gr+grDc)+body));
const detached=await bridge.Request({op:"detach",task:w.task,num:w.num});
assert.equal(detached.slot,w.slot);
await h.Run(20);
bridge.Tick(true);
win=messages.at(-1).windows.find(v=>v.task===w.task);
assert(win.detached && win.buf,"detached window exports a live surface");
assert.equal(Buffer.compare(new Uint8Array(win.buf),before),0,"native compositor and detached surface have identical pixels");
assert.equal(h.ex.WinSurfaceActive(),0n,"native drawing released its CPU barrier");
h.ex.RenderFastSet(0n);
await h.Run(15);bridge.Tick(true);
assert(messages.at(-1).windows.find(v=>v.task===w.task).detached,
  "window passthrough also runs with Web Optimization off");
assert.equal(h.ex.WinSurfaceActive(),0n);
h.ex.RenderFastSet(1n);
bridge.Input(w.slot,w.task,w.num+1);
assert.equal(gx.rd64b(gx.varFind("web_win_input")),0xFFFFFFFFFFFFFFFFn,
  "stale input identity cannot select a reused slot");
bridge.Input(w.slot,w.task,w.num);
assert.equal(gx.rd64(gx.varFind("web_win_input")),w.slot);
await h.Exec(`DocLock(DocPut(${w.task}));`);
const seqPtr=gx.varFind("web_wins")+w.slot*(gx.memberFind("CWebWin","text")+8)+
  gx.memberFind("CWebWin","seq"),seq=gx.rd64(seqPtr);
await h.Run(15);
assert.equal(gx.rd64(seqPtr),seq,"a busy native document skips rendering without blocking the CPU");
assert.equal(h.ex.WinSurfaceActive(),0n,"busy documents release the barrier");
await h.Exec(`DocUnlock(DocPut(${w.task}));`);
await h.Run(15);
assert(gx.rd64(seqPtr)>seq,"drawing resumes when the document unlocks");
await bridge.Request({op:"focus",...w});
await h.Run(10);
assert(gx.rd32(w.task+flag)&1,"detached input target participates in native hit testing");
bridge.Input(-1);
await h.Run(10);
assert.equal(gx.rd32(w.task+flag)&1,0,"detached window cannot intercept desktop input");
await h.Exec(`TaskMsg(${w.task},0,MSG_CMD,7,0,0);TaskMsg(${w.task},0,MSG_CMD,8,0,0);TaskMsg(${w.task},0,MSG_CMD,9,0,0);`);
await h.Run(10);
bridge.Tick(true);
assert(messages.some(m=>m.actions.some(a=>a.slot===w.slot && a.id===7)),
  "native document actions return to their browser owner");
assert.deepEqual(messages.flatMap(m=>m.actions).filter(a=>a.slot===w.slot).map(a=>a.id),
  [7,8,9],"queued native actions retain their order between host ticks");
await bridge.Request({op:"attach",...w,x:160,y:128});
bridge.Tick(true);
win=messages.at(-1).windows.find(v=>v.task===w.task);
assert(!win.detached && win.x===160 && win.y===128,"drag-in retains the task at its new native position");
assert.equal(gx.rd64(w.task+gx.memberFind("CTask","task_num")),w.num);
await h.Exec(`${w.task}(CTask *)->draw_it=&WebTestDraw;`);
await assert.rejects(bridge.Request({op:"detach",task:w.task,num:w.num}),/needs the TempleOS desktop/);
assert(gx.rd32(w.task+flag)&1,"custom drawing stays visible in TempleOS");
await h.Exec(`${w.task}(CTask *)->draw_it=NULL;`);
await bridge.Request({op:"detach",task:w.task,num:w.num});
await h.Exec(`${w.task}(CTask *)->draw_it=&WebTestDraw;`);
await h.Run(15);bridge.Tick(true);
assert(!messages.at(-1).windows.find(v=>v.task===w.task).detached,
  "a document that acquires custom drawing returns to the native desktop");
assert(gx.rd32(w.task+flag)&1);
await h.Exec(`${w.task}(CTask *)->draw_it=NULL;`);
await bridge.Request({op:"detach",task:w.task,num:w.num});
paused=true;
await assert.rejects(bridge.Request({op:"attach",...w,x:0,y:0}),/Resume TempleOS/);
await bridge.Request({op:"disable"});
assert.equal(gx.rd64(gx.varFind("web_win_enabled")),0,"disable works without advancing paused guest");
paused=false;
await h.Run(20);
assert.equal(gx.taskInfo(w.task).valid,false,"native cleanup closes browser-owned task");
await bridge.Request({op:"enable"});
bridge.Tick(true);
const guest=messages.at(-1).windows.find(v=>v.slot===-1);
assert(guest,"ordinary guest window available");
await bridge.Request({op:"detach",task:guest.task,num:guest.num});
await h.Run(10);
await bridge.Request({op:"disable"});
await h.Run(20);
assert(gx.taskInfo(guest.task).valid,"disable preserves ordinary guest task");
assert(gx.rd32(guest.task+flag)&1,"disable returns ordinary guest window to desktop");
console.log("PASS native windows: reference pixels, CPU barrier, input ownership, actions, round trip, custom drawing, pause and cleanup");
