U8 dsk_image[4096],dsk_raw[65536];
U16 dsk_path[1],dsk_name[261];

U0 DskFail(U8 *msg)
{
  "FAIL:%s\n",msg;
  throw('Disk');
}

U0 DskImageRead(I64 off,I64 size,U8 *dst)
{
  MemCpy(dst,dsk_image+off,size);
}

U0 DskSectorRead(I64 lba,I64 count,U8 *dst)
{
  MemCpy(dst,dsk_raw+lba*512,count*512);
}

U0 DskSectorWrite(I64 lba,I64 count,U8 *src)
{
  MemCpy(dsk_raw+lba*512,src,count*512);
}

U0 DskEntry(U16 *name,I64 attr,I64 clus,I64 size,I64 off)
{
  while (*name) "%04X",*name++;
  " %X %X %X %X\n",attr,clus,size,off;
}

U64 DskHash(U8 *buf,I64 size)
{
  U64 hash=2166136261;
  while (size--) hash=(hash^*buf++)*16777619&0xFFFFFFFF;
  return hash;
}

U0 DskResult(U8 *buf,I64 size)
{
  "%X %08X\n",size,DskHash(buf,size);
}

Bool DskNameEq(U16 *a,U16 *b)
{
  I64 ch1,ch2;
  do {
    ch1=*a++;ch2=*b++;
    if ('a'<=ch1<='z') ch1-=32;
    if ('a'<=ch2<='z') ch2-=32;
    if (ch1!=ch2) return FALSE;
  } while (ch1);
  return TRUE;
}

#include "Disk"

U0 DskBigSet(I64 off,I64 size,U64 value)
{
  while (size--) {
    dsk_image[off+size]=value&255;
    value>>=8;
  }
}

U0 DskNative()
{
  I64 i,j,*info;
  U8 *name="Long filename.HC",data[2049];
  MemSet(dsk_image,0,sizeof(dsk_image));
  DskBigSet(0,4,0x514649FB);DskBigSet(4,4,3);
  DskBigSet(20,4,9);DskBigSet(24,8,2048);
  DskBigSet(36,4,1);DskBigSet(40,8,512);DskBigSet(100,4,104);
  DskBigSet(512,8,1024);DskBigSet(1024,8,1536);
  DskBigSet(1040,8,1);DskBigSet(1048,8,2048);
  info=DskInfo(sizeof(dsk_image));
  "%X %X %X\n",info[0],info[1],info[2];
  for (i=0;i<2048;i+=256)
    "%X\n",DskOffset(i,info[1],info[2]);
  DskTmpDel;
  MemSet(dsk_raw,0,sizeof(dsk_raw));
  *(dsk_raw+11)(U16 *)=512;dsk_raw[13]=1;
  *(dsk_raw+14)(U16 *)=1;dsk_raw[16]=1;
  *(dsk_raw+32)(U32 *)=128;*(dsk_raw+36)(U32 *)=1;
  *(dsk_raw+44)(U32 *)=2;*(dsk_raw+510)(U16 *)=0xAA55;
  *(dsk_raw+512)(U32 *)=0xFFFFFF8;
  *(dsk_raw+516)(U32 *)=0xFFFFFFF;
  *(dsk_raw+520)(U32 *)=0xFFFFFFF;
  dsk_path[0]=0;
  for (i=0;i<sizeof(data);i++) data[i]=i%251;
  for (i=0;i<24;i++) {
    MemSet(dsk_name,0,sizeof(dsk_name));
    for (j=0;name[j];j++) dsk_name[j]=name[j];
    dsk_name[0]='A'+i;
    info=FatWrite(sizeof(dsk_raw),dsk_path,dsk_name,data,i*77);
    "%X %X\n",info[0],info[1];DskTmpDel;
    FatRead(sizeof(dsk_raw),dsk_path,dsk_name);DskTmpDel;
  }
  FatLst(sizeof(dsk_raw),dsk_path);DskTmpDel;
  FatWrite(sizeof(dsk_raw),dsk_path,dsk_name,data,0);DskTmpDel;
  FatRead(sizeof(dsk_raw),dsk_path,dsk_name);DskTmpDel;
  DskResult(dsk_raw,sizeof(dsk_raw));
}
DskNative;
