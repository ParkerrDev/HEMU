import assert from "node:assert/strict";
import {GuestHarness} from "./GuestHarness.mjs";

const h=await GuestHarness({exports:["DeskAddr","VideoCapture"],extraSource:`
U64 DeskAddr() {return g_desk;}
`}),{ex,gx,base,Name}=h,u8=new Uint8Array(ex.memory.buffer),
  area=gx.scratch.base+0x800000,args=area+0x40000;
let seed=0x7C14A22;
const Rand=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed>>>24;};
//Compare the captured pixels against the guest's own planar decoder.
const dv=new DataView(ex.memory.buffer),hostImage=Number(h.compiled.globals.get("video_image").addr),
  imageSlot=Number(dv.getBigUint64(hostImage,true)),fake=area+0x60000,planes=area+0x70000,
  output=area+0xA0000,member=n=>Number(ex.GuestMember(Name("CDC"),Name(n,0x7100)));
{
  gx.wr64(fake+member("body"),planes);
  dv.setUint32(base+fake+member("width_internal"),640,true);
  dv.setUint32(base+fake+member("height"),480,true);
  gx.wr64(args,fake);
  for(let i=0;i<153600;i++)u8[base+planes+i]=Rand();
  dv.setBigUint64(hostImage,BigInt(args),true);ex.VideoCapture();
  const captured=u8.slice(Number(ex.DeskAddr()),Number(ex.DeskAddr())+307200);
  dv.setBigUint64(hostImage,BigInt(imageSlot),true);
  await h.Call(Number(ex.GuestFun(Name("GrBitMap4ToBitMap8"))),[output,planes,153600,-1]);
  assert.deepEqual(captured,u8.slice(base+output,base+output+307200),"captured frame equals native planar decoder");
}
await h.Exec(`U0 VideoZoomCheck(U8 *source,U8 *output) {
  I64 zoom=gr.scrn_zoom,sx=gr.sx,sy=gr.sy;
  U8 *old=gr.dc1->body;
  gr.dc1->body=source;gr.scrn_zoom=2;gr.sx=gr.sy=0;
  GrUpdateVGAGraphics;
  MemCpy(output,gr.scrn_image->body,153600);
  gr.dc1->body=old;gr.scrn_zoom=zoom;gr.sx=sx;gr.sy=sy;
}`);
await h.Call(Number(ex.GuestFun(Name("VideoZoomCheck"))),[planes,output],20000000);
for(let plane=0;plane<4;plane++)for(let y=0;y<480;y++)for(let x=0;x<640;x++) {
  const from=base+planes+plane*38400+(y>>1)*80+(x>>4),
    to=base+output+plane*38400+y*80+(x>>3);
  assert.equal(u8[to]>>(x&7)&1,u8[from]>>((x>>1)&7)&1,"native 2x screen zoom");
}
await h.Run(5);
const slot=gx.scratch.base+0x7000;
await h.Exec(`CDC *video_capture=DCScrnCapture;*(${slot})(I64*)=video_capture;`);
const dc=gx.rd64(slot),bodyOff=Number(ex.GuestMember(Name("CDC"),Name("body",0x7100))),body=gx.rd64(dc+bodyOff),
  pixels=u8.slice(base+body,base+body+307200);
assert.ok(new Set(pixels).size>=8,"native screenshots contain the actual desktop colors");
assert.ok(pixels.some(v=>v!==pixels[0]),"native screenshot is not blank");
await h.Exec("DCDel(video_capture);");
console.log("Captured frames match native planar decoding; original guest 2x zoom and DCScrnCapture preserve desktop pixels.");
