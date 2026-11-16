#define WEB_WINS_NUM 32

public class CWebWin
{
  CTask *task;
  I64 task_num,detached,owned,show,seq;
  CDC *dc;
  U32 *text;
  U8 *gui;
  CDC *image;
  CDoc *gui_doc;
  CTask *gui_view;
  U8 *gui_value;
  I64 gui_epoch,gui_kind,gui_limit,gui_submit,gui_anchor;
  I64 gui_focus,gui_press,gui_hover,gui_edit,gui_capture,gui_ms_show,
	gui_ms_x,gui_ms_y,gui_center_x,gui_center_y;
};

public CWebWin web_wins[WEB_WINS_NUM];
public I64 web_win_enabled=0,web_win_input=-1,web_win_result=-1;
public I64 web_win_no_close=0;
public I64 web_action_head=0,web_action_tail=0,web_actions[512];
U8 *web_action_text[64];
CWebWin *web_gui_capture=NULL;
I64 web_win_frame=-1;
U16 *web_win_z=NULL;
U0 (*web_win_draw)(CTask *task,CDC *dc)=NULL;
U0 (*web_win_final)(CDC *dc)=NULL;

Bool WebWinValid(CWebWin *w)
{
  return TaskValidate(w->task) && w->task->task_num==w->task_num;
}

public U0 WebWinCloseEnable(I64 slot,Bool val)
{//Keep essential windows open without blocking native move or resize.
  CDoc *doc=DocBorder(web_wins[slot].task);
  CDocEntry *doc_e;
  Bool unlock=DocLock(doc);
  for (doc_e=doc->head.next;doc_e!=doc;doc_e=doc_e->next)
    if (doc_e->de_flags&DOCEF_TAG && doc_e->tag &&
	!StrCmp(doc_e->tag,"[X]"))
      LBEqu(&doc_e->de_flags,DOCEf_SKIP,!val);
  LBEqu(&web_win_no_close,slot,!val);
  if (unlock)
    DocUnlock(doc);
}

U0 WebGuiRelease(CWebWin *w)
{
  if (web_gui_capture==w) {
    ms.show=w->gui_ms_show;
    MsSet(w->gui_ms_x,w->gui_ms_y);
    web_gui_capture=NULL;
  }
  w->gui_capture=0;
}

public Bool WebWinClose(I64 slot,I64 task_num)
{
  Bool res=FALSE;
  I64 flags=GetRFlags;
  CWebWin *w;
  CLI
  if (0<=slot<WEB_WINS_NUM) {
    w=&web_wins[slot];
    if (w->owned && w->task_num==task_num && WebWinValid(w)) {
      WebGuiRelease(w);
      res=Kill(w->task,FALSE);
    }
  }
  SetRFlags(flags);
  return res;
}

public Bool WebWinTaskFocus(CTask *task,I64 task_num)
{
  Bool res=FALSE;
  I64 flags=GetRFlags;
  CLI
  if (TaskValidate(task) && task->task_num==task_num) {
    WinFocus(task);
    res=TRUE;
  }
  SetRFlags(flags);
  return res;
}

U0 WebWinFree(CWebWin *w)
{
  WebGuiRelease(w);
  DocDel(w->gui_doc);
  Free(w->gui_view);
  Free(w->gui_value);
  DCDel(w->dc);
  Free(w->text);
  Free(w->gui);
  DCDel(w->image);
  MemSet(w,0,sizeof(CWebWin));
}

U0 WebWinStop()
{//Put guest tasks back before releasing their private drawing buffers.
  I64 i;
  CWebWin *w;
  for (i=0,w=web_wins;i<WEB_WINS_NUM;i++,w++) {
    if (WebWinValid(w)) {
      if (w->owned)
	WebWinClose(i,w->task_num);
      else
	LBEqu(&w->task->display_flags,DISPLAYf_SHOW,w->show);
    }
    WebWinFree(w);
  }
  sys_winmgr_task->draw_it=web_win_draw;
  gr.fp_final_scrn_update=web_win_final;
  Free(web_win_z);
  for (i=0;i<64;i++) {
    Free(web_action_text[i]);
    web_action_text[i]=NULL;
  }
  web_win_z=NULL;
  web_win_enabled=0;
  web_win_input=-1;
  WinZBufUpdate;
}

U0 WebWinHide()
{
  I64 i;
  Bool changed=FALSE;
  CWebWin *w;
  web_win_frame=winmgr.updates;
  for (i=0,w=web_wins;i<WEB_WINS_NUM;i++,w++)
    if (w->detached && WebWinValid(w))
      changed|=LBtr(&w->task->display_flags,DISPLAYf_SHOW);
  if (changed)
    WinZBufUpdate;
}

U0 WebWinBefore(CTask *task,CDC *dc)
{
  if (!web_win_enabled) {
    WebWinStop;
    if (web_win_draw)
      (*web_win_draw)(task,dc);
    return;
  }
  if (web_win_draw)
    (*web_win_draw)(task,dc);
  WebWinHide;
}

Bool WebWinTaskOK(CTask *task)
{
  CCtrl *c;
  if (task==sys_winmgr_task || task==adam_task || task->gs->num ||
      task->draw_it || Bt(&task->display_flags,DISPLAYf_NO_BORDER) ||
      Bt(&task->win_inhibit,WIf_SELF_FOCUS) ||
      task->win_left<1 || task->win_right>=TEXT_COLS-1 ||
      task->win_top<1 || task->win_bottom>=TEXT_ROWS-1)
    return FALSE;
  c=task->next_ctrl;
  while (c!=&task->next_ctrl) {
    if (c->win_task!=task || c->draw_it!=&DrawWinScroll ||
	c->update_derived_vals!=&WinDerivedScrollValsUpdate ||
	!(c->type==CTRLT_WIN_HSCROLL && c->state==&task->horz_scroll ||
	c->type==CTRLT_WIN_VSCROLL && c->state==&task->vert_scroll))
      return FALSE;
    c=c->next;
  }
  return TRUE;
}

Bool WebWinHeapOK(CTask *task)
{
  CHeapCtrl *hc=task->data_heap;
  return !Bt(&hc->locked_flags,HClf_LOCKED) &&
	!Bt(&hc->bp->locked_flags,BPlf_LOCKED);
}

