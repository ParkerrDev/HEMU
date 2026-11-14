#define AC_DBL_BUF_SPOTS_NUM	2

CDoc *ac_dbl_buf_doc=NULL;
I64 ac_dbl_buf_task_num=-1,ac_dbl_buf_left=0,ac_dbl_buf_top=0,
      ac_dbl_buf_put=-1,ac_dbl_buf_put_task_num=-1,
      ac_dbl_buf_put_left=0,ac_dbl_buf_put_top=0;

class CACDblBufScroll
{//Where a scroll bar was last drawn, in scrn pixels.
  Bool drawn; //FALSE if not since the win was shown.
  I64 left,right,top,bottom;
} ac_dbl_buf_scroll[2];

class CACDblBufSpot
{//Where ACDocRst puts the win, and where the visitor last moved it from.
  I64 left,top,moved_left,moved_top;
  Bool moved;
} ac_dbl_buf_spots[AC_DBL_BUF_SPOTS_NUM];

I64 ACDblBufSpotFind(I64 left,I64 top)
{//Which spot ACDocRst was given, or -1.
  I64 i;
  for (i=0;i<AC_DBL_BUF_SPOTS_NUM;i++)
    if (ac_dbl_buf_spots[i].left==left && ac_dbl_buf_spots[i].top==top)
      return i;
  return -1;
}

U0 ACDblBufSpotsInit()
{//ACPutChoices puts the list at 51,13 and the key maps go at 27,3. A boot
//shows the list, which the visitor may have moved already.
  MemSet(ac_dbl_buf_spots,0,sizeof(ac_dbl_buf_spots));
  ac_dbl_buf_spots[0].left=51;
  ac_dbl_buf_spots[0].top=13;
  ac_dbl_buf_spots[1].left=27;
  ac_dbl_buf_spots[1].top=3;
  ac_dbl_buf_put=-1;
  if (TaskValidate(ac.task)) {
    ac_dbl_buf_put=ACDblBufSpotFind(ac.task->win_left,ac.task->win_top);
    if (ac_dbl_buf_put<0)
      ac_dbl_buf_put=0;
    ac_dbl_buf_put_task_num=ac.task->task_num;
    ac_dbl_buf_put_left=ac_dbl_buf_spots[ac_dbl_buf_put].left;
    ac_dbl_buf_put_top=ac_dbl_buf_spots[ac_dbl_buf_put].top;
  }
}

U0 ACDblBufSpotPut()
{//The win goes to the spot ACDocRst was given, or where the visitor moved
//it from there. Only a drag moves it, so a win not where it was put was
//dragged, from the spot it was put at.
  I64 left=ac_dbl_buf_left,top=ac_dbl_buf_top;
  CACDblBufSpot *tmps;
  if (ac_dbl_buf_put>=0 && ac_dbl_buf_put_task_num==Fs->task_num &&
	(Fs->win_left!=ac_dbl_buf_put_left ||
	Fs->win_top!=ac_dbl_buf_put_top)) {
    tmps=&ac_dbl_buf_spots[ac_dbl_buf_put];
    tmps->moved_left=Fs->win_left;
    tmps->moved_top=Fs->win_top;
    tmps->moved=TRUE;
  }
  ac_dbl_buf_put=ACDblBufSpotFind(left,top);
  if (ac_dbl_buf_put>=0) {
    tmps=&ac_dbl_buf_spots[ac_dbl_buf_put];
    if (tmps->moved) {
      left=tmps->moved_left;
      top=tmps->moved_top;
    }
  }
  WinHorz(left,Fs->win_right);
  WinVert(top,Fs->win_bottom);
}

U0 ACDblBufScrollOut(CCtrl *c,CACDblBufScroll *s)
{//Out of the win, which shrank or moved. The z buf gives the place to the
//win under it, but the scrn still shows this win's text there.
  CDC *dc=DCAlias(gr.dc2,Fs);
  dc->flags|=DCF_ON_TOP;
  c->left=s->left-Fs->pix_left;
  c->right=s->right-Fs->pix_left;
  c->top=s->top-Fs->pix_top;
  c->bottom=s->bottom-Fs->pix_top;
  DrawWinScroll(dc,c);
  DCDel(dc);
}

