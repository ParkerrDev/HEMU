import assert from "node:assert/strict";
import {LegacySnapshot} from "./LegacySnapshot.mjs";
import {HemuBoot} from "./WorkerHost.mjs";

for (const patch of ["doc-sprite-clip-v1","ac-dbl-buf-v1"]) {
  const snapshot=await LegacySnapshot({guestPatches:[patch],paused:false}),
    h=await HemuBoot({snapshot});
  try {
    const failed=h.msgs.find(m=>m.cmd==="error")||await h.Wait(m=>m.cmd==="error",30000);
    assert.match(failed.msg,/Saved .* patch metadata does not match guest code/);
    assert.ok(!h.msgs.some(m=>["guestReady","smpReady","restored"].includes(m.cmd)),
      "historical patch claims are checked before publishing a restored machine");
    assert.equal(Atomics.load(h.ctrl,0),0,"no application core resumes invalid saved code");
  } finally {await h.Stop();}
}
console.log("Historical saves: legal correction names cannot claim uncorrected RAM; refusal precedes readiness and AP execution.");
