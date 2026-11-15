U8 *dsk_tmp=NULL;
I64 dsk_info[3];

U8 *DskTmp(I64 size)
{
  U8 *res=MAlloc(size+8);
  *res(U8 **)=dsk_tmp;dsk_tmp=res;
  return res+8;
}

U0 DskTmpDel()
{
  U8 *next;
  while (dsk_tmp) {
    next=*dsk_tmp(U8 **);
    Free(dsk_tmp);dsk_tmp=next;
  }
}

U64 DskBig(U8 *buf,I64 size)
{
  U64 res=0;
  while (size--)
    res=res<<8|*buf++;
  return res;
}

I64 DskClusOff(U64 entry,I64 size,I64 bytes,Bool zero)
{
  U64 mask=0x00FFFFFFFFFFFE00,allowed=mask|0x8000000000000000;
  I64 off=entry&mask;
  if (zero) allowed|=1;
  if (entry&0x4000000000000000)
    DskFail("compressed cluster");
  if (entry&~allowed)
    DskFail("reserved cluster bits");
  if (!off && entry&0x8000000000000000 ||
      off && (off%size || off>bytes-size))
    DskFail("cluster bounds");
  return off;
}

I64 *DskInfo(I64 bytes)
{//Only image metadata crosses the host boundary. Disk bytes stay outside RAM.
  U8 buf[104],*l1,*l2;
  I64 version,bits,size,entries,virtual_size,l1_cnt,l1_off,
	clusters,tables,i,j,off,n;
  dsk_info[0]=bytes;dsk_info[1]=dsk_info[2]=0;
  if (bytes<512 || bytes%512) DskFail("disk sector size");
  DskImageRead(0,104,buf);
  if (DskBig(buf,4)!=0x514649FB) return dsk_info;
  version=DskBig(buf+4,4);bits=DskBig(buf+20,4);
  virtual_size=DskBig(buf+24,8);l1_cnt=DskBig(buf+36,4);
  l1_off=DskBig(buf+40,8);
  if (version!=2 && version!=3) DskFail("version");
  if (!(9<=bits<=21)) DskFail("cluster size");
  size=1<<bits;entries=size/8;
  if (DskBig(buf+8,8)) DskFail("backing files require a standalone image");
  if (DskBig(buf+32,4)) DskFail("encrypted disk");
  if (!(512<=virtual_size<=0x1FFFFFFFFFFFFF) || virtual_size%512)
    DskFail("disk sector size");
  if (version==3) {
    if (DskBig(buf+72,8)) DskFail("incompatible feature flags");
    n=DskBig(buf+100,4);
    if (!(104<=n<=size) || n%8 || n>bytes) DskFail("header length");
  }
  clusters=(virtual_size+size-1)/size;
  tables=(clusters+entries-1)/entries;
  if (tables>l1_cnt || !(size<=l1_off<=bytes) ||
      l1_off%size || l1_cnt>(bytes-l1_off)/8)
    DskFail("L1 table bounds");
  l1=DskTmp(tables*8);l2=DskTmp(size);
  DskImageRead(l1_off,tables*8,l1);
  for (i=0;i<tables;i++) {
    off=DskClusOff(DskBig(l1+i*8,8),size,bytes,FALSE);
    if (off) {
      n=MinI64(entries,clusters-i*entries);
      DskImageRead(off,n*8,l2);
      for (j=0;j<n;j++)
	DskClusOff(DskBig(l2+j*8,8),size,bytes,version==3);
    }
  }
  dsk_info[0]=virtual_size;dsk_info[1]=bits;dsk_info[2]=l1_off;
  return dsk_info;
}

I64 DskOffset(I64 pos,I64 bits,I64 l1_off)
{
  U8 buf[8];
  I64 size=1<<bits,entries=size/8,index=pos/size,off;
  U64 entry,mask=0x00FFFFFFFFFFFE00;
  if (!bits) return pos;
  DskImageRead(l1_off+index/entries*8,8,buf);
  off=DskBig(buf,8)&mask;
  if (!off) return -1;
  DskImageRead(off+index%entries*8,8,buf);
  entry=DskBig(buf,8);off=entry&mask;
  if (entry&1 || !off) return -1;
  return off+pos%size;
}

class CWebFat
{
  I64 off,secs,fats,fat_size,root,fat_lba,data_lba,
	clus_bytes,clus_cnt;
  U32 *fat;
};

class CWebDir
{
  U8 *bytes;
  I64 size,clus,cnt;
};

