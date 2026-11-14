#define RENDER_CODE_NUM 9
#define RENDER_FRAME_SIZE 1024
#define TASKf_NONTIMER_RAND 14

class CRenderCode
{
  U64 addr,size;
  U8 *bytes;
} render_code[RENDER_CODE_NUM];
Bool render_fast=TRUE,render_ready=FALSE;
U8 render_gate[65536];
I64 render_calls[RENDER_CODE_NUM];
U64 video_blot,video_line,video_flush,video_reverse;
U64 render_dc_size,render_task_size;
I64 video_calls;

I64 RenderFastSet(I64 value=-1)
{
  if (value>=0) render_fast=value!=0;
  return render_fast;
}

Bool RenderRange(U64 addr,U64 size)
{
  return addr && addr<mem_size && size<=mem_size-addr;
}

Bool RenderOverlap(U64 a,U64 size_a,U64 b,U64 size_b)
{
  return a<b+size_b && b<a+size_a;
}

Bool RenderReadSafe(U64 addr,U64 size)
{//Native prologues overwrite their frame before reading caller data.
  if (!RenderRange(addr,size) || reg[4]<RENDER_FRAME_SIZE ||
	RenderOverlap(addr,size,reg[4]-RENDER_FRAME_SIZE,RENDER_FRAME_SIZE))
    return FALSE;
  return TRUE;
}

Bool RenderWriteSafe(U64 addr,U64 size)
{//A native call may change its own instructions or saved stack slots.
  I64 i;
  if (!RenderReadSafe(addr,size) || RenderOverlap(addr,size,reg[4],56))
    return FALSE;
  for (i=0;i<RENDER_CODE_NUM;i++)
    if (render_code[i].addr && RenderOverlap(addr,size,
	  render_code[i].addr,render_code[i].size)) return FALSE;
  return TRUE;
}

U64 GuestCodeSize(U8 *name)
{//HashEntrySize uses the final address in CDbgInfo, not CHashFun.size.
  I64 off=GuestMember("CHashSrcSym","dbg_info"),
	lo=GuestMember("CDbgInfo","min_line"),
	hi=GuestMember("CDbgInfo","max_line"),
	body=GuestMember("CDbgInfo","body");
  U64 entry=GuestHashFind(name,HTT_FUN),dbg,first,last,cnt;
  if (off<0 || lo<0 || hi<0 || body<0 || !entry) return 0;
  dbg=GuestU64(entry+off);
  if (!RenderRange(dbg,body+4)) return 0;
  first=GuestU32(dbg+lo);last=GuestU32(dbg+hi);
  if (last<first || last-first>65536) return 0;
  cnt=last-first+2;
  if (!RenderRange(dbg+body,cnt*4)) return 0;
  first=GuestU32(dbg+body);last=GuestU32(dbg+body+(cnt-1)*4);
  if (first!=GuestFun(name) || last<=first || last-first>65536) return 0;
  return last-first;
}

U0 RenderCodeSave(I64 index,U8 *name,U8 *next=NULL)
{//Only the initial stock load establishes replacement eligibility.
  U64 addr=GuestFun(name),size;
  CRenderCode *code=&render_code[index];
  if (next) size=GuestFun(next)-addr;
  else size=GuestCodeSize(name);
  if (!size || size>65536 || !RenderRange(addr,size)) return;
  code->addr=addr;code->size=size;code->bytes=MAlloc(size);
  MemCpy(code->bytes,mem+addr,size);
  if (index<6 || index==8) render_gate[addr&0xFFFF]=1;
}

