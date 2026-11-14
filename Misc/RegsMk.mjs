import {readFileSync,writeFileSync} from "node:fs";
import {RegsRead,RegsSource} from "./Regs.mjs";

const path=process.argv[2];
if (!path)
  throw Error("Usage: node Misc/RegsMk.mjs capture.txt [output.HC]");
const raw=readFileSync(path,"utf8"),
  capture=RegsRead(raw,[...raw.matchAll(/CPU#\d+/g)].length);
let file="SnapRegs";
if (capture.cores.length==4)
  file+="Smp";
writeFileSync(process.argv[3]??new URL("../Kernel/"+file+".HC",import.meta.url),
  RegsSource(capture));
console.log("Generated "+capture.cores.length+" cores from "+
  capture.registerSha256);