CWebFat *FatOpen(I64 disk_size)
{
  U8 buf[512];
  I64 i,typ,off=0,total;
  CWebFat *fs=DskTmp(sizeof(CWebFat));
  DskSectorRead(0,1,buf);
  if (*(&buf[510])(U16 *)==0xAA55)
    for (i=0;i<4;i++) {
      typ=buf[450+i*16];
      if (typ==0xB || typ==0xC) {
	off=*(&buf[454+i*16])(U32 *);
	break;
      }
    }
  if (off>=disk_size/512) DskFail("FAT32 partition bounds");
  DskSectorRead(off,1,buf);
  fs->off=off;fs->secs=buf[13];fs->fats=buf[16];
  fs->fat_size=*(&buf[36])(U32 *);fs->root=*(&buf[44])(U32 *);
  fs->fat_lba=off+*(&buf[14])(U16 *);
  fs->data_lba=fs->fat_lba+fs->fats*fs->fat_size;
  total=*(&buf[32])(U32 *);
  if (*(&buf[11])(U16 *)!=512 || !fs->secs ||
      fs->secs&(fs->secs-1) || fs->secs>128 ||
      !(1<=fs->fats<=2) || !fs->fat_size ||
      fs->fat_lba<=off || fs->data_lba>=off+total ||
      off+total>disk_size/512)
    DskFail("FAT32 dimensions");
  fs->clus_bytes=fs->secs*512;
  fs->clus_cnt=(off+total-fs->data_lba)/fs->secs+2;
  if (fs->clus_cnt>fs->fat_size*128 ||
      !(2<=fs->root<fs->clus_cnt)) DskFail("FAT32 cluster bounds");
  fs->fat=DskTmp(fs->fat_size*512);
  DskSectorRead(fs->fat_lba,fs->fat_size,fs->fat);
  return fs;
}

I64 FatNext(CWebFat *fs,I64 clus)
{
  if (!(2<=clus<fs->clus_cnt)) DskFail("FAT32 chain bounds");
  return fs->fat[clus]&0xFFFFFFF;
}

I64 FatChainCnt(CWebFat *fs,I64 clus)
{
  I64 cnt=0;
  while (clus<0xFFFFFF8) {
    clus=FatNext(fs,clus);
    if (++cnt>=fs->clus_cnt) DskFail("FAT32 cyclic chain");
  }
  return cnt;
}

U0 FatChainRead(CWebFat *fs,I64 clus,U8 *buf)
{
  while (clus<0xFFFFFF8) {
    DskSectorRead(fs->data_lba+(clus-2)*fs->secs,fs->secs,buf);
    buf+=fs->clus_bytes;clus=FatNext(fs,clus);
  }
}

CWebDir *FatDir(CWebFat *fs,I64 clus)
{
  CWebDir *dir=DskTmp(sizeof(CWebDir));
  dir->cnt=FatChainCnt(fs,clus);dir->clus=clus;
  dir->size=dir->cnt*fs->clus_bytes;
  dir->bytes=DskTmp(dir->size);
  FatChainRead(fs,clus,dir->bytes);
  return dir;
}

I64 FatEntry(CWebDir *dir,I64 pos,U16 *name)
{
  I64 i,n=0,at,seq,ch;
  U8 *b;
  MemSet(name,0,522);
  while (pos<dir->size) {
    b=dir->bytes+pos;
    if (!b[0]) return -1;
    if (b[0]==0xE5) MemSet(name,0,522);
    else if (b[11]==0xF) {
      seq=b[0]&31;
      if (!(1<=seq<=20)) DskFail("FAT32 long name");
      if (b[0]&0x40) MemSet(name,0,522);
      for (i=0;i<13;i++) {
	if (i<5) at=1+i*2;
	else if (i<11) at=14+(i-5)*2;
	else at=28+(i-11)*2;
	ch=*(b+at)(U16 *);
	if (ch==0xFFFF) ch=0;
	name[(seq-1)*13+i]=ch;
      }
    } else {
      if (!name[0]) {
	for (i=0;i<8;i++)
	  if (b[i]!=32) name[n++]=b[i];
	if (b[8]!=32) {
	  name[n++]='.';
	  for (i=8;i<11;i++)
	    if (b[i]!=32) name[n++]=b[i];
	}
      }
      return pos;
    }
    pos+=32;
  }
  return -1;
}