Bool RenderCodeOk(I64 index)
{
  CRenderCode *code=&render_code[index];
  U8 *a=mem+code->addr,*b=code->bytes;
  I64 size=code->size;
  if (!code->addr) return FALSE;
  for (;size>=64;size-=64) {
    if (*a(U64 *)^*b(U64 *)|
	  *(a+8)(U64 *)^*(b+8)(U64 *)|
	  *(a+16)(U64 *)^*(b+16)(U64 *)|
	  *(a+24)(U64 *)^*(b+24)(U64 *)|
	  *(a+32)(U64 *)^*(b+32)(U64 *)|
	  *(a+40)(U64 *)^*(b+40)(U64 *)|
	  *(a+48)(U64 *)^*(b+48)(U64 *)|
	  *(a+56)(U64 *)^*(b+56)(U64 *)) return FALSE;
    a+=64;b+=64;
  }
  for (;size>=8;size-=8) {
    if (*a(U64 *)!=*b(U64 *)) return FALSE;
    a+=8;b+=8;
  }
  for (;size;size--)
    if (*a++!=*b++) return FALSE;
  return TRUE;
}

U0 RenderInit()
{
  if (render_ready) return;
  render_ready=TRUE;
  MemSet(render_code,0,sizeof(render_code));
  MemSet(render_gate,0,sizeof(render_gate));
  MemSet(render_calls,0,sizeof(render_calls));
  video_calls=0;
  render_dc_size=GuestU64(GuestHashFind("CDC",HTT_CLASS)+
	GuestMember("CHashClass","size"));
  render_task_size=GuestU64(GuestHashFind("CTask",HTT_CLASS)+
	GuestMember("CHashClass","size"));
  if (!render_dc_size || !render_task_size) return;
  RenderCodeSave(0,"DCBlotColor8");
  RenderCodeSave(1,"DCBlotColor4","IsPixCovered0");
  RenderCodeSave(2,"GrUpdateLine64","GrUpdateLine64FlushCache");
  RenderCodeSave(3,"GrUpdateLine64FlushCache","DCBlotColor4");
  RenderCodeSave(4,"GrHLine");
  RenderCodeSave(5,"GrVLine");
  RenderCodeSave(6,"RandU16");
  RenderCodeSave(7,"IsPixCovered0","GrRopEquU8NoClipping");
  RenderCodeSave(8,"GrFillTri0");
  video_blot=render_code[1].addr;
  video_line=render_code[2].addr;
  video_flush=render_code[3].addr;
  video_reverse=GuestVar("rev_bits_table");
}

U0 VideoBlot4(U64 dst,U64 src,U64 cache,I64 cnt)
{//DCBlotColor4 updates its four planes only where the source changed.
  U64 v,b;
  I64 i,p;
  for (i=0;i<cnt;i++) {
    v=GuestU64(src+i*8);
    if (v!=GuestU64(cache+i*8)) {
      WrMem(cache+i*8,8,v);
      for (p=0;p<4;p++) {
	b=v>>p&0x0101010101010101;
	b*=0x0102040810204080;
	mem[dst+p*cnt+i]=b>>56;
      }
    }
  }
}

U0 VideoLine(U64 vga_arg,U64 src_arg,I64 cnt,U64 dst_arg,Bool flush)
{//The line writer also maintains the OS's screen image and pointers.
  U64 vga=GuestU64(vga_arg),src=GuestU64(src_arg),
	dst=GuestU64(dst_arg),table=GuestU64(video_reverse),v,b;
  I64 i,j,k,shift;
  for (i=0;i<cnt;i++) {
    v=GuestU64(src+i*8);
    if (flush || v!=GuestU64(dst+i*8)) {
      WrMem(dst+i*8,8,v);
      b=0;
      for (j=0;j<8;j++) {
	shift=j*8;
	k=v>>shift&255;
	b|=mem[table+k]<<shift;
      }
      WrMem(vga+i*8,8,b);
    }
  }
  WrMem(vga_arg,8,vga+cnt*8);
  WrMem(src_arg,8,src+cnt*8);
  WrMem(dst_arg,8,dst+cnt*8);
}