Bool WebWinDocOK(CDoc *doc)
{
  CDocEntry *de;
  if (!doc)
    return TRUE;
  de=doc->head.next;
  while (de!=doc) {
    if (de->type_u8==DOCT_SONG ||
	de->de_flags&DOCEF_TAG_CB && de->tag_cb &&
	de->tag_cb!=&EdFilterCB && de->tag_cb!=&EdOverStrikeCB &&
	de->tag_cb!=&EdDollarCB && de->tag_cb!=&EdMoreCB &&
	de->tag_cb!=&EdDollarTypeCB && de->tag_cb!=&EdAutoSaveCB)
      return FALSE;
    de=de->next;
  }
  return TRUE;
}

Bool WebWinClear(CTask *task)
{//Persistent desktop graphics cannot follow a document's private surface.
  I64 x,y;
  U64 *row;
  for (y=(task->win_top-1)*FONT_HEIGHT;
	y<(task->win_bottom+2)*FONT_HEIGHT;y++) {
    row=gr.dc->body+y*gr.dc->width_internal;
    for (x=task->win_left-1;x<task->win_right+2;x++)
      if (row[x]!=-1)
	return FALSE;
  }
  return TRUE;
}

class CWebDraw
{
  Bool held,saved,ld,lb,failed;
  CTask *task,*old_task;
  CDC *dc;
  U32 *text;
  U16 *z;
  CDoc *doc,*border;
  CD3I64 scroll;
};

U0 WebWinRenderEnd(CWebWin *w,CWebDraw *d)
{//Release the CPUs before HolyC frees its try frame or unlocks a pending break.
  if (d->saved) {
    gr.dc2=d->dc;
    gr.text_base=d->text;
    gr.win_z_buf=d->z;
    sys_task_being_scrn_updated=d->old_task;
    WinScrollRestore(d->task,&d->scroll);
    if (d->failed) {
      w->detached=0;
      LBts(&d->task->display_flags,DISPLAYf_SHOW);
      if (web_win_input==w-web_wins)
	web_win_input=-1;
      WinZBufUpdate;
    }
    d->saved=FALSE;
  }
  if (d->held) {
    OutU8(0x5047,0);
    d->held=FALSE;
  }
  if (d->lb) {
    d->lb=FALSE;
    DocUnlock(d->border);
  }
  if (d->ld) {
    d->ld=FALSE;
    DocUnlock(d->doc);
  }
}

Bool WebWinRender(CWebWin *w)
{//Freeze other CPUs before redirecting native document drawing buffers.
  I64 flags=GetRFlags;
  Bool res=FALSE;
  CTask *task;
  CDoc *doc,*border;
  CWebDraw d;
  MemSet(&d,0,sizeof(CWebDraw));
  CLI
  try {
    if (!(d.held=InU8(0x5047)) || !WebWinValid(w))
      goto wr_done;
    d.task=task=w->task;
    d.doc=doc=DocDisplay(task);
    d.border=border=DocBorder(task);
    d.old_task=sys_task_being_scrn_updated;
    d.dc=gr.dc2;
    d.text=gr.text_base;
    d.z=gr.win_z_buf;
    MemCpy(&d.scroll,&task->scroll_x,sizeof(CD3I64));
    d.saved=TRUE;
    if (Bt(&task->task_flags,TASKf_TASK_LOCK) ||
	Bt(&sys_semas[SEMA_HEAPLOG_ACTIVE],0) ||
	!WebWinHeapOK(Fs) || !WebWinHeapOK(task) ||
	doc && (Bt(&doc->locked_flags,DOClf_LOCKED) ||
	!WebWinHeapOK(doc->mem_task)) ||
	border && (Bt(&border->locked_flags,DOClf_LOCKED) ||
	!WebWinHeapOK(border->mem_task)))
      goto wr_done;
    if (!WebWinTaskOK(task) || !WebWinDocOK(doc) ||
	!WebWinDocOK(border) || !WebWinClear(task)) {
      d.failed=TRUE;
      goto wr_done;
    }
    if (doc)
      d.ld=DocLock(doc);
    if (border)
      d.lb=DocLock(border);
    gr.dc2=w->dc;
    gr.text_base=w->text;
    gr.win_z_buf=web_win_z;
    sys_task_being_scrn_updated=task;
    GrUpdateTextBG;
    GrUpdateTextFG;
    TextBorder(Fs,task->win_left,task->win_right,task->win_top,
	  task->win_bottom,task->border_attr,task==sys_focus_task);
    TextRect(task->win_left,task->win_right,
	  task->win_top,task->win_bottom,task->text_attr<<8);
    if (!(task->win_inhibit&WIF_SELF_DOC))
      DocUpdateTaskDocs(task);
    WinScrollNull(task,&d.scroll);
    DrawCtrls(task);
    res=TRUE;
wr_done:
    WebWinRenderEnd(w,&d);
  } catch {
    Fs->catch_except=TRUE;
    d.failed=TRUE;
    res=FALSE;
    WebWinRenderEnd(w,&d);
  }
  SetRFlags(flags);
  return res;
}

U0 WebWinAfter(CDC *dc)
{
  I64 i;
  CTask *focus=sys_focus_task;
  Bool old_show=ms.show;
  CWebWin *w;
  if (0<=web_win_input<WEB_WINS_NUM)
    ms.show=FALSE;
  if (web_win_final)
    (*web_win_final)(dc);
  ms.show=old_show;
  //A maximized native editor covers both the desktop and its GUI owner.
  if (web_win_enabled && web_win_frame!=winmgr.updates &&
      TaskValidate(focus) && focus->win_left==1 &&
      focus->win_right==TEXT_COLS-2 && 1<=focus->win_top<=2 &&
      focus->win_bottom==TEXT_ROWS-2 && WebWinTaskOK(focus) &&
      WebWinDocOK(DocDisplay(focus)) && WebWinDocOK(DocBorder(focus)))
    WebWinHide;
  if (!web_win_enabled || web_win_frame!=winmgr.updates ||
      sys_winmgr_task->draw_it!=&WebWinBefore) {
    WebWinStop;
    return;
  }
  for (i=0,w=web_wins;i<WEB_WINS_NUM;i++,w++) {
    if (w->task && !WebWinValid(w))
      WebWinFree(w);
    if (w->detached && WebWinValid(w) && WebWinRender(w))
      w->seq++;
  }
  if (0<=web_win_input<WEB_WINS_NUM) {
    w=&web_wins[web_win_input];
    if (w->detached && WebWinValid(w))
      LBts(&w->task->display_flags,DISPLAYf_SHOW);
  }
}