I64 FatEntryClus(U8 *b)
{
  return *(b+20)(U16 *)<<16|*(b+26)(U16 *);
}

CWebDir *FatFindDir(CWebFat *fs,U16 *path)
{
  U16 part[261],name[261];
  I64 i,pos,clus=fs->root;
  CWebDir *dir;
  while (*path) {
    while (*path=='/') path++;
    if (!*path) break;
    i=0;
    while (*path && *path!='/') {
      if (i==260) DskFail("FAT32 path length");
      part[i++]=*path++;
    }
    part[i]=0;dir=FatDir(fs,clus);pos=0;
    while ((pos=FatEntry(dir,pos,name))>=0) {
      if (dir->bytes[pos+11]&0x10 && DskNameEq(name,part)) break;
      pos+=32;
    }
    if (pos<0) DskFail("directory not found");
    clus=FatEntryClus(dir->bytes+pos);
  }
  return FatDir(fs,clus);
}

I64 FatFindFile(CWebDir *dir,U16 *filename)
{
  U16 name[261];
  I64 pos=0;
  while ((pos=FatEntry(dir,pos,name))>=0) {
    if (!(dir->bytes[pos+11]&0x10) && DskNameEq(name,filename))
      return pos;
    pos+=32;
  }
  return -1;
}

U0 FatLst(I64 disk_size,U16 *path)
{
  U16 name[261];
  I64 pos=0;
  CWebFat *fs=FatOpen(disk_size);
  CWebDir *dir=FatFindDir(fs,path);
  while ((pos=FatEntry(dir,pos,name))>=0) {
    if (name[0] && !(name[0]=='.' && (!name[1] ||
	name[1]=='.' && !name[2])))
      DskEntry(name,dir->bytes[pos+11],FatEntryClus(dir->bytes+pos),
	    *(dir->bytes+pos+28)(U32 *),pos);
    pos+=32;
  }
}

I64 FatRead(I64 disk_size,U16 *path,U16 *filename)
{
  CWebFat *fs=FatOpen(disk_size);
  CWebDir *dir=FatFindDir(fs,path);
  I64 pos=FatFindFile(dir,filename),clus,cnt,size;
  U8 *buf;
  if (pos<0) return -1;
  clus=FatEntryClus(dir->bytes+pos);size=*(dir->bytes+pos+28)(U32 *);
  if (!size) {DskResult(NULL,0);return 0;}
  cnt=FatChainCnt(fs,clus);
  if (size>cnt*fs->clus_bytes) DskFail("FAT32 file size");
  buf=DskTmp(cnt*fs->clus_bytes);FatChainRead(fs,clus,buf);
  DskResult(buf,size);
  return size;
}

I64 FatFreeClus(CWebFat *fs)
{
  I64 clus;
  for (clus=2;clus<fs->clus_cnt;clus++)
    if (!(fs->fat[clus]&0xFFFFFFF)) return clus;
  DskFail("disk full");
  return 0;
}

