U64 win_rate_pool,win_rate_clamp,win_rate_fmt,win_rate_old[4];
U8 win_rate_text[128];

Bool WinRateFind()
{//Validate V5.03's constants inside the two named guest functions.
  U64 a,start=GuestFun("WinMgrSleep"),pool=0,clamp=0,fmt=0;
  I64 i,np=0,nc=0,nf=0;
  F64 d,p,q;
  if (!start || start+4096>=mem_size) return FALSE;
  for (a=start;a<start+4096;a++) {
    d=BitsToF64(GuestU64(a));
    p=BitsToF64(GuestU64(a+8));
    q=BitsToF64(GuestU64(a+16));
    if (Abs(d-0.01)<1e-15 && Abs(p-1001/240000.0)<1e-15 &&
	  Abs(q-1001/30000.0)<1e-15) {
      pool=a;
      np++;
    }
    if (a>=start+2 && mem[a-2]==0x48 &&
	  mem[a-1]>=0xB8 && mem[a-1]<=0xBF && d==99.0) {
      clamp=a;
      nc++;
    }
  }
  start=GuestFun("WallPaper");
  if (!start || start+4096>=mem_size) return FALSE;
  for (a=start;a<start+4096;a++)
    if (GuestU64(a)==0x667432253A535046) {
      fmt=a;
      nf++;
    }
  if (np!=1 || nc!=1 || nf!=1) return FALSE;
  for (i=0;i<127 && mem[fmt+i];i++);
  if (i==127) return FALSE;
  MemCpy(win_rate_text,mem+fmt,i+1);
  win_rate_pool=pool;win_rate_clamp=clamp;win_rate_fmt=fmt;
  for (i=0;i<3;i++) win_rate_old[i]=GuestU64(pool+i*8);
  win_rate_old[3]=GuestU64(clamp);
  return TRUE;
}

Bool WinRateSet(I64 rate)
{//0 uses the timer's 1ms quantum. 30 restores the stock guest constants.
  I64 i;
  F64 period;
  if (rate!=0 && rate!=30 && rate!=60 && rate!=120) return FALSE;
  if (!win_rate_pool && !WinRateFind) return FALSE;
  if (rate==30) {
    for (i=0;i<3;i++)
      WrMem(win_rate_pool+i*8,8,win_rate_old[i]);
    WrMem(win_rate_clamp,8,win_rate_old[3]);
    for (i=0;win_rate_text[i];i++) mem[win_rate_fmt+i]=win_rate_text[i];
    mem[win_rate_fmt+i]=0;
  } else {
    period=0.001;
    if (rate) period=1.0/rate;
    WrMem(win_rate_pool,8,F64ToBits(0.0000001));
    WrMem(win_rate_pool+8,8,F64ToBits(period/8));
    WrMem(win_rate_pool+16,8,F64ToBits(period));
    WrMem(win_rate_clamp,8,F64ToBits(9999.0));
    MemCpy(mem+win_rate_fmt,"FPS%3tf",7);
    for (i=8;win_rate_text[i];i++)
      mem[win_rate_fmt+i-1]=win_rate_text[i];
    mem[win_rate_fmt+i-1]=0;
  }
  //The old pacing grid belongs to the previous setting.
  WrMem(guest.winmgr_ideal_refresh_tS,8,
	GuestU64(guest.winmgr_last_refresh_tS));
  return TRUE;
}