public U0 WebWinInit()
{
  if (web_win_z) {
    if (web_win_enabled)
      return;
    WebWinStop;
  }
  MemSet(web_wins,0,sizeof(web_wins));
  MemSet(web_action_text,0,sizeof(web_action_text));
  web_win_z=CAlloc(TEXT_COLS*TEXT_ROWS*sizeof(U16));
  web_win_draw=sys_winmgr_task->draw_it;
  web_win_final=gr.fp_final_scrn_update;
  sys_winmgr_task->draw_it=&WebWinBefore;
  gr.fp_final_scrn_update=&WebWinAfter;
  web_win_input=-1;
  web_win_frame=-1;
  web_action_head=web_action_tail=0;
  web_win_enabled=1;
}

public I64 WebWinFind(CTask *task)
{
  I64 i;
  for (i=0;i<WEB_WINS_NUM;i++)
    if (web_wins[i].task==task && WebWinValid(&web_wins[i]))
      return i;
  return -1;
}

public I64 WebWinDetach(CTask *task,I64 task_num)
{
  I64 i=WebWinFind(task);
  CWebWin *w;
  CDoc *doc;
  if (!TaskValidate(task) || task->task_num!=task_num ||
      task==sys_winmgr_task || task==adam_task ||
      task->gs->num || task->draw_it ||
      Bt(&task->display_flags,DISPLAYf_NO_BORDER) ||
      Bt(&task->win_inhibit,WIf_SELF_FOCUS) ||
      task->win_width>TEXT_COLS-2 || task->win_height>TEXT_ROWS-2)
    return -1;
  if (i<0)
    for (i=0;i<WEB_WINS_NUM;i++)
      if (!web_wins[i].task)
	break;
  if (i==WEB_WINS_NUM)
    return -1;
  w=&web_wins[i];
  if (!w->task) {
    w->task=task;
    w->task_num=task_num;
    w->show=Bt(&task->display_flags,DISPLAYf_SHOW);
  }
  if (!w->dc) {
    w->dc=DCNew(GR_WIDTH,GR_HEIGHT);
    w->dc->flags|=DCF_SCRN_BITMAP;
    w->text=CAlloc(TEXT_COLS*TEXT_ROWS*sizeof(U32));
    MemCpy(w->text,gr.text_base,TEXT_COLS*TEXT_ROWS*sizeof(U32));
  }
  if (doc=DocDisplay(task))
    LBts(&doc->flags,DOCf_DO_FULL_REFRESH);
  if (doc=DocBorder(task))
    LBts(&doc->flags,DOCf_DO_FULL_REFRESH);
  w->detached=1;
  WinHorz(ClampI64(task->win_left,1,TEXT_COLS-1-task->win_width),
	ClampI64(task->win_left,1,TEXT_COLS-1-task->win_width)+
	task->win_width-1,task);
  WinVert(ClampI64(task->win_top,1,TEXT_ROWS-1-task->win_height),
	ClampI64(task->win_top,1,TEXT_ROWS-1-task->win_height)+
	task->win_height-1,task);
  LBtr(&task->display_flags,DISPLAYf_SHOW);
  WinZBufUpdate;
  return i;
}

public Bool WebWinAttach(I64 slot,I64 x,I64 y)
{
  CWebWin *w;
  I64 cols,rows;
  if (!(0<=slot<WEB_WINS_NUM))
    return FALSE;
  w=&web_wins[slot];
  if (!WebWinValid(w))
    return FALSE;
  cols=w->task->win_width;
  rows=w->task->win_height;
  x=ClampI64(x/FONT_WIDTH+1,1,TEXT_COLS-1-cols);
  y=ClampI64(y/FONT_HEIGHT+1,1,TEXT_ROWS-1-rows);
  WinHorz(x,x+cols-1,w->task);
  WinVert(y,y+rows-1,w->task);
  w->detached=0;
  if (web_win_input==slot)
    web_win_input=-1;
  LBts(&w->task->display_flags,DISPLAYf_SHOW);
  WinFocus(w->task);
  return TRUE;
}

public Bool WebWinFocus(I64 slot)
{
  CWebWin *w;
  if (!(0<=slot<WEB_WINS_NUM))
    return FALSE;
  w=&web_wins[slot];
  if (!WebWinValid(w))
    return FALSE;
  if (w->detached) {
    web_win_input=slot;
    LBts(&w->task->display_flags,DISPLAYf_SHOW);
  }
  WinFocus(w->task);
  return TRUE;
}

public U0 WebWinDoc(I64 slot,U8 *st)
{
  CWebWin *w;
  CDoc *doc;
  if (!(0<=slot<WEB_WINS_NUM))
    return;
  w=&web_wins[slot];
  if (w->owned && WebWinValid(w) && (doc=DocPut(w->task))) {
    w->task->draw_it=NULL;
    DocClear(doc);
    DocPrint(doc,"%s",st);
    DocTop(doc);
  }
}

class CWebGuiCmd
{
  I32 kind,x,y,width,height,color,id,size;
};

extern U0 WebGuiDocDraw(CWebWin *w,CDC *dc);

U0 WebGuiDraw(CTask *task,CDC *dc)
{
  I64 slot=WebWinFind(task),i,cnt;
  CWebWin *w;
  CWebGuiCmd *c;
  U8 *end,*payload;
  //A full-size GUI covers the desktop, so its callback is skipped.
  if (web_win_frame!=winmgr.updates)
    WebWinHide;
  if (slot<0 || !(w=&web_wins[slot])->gui)
    return;
  if (!(24<=*w->gui(U32 *)<=0x100000))
    return;
  end=w->gui+*w->gui(U32 *);
  cnt=w->gui(U32 *)[1];
  dc->color=w->gui(U32 *)[4]&15;
  GrRect(dc,0,0,task->pix_width,task->pix_height);
  c=w->gui+24;
  for (i=0;i<cnt && c(U8 *)+sizeof(CWebGuiCmd)<=end;i++) {
    payload=c(U8 *)+sizeof(CWebGuiCmd);
    if (c->size<0 || payload+c->size>end)
      break;
    dc->color=c->color&15;
    switch (c->kind) {
      case 1:
	GrRect(dc,c->x,c->y,c->width,c->height);
	break;
      case 2:
	if (c->size && !payload[c->size-1])
	  GrPrint(dc,c->x,c->y,"%s",payload);
	break;
      case 3:
	if (0<c->width<=640 && 0<c->height<=480 &&
	    ((c->width+7)&~7)*c->height<=c->size) {
	  w->image->width=c->width;
	  w->image->width_internal=(c->width+7)&~7;
	  w->image->height=c->height;
	  w->image->body=payload;
	  GrBlot(dc,c->x,c->y,w->image);
	}
	break;
      case 4:
	if (c->id==w->gui_focus || c->id==w->gui_hover) {
	  dc->color=YELLOW;
	  if (w->gui_press==c->id)
	    dc->color=RED;
	  GrRect(dc,c->x,c->y,c->width,1);
	  GrRect(dc,c->x,c->y+c->height-1,c->width,1);
	}
    }
    c=payload+c->size;
  }
  WebGuiDocDraw(w,dc);
}