Bool VideoTry()
{//Named graphics primitives; invalid ranges fall back to guest code.
  U64 a,b,d,ret=GuestU64(reg[4]),src,dst,v,carry=0,table;
  Bool changed;
  I64 cnt;
  if (rfl&F_DF) return FALSE;
  if (video_blot && rip==video_blot) {
    a=GuestU64(reg[4]+8);
    b=GuestU64(reg[4]+16);
    d=GuestU64(reg[4]+24);
    cnt=GuestU64(reg[4]+32);
    if (cnt<=0 || cnt>RAM_SIZE/8 || a>=mem_size ||
	  b>=mem_size || d>=mem_size || a+cnt*4>mem_size ||
	  b+cnt*8>mem_size || d+cnt*8>mem_size) return FALSE;
    if (a<b+cnt*8 && b<a+cnt*4 || a<d+cnt*8 && d<a+cnt*4 ||
	  b<d+cnt*8 && d<b+cnt*8) return FALSE;
    if (!RenderWriteSafe(a,cnt*4) || !RenderWriteSafe(d,cnt*8) ||
	  !RenderReadSafe(b,cnt*8))
      return FALSE;
    v=GuestU64(b+(cnt-1)*8);
    changed=v!=GuestU64(d+(cnt-1)*8);
    VideoBlot4(a,b,d,cnt);
    reg[0]=v;
    reg[3]=d+cnt*8;
    reg[2]=v;
    if (changed) {
      reg[2]=v>>3&0x0101010101010101;
      reg[2]*=0x0102040810204080;
      reg[2]>>=56;
    }
    reg[8]=a+cnt*2;
    reg[9]=a+cnt*3;
  } else if (video_line && (rip==video_line || rip==video_flush)) {
    a=GuestU64(reg[4]+8);
    b=GuestU64(reg[4]+16);
    cnt=GuestU64(reg[4]+24);
    d=GuestU64(reg[4]+32);
    src=GuestU64(b);dst=GuestU64(d);
    if (cnt<=0 || cnt>RAM_SIZE/8 || a>=mem_size || b>=mem_size ||
	  d>=mem_size || src>=mem_size || dst>=mem_size ||
	  a+8>mem_size || b+8>mem_size ||
	  d+8>mem_size || src+cnt*8>mem_size || dst+cnt*8>mem_size ||
	  !video_reverse || !GuestU64(video_reverse) ||
	  GuestU64(video_reverse)+256>mem_size) return FALSE;
    v=GuestU64(a)&0xFFFFFFFFFF;
    if (!RenderRange(v,cnt*8) ||
	  RenderOverlap(v,cnt*8,src,cnt*8) ||
	  RenderOverlap(v,cnt*8,dst,cnt*8) ||
	  RenderOverlap(src,cnt*8,dst,cnt*8) ||
	  RenderOverlap(a,8,b,8) || RenderOverlap(a,8,d,8) ||
	  RenderOverlap(b,8,d,8) || !RenderWriteSafe(a,8) ||
	  !RenderWriteSafe(b,8) || !RenderWriteSafe(d,8) ||
	  !RenderWriteSafe(dst,cnt*8) || !RenderWriteSafe(v,cnt*8) ||
	  !RenderReadSafe(src,cnt*8) || !RenderReadSafe(video_reverse,8) ||
	  !RenderReadSafe(GuestU64(video_reverse),256))
      return FALSE;
    table=GuestU64(video_reverse);
    VideoLine(a,b,cnt,d,rip==video_flush);
    reg[0]=b;
    reg[3]=table;
    reg[8]=GuestU64(a);
    carry=reg[8]<8;
  } else return FALSE;
  video_calls++;
  reg[1]=0;
  Arith(5,1,1,8);
  rfl=rfl&~1|carry;
  reg[4]+=40;
  rip=ret;
  return TRUE;
}

//See $LK,"::/Doc/Credits.DD"$.
#define LIN_CONGRUE_A	6364136223846793005
#define LIN_CONGRUE_C	1442695040888963407

