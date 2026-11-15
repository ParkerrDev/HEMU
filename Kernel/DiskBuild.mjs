import {readFileSync,writeFileSync,mkdirSync} from "node:fs";
import {resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {compileHolyC} from "../holyc-wasm/src/compiler.js";

export function DiskCompile() {
  return compileHolyC(readFileSync(new URL("DiskHost.HC",import.meta.url),"latin1"),{
    filename:"DiskHost.HC",lenient:false,includeResolver:name=>name==="Disk"?
      readFileSync(new URL("Disk.HC",import.meta.url),"latin1"):null,exports:["DskInfo","DskOffset","DskTmp","DskTmpDel","FatLst","FatRead","FatWrite"]});
}

export function DiskBuild(out) {
  const compiled=DiskCompile();
  if(compiled.warnings.length)throw Error(compiled.warnings.join("\n"));
  mkdirSync(out,{recursive:true});writeFileSync(resolve(out,"disk.wasm"),compiled.bytes);
  console.log(`disk.wasm: ${compiled.bytes.length} bytes`);
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))
  DiskBuild(resolve(process.argv[2]||"build"));
