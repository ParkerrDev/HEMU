#define WEB_WINS_NUM 32

public class CWebWin
{
  CTask *task;
  I64 task_num,detached,owned,show,seq;
  CDC *dc;
  U32 *text;
};

public CWebWin web_wins[WEB_WINS_NUM];
public I64 web_win_enabled=0,web_win_input=-1,web_win_result=-1;
public I64 web_action_head=0,web_action_tail=0,web_actions[192];
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

U0 WebWinBefore(CTask *task,CDC *dc)
{
  I64 i;
  Bool changed=FALSE;
  CWebWin *w;
  web_win_frame=winmgr.updates;
  if (!web_win_enabled) {
    WebWinStop;
    if (web_win_draw)
      (*web_win_draw)(task,dc);
    return;
  }
  if (web_win_draw)
    (*web_win_draw)(task,dc);
  for (i=0,w=web_wins;i<WEB_WINS_NUM;i++,w++)
    if (w->detached && WebWinValid(w))
      changed|=LBtr(&w->task->display_flags,DISPLAYf_SHOW);
  if (changed)
    WinZBufUpdate;
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
  if (!web_win_enabled || web_win_frame!=winmgr.updates) {
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
    DocClear(doc);
    DocPrint(doc,"%s",st);
    DocTop(doc);
  }
}

U0 WebWinTask(I64 slot)
{
  CWebWin *w=&web_wins[slot];
  I64 arg1,arg2,msg,flags;
  DocTermNew;
  DocCursor(OFF);
  WinBorder(ON);
  Fs->win_inhibit=WIG_USER_TASK_DFT;
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
    msg=GetMsg(&arg1,&arg2,1<<MSG_CMD|1<<MSG_KEY_DOWN);
    if (msg==MSG_CMD) {
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
	web_actions[web_action_head%64*3]=slot;
	web_actions[web_action_head%64*3+1]=w->task_num;
	web_actions[web_action_head%64*3+2]=arg1;
	web_action_head++;
      }
      SetRFlags(flags);
    }
    if (msg==MSG_KEY_DOWN) {
      if (arg1==CH_ESC || arg1==CH_SHIFT_ESC)
	break;
      DocPutKey(DocPut,arg1,arg2);
    }
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