U16 RasterRand(U64 fsb)
{//RandU16 for the dither, on the task at fsb (Kernel/KMathB.HC).
  U64 seed=*(mem+fsb+of_task.rand_seed)(U64*);
  seed=LIN_CONGRUE_A*seed^(seed&0xFFFFFFFF0000)>>16;
  seed+=LIN_CONGRUE_C;
  if (!(*(mem+fsb+of_task.task_flags)(U32*)>>TASKf_NONTIMER_RAND&1))
    seed^=TscRead;
  *(mem+fsb+of_task.rand_seed)(U64*)=seed;
  return seed&0xFFFF;
}
I64 RasterDone(I64 cnt)
{//Return from a line primitive, discarding its six stack arguments.
  reg[0]=cnt;
  rip=RdMem(reg[4],8);
  reg[4]+=56;
  return 1;
}

I64 SpanFill(U64 dc,I64 vert,I64 x1,I64 x2,I64 y,I64 z1,I64 z2)
{//GrHLine and GrVLine share clipping, depth and raster operations.
  U64 flags=*(mem+dc+of_dc.flags)(U32 *),
	color_word=*(mem+dc+of_dc.color)(U32 *),
	zbuf=*(mem+dc+of_dc.depth_buf)(U64 *),
	win=*(mem+dc+of_dc.win_task)(U64 *),
	body=*(mem+dc+of_dc.body)(U64 *),fsb=msr_fsbase,wzbuf=0;
  I64 stride=*(mem+dc+of_dc.width_internal)(I32 *),
	width=*(mem+dc+of_dc.width)(I32 *),
	height=*(mem+dc+of_dc.height)(I32 *),
	bg=*(mem+dc+of_dc.bkcolor)(U32 *)&0xFF,
	clip_lo=0,clip_hi=0,res=0,i,idx,zptr,zslope=0,zacc,cur_z,
	mode,color,w1,w2,cw,size_a=width,size_c=height,pix_step=1,
	scroll_a=of_task.scroll_x,scroll_c=of_task.scroll_y,
	min_a=of_dc.min_x,max_a=of_dc.max_x,
	min_c=of_dc.min_y,max_c=of_dc.max_y,
	pix_lo_a=of_task.pix_left,pix_hi_a=of_task.pix_right,
	pix_lo_c=of_task.pix_top,pix_hi_c=of_task.pix_bottom,
	cur_a=of_dc.cur_x,cur_c=of_dc.cur_y,
	cnt,cx,cy,dist,dx,dy,wzn=0,cov_row=0,cov_step=1;
  I32 *depth;
  U8 *dst;
  Bool dither=FALSE,probability_dither=FALSE,need_cov,char_clear=TRUE;
  if (!zbuf) return -1;
  if (vert) {
    size_a=height;size_c=width;pix_step=stride;
    scroll_a=of_task.scroll_y;scroll_c=of_task.scroll_x;
    min_a=of_dc.min_y;max_a=of_dc.max_y;
    min_c=of_dc.min_x;max_c=of_dc.max_x;
    pix_lo_a=of_task.pix_top;pix_hi_a=of_task.pix_bottom;
    pix_lo_c=of_task.pix_left;pix_hi_c=of_task.pix_right;
    cur_a=of_dc.cur_y;cur_c=of_dc.cur_x;
  }
  if (flags & DCF_SCRN_BITMAP) {
    x1+=*(mem+win+scroll_a)(I64 *);
    x2+=*(mem+win+scroll_a)(I64 *);
    y+=*(mem+win+scroll_c)(I64 *);
    z1+=*(mem+win+of_task.scroll_z)(I64 *);
    z2+=*(mem+win+of_task.scroll_z)(I64 *);
  }
  if (flags & DCF_RECORD_EXTENTS) {
    if (x1<*(mem+dc+min_a)(I64 *)) *(mem+dc+min_a)(I64 *)=x1;
    if (x1>*(mem+dc+max_a)(I64 *)) *(mem+dc+max_a)(I64 *)=x1;
    if (x2<*(mem+dc+min_a)(I64 *)) *(mem+dc+min_a)(I64 *)=x2;
    if (x2>*(mem+dc+max_a)(I64 *)) *(mem+dc+max_a)(I64 *)=x2;
    if (y<*(mem+dc+min_c)(I64 *)) *(mem+dc+min_c)(I64 *)=y;
    if (y>*(mem+dc+max_c)(I64 *)) *(mem+dc+max_c)(I64 *)=y;
  }
  if (y<0) return 0;
  if (x2<x1) {
    i=x1;x1=x2;x2=i;
    i=z1;z1=z2;z2=i;
  }
  if (x2<0) return 0;
  if (x1<0) {
    clip_lo=-x1;x1=0;
  }
  if (flags & DCF_SCRN_BITMAP) {
    x1+=*(mem+win+pix_lo_a)(I64 *);
    x2+=*(mem+win+pix_lo_a)(I64 *);
    if (x1>*(mem+win+pix_hi_a)(I64 *)) return 0;
    if (x2>*(mem+win+pix_hi_a)(I64 *)) {
      clip_hi=x2-*(mem+win+pix_hi_a)(I64 *);
      x2=*(mem+win+pix_hi_a)(I64 *);
    }
    y+=*(mem+win+pix_lo_c)(I64 *);
    if (y<0 || y>*(mem+win+pix_hi_c)(I64 *) || x2<0) return 0;
  }
  if (x1>=size_a || y>=size_c) return 0;
  //Depth uses the original endpoints, before either clipping boundary.
  cnt=x2+clip_hi-(x1-clip_lo);
  if (vert) idx=x1*stride+y;
  else idx=y*stride+x1;
  zptr=zbuf+idx*4;
  if (cnt) zslope=(z2-z1)<<32/cnt;
  zacc=z1<<32;
  zacc+=clip_lo*zslope;
  if (x2>=size_a) x2=size_a-1;
  if (flags & DCF_LOCATE_NEAREST) {
    cx=*(mem+dc+cur_a)(I32 *);
    cy=*(mem+dc+cur_c)(I32 *);
    if (x1<=cx<=x2) dist=0;
    else if (cx<x1) {
      dx=x1-cx;dist=dx*dx;
    } else {
      dx=cx-x2;dist=dx*dx;
    }
    dy=y-cy;dist+=dy*dy;
    if (dist<*(mem+dc+of_dc.nearest_dist)(I64 *))
      *(mem+dc+of_dc.nearest_dist)(I64 *)=dist;
  }
  if (flags & DCF_DONT_DRAW) return 0;
  //The screen z-map is a grid of character cells, sampled every eight pixels.
  need_cov=flags & DCF_SCRN_BITMAP && !(flags & DCF_ON_TOP) && win &&
	*(mem+win+of_task.next_task)(U64 *)!=
	*(mem+guest.sys_winmgr_task)(U64 *);
  if (vert) cov_step=80;
  if (need_cov) {
    wzbuf=*(mem+guest.gr_win_z_buf)(U64 *);
    if (wzbuf && wzbuf<mem_size) {
      wzn=*(mem+win+of_task.win_z_num)(U16 *);
      if (vert) cov_row=y>>3;
      else cov_row=y>>3*80;
      char_clear=wzn>=
	    *(mem+wzbuf+(cov_row+x1>>3*cov_step)*2)(U16 *);
    } else
      need_cov=FALSE;
  }
  w1=color_word&0xFFFF;w2=color_word>>16&0xFFFF;cw=w1;
  if (color_word & (ROPF_DITHER|ROPF_PROBABILITY_DITHER)) {
    dither=TRUE;
    w2=w2&0xFF|w1&0xFF00; //Both colors use the first color's operation.
    if (color_word & ROPF_PROBABILITY_DITHER) {
      probability_dither=TRUE;
      if (RasterRand(fsb)<*(mem+dc+of_dc.dither_probability_u16)(U64 *))
	cw=w2;
    } else {
      if ((x1^y)&1) {
	i=w1;w1=w2;w2=i;
      }
      cw=w1;
    }
  }
  if (!vert && !need_cov && !(w1&0xFF00)) {
    dst=mem+body+idx;
    depth=(mem+zptr)(I32 *);
    if (!dither) {
      for (i=x1;i<=x2;i++) {
	cur_z=zacc>>32;
	if (0<=cur_z<=*depth) {
	  *depth=cur_z;
	  *dst=cw;
	  res++;
	}
	dst++;depth++;zacc+=zslope;
      }
      goto sf_done;
    }
    if (probability_dither) {
      for (i=x1;i<=x2;i++) {
	cur_z=zacc>>32;
	if (0<=cur_z<=*depth) {
	  *depth=cur_z;
	  *dst=cw;
	  res++;
	}
	if (RasterRand(fsb)<*(mem+dc+of_dc.dither_probability_u16)(U64 *))
	  cw=w2;
	else
	  cw=w1;
	dst++;depth++;zacc+=zslope;
      }
      goto sf_done;
    }
  }
  for (i=x1;i<=x2;i++) {
    if (char_clear) {
      cur_z=zacc>>32;
      if (cur_z>=0) {
	depth=(mem+zptr)(I32 *);
	if (cur_z<=*depth) {
	  *depth=cur_z;
	  color=cw&0xFF;mode=cw>>8&0xFF;
	  if (mode==ROPB_XOR) mem[body+idx]^=color;
	  else if (mode==ROPB_COLLISION) {
	    color=mem[body+idx];
	    if (color!=TRANSPARENT && color!=bg)
	      (*(mem+dc+of_dc.collision_cnt)(U64 *))++;
	  } else mem[body+idx]=color;
	  res++;
	}
      }
    }
    if (dither) {
      if (probability_dither) {
	if (RasterRand(fsb)<*(mem+dc+of_dc.dither_probability_u16)(U64 *))
	  cw=w2;
	else cw=w1;
      } else {
	color=w1;w1=w2;w2=color;cw=w1;
      }
    }
    if (need_cov && !((i+1)&7) && i+1<=x2)
      char_clear=wzn>=
	    *(mem+wzbuf+(cov_row+(i+1)>>3*cov_step)*2)(U16 *);
    idx+=pix_step;zptr+=pix_step*4;zacc+=zslope;
  }
sf_done:
  return res;
}

