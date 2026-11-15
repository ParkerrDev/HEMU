import {Machine} from "./Machine.js";

export function MachineShared({message,error,earlyWorker=null})
{//Pages share one guest, disk and request queue through a browser-owned worker.
  if (!globalThis.SharedWorker)
    return Machine({message,error,earlyWorker});
  let worker=new SharedWorker(new URL("./MachineHub.js",import.meta.url),
      {type:"module",name:"templeos",extendedLifetime:true}),
    port=worker.port,local=null,pending=new Map(),next=1,kind=null,owner=false,
    capture={ready:false,msg:"Wait for TempleOS and C: to finish loading."},
    busFailed=false,closed=false,Release=null;
  function Failed(msg)
  {
    for (let request of pending.values()) request.Reject(Error(msg));
    pending.clear();error({msg,retained:false,started:!!kind,cores:1});
  }
  port.onmessage=function ({data:m}) {
    if (m.reply) {
      let request=pending.get(m.reply);
      if (!request) return;
      pending.delete(m.reply);
      if (m.error) request.Reject(Error(m.error));
      else request.Resolve(m.result);
    } else if (m.cmd=="host") {
      local=Machine({earlyWorker,message:function (value) {
        port.postMessage({op:"hostMessage",value},value.buf instanceof ArrayBuffer?[value.buf]:[]);
      },error:function (value) {port.postMessage({op:"hostError",value});}});
      earlyWorker=null;
      navigator.locks.request(m.lock,function () {
        if (closed) return;
        port.postMessage({op:"hostReady"});
        return new Promise(function (Resolve) {Release=Resolve;});
      }).catch(function (e) {Failed(e.message);});
    } else if (m.cmd=="hostPost") local?.post(m.message);
    else if (m.cmd=="hostCall") {
      (async function () {
        let result,failure;
        try {result=await local[m.method](...m.args);}
        catch (e) {failure=e.message;}
        port.postMessage({op:"hostReply",value:{id:m.id,result,error:failure,
          kind:local?.kind,busFailed:local?.busFailed}});
      })();
    } else if (m.cmd=="machine") {
      kind=m.kind;busFailed=m.busFailed;
    } else if (m.cmd=="owner") {
      owner=m.value;message(m);
    } else if (m.cmd=="machineError") error(m.error);
    else {
      if (m.cmd=="captureState") capture=m;
      message(m);
    }
  };
  port.onmessageerror=function () {Failed("The shared TempleOS connection failed.");};
  worker.onerror=function (e) {Failed(e.message || "The shared TempleOS worker failed.");};
  function Call(op,value,transfer=[])
  {
    return new Promise(function (Resolve,Reject) {
      if (closed) {Reject(Error("This TempleOS view is closed."));return;}
      let id=next++;
      pending.set(id,{Resolve,Reject});
      try {port.postMessage({op,id,value},transfer);}
      catch (e) {pending.delete(id);Reject(e);}
    });
  }
  function Post(value,transfer=[])
  {
    if (!closed) port.postMessage({op:"post",value},transfer);
  }
  return {
    Connect() {return Call("connect");},
    Warm(cores) {port.postMessage({op:"warm",value:cores});},
    Start(boot,resumeDisk=false) {return Call("start",{boot,resumeDisk});},
    Restart(boot) {return Call("restart",boot);},
    Stop() {port.postMessage({op:"stop"});},
    Claim() {port.postMessage({op:"claim"});},
    Visible(value) {port.postMessage({op:"visible",value});},
    Detach() {
      if (closed) return;
      port.postMessage({op:"detach"});closed=true;port.close();
      local?.Stop();Release?.();
      for (let request of pending.values()) request.Reject(Error("TempleOS view closed."));
      pending.clear();
    },
    post:Post,
    Request(value,transfer=[]) {return Call("request",value,transfer);},
    get capture() {return capture;},
    get kind() {return kind;},
    get busFailed() {return busFailed;},
    get owner() {return owner;}
  };
}
