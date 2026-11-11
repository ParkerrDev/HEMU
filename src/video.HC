U64 video_blot,video_line,video_flush,video_image,video_reverse;
U64 video_spread[256];
I64 video_calls;
Bool video_ready;

U0 VideoTablesInit()
{//Expand each plane byte into eight one-bit pixel bytes.
  I64 i,j;
  for (i=0;i<256;i++)
    for (j=0;j<8;j++)
      video_spread[i]|=(i>>j&1)<<j*8;
  video_ready=TRUE;
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
	mem[dst+p*cnt+i]=b*0x0102040810204080>>56;
      }
    }
  }
}

U0 VideoLine(U64 vga_arg,U64 src_arg,I64 cnt,U64 dst_arg,Bool flush)
{//The line writer also maintains the OS's screen image and pointers.
  U64 vga=GuestU64(vga_arg),src=GuestU64(src_arg),
	dst=GuestU64(dst_arg),table=GuestU64(video_reverse),v,b;
  I64 i,j,k;
  for (i=0;i<cnt;i++) {
    v=GuestU64(src+i*8);
    if (flush || v!=GuestU64(dst+i*8)) {
      WrMem(dst+i*8,8,v);
      b=0;
      for (j=0;j<8;j++) {
	k=v>>j*8&255;
	b|=mem[table+k]<<j*8;
      }
      WrMem(vga+i*8,8,b);
    }
  }
  WrMem(vga_arg,8,vga+cnt*8);
  WrMem(src_arg,8,src+cnt*8);
  WrMem(dst_arg,8,dst+cnt*8);
}

Bool VideoHLE()
{//Named graphics primitives; invalid ranges fall back to guest code.
  U64 a,b,d,ret=GuestU64(reg[4]),src,dst,v,carry=0;
  Bool changed;
  I64 cnt;
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
    v=GuestU64(b+(cnt-1)*8);
    changed=v!=GuestU64(d+(cnt-1)*8);
    VideoBlot4(a,b,d,cnt);
    reg[0]=v;
    reg[3]=d+cnt*8;
    reg[2]=v;
    if (changed)
      reg[2]=(v>>3&0x0101010101010101)*0x0102040810204080>>56;
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
    VideoLine(a,b,cnt,d,rip==video_flush);
    reg[0]=b;
    reg[3]=GuestU64(video_reverse);
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

U0 VideoCapture()
{//The completed planar screen image includes TempleOS's native zoom.
  U64 dc=GuestU64(video_image),src=GuestU64(dc+of_dc.body),*dst=g_desk;
  I64 i;
  if (!dc || dc>=mem_size || GuestU32(dc+of_dc.width_internal)!=640 ||
	GuestU32(dc+of_dc.height)!=480 || !src || src>=mem_size ||
	src+153600>mem_size)
    return;
  if (!__capture_lock) return;
  if (!video_ready) VideoTablesInit;
  for (i=0;i<38400;i++)
    dst[i]=video_spread[mem[src+i]]|video_spread[mem[src+38400+i]]<<1|
	  video_spread[mem[src+76800+i]]<<2|
	  video_spread[mem[src+115200+i]]<<3;
  g_desk_ready=1;
  g_desk_seq++;
  __capture_unlock;
}
