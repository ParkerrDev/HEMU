#define TRIANGLE_SHAPE_NUM 12
#define TRIANGLE_CASE_NUM 640
#define TRIANGLE_VALUE_NUM 13

I32 triangle_pts[TRIANGLE_SHAPE_NUM][9]={
  {2,3,40,25,7,170,9,20,320},
  {3,2,40,7,21,170,20,9,320},
  {3,5,40,27,5,170,10,21,320},
  {3,19,40,27,19,170,10,2,-70},
  {5,2,40,5,21,170,25,10,320},
  {2,2,40,10,10,170,20,20,320},
  {11,9,40,11,9,40,11,9,40},
  {4,6,40,24,17,170,4,6,320},
  {-20,-15,-70,44,7,170,8,39,320},
  {-30,2,40,-8,20,170,-4,5,320},
  {28,22,40,29,22,170,28,23,320},
  {0,0,-40,28,1,170,0,1,320}
};
I64 triangle_orders[6][3]={
  {0,1,2},{0,2,1},{1,0,2},{1,2,0},{2,0,1},{2,1,0}
};
I32 triangle_fan[6][3]={
  {3,2,40},{20,2,90},{27,10,180},
  {20,20,300},{3,20,200},{-4,10,100}
};
I32 triangle_depths[8][3]={
  {0x4000002E,0x40000040,0x40000060},
  {0x7FEFFFFF,0x7FEFFF8F,0x7FEFFFCF},
  {-0x7FEFFFC3,-0x7FEFFFDF,-0x7FEFFFEF},
  {-0x7FEFFFFF,-0x7FEFFF8F,-0x7FEFFFCF},
  {0x7FEFFFFF,0x7FDFFFFF,0x7FE7FFFF},
  {0x7FEFFFFF,0x7FDFFFFE,0x7FE7FFFF},
  {0x7FF00000,0x7FEFFF8F,0x7FEFFFCF},
  {-0x7FF00000,-0x7FEFFF8F,-0x7FEFFFCF}
};
U64 triangle_colors[6]={12,0x10C,0x20C,0x4004000C,0x8004000C,12},
  triangle_res[TRIANGLE_CASE_NUM*TRIANGLE_VALUE_NUM];
I64 triangle_cnt,triangle_transform_cnt;

U64 TriangleHash(U8 *src,I64 cnt)
{
  U64 res=0xCBF29CE484222325;
  while (cnt--) {
    res^=*src++;
    res*=0x100000001B3;
  }
  return res;
}

U0 TriangleTransform(CDC *,I64 *_x,I64 *_y,I64 *_z)
{//The polygon wrapper must still call a guest-defined transformation.
  *_x=*_x*2+3;
  *_y+=4;
  *_z+=20;
  triangle_transform_cnt++;
}

U0 TriangleRst(CDC *dc,I64 mode)
{
  I64 i,size=dc->width_internal*(dc->height+1);
  for (i=0;i<size;i++) {
    dc->body[i]=i%16;
    if (!(i%13)) dc->body[i]=TRANSPARENT;
    dc->depth_buf[i]=70+i%7*80;
  }
  dc->color=triangle_colors[mode];dc->bkcolor=7;
  dc->dither_probability_u16=25123;
  dc->flags=DCF_RECORD_EXTENTS|DCF_LOCATE_NEAREST;
  if (mode==5) dc->flags|=DCF_DONT_DRAW;
  dc->min_x=dc->min_y=I64_MAX;
  dc->max_x=dc->max_y=I64_MIN;
  dc->cur_x=17;dc->cur_y=11;
  dc->nearest_dist=I64_MAX;dc->collision_cnt=0;
  Fs->rand_seed=0x123456789ABCDEF0;
  triangle_transform_cnt=0;
}

U0 TriangleRecord(CDC *dc,I64 res,CD3I32 *poly,I64 n)
{//Include row padding, a spare row and the caller's unmodified vertices.
  I64 size=dc->width_internal*(dc->height+1);
  U64 *dst=&triangle_res[triangle_cnt*TRIANGLE_VALUE_NUM];
  *dst++=triangle_cnt++;*dst++=res;*dst++=Fs->rand_seed;
  *dst++=TriangleHash(dc->body,size);
  *dst++=TriangleHash(dc->depth_buf,size*4);
  *dst++=dc->collision_cnt;*dst++=dc->nearest_dist;
  *dst++=dc->min_x;*dst++=dc->max_x;
  *dst++=dc->min_y;*dst++=dc->max_y;
  *dst++=triangle_transform_cnt;
  *dst++=TriangleHash(poly,n*sizeof(CD3I32));
}