#include "Poly"

Bool RenderContextOk(U64 dc)
{//Validate the whole context before any span changes guest state.
  U64 body,zbuf,win,flags,extent,slot;
  I64 width,height,stride,i;
  if (!RenderReadSafe(dc,render_dc_size)) return FALSE;
  body=GuestU64(dc+of_dc.body);zbuf=GuestU64(dc+of_dc.depth_buf);
  width=*(mem+dc+of_dc.width)(I32 *);
  height=*(mem+dc+of_dc.height)(I32 *);
  stride=*(mem+dc+of_dc.width_internal)(I32 *);
  if (!(0<width<=4096) || !(0<height<=4096) || !(width<=stride<=4096))
    return FALSE;
  extent=stride*(height+1);
  if (!RenderRange(body,extent+1) || !RenderRange(zbuf,extent*4+1) ||
	!RenderReadSafe(msr_fsbase,render_task_size)) return FALSE;
  if (GuestU64(msr_fsbase)!=msr_fsbase ||
	RenderOverlap(dc,render_dc_size,msr_fsbase,render_task_size))
    return FALSE;
  if (!RenderWriteSafe(body,extent) || !RenderWriteSafe(zbuf,extent*4) ||
	!RenderWriteSafe(dc,render_dc_size) ||
	!RenderWriteSafe(msr_fsbase+of_task.rand_seed,8)) return FALSE;
  if (RenderOverlap(body,extent,zbuf,extent*4) ||
	RenderOverlap(body,extent,dc,render_dc_size) ||
	RenderOverlap(zbuf,extent*4,dc,render_dc_size) ||
	RenderOverlap(body,extent,msr_fsbase,render_task_size) ||
	RenderOverlap(zbuf,extent*4,msr_fsbase,render_task_size))
    return FALSE;
  if ((GuestU32(dc+of_dc.color)>>8&255)>ROPB_MONO) return FALSE;
  flags=GuestU32(dc+of_dc.flags);
  if (flags & DCF_SCRN_BITMAP) {
    win=GuestU64(dc+of_dc.win_task);
    if (!RenderReadSafe(win,render_task_size) || width>640 || height>480 ||
	  !RenderReadSafe(guest.gr_win_z_buf,8) ||
	  !RenderReadSafe(guest.sys_winmgr_task,8) ||
	  !RenderReadSafe(GuestU64(guest.gr_win_z_buf),80*60*2) ||
	  GuestU64(win+of_task.pix_left)>GuestU64(win+of_task.pix_right) ||
	  GuestU64(win+of_task.pix_right)>=width ||
	  GuestU64(win+of_task.pix_top)>GuestU64(win+of_task.pix_bottom) ||
	  GuestU64(win+of_task.pix_bottom)>=height)
      return FALSE;
    if (RenderOverlap(body,extent,win,render_task_size) ||
	  RenderOverlap(zbuf,extent*4,win,render_task_size) ||
	  RenderOverlap(dc,render_dc_size,win,render_task_size) ||
	  win!=msr_fsbase && RenderOverlap(msr_fsbase+of_task.rand_seed,8,
	  win,render_task_size)) return FALSE;
    for (i=0;i<2;i++) {
      if (i) slot=guest.sys_winmgr_task;
      else slot=guest.gr_win_z_buf;
      if (RenderOverlap(body,extent,slot,8) ||
	    RenderOverlap(zbuf,extent*4,slot,8) ||
	    RenderOverlap(dc,render_dc_size,slot,8) ||
	    RenderOverlap(msr_fsbase+of_task.rand_seed,8,slot,8))
	return FALSE;
    }
    if (!(-0x40000000<=*(mem+win+of_task.scroll_x)(I64 *)<=0x40000000) ||
	  !(-0x40000000<=*(mem+win+of_task.scroll_y)(I64 *)<=0x40000000) ||
	  !(-0x40000000<=*(mem+win+of_task.scroll_z)(I64 *)<=0x40000000))
      return FALSE;
  }
  return TRUE;
}