I64 FatWrite(I64 disk_size,U16 *path,U16 *filename,U8 *src,I64 size)
{
  CWebFat *fs=FatOpen(disk_size);
  CWebDir *dir=FatFindDir(fs,path);
  I64 pos=FatFindFile(dir,filename),clus,next,last=0,first=0,
	i,j,n=0,dot=-1,len,ext,base,lfn,sum=0,ch,at,need,run=0,
	slots,cnt,seq;
  U8 short_name[11],*b,*data;
  Bool fits=TRUE,same=TRUE;
  while (filename[n]) {
    ch=filename[n];
    if (ch=='.') dot=n;
    if ('a'<=ch<='z') same=FALSE;
    if (!('a'<=ch<='z' || 'A'<=ch<='Z' || '0'<=ch<='9' ||
	ch=='.' || ch=='_')) fits=FALSE;
    if (++n>255) DskFail("FAT32 filename length");
  }
  if (!n) DskFail("FAT32 empty filename");
  if (dot>0) {base=dot;ext=n-dot-1;}
  else {base=n;ext=0;}
  len=0;
  for (i=0;i<base;i++)
    if (filename[i]!='.') len++;
  fits=fits && len<=8 && ext<=3;
  MemSet(short_name,32,11);j=0;
  for (i=0;i<base && j<8;i++)
    if (filename[i]!='.') {
      ch=filename[i];
      if ('a'<=ch<='z') ch-=32;
      if (!('A'<=ch<='Z' || '0'<=ch<='9' || ch=='_')) ch='_';
      short_name[j++]=ch;
    }
  if (!fits) {
    j=MinI64(j,6);short_name[j++]='~';short_name[j]='1';
  }
  for (i=0;i<MinI64(ext,3);i++) {
    ch=filename[dot+1+i];
    if ('a'<=ch<='z') ch-=32;
    if (!('A'<=ch<='Z' || '0'<=ch<='9' || ch=='_')) ch='_';
    short_name[8+i]=ch;
  }
  lfn=0;
  if (!fits || !same) lfn=(n+12)/13;
  slots=lfn+1;
  if (pos>=0) {
    clus=FatEntryClus(dir->bytes+pos);
    if (*(dir->bytes+pos+28)(U32 *)) FatChainCnt(fs,clus);
    while (2<=clus<0xFFFFFF8) {
      next=FatNext(fs,clus);fs->fat[clus]=0;clus=next;
    }
    dir->bytes[pos]=0xE5;
    for (i=pos-32;i>=0 && dir->bytes[i+11]==0xF;i-=32)
      dir->bytes[i]=0xE5;
  }
  need=MaxI64(1,(size+fs->clus_bytes-1)/fs->clus_bytes);
  for (i=0;i<need;i++) {
    clus=FatFreeClus(fs);
    if (last) fs->fat[last]=clus;
    else first=clus;
    fs->fat[clus]=0xFFFFFFF;last=clus;
  }
  at=-1;
  for (i=0;i<dir->size;i+=32) {
    if (!dir->bytes[i] || dir->bytes[i]==0xE5) {
      if (!run) at=i;
      if (++run==slots) break;
    } else run=0;
  }
  if (run<slots) {
    clus=dir->clus;
    for (i=1;i<dir->cnt;i++) clus=FatNext(fs,clus);
    at=dir->size-run*32;
    cnt=((slots-run)*32+fs->clus_bytes-1)/fs->clus_bytes;
    for (i=0;i<cnt;i++) {
      next=FatFreeClus(fs);fs->fat[clus]=next;
      fs->fat[next]=0xFFFFFFF;clus=next;
    }
    b=DskTmp(dir->size+cnt*fs->clus_bytes);
    MemCpy(b,dir->bytes,dir->size);
    MemSet(b+dir->size,0,cnt*fs->clus_bytes);
    dir->bytes=b;dir->size+=cnt*fs->clus_bytes;
  }
  for (i=0;i<11;i++) sum=(sum>>1|(sum&1)<<7+short_name[i])&0xFF;
  for (i=0;i<lfn;i++) {
    b=dir->bytes+at+i*32;MemSet(b,0,32);seq=lfn-i;
    b[0]=seq;if (!i) b[0]|=0x40;
    b[11]=0xF;b[13]=sum;
    for (j=0;j<13;j++) {
      pos=(seq-1)*13+j;ch=0xFFFF;
      if (pos<n) ch=filename[pos];
      else if (pos==n) ch=0;
      if (j<5) pos=1+j*2;
      else if (j<11) pos=14+(j-5)*2;
      else pos=28+(j-11)*2;
      *(b+pos)(U16 *)=ch;
    }
  }
  b=dir->bytes+at+lfn*32;MemSet(b,0,32);
  MemCpy(b,short_name,11);b[11]=0x20;
  *(b+24)(U16 *)=46<<9|6<<5|11;
  *(b+20)(U16 *)=first>>16;*(b+26)(U16 *)=first;
  *(b+28)(U32 *)=size;
  data=DskTmp(fs->clus_bytes);clus=first;
  for (i=0;i<need;i++) {
    MemSet(data,0,fs->clus_bytes);
    cnt=MinI64(fs->clus_bytes,MaxI64(0,size-i*fs->clus_bytes));
    MemCpy(data,src+i*fs->clus_bytes,cnt);
    DskSectorWrite(fs->data_lba+(clus-2)*fs->secs,fs->secs,data);
    clus=FatNext(fs,clus);
  }
  clus=dir->clus;
  for (i=0;i<dir->size;i+=fs->clus_bytes) {
    DskSectorWrite(fs->data_lba+(clus-2)*fs->secs,fs->secs,dir->bytes+i);
    clus=FatNext(fs,clus);
  }
  for (i=0;i<fs->fats;i++)
    DskSectorWrite(fs->fat_lba+i*fs->fat_size,fs->fat_size,fs->fat);
  dsk_info[0]=first;dsk_info[1]=need;
  return dsk_info;
}
