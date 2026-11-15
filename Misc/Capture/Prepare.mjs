import {readFileSync,openSync,writeSync,closeSync} from "node:fs";
import {createHash} from "node:crypto";
import {makeDisk,fat32Read,fat32Upload} from "../../Kernel/QCow2.js";

const image=process.argv[2],inputs={},outputs={};
if (!image) throw Error("Usage: node Misc/Capture/Prepare.mjs PRIVATE.raw");

function Hash(bytes)
{
  return createHash("sha256").update(bytes).digest("hex");
}

function Read(name)
{
  let bytes=readFileSync(new URL(name,import.meta.url));
  inputs[name]=Hash(bytes);
  return bytes;
}

function Replace(source,needle,replacement)
{
  if (source.split(needle).length!=2)
    throw Error("Native source marker must occur once: "+needle);
  return source.replace(needle,replacement);
}

function Doc(source)
{
  source=Replace(source,"I64 i,ii,j,k,x,x0,y,y0,",
    "I64 doc_clip_y,i,ii,j,k,x,x0,y,y0,");
  source=Replace(source,"  unlock=DocLock(doc);",
    "  unlock=DocLock(doc);\n  doc_clip_y=DocClipGet(doc);");
  source=Replace(source,"\tfull_refresh=FALSE;\n      if (win_task)",
    "\tfull_refresh=FALSE;\n      if (doc_clip_y<0) full_refresh=TRUE;\n      if (win_task)");
  source=Replace(source,"    doc->min_x=I32_MAX; doc->min_y=I32_MAX;",
    "    doc_clip_y=0;\n    doc->min_x=I32_MAX; doc->min_y=I32_MAX;");
  source=Replace(source,"\tif (tmpb && dc) {",
    "\tif (tmpb && dc) {\n\t  if (full_refresh)\n\t    doc_clip_y=DocClipExtent(tmpb->data,doc_clip_y);");
  source=Replace(source,"!full_refresh && doc_e->y>y_plot_bottom)",
    "!full_refresh && doc_e->y>y_plot_bottom+(doc_clip_y+FONT_HEIGHT-1)/FONT_HEIGHT)");
  source=Replace(source,"  DCDel(dc);\n  Free(depth_buf);",
    "  if (full_refresh && recalc_flags&RECALCG_MASK==RECALCt_TO_SCRN)\n"+
    "    DocClipPut(doc,doc_clip_y);\n  DCDel(dc);\n  Free(depth_buf);");
  return Read("DocClip.HC").toString("latin1")+"\n"+source;
}

function AC(source)
{
  source=Replace(source,"  CDoc *doc=DocPut;","  CDoc *doc=ACDblBufBack;");
  source=Replace(source,"  LBtr(&Fs->display_flags,DISPLAYf_SHOW);\n"+
    "  WinHorz(left,Fs->win_right);\n  WinVert(top,Fs->win_bottom);",
    "  ac_dbl_buf_left=left;\n  ac_dbl_buf_top=top;");
  let needle="if (!LBts(&Fs->display_flags,DISPLAYf_SHOW))";
  if (source.split(needle).length!=4)
    throw Error("Expected three native AutoComplete display conditions");
  source=source.replaceAll(needle,"if (!ACDblBufShow)");
  return Read("ACDblBuf.HC").toString("latin1")+"\n"+source;
}

function Archive(bytes)
{//TempleOS CT_NONE: packed CArcCompress header, then unchanged bytes.
  let out=Buffer.alloc(17+bytes.length);
  out.writeBigInt64LE(BigInt(out.length),0);
  out.writeBigInt64LE(BigInt(bytes.length),8);
  out[16]=1;
  bytes.copy(out,17);
  return out;
}

let disk=await makeDisk(readFileSync(image)),records=JSON.parse(Read("Original/Sources.json"));
for (let record of records) {
  let encoded=fat32Read(disk,record.dir,record.name),
    original=Read("Original/"+record.name.slice(0,-2)),source=original.toString("latin1");
  if (!encoded || Hash(encoded)!=record.encodedSha256 || Hash(original)!=record.sourceSha256)
    throw Error("Native source identity changed: "+record.dir+"/"+record.name);
  if (record.name=="DocRecalc.HC.Z") source=Doc(source);
  else if (record.name=="ACTask.HC.Z") source=AC(source);
  else source+="\n"+Read("Welcome.HC").toString("latin1");
  let bytes=Archive(Buffer.from(source,"latin1"));
  fat32Upload(disk,record.name,bytes,record.dir);
  outputs[record.dir+"/"+record.name]=Hash(bytes);
}
let logo=Read("Welcome.DAT");
fat32Upload(disk,"Welcome.DAT",logo,"Home");
outputs["Home/Welcome.DAT"]=Hash(logo);
inputs["Prepare.mjs"]=Hash(readFileSync(new URL(import.meta.url)));
let fd=openSync(image,"r+");
try {
  for (let [lba,bytes] of disk.overlay)
    writeSync(fd,bytes,0,bytes.length,lba*512);
} finally {closeSync(fd);}
console.log(JSON.stringify({inputs,outputs,originals:records}));
