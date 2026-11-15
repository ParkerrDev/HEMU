let clients=new Set(),owner=null,starter=null,host=null,boot=null,started=false,
  cache=new Map(),control=Promise.resolve(),saving=null,exports=[],calls=new Map(),
  next=1,saveTimer=null,dirty=false,
  machine={kind:null,busFailed:false,capture:{ready:false},
    Warm(cores) {return HostCall("Warm",[cores]);},
    Start(boot,resumeDisk) {return HostCall("Start",[boot,resumeDisk]);},
    Restart(boot) {return HostCall("Restart",[boot]);},
    Stop() {return HostCall("Stop",[]);},
    post(m) {if (host) Send(host,{cmd:"hostPost",message:m});},
    Request(m) {return HostCall("Request",[m]);}};
async function HostCall(method,args)
{
  let client=host;
  if (!client) throw Error("The TempleOS host tab closed. Restoring the last saved session.");
  await client.ready;
  if (client!==host) throw Error("The TempleOS host changed. Retry when it is ready.");
  return new Promise(function (Resolve,Reject) {
    let id=next++;
    calls.set(id,{Resolve,Reject});Send(client,{cmd:"hostCall",method,args,id});
  });
}
function HostSet(client)
{
  host=client;
  if (client) {
    client.ready=new Promise(function (Resolve,Reject) {
      client.Ready=Resolve;client.Fail=Reject;
    });
    client.ready.catch(function () {});
    client.deadline=setTimeout(function () {if (host===client) Detach(client);},15000);
    Send(client,{cmd:"host",lock:"templeos-host-"+client.id});
  }
}
function SaveSoon()
{
  dirty=true;clearTimeout(saveTimer);
  saveTimer=setTimeout(Background,3000);
}
function Send(client,m)
{
  try {client.port.postMessage(m);}
  catch {Detach(client);}
}
function Broadcast(m)
{
  for (let client of clients) Send(client,m);
}
function State(client)
{
  Send(client,{cmd:"machine",kind:machine.kind,busFailed:machine.busFailed});
}
function ExportsFail(msg)
{
  for (let request of exports) Send(request.client,{cmd:"exportResult",ok:false,
    kind:request.message.cmd=="exportSnapshot"?"snapshot":"disk",msg});
  exports=[];
}
function Receive(m)
{
  if (["fileResult","dirList"].includes(m.cmd)) return;
  if (m.cmd=="starting") {
    cache.clear();started=false;machine.capture={ready:false};
  }
  if (m.cmd=="exportResult") {
    let request=exports[0];
    if (!request || request.message.id!==m.id) return;
    exports.shift();Send(request.client,m);
    if (exports.length) machine.post(exports[0].message);
    return;
  }
  if (m.cmd=="windows" || m.cmd=="snd") {
    if (owner) Send(owner,m);
    return;
  }
  if (["frame","captureState","guestReady","diskInfo","diskSave","sessionSave",
    "settings","paused","restored","inputMode","smpReady"].includes(m.cmd))
    cache.set(m.cmd,m);
  if (m.cmd=="palette") cache.set("palette"+m.index,m);
  if (m.cmd=="frame") started=true;
  if (m.cmd=="captureState") machine.capture=m;
  if (m.cmd=="diskSave" && m.state=="saving") SaveSoon();
  Broadcast(m);
  if (m.cmd=="captureState" && m.ready) SaveSoon();
  if (m.cmd=="inputMode" && !m.game && !m.capture && dirty) SaveSoon();
}
function Failed(error)
{
  if (!error.msg) error={msg:error.message || String(error),retained:false,cores:1};
  Broadcast({cmd:"machineError",error});
  machine.capture={ready:false,msg:error.msg};
  Receive({cmd:"captureState",...machine.capture});
  for (let client of clients) State(client);
}
function Claim(client)
{
  control=control.then(async function () {
    if (!clients.has(client) || owner===client) return;
    if (owner && machine.kind) {
      machine.post({cmd:"input",keys:[],keysUp:true,reset:true,b:0});
      let result=await machine.Request({cmd:"windows",op:"disable"});
      if (!result.ok) throw Error(result.msg);
      Send(owner,{cmd:"owner",value:false});
    }
    owner=client;Send(client,{cmd:"owner",value:true});
  }).catch(function (e) {
    Send(client,{cmd:"sessionSave",state:"error",msg:e.message});
  });
  return control;
}
function Background()
{
  if (!machine.capture.ready || saving || !dirty || !host) return;
  let hidden=![...clients].some(c=>c.visible),input=cache.get("inputMode");
  if (!hidden && !cache.get("paused")?.value && (input?.game || input?.capture)) return;
  dirty=false;
  saving=machine.Request({cmd:"saveSession",suspend:hidden}).then(function (result) {
    if (!result.ok) dirty=true;

  }).catch(function () {dirty=true;}).finally(function () {
    saving=null;
    if ([...clients].some(c=>c.visible)) machine.post({cmd:"suspend",value:false});
  });
}
function Detach(client)
{
  if (!clients.delete(client)) return;
  if (starter===client) {
    starter=null;
    if (!boot && clients.size && host!==client) {
      starter=[...clients][0];Send(starter,{cmd:"bootNeeded"});
    }
  }
  if (host===client) {
    clearTimeout(client.deadline);client.Fail?.(Error("Host tab closed before it was ready."));
    ExportsFail("Host tab closed during export. Retry after TempleOS restores.");
    host=null;boot=null;started=false;cache.clear();
    machine.kind=null;machine.capture={ready:false};
    for (let request of calls.values()) request.Reject(Error("Host tab closed; restoring the last saved session."));
    calls.clear();
    Broadcast({cmd:"restarting"});
    starter=[...clients][0] || null;
    if (starter) {HostSet(starter);Send(starter,{cmd:"bootNeeded"});}
  }
  if (owner===client) {
    control=control.then(async function () {
      if (owner!==client) return;
      machine.post({cmd:"input",keys:[],keysUp:true,reset:true,b:0});
      if (machine.kind) await machine.Request({cmd:"windows",op:"disable"});
      owner=null;
    });
    let next=[...clients].find(c=>c.visible);
    if (next) Claim(next);
  }
  control.then(Background);
}
async function Handle(client,m)
{
  let value=m.value;
  if (m.op=="connect") {
    client.visible=true;
    State(client);
    for (let state of cache.values()) Send(client,state);
    if (!host) HostSet(client);
    if (!starter && !boot) starter=client;
    if (!owner) await Claim(client);
    machine.post({cmd:"suspend",value:false});
    return {boot:!boot && starter===client,started,cores:boot?.cores || 1};
  }
  if (m.op=="hostReady" && client===host) {
    clearTimeout(client.deadline);client.Ready();
    navigator.locks.request("templeos-host-"+client.id,function () {
      if (host===client) Detach(client);
    });
  } else if (m.op=="hostReply" && client===host) {
    let request=calls.get(value.id);
    if (!request) return;
    calls.delete(value.id);
    machine.kind=value.kind;machine.busFailed=value.busFailed;
    for (let page of clients) State(page);
    if (value.error) request.Reject(Error(value.error));
    else request.Resolve(value.result);
  } else if (m.op=="hostMessage" && client===host) Receive(value);
  else if (m.op=="hostError" && client===host) Failed(value);
  else if (m.op=="warm") {
    if (starter===client && !boot) machine.Warm(value).catch(Failed);
  } else if (m.op=="start" || m.op=="restart") {
    if (m.op=="start" && starter && starter!==client) throw Error("Another tab is starting TempleOS.");
    clearTimeout(saveTimer);dirty=false;machine.capture={ready:false};
    await control;
    for (let page of clients) if (page!==client) Send(page,{cmd:"restarting"});
    cache.clear();started=false;
    ExportsFail("TempleOS restarted during export. Retry when it is ready.");
    let next={...(m.op=="start"?value.boot:value),sharedSession:true},previous=boot;
    boot={cores:next.cores};
    let result=m.op=="start"?await machine.Start(next,value.resumeDisk):await machine.Restart(next);
    if (!result) boot=previous;
    for (let page of clients) State(page);
    return result;
  } else if (m.op=="claim") return Claim(client);
  else if (m.op=="visible") {
    client.visible=!!value;
    if (value) machine.post({cmd:"suspend",value:false});
    else {dirty=true;control.then(Background);}
  } else if (m.op=="detach") Detach(client);
  else if (m.op=="stop") {
    if (client===starter && !started) {machine.Stop();boot=null;}
  } else if (m.op=="request") {
    if (value.cmd=="windows") {
      await control;
      if (owner!==client) return {ok:value.op=="disable",msg:"This window belongs to the active TempleOS tab."};
    }
    const result=await machine.Request(value);
    if (result.ok && !["listDir","readFile","saveSession"].includes(value.cmd)) SaveSoon();
    if (dirty && ![...clients].some(c=>c.visible)) Background();
    return result;
  } else if (m.op=="post") {
    if (value.cmd=="input" || value.cmd=="keysUp") {
      await control;
      if (owner!==client) return;
      if (value.keys?.length || value.b || value.wheel || value.dx || value.dy) SaveSoon();
    }
    if (value.cmd=="exportSnapshot" || value.cmd=="exportDisk") {
      exports.push({client,message:{...value,id:"export-"+(next++)}});
      if (exports.length===1) machine.post(exports[0].message);
    } else {
      machine.post(value);
      if (["set","pause"].includes(value.cmd)) SaveSoon();
    }
  }
}
onconnect=function (e) {
  let client={id:crypto.randomUUID(),port:e.ports[0],visible:false};
  clients.add(client);
  client.port.onmessage=async function ({data:m}) {
    try {
      let result=await Handle(client,m);
      if (m.id) Send(client,{reply:m.id,result});
    } catch (e) {
      if (m.id) Send(client,{reply:m.id,error:e.message});
      else Send(client,{cmd:"sessionSave",state:"error",msg:e.message});
    }
  };
  client.port.onmessageerror=function () {Detach(client);};
};