public U8 *WebWinGuiAlloc(I64 slot)
{
  CWebWin *w;
  if (!(0<=slot<WEB_WINS_NUM))
    return NULL;
  w=&web_wins[slot];
  if (!w->owned || !WebWinValid(w))
    return NULL;
  if (!w->gui) {
    w->gui=CAlloc(0x100000,adam_task);
    w->image=DCNew(8,1,adam_task,TRUE);
    w->image->flags=DCF_ALIAS;
    w->task->draw_it=&WebGuiDraw;
    DocClear(DocPut(w->task));
  }
  return w->gui;
}

I64 WebGuiHit(CWebWin *w,I64 x,I64 y,I64 after=-1,I64 kind=4)
{
  I64 i,cnt,id=0,first=0;
  CWebGuiCmd *c;
  U8 *end,*payload;
  Bool found=FALSE;
  if (!w->gui || !(24<=*w->gui(U32 *)<=0x100000))
    return 0;
  end=w->gui+*w->gui(U32 *);
  cnt=w->gui(U32 *)[1];
  c=w->gui+24;
  for (i=0;i<cnt && c(U8 *)+sizeof(CWebGuiCmd)<=end;i++) {
    payload=c(U8 *)+sizeof(CWebGuiCmd);
    if (c->size<0 || payload+c->size>end)
      break;
    if (c->kind==kind) {
      if (!first)
	first=c->id;
      if (after>=0) {
	if (found)
	  return c->id;
	found=c->id==after;
      } else if (c->x<=x<c->x+c->width && c->y<=y<c->y+c->height)
	id=c->id;
    }
    c=payload+c->size;
  }
  if (after>=0)
    return first;
  return id;
}

CWebGuiCmd *WebGuiInput(CWebWin *w,I64 id)
{
  CWebGuiCmd *c;
  U8 *end,*payload;
  I64 i,cnt;
  if (!w->gui)
    return NULL;
  end=w->gui+*w->gui(U32 *);
  cnt=w->gui(U32 *)[1];
  c=w->gui+24;
  for (i=0;i<cnt && c(U8 *)+sizeof(CWebGuiCmd)<=end;i++) {
    payload=c(U8 *)+sizeof(CWebGuiCmd);
    if (c->size<0 || payload+c->size>end)
      break;
    if ((c->kind==7 || c->kind==8) && c->id==id)
      return c;
    c=payload+c->size;
  }
  return NULL;
}

U0 WebWinAction(I64 slot,I64 id,I64 kind=0,I64 x=0,I64 y=0,
	I64 arg1=0,I64 arg2=0,U8 *value=NULL)
{
  CWebWin *w=&web_wins[slot];
  I64 flags;
wa_wait:
  while (web_action_head-web_action_tail>=64 && web_win_enabled)
    Sleep(1);
  flags=GetRFlags;
  CLI
  if (web_action_head-web_action_tail>=64 && web_win_enabled) {
    SetRFlags(flags);
    goto wa_wait;
  }
  if (web_win_enabled) {
    Free(web_action_text[web_action_head%64]);
    web_action_text[web_action_head%64]=NULL;
    if (value) {
      arg1=web_action_text[web_action_head%64]=StrNew(value,adam_task);
      arg2=StrLen(value);
    }
    web_actions[web_action_head%64*8]=slot;
    web_actions[web_action_head%64*8+1]=w->task_num;
    web_actions[web_action_head%64*8+2]=id;
    web_actions[web_action_head%64*8+3]=kind;
    web_actions[web_action_head%64*8+4]=x;
    web_actions[web_action_head%64*8+5]=y;
    web_actions[web_action_head%64*8+6]=arg1;
    web_actions[web_action_head%64*8+7]=arg2;
    web_action_head++;
  }
  SetRFlags(flags);
}

Bool WebGuiCanvas(CWebWin *w,CWebGuiCmd *c)
{
  return c && c->kind==7 && 0<c->width<=GR_WIDTH &&
      0<c->height<=GR_HEIGHT && c->x<w->task->pix_width &&
      c->x+c->width>0 && c->y<w->task->pix_height && c->y+c->height>0;
}

U0 WebGuiCenter(CWebWin *w,CWebGuiCmd *c)
{
  I64 left=MaxI64(0,c->x),right=MinI64(w->task->pix_width,c->x+c->width),
      top=MaxI64(0,c->y),bottom=MinI64(w->task->pix_height,c->y+c->height);
  w->gui_center_x=w->task->pix_left+(left+right)/2;
  w->gui_center_y=w->task->pix_top+(top+bottom)/2;
}

public Bool WebGuiCapture(I64 slot,I64 id,Bool on)
{//The guest owns the mouse; its host only transports motion and capture loss.
  CWebWin *w;
  CWebGuiCmd *c;
  if (!(0<=slot<WEB_WINS_NUM))
    return FALSE;
  w=&web_wins[slot];
  if (!w->owned || !WebWinValid(w))
    return FALSE;
  if (!on) {
    if (w->gui_capture && w->gui_capture!=id)
      return TRUE;
    WebGuiRelease(w);
    return TRUE;
  }
  c=WebGuiInput(w,id);
  if (!web_win_enabled || !WebGuiCanvas(w,c))
    return FALSE;
  WebWinFocus(slot);
  if (w->task!=sys_focus_task)
    return FALSE;
  if (web_gui_capture==w && w->gui_capture==id)
    return TRUE;
  if (web_gui_capture)
    WebGuiRelease(web_gui_capture);
  w->gui_ms_show=ms.show;
  w->gui_ms_x=ms.pos.x;
  w->gui_ms_y=ms.pos.y;
  WebGuiCenter(w,c);
  web_gui_capture=w;
  w->gui_capture=w->gui_focus=id;
  ms.show=FALSE;
  MsSet(w->gui_center_x,w->gui_center_y);
  return TRUE;
}

