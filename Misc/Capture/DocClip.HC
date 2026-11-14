#define DOC_CLIP_NUM 256
class CDocClip
{
  CDoc *doc;
  I64 up,updates,age;
};
CDocClip doc_clip_cache[DOC_CLIP_NUM];
I64 doc_clip_lock=0,doc_clip_age=0;

I64 DocClipGet(CDoc *doc)
{//A bounded cache. An unknown or recycled document gets a full pass.
  I64 i,key=(doc(U64)>>6^doc(U64)>>16)&(DOC_CLIP_NUM-1),res=-1;
  CDocClip *tmpc;
  while (LBts(&doc_clip_lock,0)) Yield;
  for (i=0;i<DOC_CLIP_NUM;i++) {
    tmpc=&doc_clip_cache[(key+i)&(DOC_CLIP_NUM-1)];
    if (!tmpc->doc) break;
    if (tmpc->doc==doc) {
      if (tmpc->updates<=doc->updates_cnt) res=tmpc->up;
      tmpc->age=++doc_clip_age;
      break;
    }
  }
  LBtr(&doc_clip_lock,0);
  return res;
}

U0 DocClipPut(CDoc *doc,I64 up)
{
  I64 i,key=(doc(U64)>>6^doc(U64)>>16)&(DOC_CLIP_NUM-1);
  CDocClip *tmpc,*old=&doc_clip_cache[key];
  while (LBts(&doc_clip_lock,0)) Yield;
  for (i=0;i<DOC_CLIP_NUM;i++) {
    tmpc=&doc_clip_cache[(key+i)&(DOC_CLIP_NUM-1)];
    if (!tmpc->doc || tmpc->doc==doc) {
      old=tmpc;
      break;
    }
    if (tmpc->age<old->age) old=tmpc;
  }
  old->doc=doc;old->up=up;old->updates=doc->updates_cnt;
  old->age=++doc_clip_age;
  LBtr(&doc_clip_lock,0);
}

I64 DocClipExtent(U8 *sprite,I64 up)
{//Static 2D sprites may extend above their document anchor.
  I64 min_y;
  if (!(SpriteTypeMask(sprite)&(1<<SPT_MESH|1<<SPT_SHIFTABLE_MESH))) {
    SpriteExtents(sprite,,,&min_y);
    if (min_y<0) up=MaxI64(up,-min_y);
  }
  return up;
}

MemSet(doc_clip_cache,0,sizeof(doc_clip_cache));