U0 ACDblBufScrollDraw(CDC *dc,CCtrl *c)
{//The scrn shows a win's text from the last update that drew the win,
//but its ctrls from this one. Draw the bar where it was, by that text.
  CACDblBufScroll *s=&ac_dbl_buf_scroll[c->type==CTRLT_WIN_VSCROLL];
  CTask *task=c->win_task;
  I64 left=c->left,right=c->right,top=c->top,bottom=c->bottom;
  if (s->drawn) {
    c->left=s->left-task->pix_left;
    c->right=s->right-task->pix_left;
    c->top=s->top-task->pix_top;
    c->bottom=s->bottom-task->pix_top;
    if (0<=c->left && c->right<task->pix_width &&
	  0<=c->top && c->bottom<task->pix_height)
      DrawWinScroll(dc,c);
    else
      ACDblBufScrollOut(c,s);
    c->left=left;
    c->right=right;
    c->top=top;
    c->bottom=bottom;
  }
  s->left=left+task->pix_left;
  s->right=right+task->pix_left;
  s->top=top+task->pix_top;
  s->bottom=bottom+task->pix_top;
  s->drawn=TRUE;
}

U0 ACDblBufScrollSet(I64 type)
{//Take a bar from the stock routine, where it drew it last. DrawCtrls
//draws it with the win one char bigger, to reach the border.
  CCtrl *c=CtrlFindUnique(Fs,type);
  CACDblBufScroll *s=&ac_dbl_buf_scroll[type==CTRLT_WIN_VSCROLL];
  if (c && c->draw_it==&DrawWinScroll) {
    s->left=c->left+Fs->pix_left-FONT_WIDTH;
    s->right=c->right+Fs->pix_left-FONT_WIDTH;
    s->top=c->top+Fs->pix_top-FONT_HEIGHT;
    s->bottom=c->bottom+Fs->pix_top-FONT_HEIGHT;
    s->drawn=Bt(&Fs->display_flags,DISPLAYf_SHOW);
    c->draw_it=&ACDblBufScrollDraw;
  }
}

CDoc *ACDblBufBack()
{//The doc the next list goes in. The shown one stays on the scrn.
  if (DocPut==DocDisplay) {
    if (ac_dbl_buf_task_num==Fs->task_num)
      Fs->put_doc=ac_dbl_buf_doc;
    else {
      DocDblBufStart;
      ACDblBufScrollSet(CTRLT_WIN_HSCROLL);
      ACDblBufScrollSet(CTRLT_WIN_VSCROLL);
      ac_dbl_buf_task_num=Fs->task_num;
    }
  }
  return DocPut;
}

U0 ACDblBufBorder(CDoc *old,CDoc *doc)
{//The border's More, $$ and type fields show the doc they were made with.
  CDoc *bdoc=DocBorder;
  CDocEntry *tmpde;
  if (!bdoc) return;
  tmpde=bdoc->head.next;
  while (tmpde!=bdoc) {
    if (tmpde->user_data==old)
      tmpde->user_data=doc;
    tmpde=tmpde->next;
  }
}

Bool ACDblBufShow()
{//Swap in the finished doc. FALSE if the win z buf must be redone.
//Nothing from the lock to the swap yields, so the WinMgr's first frame of
//the new doc has the size and scroll it would settle on frames later.
  Bool res=TRUE;
  if (DocPut!=DocDisplay) {
    DocLock(DocDisplay); //Any wait comes before the move and swap.
    ACDblBufSpotPut;
    DocRecalc(DocPut,RECALCt_NORMAL|RECALCF_HAS_CURSOR); //Fits the win to it
    DocRecalc(DocPut,RECALCt_NORMAL|RECALCF_HAS_CURSOR); //and scrolls in it.
    ac_dbl_buf_put_task_num=Fs->task_num;
    ac_dbl_buf_put_left=Fs->win_left; //As the fit left it.
    ac_dbl_buf_put_top=Fs->win_top;
    DocDblBufSwap;
    ac_dbl_buf_doc=DocPut;
    Fs->put_doc=Fs->display_doc; //Clicked links act on the shown doc.
    ACDblBufBorder(ac_dbl_buf_doc,Fs->display_doc);
    res=FALSE;
  }
  if (!LBts(&Fs->display_flags,DISPLAYf_SHOW)) {
    ac_dbl_buf_scroll[0].drawn=ac_dbl_buf_scroll[1].drawn=FALSE;
    res=FALSE;
  }
  return res;
}

MemSet(ac_dbl_buf_scroll,0,sizeof(ac_dbl_buf_scroll));
ACDblBufSpotsInit;