U0 WebGuiMotion(I64 slot)
{
  CWebWin *w=&web_wins[slot];
  CWebGuiCmd *c;
  I64 x,y;
  if (!w->gui_capture)
    return;
  c=WebGuiInput(w,w->gui_capture);
  if (!web_win_enabled || w->task!=sys_focus_task ||
      w->gui_focus!=w->gui_capture || !WebGuiCanvas(w,c)) {
    WebGuiRelease(w);
    return;
  }
  x=ms.pos.x-w->gui_center_x;
  y=ms.pos.y-w->gui_center_y;
  WebGuiCenter(w,c);
  ms.show=FALSE;
  MsSet(w->gui_center_x,w->gui_center_y);
  if (x || y)
    WebWinAction(slot,w->gui_capture,12,x,y,c->width,c->height);
}

CWebGuiCmd *WebGuiCmdFind(CWebWin *w,I64 id,I64 kind)
{
  CWebGuiCmd *c;
  U8 *end,*payload;
  I64 i,cnt;
  if (!w->gui || !(24<=*w->gui(U32 *)<=0x100000))
    return NULL;
  end=w->gui+*w->gui(U32 *);
  cnt=w->gui(U32 *)[1];
  c=w->gui+24;
  for (i=0;i<cnt && c(U8 *)+sizeof(CWebGuiCmd)<=end;i++) {
    payload=c(U8 *)+sizeof(CWebGuiCmd);
    if (c->size<0 || payload+c->size>end)
      break;
    if (c->kind==kind && c->id==id)
      return c;
    c=payload+c->size;
  }
  return NULL;
}

CWebGuiCmd *WebGuiFieldCmd(CWebWin *w,I64 id)
{
  CWebGuiCmd *c=WebGuiCmdFind(w,id,6);
  U8 *st;
  I64 i;
  if (!c || !(1<=c->x<=3) || !(0<c->y<=65536) || c->size<3)
    return NULL;
  st=c(U8 *)+sizeof(CWebGuiCmd);
  if (st[c->size-1] || st[c->size-2])
    return NULL;
  for (i=0;i<c->size-2 && st[i];i++);
  if (i==c->size-2 || i>=STR_LEN)
    return NULL;
  return c;
}

Bool WebGuiDocView(CWebWin *w)
{//A document viewport shares its owner's heap, never its window geometry.
  CWebGuiCmd *c=WebGuiCmdFind(w,w->gui_edit,9);
  CTask *view=w->gui_view,*task=w->task;
  I64 l,t,r,b;
  if (!c || c->x<0 || c->y<0 || c->width<8 || c->height<8)
    return FALSE;
  l=task->win_left+(c->x+7)/8;
  t=task->win_top+(c->y+7)/8;
  r=MinI64(task->win_right,task->win_left+(c->x+c->width)/8-1);
  b=MinI64(task->win_bottom,task->win_top+(c->y+c->height)/8-1);
  if (l>r || t>b || l<0 || t<0 || r>=TEXT_COLS || b>=TEXT_ROWS)
    return FALSE;
  MemCpy(view,task,sizeof(CTask));
  view->addr=view;
  view->data_heap=adam_task->data_heap;
  QueInit(&view->next_ctrl);
  view->win_left=l; view->win_right=r;
  view->win_top=t; view->win_bottom=b;
  view->win_width=r-l+1; view->win_height=b-t+1;
  view->pix_left=l*8; view->pix_right=(r+1)*8-1;
  view->pix_top=t*8; view->pix_bottom=(b+1)*8-1;
  view->pix_width=view->win_width*8;
  view->pix_height=view->win_height*8;
  view->scroll_x=view->scroll_y=view->scroll_z=0;
  MemSet(&view->horz_scroll,0,sizeof(CWinScroll));
  MemSet(&view->vert_scroll,0,sizeof(CWinScroll));
  view->text_attr=c->color&255;
  Bts(&view->display_flags,DISPLAYf_NO_BORDER);
  return TRUE;
}

U8 *WebGuiDocValue(CDoc *doc)
{//Save plain CP437 text without inserting a DolDoc cursor marker.
  U8 *res;
  Bool unlock=DocLock(doc),no_cursor=Bt(&doc->flags,DOCf_NO_CURSOR);
  doc->flags|=DOCF_NO_CURSOR;
  res=DocSave(doc);
  LBEqu(&doc->flags,DOCf_NO_CURSOR,no_cursor);
  if (unlock)
    DocUnlock(doc);
  return res;
}

U0 WebGuiDocPublish(I64 slot)
{
  CWebWin *w=&web_wins[slot];
  U8 *st;
  if (!w->gui_doc)
    return;
  st=WebGuiDocValue(w->gui_doc);
  if (StrLen(st)<=w->gui_limit && StrCmp(st,w->gui_value)) {
    Free(w->gui_value);
    w->gui_value=StrNew(st,adam_task);
    WebWinAction(slot,w->gui_edit,5,w->gui_epoch,0,0,0,st);
  }
  Free(st);
}

U0 WebGuiDocDel(CWebWin *w)
{
  CDoc *doc=w->gui_doc;
  CTask *view=w->gui_view;
  U8 *value=w->gui_value;
  w->gui_doc=NULL;
  w->gui_view=NULL;
  w->gui_value=NULL;
  w->gui_edit=0;
  DocDel(doc);
  Free(view);
  Free(value);
}

U0 WebGuiDocSync(CWebWin *w)
{//Only a new host epoch replaces native edits; scene echoes never do.
  CWebGuiCmd *c;
  CDoc *doc=w->gui_doc;
  U8 *st;
  Bool unlock;
  if (!doc)
    return;
  c=WebGuiFieldCmd(w,w->gui_edit);
  if (!c || c->x==3) {
    WebGuiDocDel(w);
    return;
  }
  unlock=DocLock(doc);
  w->gui_kind=c->x;
  w->gui_limit=c->y;
  w->gui_submit=c->width;
  if (w->gui_epoch!=c->height) {
    st=c(U8 *)+sizeof(CWebGuiCmd);
    st+=StrLen(st)+1;
    DocRst(doc,TRUE);
    doc->flags|=DOCF_PLAIN_TEXT|DOCF_ALLOW_UNDO|
	  DOCF_NO_SCROLL_BARS|DOCF_DONT_SWAP_OUT;
    DocPrint(doc,"%s",st);
    DocBottom(doc);
    Free(w->gui_value);
    w->gui_value=StrNew(st,adam_task);
    w->gui_epoch=c->height;
  }
  WebGuiDocView(w);
  if (unlock)
    DocUnlock(doc);
}