Bool RenderBlit8()
{
  U64 dst=GuestU64(reg[4]+8),src=GuestU64(reg[4]+16),sb,db;
  I64 width,height,n,i,value;
  if (!RenderReadSafe(src,render_dc_size) ||
	!RenderReadSafe(dst,render_dc_size)) return FALSE;
  width=*(mem+src+of_dc.width_internal)(I32 *);
  height=*(mem+src+of_dc.height)(I32 *);
  n=width*height;
  sb=GuestU64(src+of_dc.body);db=GuestU64(dst+of_dc.body);
  if (width<=0 || height<=0 || !RenderReadSafe(sb,n) || !RenderRange(db,n))
    return FALSE;
  if (!RenderWriteSafe(db,n)) return FALSE;
  for (i=0;i<n;i++) {
    value=mem[sb+i];
    if (value!=TRANSPARENT) mem[db+i]=value;
  }
  reg[0]=n;
  reg[1]=width;reg[2]=0;
  Arith(7,n,n,8);
  rip=GuestU64(reg[4]);reg[4]+=24;
  return TRUE;
}

Bool RenderTriangle()
{//Keep fan construction and transformation callbacks in GrFillPoly3.
  U64 dc=GuestU64(reg[4]+8),points[3],body,zbuf,extent;
  CPolyPt pt[3];
  I64 i,j,res,scroll_z;
  for (i=4;i<8;i++)
    if (!RenderCodeOk(i)) return FALSE;
  for (i=0;i<3;i++) {
    points[i]=GuestU64(reg[4]+16+i*8);
    if (!RenderReadSafe(points[i],12)) return FALSE;
    pt[i].x=*(mem+points[i])(I32 *);
    pt[i].y=*(mem+points[i]+4)(I32 *);
    pt[i].z=*(mem+points[i]+8)(I32 *);
    if (!(-0x100000<=pt[i].x<=0x100000) ||
	  !(-0x100000<=pt[i].y<=0x100000) ||
	  !(-0x7FEFFFFF<=pt[i].z<=0x7FEFFFFF)) return FALSE;
    for (j=0;j<i;j++)
      if (!(-0x100000<=pt[i].z-pt[j].z<=0x100000)) return FALSE;
  }
  if (!RenderContextOk(dc)) return FALSE;
  if (GuestU32(dc+of_dc.flags)&DCF_SCRN_BITMAP) {
    scroll_z=*(mem+GuestU64(dc+of_dc.win_task)+of_task.scroll_z)(I64 *);
    for (i=0;i<3;i++)
      if (!(-0x7FEFFFFF<=pt[i].z+scroll_z<=0x7FEFFFFF)) return FALSE;
  }
  body=GuestU64(dc+of_dc.body);zbuf=GuestU64(dc+of_dc.depth_buf);
  extent=GuestU32(dc+of_dc.width_internal)*(GuestU32(dc+of_dc.height)+1);
  for (i=0;i<3;i++)
    if (RenderOverlap(points[i],12,body,extent) ||
	  RenderOverlap(points[i],12,zbuf,extent*4) ||
	  RenderOverlap(points[i],12,dc,render_dc_size) ||
	  RenderOverlap(points[i],12,msr_fsbase+of_task.rand_seed,8))
      return FALSE;
  res=PolyTri(dc,pt[0].x,pt[0].y,pt[0].z,pt[1].x,pt[1].y,pt[1].z,
	pt[2].x,pt[2].y,pt[2].z);
  reg[0]=res;rip=GuestU64(reg[4]);reg[4]+=40;
  return TRUE;
}

