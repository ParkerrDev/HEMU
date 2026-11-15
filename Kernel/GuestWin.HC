#define WEB_WINS_NUM 32

public class CWebWin
{
  CTask *task;
  I64 task_num,detached,owned,show,seq;
  CDC *dc;
  U32 *text;
  U8 *gui;
  CDC *image;
  I64 gui_focus,gui_press,gui_hover;
};

public CWebWin web_wins[WEB_WINS_NUM];
public I64 web_win_enabled=0,web_win_input=-1,web_win_result=-1;
public I64 web_action_head=0,web_action_tail=0,web_actions[512];
I64 web_win_frame=-1;
U16 *web_win_z=NULL;
U0 (*web_win_draw)(CTask *task,CDC *dc)=NULL;
U0 (*web_win_final)(CDC *dc)=NULL;

Bool WebWinValid(CWebWin *w)
{
  return TaskValidate(w->task) && w->task->task_num==w->task_num;
}

public Bool WebWinClose(I64 slot,I64 task_num)
{
  Bool res=FALSE;
  I64 flags=GetRFlags;
  CWebWin *w;
  CLI
  if (0<=slot<WEB_WINS_NUM) {
    w=&web_wins[slot];
    if (w->owned && w->task_num==task_num && WebWinValid(w))
      res=Kill(w->task,FALSE);
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
  Bool old_show=ms.show;
  CWebWin *w;
  if (0<=web_win_input<WEB_WINS_NUM)
    ms.show=FALSE;
  if (web_win_final)
    (*web_win_final)(dc);
  ms.show=old_show;
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

U0 WebWinAction(I64 slot,I64 id,I64 kind=0,I64 x=0,I64 y=0,
	I64 arg1=0,I64 arg2=0)
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

U0 WebWinTask(I64 slot)
{
  CWebWin *w=&web_wins[slot];
  I64 arg1,arg2,msg,id,scroll,kind,z=ms.pos.z,x,y,old_x=-1,old_y=-1;
  Bool inside=FALSE,old_inside=FALSE;
  DocTermNew;
  DocCursor(OFF);
  WinBorder(ON);
  //Send each press immediately; the browser combines double clicks.
  Fs->win_inhibit=WIG_USER_TASK_DFT|WIG_DBL_CLICK;
  Fs->title_src=TTS_CONST;
  Fs->border_src=BDS_CONST;
  Fs->border_attr=BLUE+WHITE<<4;
  Fs->text_attr=BLUE+WHITE<<4;
  w->task=Fs;
  w->task_num=Fs->task_num;
  LBts(&Fs->display_flags,DISPLAYf_SHOW);
  WinToTop;
  WinZBufUpdate;
  while (TRUE) {
    msg=ScanMsg(&arg1,&arg2,1<<MSG_CMD|1<<MSG_KEY_DOWN|
	  1<<MSG_MS_L_DOWN|1<<MSG_MS_L_UP|
	  1<<MSG_MS_L_D_DOWN|1<<MSG_MS_L_D_UP);
    x=ms.pos.x-Fs->pix_left;
    y=ms.pos.y-Fs->pix_top;
    inside=WinInside(ms.pos.x,ms.pos.y,Fs) &&
	0<=ms.pos_text.x<TEXT_COLS && 0<=ms.pos_text.y<TEXT_ROWS &&
	Fs->win_z_num>=gr.win_z_buf[ms.pos_text.y*TEXT_COLS+ms.pos_text.x];
    if (w->gui && (inside || old_inside || w->gui_press) &&
	(x!=old_x || y!=old_y || inside!=old_inside)) {
      old_x=x;
      old_y=y;
      w->gui_hover=WebGuiHit(w,x,y);
      if (!inside)
	w->gui_hover=0;
      WebWinAction(slot,w->gui_hover,3,x,y);
    }
    old_inside=inside;
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
      w->gui_press=w->gui_focus=WebGuiHit(w,arg1,arg2);
      WebWinAction(slot,w->gui_focus,1,arg1,arg2);
    }
    if (w->gui && (msg==MSG_MS_L_UP || msg==MSG_MS_L_D_UP)) {
      id=WebGuiHit(w,arg1,arg2);
      WebWinAction(slot,id,2,arg1,arg2);
      if (id && id==w->gui_press)
	WebWinAction(slot,id,0,arg1,arg2);
      w->gui_press=0;
    }
    if (msg==MSG_KEY_DOWN) {
      if (arg1==CH_ESC || arg1==CH_SHIFT_ESC)
	break;
      if (w->gui) {
	if (arg1=='\t') {
	  w->gui_focus=WebGuiHit(w,0,0,w->gui_focus);
	  WebWinAction(slot,w->gui_focus,4);
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
	    WebWinAction(slot,w->gui_focus);
      } else
	DocPutKey(DocPut,arg1,arg2);
    }
    if (!msg)
      Sleep(10);
  }
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
  task=Spawn(&WebWinTask,i,title,,adam_task);
  if (!task) {
    web_wins[i].owned=0;
    return -1;
  }
  web_wins[i].task=task;
  web_wins[i].task_num=task->task_num;
  while (TaskValidate(task) && !DocPut(task))
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