U0 WebGuiDocDraw(CWebWin *w,CDC *dc)
{//Draw DolDoc's native cells above the browser scene using Terry's font.
  CDoc *doc=w->gui_doc;
  CTask *view=w->gui_view;
  I64 x,y,xx,yy,ch,attr;
  Bool unlock,blink=Blink;
  if (!doc || Bt(&doc->locked_flags,DOClf_LOCKED) && doc->owning_task!=Fs)
    return;
  unlock=DocLock(doc);
  if (WebGuiDocView(w)) {
    LBEqu(&doc->flags,DOCf_HIDE_CURSOR,
	  w->task!=sys_focus_task || w->gui_focus!=w->gui_edit);
    DocRecalc(doc,RECALCF_HAS_CURSOR);
    TextRect(view->win_left,view->win_right,view->win_top,
	  view->win_bottom,view->text_attr<<8);
    DocRecalc(doc,RECALCt_TO_SCRN|RECALCF_HAS_CURSOR);
    dc->color=view->text_attr>>4;
    GrRect(dc,view->pix_left-w->task->pix_left,
	  view->pix_top-w->task->pix_top,view->pix_width,view->pix_height);
    for (y=view->win_top;y<=view->win_bottom;y++)
      for (x=view->win_left;x<=view->win_right;x++) {
	ch=gr.text_base[y*TEXT_COLS+x];
	attr=ch.u8[1];
	if (ch&ATTRF_SEL)
	  attr^=255;
	if (ch&ATTRF_INVERT)
	  attr=attr<<4+attr>>4;
	if (ch&ATTRF_BLINK && blink)
	  attr=attr<<4+attr>>4;
	xx=x*8-w->task->pix_left;
	yy=y*8-w->task->pix_top;
	if (attr>>4&15!=view->text_attr>>4) {
	  dc->color=attr>>4&15;
	  GrRect(dc,xx,yy,8,8);
	}
	if (ch.u8[0] && ch.u8[0]!=CH_SPACE || ch&ATTRF_UNDERLINE)
	  if (x*8+8<=dc->width && y*8+8<=dc->height &&
		!IsPixCovered0(w->task,x*8,y*8)) {
	    ch.u8[1]=attr&15;
	    GrRopEquU8NoClipping(ch&(ATTRF_UNDERLINE+0xFFF),
		  dc->body+y*8*dc->width_internal+x*8,dc->width_internal);
	  }
      }
  }
  if (unlock)
    DocUnlock(doc);
}

I64 WebGuiDocPos(CDoc *doc)
{
  CDocEntry *e=doc->head.next;
  I64 res=0;
  while (e!=doc && e!=doc->cur_entry) {
    if (e->type_u8==DOCT_TEXT)
      res+=StrLen(e->tag);
    else if (e->type_u8==DOCT_TAB || e->type_u8==DOCT_NEW_LINE)
      res++;
    e=e->next;
  }
  if (e!=doc)
    res+=doc->cur_col-e->min_col;
  return res;
}

U0 WebGuiDocSeek(CDoc *doc,I64 pos)
{
  CDocEntry *e=doc->head.next;
  I64 n;
  while (e!=doc) {
    n=0;
    if (e->type_u8==DOCT_TEXT)
      n=StrLen(e->tag);
    else if (e->type_u8==DOCT_TAB || e->type_u8==DOCT_NEW_LINE)
      n=1;
    if (pos<n)
      break;
    pos-=n;
    e=e->next;
  }
  doc->cur_entry=e;
  doc->cur_col=e->min_col+pos;
}

U0 WebGuiDocMouse(CWebWin *w,I64 x,I64 y,Bool select=FALSE)
{
  CDoc *doc=w->gui_doc;
  CTask *view=w->gui_view;
  I64 pos,i;
  Bool unlock;
  if (!doc)
    return;
  unlock=DocLock(doc);
  if (WebGuiDocView(w)) {
    DocRecalc(doc,RECALCF_HAS_CURSOR);
    doc->x=ClampI64((x+w->task->pix_left-view->pix_left)/8,
	  0,view->win_width-1)+doc->line_start_col;
    doc->y=ClampI64((y+w->task->pix_top-view->pix_top)/8,
	  0,view->win_height-1)+doc->top_line_num;
    DocRecalc(doc,RECALCt_FIND_CURSOR);
    pos=WebGuiDocPos(doc);
    EdSelAll(doc,FALSE);
    if (select) {
      WebGuiDocSeek(doc,w->gui_anchor);
      if (pos>=w->gui_anchor)
	for (i=w->gui_anchor;i<pos;i++)
	  EdCursorRight(doc,SCF_SHIFT);
      else
	for (i=w->gui_anchor;i>pos;i--)
	  EdCursorLeft(doc,SCF_SHIFT);
      DocRecalc(doc,RECALCF_HAS_CURSOR);
    } else
      w->gui_anchor=pos;
  }
  if (unlock)
    DocUnlock(doc);
}

U8 *WebGuiChoice(U8 *st)
{
  U8 *value=st+StrLen(st)+1,*res=NULL;
  CDoc *doc=DocNew;
  I64 i=0,n;
  StrCpy(Fs->task_title,st);
  Fs->title_src=TTS_LOCKED_CONST;
  st=value+StrLen(value)+1;
  while (*st) {
    if (*st=='1')
      DocPrint(doc,"$$MU,\"%$$Q\",LE=%d,RE=%d$$\n",st+1,i,i);
    else
      DocPrint(doc,"$$DKGRAY$$%$$s$$FG$$\n",st+1);
    st+=StrLen(st)+1;
    i++;
  }
  n=PopUpMenu(doc);
  DocDel(doc);
  if (n!=DOCM_CANCEL)
    res=MStrPrint("%d",n);
  if (res) {
    st=StrNew(res,Fs->parent_task);
    Free(res);
    return st;
  }
  return NULL;
}

