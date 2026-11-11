//The integer edge walk in V5.03 Adam/Gr/GrPrimatives.HC:GrFillTri0.
//Transpose the points for the vertical case; both use the same edge walk.

class CPolyPt
{
  I64 x,y,z;
};

I64 PolyTri(U64 dc,I64 ax,I64 ay,I64 az,I64 bx,I64 by,I64 bz,
      I64 cx,I64 cy,I64 cz)
{
  I64 x1,x2,y1,z1,z2,dx1,dy1,dz1,dx2,dy2,dz2,res=0,i,min,max,
	sa,pa,pb,off;
  U64 win;
  CPolyPt pts[3],*p1=&pts[0],*p2=&pts[1],*p4=&pts[2],*tmpp;
  Bool vert=AbsI64(ay-by)+AbsI64(ay-cy)>
	AbsI64(ax-bx)+AbsI64(ax-cx);
  if (vert) {
    p1->x=ay;p1->y=ax;
    p2->x=by;p2->y=bx;
    p4->x=cy;p4->y=cx;
  } else {
    p1->x=ax;p1->y=ay;
    p2->x=bx;p2->y=by;
    p4->x=cx;p4->y=cy;
  }
  p1->z=az;p2->z=bz;p4->z=cz;
  if (p4->x<p2->x) {
    tmpp=p4;p4=p2;p2=tmpp;
  }
  if (p2->x<p1->x) {
    tmpp=p2;p2=p1;p1=tmpp;
  }

  if (p4->y<p2->y) {
    tmpp=p4;p4=p2;p2=tmpp;
  }

  min=0;
  if (vert) {
    max=RdMem(dc+of_dc.width,4);
    sa=of_task.scroll_x;pa=of_task.pix_left;pb=of_task.pix_right;
  } else {
    max=RdMem(dc+of_dc.height,4);
    sa=of_task.scroll_y;pa=of_task.pix_top;pb=of_task.pix_bottom;
  }
  if (RdMem(dc+of_dc.flags,4)&0x4000) {
    win=RdMem(dc+of_dc.win_task,8);
    off=RdMem(win+sa,8)+RdMem(win+pa,8);
    min-=off;
    max-=off;
    if (max>RdMem(win+pb,8)-off)
      max=RdMem(win+pb,8)-off;
  }

  if ((dy2=p4->y-p1->y)<0) {
    dy1=p2->y-p1->y;
    dx1=(p1->x-p2->x)<<32;dx1/=dy1;
    dz1=(p1->z-p2->z)<<32;dz1/=dy1;

    dx2=(p1->x-p4->x)<<32;dx2/=dy2;
    dz2=(p1->z-p4->z)<<32;dz2/=dy2;
    x1=x2=p1->x<<32; y1=p1->y; z1=z2=p1->z<<32;
    if (y1+dy2<min) {
      i=min-(y1+dy2);
      if (i>-dy2) return res;
      dy2+=i;
    }
    if (y1>=max) {
      i=y1-max+1;
      if (i>-dy2)
	i=-dy2;
      dy2+=i;
      y1-=i;
      x1+=dx1*i;
      x2+=dx2*i;
      z1+=dz1*i;
      z2+=dz2*i;
    }
    while (dy2++) {
      res+=SpanFill(dc,vert,x1.i32[1],x2.i32[1],y1,z1.i32[1],z2.i32[1]);
      y1--;
      x1+=dx1;
      x2+=dx2;
      z1+=dz1;
      z2+=dz2;
    }
    if (dy2=p2->y-p4->y) {
      dx2=(p4->x-p2->x)<<32;dx2/=dy2;
      dz2=(p4->z-p2->z)<<32;dz2/=dy2;
      if (y1+dy2<min) {
	i=min-(y1+dy2);
	if (i>-dy2) return res;
	dy2+=i;
      }
      if (y1>=max) {
	i=y1-max+1;
	if (i>-dy2) return res;
	dy2+=i;
	y1-=i;
	x1+=dx1*i;
	x2+=dx2*i;
	z1+=dz1*i;
	z2+=dz2*i;
      }
    }
    while (dy2++<=0) {
      res+=SpanFill(dc,vert,x1.i32[1],x2.i32[1],y1,z1.i32[1],z2.i32[1]);
      y1--;
      x1+=dx1;
      x2+=dx2;
      z1+=dz1;
      z2+=dz2;
    }
  } else if ((dy2=p2->y-p1->y)>0) {
    dy1=p4->y-p1->y;
    dx1=(p4->x-p1->x)<<32;dx1/=dy1;
    dz1=(p4->z-p1->z)<<32;dz1/=dy1;

    dx2=(p2->x-p1->x)<<32;dx2/=dy2;
    dz2=(p2->z-p1->z)<<32;dz2/=dy2;
    x1=x2=p1->x<<32; y1=p1->y; z1=z2=p1->z<<32;
    if (y1+dy2>=max) {
      i=y1+dy2-max+1;
      if (i>dy2) return res;
      dy2-=i;
    }
    if (y1<min) {
      i=min-y1;
      if (i>dy2)
	i=dy2;
      dy2-=i;
      y1+=i;
      x1+=dx1*i;
      x2+=dx2*i;
      z1+=dz1*i;
      z2+=dz2*i;
    }
    while (dy2--) {
      res+=SpanFill(dc,vert,x1.i32[1],x2.i32[1],y1,z1.i32[1],z2.i32[1]);
      y1++;
      x1+=dx1;
      x2+=dx2;
      z1+=dz1;
      z2+=dz2;
    }
    if (dy2=p4->y-p2->y) {
      dx2=(p4->x-p2->x)<<32;dx2/=dy2;
      dz2=(p4->z-p2->z)<<32;dz2/=dy2;
      if (y1+dy2>=max) {
	i=y1+dy2-max+1;
	if (i>dy2) return res;
	dy2-=i;
      }
      if (y1<min) {
	i=min-y1;
	if (i>dy2) return res;
	dy2-=i;
	y1+=i;
	x1+=dx1*i;
	x2+=dx2*i;
	z1+=dz1*i;
	z2+=dz2*i;
      }
    }
    while (dy2-->=0) {
      res+=SpanFill(dc,vert,x1.i32[1],x2.i32[1],y1,z1.i32[1],z2.i32[1]);
      y1++;
      x1+=dx1;
      x2+=dx2;
      z1+=dz1;
      z2+=dz2;
    }
  } else {
    if (dy1=p2->y-p1->y) {
      dx1=(p2->x-p1->x)<<32;dx1/=dy1;
      dz1=(p2->z-p1->z)<<32;dz1/=dy1;
      if (dy2=p2->y-p4->y) {
	dx2=(p2->x-p4->x)<<32;dx2/=dy2;
	dz2=(p2->z-p4->z)<<32;dz2/=dy2;
      } else {
	dx2=0;
	dz2=0;
      }
      x1=x2=p2->x<<32; y1=p2->y; z1=z2=p2->z<<32;
      if (y1<min) {
	i=min-y1;
	if (i>-dy1)
	  i=-dy1;
	dy1+=i;
	y1+=i;
	x1+=dx1*i;
	x2+=dx2*i;
	z1+=dz1*i;
	z2+=dz2*i;
      }
      while (dy1++<=0) {
	if (y1<max)
	  res+=SpanFill(dc,vert,x1.i32[1],x2.i32[1],y1,z1.i32[1],z2.i32[1]);
	y1++;
	x1+=dx1;
	x2+=dx2;
	z1+=dz1;
	z2+=dz2;
      }
    }
    if (dy1=p4->y-p1->y) {
      dx1=(p1->x-p4->x)<<32;dx1/=dy1;
      dz1=(p1->z-p4->z)<<32;dz1/=dy1;
      if (dy2=p4->y-p2->y) {
	dx2=(p2->x-p4->x)<<32;dx2/=dy2;
	dz2=(p2->z-p4->z)<<32;dz2/=dy2;
      } else {
	dx2=0;
	dz2=0;
      }
      x1=x2=p4->x<<32; y1=p4->y; z1=z2=p4->z<<32;
      if (y1-dy1<min) {
	i=min-(y1-dy1);
	if (i>dy1) return res;
	dy1-=i;
      }
      if (y1>=max) {
	i=y1-max+1;
	if (i>dy1) return res;
	dy1-=i;
	y1-=i;
	x1+=dx1*i;
	x2+=dx2*i;
	z1+=dz1*i;
	z2+=dz2*i;
      }
      while (dy1-->=0) {
	res+=SpanFill(dc,vert,x1.i32[1],x2.i32[1],y1,z1.i32[1],z2.i32[1]);
	y1--;
	x1+=dx1;
	x2+=dx2;
	z1+=dz1;
	z2+=dz2;
      }
    }
  }
  return res;
}
