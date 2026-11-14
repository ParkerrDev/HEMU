import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {chromium} from "playwright-core";

const browser=await chromium.launch({executablePath:process.env.CHROMIUM||"/usr/bin/chromium",
  headless:true,args:["--no-sandbox"]});
try {
  const page=await browser.newPage(),source=await readFile(new URL("../Speaker.js",import.meta.url),"utf8");
  const results=await page.evaluate(async source=>{
    const {Speaker}=await import(URL.createObjectURL(new Blob([source],{type:"text/javascript"}))),results=[];
    for(const [ns,now] of [[370370367,0],[8758122593,.008]])for(const last of [437,0]) {
      const audio=new OfflineAudioContext(1,9600,48000),calls=[];
      //Use the real audio renderer with a fixed clock, independent of device/startup timing.
      window.AudioContext=class {
        get currentTime(){return audio.currentTime+now;}
        get state(){return "running";}
        get destination(){return audio.destination;}
        createOscillator(){return audio.createOscillator();}
        createGain(){
          const node=audio.createGain(),set=node.gain.setValueAtTime.bind(node.gain);
          node.gain.setValueAtTime=(value,time)=>{calls.push({value,time});return set(value,time);};
          return node;
        }
      };
      const speaker=Speaker();await speaker.Resume();
      speaker.Tone(last?0:437,ns);speaker.Tone(last,ns);
      const samples=(await audio.startRendering()).getChannelData(0).subarray(4800),
        rms=Math.sqrt(samples.reduce((sum,x)=>sum+x*x,0)/samples.length);
      results.push({ns,now,last,rms,times:calls.slice(-2).map(c=>c.time)});
    }
    return results;
  },source);
  for(const r of results) {
    assert.equal(r.times[0],r.times[1],"Equal guest times must remain equal after a clock remap: "+JSON.stringify(r));
    if(r.last)assert.ok(r.rms>.01,"The last tone must remain audible: "+JSON.stringify(r));
    else assert.equal(r.rms,0,"The last silence must remain silent: "+JSON.stringify(r));
  }
  console.log("Real audio rendering preserves same-timestamp native tone/silence order across floating-point clock remaps.");
} finally {await browser.close();}