Bool WebGuiEdit(I64 slot,I64 id)
{//Text stays in its owner's window; a choice uses TempleOS's native menu.
  CWebWin *w=&web_wins[slot];
  CWebGuiCmd *c=WebGuiFieldCmd(w,id);
  U8 *st,*value,*cmd,*res;
  I64 epoch;
  if (!c)
    return !!WebGuiCmdFind(w,id,6);
  if (w->gui_doc && w->gui_edit==id)
    return TRUE;
  WebGuiDocPublish(slot);
  WebGuiDocDel(w);
  st=MAlloc(c->size);
  MemCpy(st,c(U8 *)+sizeof(CWebGuiCmd),c->size);
  value=st+StrLen(st)+1;
  epoch=c->height;
  if (c->x==3) {
    cmd=MStrPrint("WebGuiChoice(0x%X);",st);
    res=PopUp(cmd,Fs);
    if (res) {
      WebWinAction(slot,id,5,epoch,0,0,0,res);
      Free(res);
    }
    Free(cmd);
  } else if (WebGuiCmdFind(w,id,9)) {
    w->gui_edit=id;
    w->gui_kind=c->x;
    w->gui_limit=c->y;
    w->gui_submit=c->width;
    w->gui_epoch=epoch;
    w->gui_view=CAlloc(sizeof(CTask),adam_task);
    w->gui_doc=DocNew(,adam_task);
    w->gui_doc->win_task=w->gui_view;
    w->gui_doc->flags|=DOCF_PLAIN_TEXT|DOCF_ALLOW_UNDO|
	  DOCF_NO_SCROLL_BARS|DOCF_DONT_SWAP_OUT;
    w->gui_value=StrNew(value,adam_task);
    if (!WebGuiDocView(w)) {
      WebGuiDocDel(w);
      Free(st);
      return TRUE;
    }
    DocPrint(w->gui_doc,"%s",value);
    DocBottom(w->gui_doc);
  }
  Free(st);
  return TRUE;
}

Bool WebGuiDocKey(I64 slot,I64 ch,I64 sc)
{
  CWebWin *w=&web_wins[slot];
  CDoc *doc=w->gui_doc;
  U8 *old,*value;
  Bool unlock;
  if (!doc || w->gui_focus!=w->gui_edit)
    return FALSE;
  if (ch==CH_ESC || ch==CH_SHIFT_ESC || ch=='\t' && w->gui_kind==1) {
    WebGuiDocPublish(slot);
    if (ch!='\t')
      w->gui_focus=0;
    return ch!='\t';
  }
  if (ch=='\n' && w->gui_kind==1) {
    WebGuiDocPublish(slot);
    if (w->gui_submit)
      WebWinAction(slot,w->gui_edit,6,w->gui_epoch);
    return TRUE;
  }
  if (sc&SCF_ALT && ch!=CH_BACKSPACE)
    return TRUE;
  if (sc&SCF_CTRL && ch!=CH_CTRLA && ch!=CH_CTRLC &&
	ch!=CH_CTRLV && ch!=CH_CTRLX && ch!=CH_CTRLY &&
	ch!=CH_CTRLZ && ch!=CH_BACKSPACE && ch)
    return TRUE;
  if (!ch && !(SC_HOME<=sc.u8[0]<=SC_DELETE))
    return TRUE;
  unlock=DocLock(doc);
  WebGuiDocView(w);
  old=WebGuiDocValue(doc);
  if (ch==CH_CTRLA)
    EdSelAll(doc,TRUE);
  else if (ch==CH_CTRLZ)
    DocUndoRestore(doc);
  else
    DocPutKey(doc,ch,sc);
  DocRecalc(doc,RECALCF_HAS_CURSOR);
  value=WebGuiDocValue(doc);
  if (StrLen(value)>w->gui_limit && StrLen(value)>StrLen(old) ||
	w->gui_kind==1 && StrOcc(value,'\n')) {
    DocRst(doc,TRUE);
    doc->flags|=DOCF_PLAIN_TEXT|DOCF_ALLOW_UNDO|
	  DOCF_NO_SCROLL_BARS|DOCF_DONT_SWAP_OUT;
    DocPrint(doc,"%s",old);
    DocBottom(doc);
  }
  Free(old);
  Free(value);
  if (unlock)
    DocUnlock(doc);
  WebGuiDocPublish(slot);
  return TRUE;
}

U0 WebWinTaskEnd()
{//A killed owner must release its Adam-owned document before cleanup.
  I64 slot=WebWinFind(Fs);
  if (slot>=0) {
    WebGuiRelease(&web_wins[slot]);
    if (web_wins[slot].gui_doc)
      DocUnlock(web_wins[slot].gui_doc);
  }
  Exit;
}

