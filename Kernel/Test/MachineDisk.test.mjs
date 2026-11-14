import assert from "node:assert/strict";
import {mkdtemp,rm,readFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {chromium} from "playwright-core";
import {DesktopServer} from "../../Misc/Server.mjs";
import {BrowserMachine,MachinePost,MachineReady} from "./BrowserMachine.mjs";

const browser=await chromium.launch({executablePath:process.env.CHROMIUM||"/usr/bin/chromium",headless:true,
  args:["--no-sandbox"]}),temp=await mkdtemp(join(tmpdir(),"hemu-machine-disk-"));
let id=0;
async function Request(page,message) {
  const request="machine-disk-"+(++id);await MachinePost(page,{...message,id:request});
  await page.waitForFunction(id=>window.machine.events.some(m=>m.id===id&&["fileResult","dirList"].includes(m.cmd)),request);
  const result=await page.evaluate(id=>window.machine.events.find(m=>m.id===id&&["fileResult","dirList"].includes(m.cmd)),request);
  assert.equal(result.ok,true,result.msg);return result;
}
try {
  for(const cores of [1,4]) {
    const app=await DesktopServer({cores}),context=await browser.newContext();
    try {
      await BrowserMachine(context);
      await context.route("**/Kernel/HemuWorker.js",async route=>route.fulfill({contentType:"text/javascript",
        headers:{"Cross-Origin-Embedder-Policy":"require-corp","Cross-Origin-Resource-Policy":"same-origin"},
        body:'addEventListener("message",e=>{if(e.data.cmd==="testHostCrash")throw new Error("Forced BSP host crash");});\n'+
          await readFile(new URL("../HemuWorker.js",import.meta.url),"utf8")}));
      await context.addInitScript(()=>{
        const Base=Worker;
        window.Worker=class extends Base {
          postMessage(m,...args) {
            if(m.cmd==="init"&&m.gz&&window.delayNextDisk) {m={...m,diskDelay:15000};window.delayNextDisk=false;}
            return super.postMessage(m,...args);
          }
        };
      });
      const page=await context.newPage(),errors=[];
      page.on("dialog",dialog=>dialog.accept());page.on("pageerror",error=>errors.push(error.message));
      await page.goto(app.url);await MachineReady(page,cores);
      const download=page.waitForEvent("download",{timeout:60000}),path=join(temp,cores+".hemu");
      await page.locator("#save").click();await (await download).saveAs(path);
      const Write=()=>Request(page,{cmd:"osWrite",path:"C:/Home/RestartKeep.HC",name:"RestartKeep.HC",
        bytes:Array.from(new TextEncoder().encode('"Keep this C:";\n'))});
      const Check=async expected=>assert.equal((await Request(page,{cmd:"listDir",dir:"Home"})).files.some(f=>f.name==="RestartKeep.HC"),expected);
      await Write();
      let after=await page.evaluate(()=>window.machine.events.length);
      await page.evaluate(()=>window.delayNextDisk=true);
      await page.locator("#restart").click();
      await page.waitForFunction(n=>window.machine.events.slice(n).some(m=>m.cmd==="guestReady"&&m.diskPending),after,{timeout:45000});
      after=await page.evaluate(()=>window.machine.events.length);
      await page.locator("#restart").click();await MachineReady(page,cores,{after});await Check(true);
      after=await page.evaluate(()=>window.machine.events.length);
      await page.locator("#open").setInputFiles(path);await MachineReady(page,cores,{after});await Check(false);
      await Write();after=await page.evaluate(()=>window.machine.events.length);
      await page.locator("#restart").click();await MachineReady(page,cores,{after});await Check(true);
      after=await page.evaluate(()=>window.machine.events.length);
      await page.locator("#open").setInputFiles(path);await MachineReady(page,cores,{after});await Check(false);
      await Write();await Request(page,{cmd:"flushDisk"});
      await MachinePost(page,{cmd:"testHostCrash"});
      await page.waitForFunction(()=>document.getElementById("status").textContent.includes("unsaved changes in that worker cannot be recovered"));
      assert(await page.evaluate(()=>window.machine.workers.findLast(w=>w.machineCore===0).machineTerminated),
        "An uncaught host error terminates the BSP so it cannot keep executing or saving C:.");
      await page.locator("#save").evaluate(button=>button.dispatchEvent(new MouseEvent("click")));
      await page.waitForFunction(()=>document.getElementById("status").textContent.includes("cannot be exported"));
      after=await page.evaluate(()=>window.machine.events.length);
      await page.locator("#restart").click();await MachineReady(page,cores,{after});await Check(true);
      assert.deepEqual(errors.filter(message=>!message.includes("Forced BSP host crash")),[]);
      console.log(cores+" cores: C: survives restart before disk readiness and full-session restart; explicit import restores its own C:; lost BSP rejects export and restarts from committed C:.");
    } finally {await context.close();await app.close();}
  }
} finally {await browser.close();await rm(temp,{recursive:true,force:true});}
