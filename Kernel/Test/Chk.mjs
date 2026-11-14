import {spawnSync} from "node:child_process";
import {realpathSync} from "node:fs";
import {fileURLToPath} from "node:url";

const args=new Set(process.argv.slice(2));
if([...args].some(a=>!["--full","--desktop"].includes(a))) {
  console.error("Usage: node Kernel/Test/Chk.mjs [--full] [--desktop]");
  process.exit(2);
}
const root=fileURLToPath(new URL("../../",import.meta.url)),start=performance.now();
console.log("Compiler:",realpathSync(new URL("../../holyc-wasm",import.meta.url)));
const quick=["Machine.test.mjs","GuestRqsts.test.mjs","HostSelfTest.mjs","Measure.mjs","CpuId.test.mjs","CpuNative.mjs","BootTest.mjs","DiskIOChk.mjs",
  "Atomic.test.mjs","AtomicFlags.test.mjs","AtomSplit.test.mjs","Bit.test.mjs","CmpXchg8b.test.mjs","CmpXchg16b.test.mjs","CmpWrite.test.mjs","MulDiv.test.mjs","Divide.test.mjs","Stk.test.mjs","JitStkMem.test.mjs","Time.test.mjs","MemNative.mjs","DevNative.mjs","Speaker.test.mjs","SndStamp.test.mjs","Kbd.test.mjs","Capture.test.mjs","Barrier.test.mjs",
  "Bus.test.mjs","BusHemu.test.mjs","SnapshotFmt.test.mjs","SnapRegs.test.mjs","Stock.test.mjs","StockInit.test.mjs","JitOwner.test.mjs","JitPrimitives.test.mjs","JitMem.test.mjs","JitLoop.test.mjs","JitBranch.test.mjs","FpuChk.mjs",
  "FpuCvt.test.mjs","FpuCompare.test.mjs","SseCompare.test.mjs","FpuOps.test.mjs","CpuFault.test.mjs","FpuNative.mjs","JitX87.test.mjs","JitX87Mem.test.mjs","Shift.test.mjs","JitZeroShift.test.mjs","JitDiff1.mjs"],
  full=["GuestCode.test.mjs","MenuClip.test.mjs","ACFlicker.test.mjs","Video.test.mjs","RasterNative.mjs","RasterAlias.mjs","Rate.test.mjs","GuestChk.mjs","LargeFile.test.mjs",
    "JitRecycle.mjs","Worker.test.mjs","WorkerExec.test.mjs","WorkerCpuId.test.mjs","WorkerFault.test.mjs","WorkerLegacyFault.test.mjs","SavedPatch.test.mjs","WorkerClock.test.mjs","WorkerRate.test.mjs","WorkerPause.test.mjs",
    "WorkerInflate.test.mjs","WorkerSnapshot.test.mjs","WorkerBus.test.mjs","Idle.test.mjs","Welcome.test.mjs"];
let count=0;
function Run(path,env={}) {
  console.log("Checking",path);
  const r=spawnSync(process.execPath,["--max-old-space-size=3072",path],{
    cwd:root,stdio:"inherit",env:{...process.env,...env},timeout:300000
  });
  if(r.error)console.error(r.error.message);
  if(r.status!==0)process.exit(r.status||1);
  count++;
}
Run("Kernel/Build.mjs");
for(const path of quick)Run("Kernel/Test/"+path);
if(args.has("--full"))for(const path of full)Run("Kernel/Test/"+path);
if(args.has("--full"))for(const path of ["WorkerLegacyFault.test.mjs","WorkerSnapshot.test.mjs"])
  Run("Kernel/Test/"+path,{HEMU_BUS_PROTOCOL:"1"});
if(args.has("--desktop"))for(const cores of [1,4])
  Run("Kernel/Test/Desktop.test.mjs",{HEMU_DESKTOP_CORES:String(cores)});
if(args.has("--desktop")) {
  Run("Kernel/Test/SpeakerAudio.test.mjs");
  Run("Kernel/Test/DesktopLifecycle.test.mjs");
  Run("Kernel/Test/MachineDisk.test.mjs");
}
console.log(`${count} engine checks passed in ${((performance.now()-start)/1000).toFixed(1)}s.`);
