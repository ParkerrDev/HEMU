import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {GuestHarness} from "./GuestHarness.mjs";
import {AcMoveRead} from "./ACMove.mjs";

const probe=readFileSync(new URL("./ACFlicker.HC",import.meta.url)),
  move=readFileSync(new URL("./ACMove.HC",import.meta.url)),
  fixture=JSON.parse(readFileSync(new URL("./ACFlickerOracle.json",import.meta.url))),
  Hash=b=>createHash("sha256").update(b).digest("hex");
assert.equal(Hash(probe),fixture.probeHash);
assert.equal(Hash(move),fixture.moveProbeHash);
const h=await GuestHarness({disk:true}),{gx}=h;
await h.Exec(probe.toString("latin1"));
await h.Exec("ACFlickerCheck(3000);");
const res=gx.varFind("ac_flicker_res"),text=gx.varFind("ac_flicker_text"),
  actual=[0,1,2].map(phase=>{
    const [frames,hidden,refills,switches,spans,changes,shorts]=
      Array.from({length:7},(_,i)=>gx.rd64(res+(phase*7+i)*8));
    return {frames,hidden,refills,switches,spans,changes,shorts,text:gx.rdStr(text+phase*64)};
  });
actual.forEach((p,i)=>{
  assert.ok(p.refills>=5 && p.frames>0,"AutoComplete refills while its frames are sampled");
  assert.deepEqual([p.hidden,p.switches,p.spans,p.shorts],[0,0,0,0],
    "the prepared native window remains visible throughout each refill");
  assert.equal(p.text,fixture.patched[i].text);
});
assert.ok(actual[0].changes<=2 && actual[1].changes<=2,
  "refilling the same list changes its image only for the new word");
assert.ok(actual[2].changes>=2,"the window changes between the list and StandBy");
await h.Exec(move.toString("latin1"));
await h.Exec("ACMoveCheck;");
assert.deepEqual(AcMoveRead(gx),fixture.movePatched,
  "the dragged window and the key map retain their independent positions, as natively");
console.log("Prepared AutoComplete: "+actual.reduce((n,p)=>n+p.refills,0)+
  " refills without hidden frames, task switches while hidden, or flicker; native drag positions retained.");
