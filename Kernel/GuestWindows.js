const TASK_FIELDS=["task_num","display_flags","win_left","win_right",
  "win_top","win_bottom","win_inhibit","task_title"];
const WIN_FIELDS=["task","task_num","detached","owned","show","seq",
  "dc","text"];

function Quoted(st)
{
  return '"'+String(st).replace(/[^\x09\x0A\x0D\x20-\xFF]/gu,"?").
    replace(/\\/g,"\\\\").replace(/"/g,'\\"').
    replace(/\r/g,"").replace(/\n/g,"\\n").replace(/\$/g,"$$$$")+'"';
}

export function GuestWindows({gx,exec,post,paused,access=fn=>fn(),source})
{//Window buffers belong to native tasks; JS only transports their pixels.
  let enabled=false,base=0,stride=0,vars={},ct={},cw={},dc={},hosts=new Map(),
    seqs=new Map(),queue=Promise.resolve(),last=0,revision=0;
  function Fields(cls,names)
  {
    let res={},name,offset;
    for (name of names) {
      offset=gx.memberFind(cls,name);
      if (offset<0)
	throw Error("This TempleOS has no "+cls+"."+name+".");
      res[name]=offset;
    }
    return res;
  }
  function Bind()
  {
    base=gx.varFind("web_wins");
    vars={enabled:gx.varFind("web_win_enabled"),input:gx.varFind("web_win_input"),
      result:gx.varFind("web_win_result"),mgr:gx.varFind("sys_winmgr_task"),
      head:gx.varFind("web_action_head"),tail:gx.varFind("web_action_tail"),
      actions:gx.varFind("web_actions")};
    if (!base || !vars.enabled || !vars.input || !vars.result || !vars.mgr)
      throw Error("The native window bridge could not initialize.");
    ct=Fields("CTask",TASK_FIELDS);
    cw=Fields("CWebWin",WIN_FIELDS);
    dc=Fields("CDC",["body","width_internal"]);
    stride=cw.text+8;
  }
  function Read(slot,key)
  {
    return gx.rd64(base+slot*stride+cw[key]);
  }
  function Valid(task,num)
  {
    return gx.taskInfo(task).valid && gx.rd64(task+ct.task_num)===num;
  }
  function Record(slot,identity=null)
  {
    if (!Number.isInteger(slot) || slot<0 || slot>=32)
      throw Error("The window no longer exists.");
    const task=Read(slot,"task"),num=Read(slot,"task_num");
    if (!task || !Valid(task,num))
      throw Error("The window closed.");
    if (identity && (identity.task!==task || identity.num!==num))
      throw Error("The window closed or was replaced.");
    return {slot,task,num};
  }
  function Owner(w)
  {
    const owner=hosts.get(w.slot);
    if (!owner || owner.task!==w.task || owner.num!==w.num || !Read(w.slot,"owned"))
      throw Error("This is not a browser-owned window.");
    return owner;
  }
  async function Run(src)
  {
    const current=revision,res=await exec(src);
    if (current!==revision) {
      Disable();
      throw Error("Window passthrough was turned off.");
    }
    if (!res.ok)
      throw Error(res.msg || "TempleOS could not update the window.");
    return gx.rd64(vars.result);
  }
  async function Enable()
  {
    if (enabled)
      return;
    const current=revision;
    if (!gx.varFind("web_wins")) {
      const src=await source();
      if (current!==revision)
	throw Error("Window passthrough was turned off.");
      const res=await exec(src);
      if (!res.ok)
	throw Error(res.msg || "TempleOS could not compile its window bridge.");
    }
    Bind();
    if (current!==revision) {
      Disable();
      throw Error("Window passthrough was turned off.");
    }
    await Run("WebWinInit;");
    enabled=true;
    seqs.clear();hosts.clear();
  }
  function Disable()
  {
    revision++;
    if (base) access(function () {
      let slot,task,flags;
      gx.wr64(vars.input,-1);
      gx.wr64(vars.enabled,0);
      for (slot=0;slot<32;slot++) {
	task=Read(slot,"task");
	if (task && Valid(task,Read(slot,"task_num"))) {
	  flags=gx.rd32(task+ct.display_flags);
	  if (Read(slot,"owned"))
	    flags&=~1;
	  else if (Read(slot,"show"))
	    flags|=1;
	  gx.wr32(task+ct.display_flags,flags);
	}
      }
    });
    enabled=false;
    post({cmd:"windows",enabled:false,windows:[],actions:[]});
  }
  async function Handle(m)
  {
    if (m.op==="disable") {
      Disable();
      return {ok:true};
    }
    if (paused())
      throw Error("Resume TempleOS before moving windows.");
    if (m.op==="enable") {
      await Enable();
      Tick(true);
      return {ok:true};
    }
    if (!enabled)
      throw Error("Turn on window passthrough first.");
    let w,slot,task,num,title,doc,cols,rows,x,y;
    if (m.op==="host") {
      if (typeof m.host!=="string" || !m.host || m.host.length>128)
	throw Error("The browser window has no identity.");
      doc=String(m.doc||"");
      if (doc.length>65536)
	throw Error("The browser document is too large.");
      for (const [key,owner] of hosts)
	if (owner.host===m.host && Valid(owner.task,owner.num) &&
	    Read(key,"task")===owner.task && Read(key,"task_num")===owner.num)
	  return {ok:true,...Record(key)};
      title=String(m.title||m.host).replace(/[^\x20-\x7E]/g,"?").slice(0,31);
      cols=Math.max(12,Math.min(78,Math.round(Number(m.cols)||40)));
      rows=Math.max(4,Math.min(58,Math.round(Number(m.rows)||20)));
      x=Math.round(Number(m.x)||0);y=Math.round(Number(m.y)||0);
      slot=await Run("web_win_result=WebWinHostNew("+Quoted(title)+","+
	    cols+","+rows+","+x+","+y+");");
      if (slot>=32)
	throw Error("Too many passthrough windows are open.");
      //The child initializes its DolDoc before receiving a queued update.
      w=Record(slot);
      hosts.set(slot,{...w,host:m.host});
      try {await Run("WebWinDoc("+slot+","+Quoted(doc)+");");}
      catch (e) {
	if (enabled) await Run("WebWinClose("+w.slot+","+w.num+");");
	hosts.delete(slot);
	throw e;
      }
    } else if (m.op==="detach") {
      task=Number(m.task);num=Number(m.num);
      if (!Number.isSafeInteger(task) || !Number.isSafeInteger(num) ||
	  !Valid(task,num))
	throw Error("The window closed.");
      slot=await Run("web_win_result=WebWinDetach("+task+","+num+");");
      if (slot>=32)
	throw Error("This window needs the TempleOS desktop.");
      w=Record(slot);
    } else if (m.op==="focus" && m.slot===undefined) {
      task=Number(m.task);num=Number(m.num);
      if (!Number.isSafeInteger(task) || !Number.isSafeInteger(num) ||
	  !Valid(task,num))
	throw Error("The window closed.");
      await Run("WebWinTaskFocus("+task+","+num+");");
    } else {
      w=Record(Number(m.slot),m);slot=w.slot;
      if (m.op==="attach") {
	x=Math.round(Number(m.x)||0);y=Math.round(Number(m.y)||0);
	await Run("WebWinAttach("+slot+","+x+","+y+");");
      } else if (m.op==="focus")
	await Run("WebWinFocus("+slot+");");
      else if (m.op==="update") {
	Owner(w);
	doc=String(m.doc||"");
	if (doc.length>65536)
	  throw Error("The browser document is too large.");
	await Run("WebWinDoc("+slot+","+Quoted(doc)+");");
      } else if (m.op==="close") {
	Owner(w);
	await Run("WebWinClose("+slot+","+w.num+");");
	hosts.delete(slot);
      } else
	throw Error("Unknown window action.");
    }
    Tick(true);
    return {ok:true,...w};
  }
  function Request(m)
  {
    if (m.op==="disable") {
      Disable();
      return Promise.resolve({ok:true});
    }
    const current=revision,promise=queue.then(function () {
      if (current!==revision)
	throw Error("Window passthrough was turned off.");
      return Handle(m);
    });
    queue=promise.catch(()=>{});
    return promise;
  }
  function Input(slot=-1,task,num)
  {
    if (!enabled) return;
    let target=-1;
    if (Number.isInteger(slot) && slot>=0 && slot<32) {
      try {
	Record(slot,{task,num});
	if (Read(slot,"detached")) target=slot;
      } catch {}
    }
    gx.wr64(vars.input,target);
  }
  function Tick(force=false)
  {
    if (!enabled || !force && performance.now()-last<30)
      return;
    if (!gx.rd64(vars.enabled)) {
      enabled=false;
      post({cmd:"windows",enabled:false,windows:[],actions:[],
        msg:"This fullscreen program needs the TempleOS desktop. Windows have been returned."});
      return;
    }
    last=performance.now();
    return access(function () {
      let windows=[],events=[],transfer=[],slots=new Map(),slot,task,num,
          flags,win,buf,surface,body,width,row,seq,tail,head,act,tasks=gx.taskRing(),
	  mgr=gx.rd64(vars.mgr),start=tasks.indexOf(mgr);
      if (start>=0)
	tasks=tasks.slice(start).concat(tasks.slice(0,start));
      for (slot=0;slot<32;slot++) {
	task=Read(slot,"task");num=Read(slot,"task_num");
	if (hosts.has(slot) && (hosts.get(slot).task!==task || hosts.get(slot).num!==num ||
	    !Valid(task,num))) {
	  hosts.delete(slot);seqs.delete(slot);
	}
	if (task && Valid(task,num))
	  slots.set(task,slot);
      }
      for (task of tasks) {
	flags=gx.rd32(task+ct.display_flags);
	slot=slots.get(task)??-1;
	if (task===mgr || task===gx.rd64(gx.vars.adam_task) || flags&8 ||
	    gx.rd32(task+ct.win_inhibit)&1 || !(flags&1) && slot<0)
	  continue;
	win={slot,task,num:gx.rd64(task+ct.task_num),
	  title:gx.rdStr(task+ct.task_title,64),
	  x:(Number(BigInt.asIntN(64,gx.rd64b(task+ct.win_left)))-1)*8,
	  y:(Number(BigInt.asIntN(64,gx.rd64b(task+ct.win_top)))-1)*8,
	  w:Number(BigInt.asIntN(64,gx.rd64b(task+ct.win_right)-gx.rd64b(task+ct.win_left))+3n)*8,
	  h:Number(BigInt.asIntN(64,gx.rd64b(task+ct.win_bottom)-gx.rd64b(task+ct.win_top))+3n)*8,
	  detached:slot>=0 && !!Read(slot,"detached"),host:hosts.get(slot)?.host||null};
	if (win.w<=0 || win.h<=0 || win.w>640 || win.h>480)
	  continue;
	if (slot>=0) {
	  seq=Read(slot,"seq");
	  if (win.detached && (force || seqs.get(slot)!==seq) &&
	      win.x>=0 && win.y>=0 && win.x+win.w<=640 && win.y+win.h<=480) {
	    surface=Read(slot,"dc");
	    body=gx.rd64(surface+dc.body);width=gx.rd32(surface+dc.width_internal);
	    if (body && width===640) {
	      buf=new Uint8Array(win.w*win.h);
	      for (row=0;row<win.h;row++)
		buf.set(gx.rdBytes(body+(win.y+row)*width+win.x,win.w),row*win.w);
	      win.buf=buf.buffer;transfer.push(buf.buffer);
	      seqs.set(slot,seq);
	    }
	  }
	}
	windows.push(win);
      }
      head=gx.rd64(vars.head);tail=gx.rd64(vars.tail);
      while (tail<head && head-tail<=64) {
	act=vars.actions+tail%64*24;
	slot=gx.rd64(act);num=gx.rd64(act+8);
	if (hosts.get(slot)?.num===num)
	  events.push({slot,id:gx.rd64(act+16)});
	tail++;
      }
      gx.wr64(vars.tail,tail);
      post({cmd:"windows",enabled:true,windows,actions:events},transfer);
    });
  }
  return {Request,Tick,Input,Disable};
}
