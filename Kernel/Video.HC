U64 video_image;
U64 video_spread[256];
Bool video_ready;

U0 VideoTablesInit()
{//Expand each plane byte into eight one-bit pixel bytes.
  I64 i,j;
  for (i=0;i<256;i++)
    for (j=0;j<8;j++)
      video_spread[i]|=(i>>j&1)<<(j*8);
  video_ready=TRUE;
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
