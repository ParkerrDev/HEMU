U64 g_raster_hle[2],g_poly3_hle,g_dc_transform;
I64 g_raster_n,g_raster_calls,g_poly3_calls;
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
  Bool dither=FALSE,probability_dither=FALSE,need_cov,char_clear=TRUE,
	draw;
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
  //Reject before consuming randomness; the native fallback draws once.
  if (idx<0 || x2<x1 || x2-x1+1>4096 || !body ||
	body+idx+(x2-x1+1)*pix_step>=mem_size ||
	zbuf+(idx+(x2-x1+1)*pix_step)*4>=mem_size)
    return -1;
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
  for (i=x1;i<=x2;i++) {
    if (char_clear) {
      cur_z=zacc>>32;
      draw=TRUE;
      if (cur_z<0 || cur_z>*(mem+zptr)(I32 *)) draw=FALSE;
      else *(mem+zptr)(I32 *)=cur_z;
      if (draw) {
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
  g_raster_calls++;
  return res;
}
#include "poly"

I64 PolyDone(I64 cnt)
{//Return from GrFillPoly3, discarding its three stack arguments.
  reg[0]=cnt;
  rip=RdMem(reg[4],8);
  reg[4]+=32;
  return 1;
}

I64 GrPoly3HLE()
{//Fan triangles in screen coordinates; transforms stay in guest code.
  U64 dc=RdMem(reg[4]+8,8),poly=RdMem(reg[4]+24,8),body,zbuf,rmat,
	flags,width,height,stride,extent;
  I64 n=RdMem(reg[4]+16,8),i,ax,ay,az,bx,by,bz,cx,cy,cz,res=0;
  body=*(mem+dc+of_dc.body)(U64 *);
  zbuf=*(mem+dc+of_dc.depth_buf)(U64 *);
  flags=*(mem+dc+of_dc.flags)(U32 *);
  if (flags&0x600) return 0;
  if (flags&0x100 && RdMem(dc+of_dc.transform,8)!=g_dc_transform)
    return 0;
  if (n<3 || n>64 || !body || !zbuf || poly+n*12>=mem_size)
    return 0;
  //A rejected span cannot undo earlier triangles. Check the whole context.
  width=*(mem+dc+of_dc.width)(I32 *);
  height=*(mem+dc+of_dc.height)(I32 *);
  stride=*(mem+dc+of_dc.width_internal)(I32 *);
  if (!width || !height || width>4096 || height>4096 ||
	stride<width || stride>mem_size || body>=mem_size || zbuf>=mem_size)
    return 0;
  extent=stride*(height+1);
  if (extent>=mem_size-body || extent>=(mem_size-zbuf)/4)
    return 0;
  //Only the native identity transform can be skipped.
  if (*(mem+dc+of_dc.x)(I32 *) || *(mem+dc+of_dc.y)(I32 *) ||
	*(mem+dc+of_dc.z)(I32 *))
    return 0;
  rmat=*(mem+dc+of_dc.r)(U64 *);
  if (!rmat) return 0;
  for (i=0;i<16;i++) {
    if (i==0 || i==5 || i==10 || i==15) {
      if (*(mem+rmat+i*8)(I64 *)!=0x100000000) return 0;
    } else if (*(mem+rmat+i*8)(I64 *)) return 0;
  }
  ax=*(mem+poly)(I32 *);
  ay=*(mem+poly+4)(I32 *);
  az=*(mem+poly+8)(I32 *);
  for (i=1;i<n-1;i++) {
    bx=*(mem+poly+i*12)(I32 *);
    by=*(mem+poly+i*12+4)(I32 *);
    bz=*(mem+poly+i*12+8)(I32 *);
    cx=*(mem+poly+(i+1)*12)(I32 *);
    cy=*(mem+poly+(i+1)*12+4)(I32 *);
    cz=*(mem+poly+(i+1)*12+8)(I32 *);
    res+=PolyTri(dc,ax,ay,az,bx,by,bz,cx,cy,cz);
  }
  g_poly3_calls++;
  return PolyDone(res);
}

I64 RasterHLE()
{//The named guest primitives share one span filler.
  U64 dc;
  I64 vert,x1,x2,y,z1,z2,res;
  if (VideoHLE) return 1;
  if (g_poly3_hle && rip==g_poly3_hle)
    return GrPoly3HLE;
  if (g_raster_n!=2)
    return 0;
  if (rip==g_raster_hle[0])
    vert=FALSE;
  else if (rip==g_raster_hle[1])
    vert=TRUE;
  else
    return 0;
  dc=RdMem(reg[4]+8,8);
  if (vert) {
    y=RdMem(reg[4]+0x10,8);
    x1=RdMem(reg[4]+0x18,8);
    x2=RdMem(reg[4]+0x20,8);
  } else {
    x1=RdMem(reg[4]+0x10,8);
    x2=RdMem(reg[4]+0x18,8);
    y=RdMem(reg[4]+0x20,8);
  }
  z1=RdMem(reg[4]+0x28,8);
  z2=RdMem(reg[4]+0x30,8);
  res=SpanFill(dc,vert,x1,x2,y,z1,z2);
  if (res<0)
    return 0;
  return RasterDone(res);
}