CDC *TriangleNew()
{
  CDC *dc=DCNew(29,23);
  I64 size=dc->width_internal*(dc->height+1);
  Free(dc->body);dc->body=MAlloc(size);
  dc->depth_buf=MAlloc(size*4);
  return dc;
}

U0 TriangleDepth(I64 shape,I64 order)
{//Large common depths need not imply a large interpolation spread.
  I64 i,j,size,res,depth=triangle_depths[shape][0];
  U64 old_seed=Fs->rand_seed,old_flags=Fs->task_flags;
  CDC *dc=TriangleNew;
  CD3I32 poly[3];
  Bts(&Fs->task_flags,TASKf_NONTIMER_RAND);
  TriangleRst(dc,4);
  size=dc->width_internal*(dc->height+1);
  if (depth<0) depth=0;
  for (i=0;i<size;i++)
    dc->depth_buf[i]=depth-0x80000+i%7*0x20000;
  for (i=0;i<3;i++) {
    j=triangle_orders[order][i];
    MemCpy(&poly[i],&triangle_pts[0][j*3],sizeof(CD3I32));
    poly[i].z=triangle_depths[shape][j];
    if (!shape && !j) {
      poly[i].x=1236;poly[i].y=668;
    }
  }
  res=GrFillTri0(dc,&poly[0],&poly[1],&poly[2]);
  TriangleRecord(dc,res,poly,3);
  Fs->rand_seed=old_seed;Fs->task_flags=old_flags;
  DCDel(dc);
}

U0 TriangleNative()
{
  I64 shape,order,mode,n,rev,kind,i,j,res;
  U64 old_seed=Fs->rand_seed,old_flags=Fs->task_flags,*dst;
  CDC *dc=TriangleNew;
  CD3I32 poly[6];
  triangle_cnt=0;
  Bts(&Fs->task_flags,TASKf_NONTIMER_RAND);
  for (shape=0;shape<TRIANGLE_SHAPE_NUM;shape++)
    for (order=0;order<6;order++)
      for (mode=0;mode<6;mode++) {
	for (i=0;i<3;i++)
	  MemCpy(&poly[i],&triangle_pts[shape]
		[triangle_orders[order][i]*3],sizeof(CD3I32));
	TriangleRst(dc,mode);
	res=GrFillTri0(dc,&poly[0],&poly[1],&poly[2]);
	TriangleRecord(dc,res,poly,3);
      }
  for (n=3;n<=6;n++)
    for (rev=0;rev<2;rev++)
      for (kind=0;kind<4;kind++)
	for (mode=0;mode<5;mode++) {
	  for (i=0;i<n;i++) {
	    j=i;
	    if (rev) j=n-1-i;
	    MemCpy(&poly[i],triangle_fan[j],sizeof(CD3I32));
	  }
	  TriangleRst(dc,mode);
	  if (kind) {
	    dc->flags|=DCF_TRANSFORMATION;
	    dc->transform=&TriangleTransform;
	  }
	  if (kind>=2) {
	    dc->flags|=DCF_SYMMETRY;
	    DCSymmetrySet(dc,14,0,14,22);
	  }
	  if (kind==3) dc->flags|=DCF_JUST_MIRROR;
	  res=GrFillPoly3(dc,n,poly);
	  TriangleRecord(dc,res,poly,n);
	}
  for (shape=0;shape<8;shape++)
    for (order=0;order<6;order++)
      TriangleDepth(shape,order);
  Fs->rand_seed=old_seed;Fs->task_flags=old_flags;
  DCDel(dc);
  for (i=0;i<triangle_cnt;i++) {
    dst=&triangle_res[i*TRIANGLE_VALUE_NUM];
    for (j=0;j<TRIANGLE_VALUE_NUM;j++)
      "%016X ",*dst++;
    '\n';
  }
}

TriangleNative;