U0 WebWinTask(I64 slot)
{
  CWebWin *w=&web_wins[slot];
  CWebGuiCmd *input;
  I64 arg1,arg2,msg,id,scroll,kind,z=ms.pos.z,x,y,old_x=-1,old_y=-1,
	key_owner=0;
  Bool inside=FALSE,old_inside=FALSE;
  DocTermNew;
  DocCursor(OFF);
  WinBorder(ON);
  //Send each press immediately; the browser combines double clicks.
  Fs->win_inhibit=WIG_USER_TASK_DFT|WIG_DBL_CLICK|WIF_SELF_GRAB_SCROLL;
  Fs->title_src=TTS_CONST;
  Fs->border_src=BDS_CONST;
  Fs->border_attr=BLUE+WHITE<<4;
  Fs->text_attr=BLUE+WHITE<<4;
  w->task=Fs;
  w->task_num=Fs->task_num;
  LBts(&Fs->display_flags,DISPLAYf_SHOW);
  WinToTop;
  WinZBufUpdate;
  Fs->task_end_cb=&WebWinTaskEnd; //WebWinHostNew waits for initialization.
  while (TRUE) {
    msg=ScanMsg(&arg1,&arg2,1<<MSG_CMD|1<<MSG_KEY_DOWN|1<<MSG_KEY_UP|
	  1<<MSG_MS_L_DOWN|1<<MSG_MS_L_UP|
	  1<<MSG_MS_L_D_DOWN|1<<MSG_MS_L_D_UP);
    WebGuiMotion(slot);
    WebGuiDocSync(w);
    x=ms.pos.x-Fs->pix_left;
    y=ms.pos.y-Fs->pix_top;
    inside=WinInside(ms.pos.x,ms.pos.y,Fs) &&
	0<=ms.pos_text.x<TEXT_COLS && 0<=ms.pos_text.y<TEXT_ROWS &&
	Fs->win_z_num>=gr.win_z_buf[ms.pos_text.y*TEXT_COLS+ms.pos_text.x];
    if (w->gui && !w->gui_capture &&
	(inside || old_inside || w->gui_press) &&
	(x!=old_x || y!=old_y || inside!=old_inside)) {
      old_x=x;
      old_y=y;
      w->gui_hover=WebGuiHit(w,x,y);
      if (!inside)
	w->gui_hover=0;
      WebWinAction(slot,w->gui_hover,3,x,y);
      if (w->gui_doc && ms.lb && w->gui_press==w->gui_edit)
	WebGuiDocMouse(w,x,y,TRUE);
    }
    old_inside=inside;
    if (key_owner && (Fs!=sys_focus_task || key_owner!=w->gui_focus)) {
      WebWinAction(slot,key_owner,11);
      key_owner=0;
    }
    if (Fs==sys_focus_task && (input=WebGuiInput(w,w->gui_focus)) &&
	input->kind==7)
      key_owner=w->gui_focus;
    if (w->gui && Fs==sys_focus_task && z!=ms.pos.z) {
      scroll=WebGuiHit(w,ms.pos.x-Fs->pix_left,ms.pos.y-Fs->pix_top,-1,5);
      if (scroll) {
	kind=1;
	if (ms.pos.z>z)
	  kind=2;
	WebWinAction(slot,0x100000+scroll*16+kind);
      }
    }
    z=ms.pos.z;
    if (msg==MSG_CMD)
      WebWinAction(slot,arg1);
    if (w->gui && (msg==MSG_MS_L_DOWN || msg==MSG_MS_L_D_DOWN)) {
      id=w->gui_capture;
      if (!id)
	id=WebGuiHit(w,arg1,arg2);
      if (w->gui_doc && id!=w->gui_edit)
	WebGuiDocPublish(slot);
      w->gui_press=w->gui_focus=id;
      input=WebGuiFieldCmd(w,id);
      if (input && input->x!=3) {
	WebGuiEdit(slot,id);
	WebGuiDocMouse(w,arg1,arg2);
      }
      WebWinAction(slot,w->gui_focus,1,arg1,arg2);
    }
    if (w->gui && (msg==MSG_MS_L_UP || msg==MSG_MS_L_D_UP)) {
      id=w->gui_capture;
      if (!id)
	id=WebGuiHit(w,arg1,arg2);
      WebWinAction(slot,w->gui_press,2,arg1,arg2);
      if (id && id==w->gui_press)
	if (!WebGuiEdit(slot,id))
	  WebWinAction(slot,id,0,arg1,arg2);
      w->gui_press=0;
    }
    if (msg==MSG_KEY_DOWN && WebGuiDocKey(slot,arg1,arg2)) {
    } else if ((msg==MSG_KEY_DOWN || msg==MSG_KEY_UP) &&
	(input=WebGuiInput(w,w->gui_focus)) &&
	(input->kind==7 || arg1!='\t' && arg1!=CH_ESC &&
	arg1!=CH_SHIFT_ESC && arg1!=CH_SPACE)) {
      kind=input->kind;
      if (kind==8)
	kind=9;
      if (msg==MSG_KEY_UP)
	kind++;
      WebWinAction(slot,w->gui_focus,kind,0,0,arg1,arg2.u32[0]);
    } else if (msg==MSG_KEY_DOWN) {
      if ((arg1==CH_ESC || arg1==CH_SHIFT_ESC) &&
	!Bt(&web_win_no_close,slot))
	break;
      if (w->gui) {
	if (arg1=='\t') {
	  w->gui_focus=WebGuiHit(w,0,0,w->gui_focus);
	  WebWinAction(slot,w->gui_focus,4);
	  input=WebGuiFieldCmd(w,w->gui_focus);
	  if (input && input->x!=3)
	    WebGuiEdit(slot,w->gui_focus);
	}
	kind=0;
	switch (arg2.u8[0]) {
	  case SC_CURSOR_UP: kind=1; break;
	  case SC_CURSOR_DOWN: kind=2; break;
	  case SC_PAGE_UP: kind=3; break;
	  case SC_PAGE_DOWN: kind=4; break;
	  case SC_HOME: kind=5; break;
	  case SC_END: kind=6;
	}
	if (kind && (scroll=WebGuiHit(w,0,0,0,5)))
	  WebWinAction(slot,0x100000+scroll*16+kind);
	if (arg1=='\n' || arg1==CH_SPACE)
	  if (w->gui_focus)
	    if (!WebGuiEdit(slot,w->gui_focus))
	      WebWinAction(slot,w->gui_focus);
      } else
	DocPutKey(DocPut,arg1,arg2);
    }
    if (!msg)
      Sleep(10);
  }
  WebGuiDocPublish(slot);
  WebGuiDocDel(w);
  WebGuiRelease(w);
}

public I64 WebWinHostNew(U8 *title,I64 cols,I64 rows,I64 x,I64 y)
{
  I64 i;
  CTask *task;
  for (i=0;i<WEB_WINS_NUM;i++)
    if (!web_wins[i].task && !web_wins[i].owned)
      break;
  if (i==WEB_WINS_NUM)
    return -1;
  web_wins[i].owned=1;
  web_wins[i].show=1;
  LBtr(&web_win_no_close,i);
  task=Spawn(&WebWinTask,i,title,,adam_task);
  if (!task) {
    web_wins[i].owned=0;
    return -1;
  }
  web_wins[i].task=task;
  web_wins[i].task_num=task->task_num;
  while (TaskValidate(task) && task->task_end_cb!=&WebWinTaskEnd)
    Yield;
  if (!TaskValidate(task))
    return -1;
  task->draw_it=&WebGuiDraw;
  StrCpy(task->task_title,title);
  cols=ClampI64(cols,12,TEXT_COLS-2);
  rows=ClampI64(rows,4,TEXT_ROWS-2);
  x=ClampI64(x/FONT_WIDTH+1,1,TEXT_COLS-1-cols);
  y=ClampI64(y/FONT_HEIGHT+1,1,TEXT_ROWS-1-rows);
  WinHorz(x,x+cols-1,task);
  WinVert(y,y+rows-1,task);
  WinFocus(task);
  return i;
}