I64 RenderTry()
{//One entry check serves the interpreter and compiled dispatcher.
  I64 index,x1,x2,y,z1,z2,res;
  U64 dc;
  if (!render_fast || !render_ready || reg[4]<RENDER_FRAME_SIZE ||
	!RenderRange(reg[4],56)) return 0;
  for (index=0;index<RENDER_CODE_NUM;index++)
    if (render_code[index].addr && RenderOverlap(reg[4]-RENDER_FRAME_SIZE,
	  RENDER_FRAME_SIZE,render_code[index].addr,render_code[index].size))
      return 0;
  for (index=0;index<RENDER_CODE_NUM;index++)
    if ((index<6 || index==8) && rip==render_code[index].addr &&
	  RenderCodeOk(index)) {
      if (!index) res=RenderBlit8;
      else if (index<4) res=VideoTry;
      else if (index==8) res=RenderTriangle;
      else {
	if (!RenderCodeOk(6) || !RenderCodeOk(7)) return 0;
	dc=GuestU64(reg[4]+8);
	if (index==4) {
	  x1=GuestU64(reg[4]+16);x2=GuestU64(reg[4]+24);
	  y=GuestU64(reg[4]+32);
	} else {
	  y=GuestU64(reg[4]+16);x1=GuestU64(reg[4]+24);
	  x2=GuestU64(reg[4]+32);
	}
	z1=GuestU64(reg[4]+40);z2=GuestU64(reg[4]+48);
	if (!(-0x40000000<=x1<=0x40000000) ||
	      !(-0x40000000<=x2<=0x40000000) ||
	      !(-0x40000000<=y<=0x40000000) ||
	      !(-0x40000000<=z1<=0x40000000) ||
	      !(-0x40000000<=z2<=0x40000000) ||
	      !RenderContextOk(dc)) return 0;
	res=SpanFill(dc,index==5,x1,x2,y,z1,z2);
	if (res<0) return 0;
	res=RasterDone(res);
      }
      if (res) render_calls[index]++;
      return res;
    }
  return 0;
}
