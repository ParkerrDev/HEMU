//Validation of corrections stored in older full-machine saves.
export const DOC_CLIP_PATCH="doc-sprite-clip-v1",AC_DBL_BUF_PATCH="ac-dbl-buf-v1",
  GUEST_PATCHES=[DOC_CLIP_PATCH,AC_DBL_BUF_PATCH];
const AC_DBL_BUF_NUM=4;

function JumpCheck(gx,old,target)
{//PUSH RBP; MOV RBP,RSP stay, then a JMP past the new routine's copy of them.
  if(!old || !target)return false;
  const view=new DataView(gx.rdBytes(old,9).buffer);
  return view.getUint32(0,true)===0xEC8B4855 && view.getUint8(4)===0xE9 &&
    old+9+view.getInt32(5,true)===target+4;
}

function Ptr(gx,name,i=0)
{
  const addr=gx.varFind(name);
  return addr?gx.rd64(addr+i*8):0;
}

function Revision(gx,name)
{
  const addr=gx.varFind(name);
  return addr?gx.rd64(addr):0;
}

export function GuestPatchCheck(gx,patches)
{//A restored session's RAM must hold each correction its metadata lists.
  if(patches?.includes(DOC_CLIP_PATCH) && (Revision(gx,"doc_clip_revision")!==1 ||
      !JumpCheck(gx,Ptr(gx,"doc_clip_old"),Ptr(gx,"doc_clip_new"))))
    throw new Error("Saved document patch metadata does not match guest code");
  if(patches?.includes(AC_DBL_BUF_PATCH)) {
    let ok=Revision(gx,"ac_dbl_buf_revision")===1;
    for(let i=0;ok && i<AC_DBL_BUF_NUM;i++)
      ok=JumpCheck(gx,Ptr(gx,"ac_dbl_buf_old",i),Ptr(gx,"ac_dbl_buf_new",i));
    if(!ok)throw new Error("Saved AutoComplete patch metadata does not match guest code");
  }
}
