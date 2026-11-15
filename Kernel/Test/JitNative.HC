#include "JitCore"

U0 JitNativeDigest(I64 len)
{
  I64 i,hash=2166136261;
  for (i=0;i<len;i++)
    hash=(hash^jit_module.data[i])*16777619&0xFFFFFFFF;
  "%d %d %d %08X\n",len,jit_config[20],jit_config[21],hash;
}

U0 JitNativeCase(U8 *code,I64 cnt)
{
  I64 i,len,mode;
  for (i=0;i<JIT_CODE_SIZE;i++) jit_code[i]=0xCC;
  JitCopy(jit_code,code,cnt);
  for (mode=0;mode<4;mode++) {
    jit_config[13]=mode&1;
    len=JitBuild(4096,cnt+16,mode>>1);
    JitNativeDigest(len);
  }
}

U0 JitNativeRun()
{
  I64 i,mode;
  for (i=0;i<19;i++) jit_config[i]=0x200+i*64;
  jit_config[3]=0x100000;jit_config[14]=0x4000;jit_config[15]=0xC000;
  JitNativeCase("\x48\xFF\xC0",3);
  JitNativeCase("\x48\x83\xE8\x01\x75\xFA",6);
  JitNativeCase("\x48\x83\xF8\x0A\x7D\x05\x48\xFF\xC0\xEB\xF5",11);
  JitNativeCase("\x48\x83\xF8\x00\x74\x03\x48\xFF\xC0\x90",10);
  JitNativeCase("\x6A\xFF\x58",3);
  JitNativeCase("\x48\x39\xC8\xDD\x0B",5);
  JitNativeCase("\xD9\xE9\xD9\xE0\xDF\x38",6);
  JitNativeCase("\xD9\xE8\xD9\xE8\xDE\xC1",6);
  JitNativeCase("\xD9\xFC\xDF\x38",4);
  JitNativeCase("\x0F\xAE\x03\x0F\xAE\x0B",6);
  JitNativeCase("\xD9\xE8\x0F\xAE\x03",5);
  JitNativeCase("\xF3\x48\xA5",3);
  JitNativeCase("\x48\xF7\xF9",3);
  JitNativeCase("\x48\xF7\xE1\x48\xFF\xC0",6);
  JitNativeCase("\x0F\xBA\x2B\x21",4);
  JitNativeCase("\x48\x0F\xBE\xC1\x48\x0F\x44\xD0",8);
  JitNativeCase("\x0F\x31",2);
  JitNativeCase("\x0F\x30",2);
  JitNativeCase("\xFB",1);
  JitNativeCase("\x48\xCF",2);
  JitNativeCase("\xF0\x48\xFF\x00",4);
  for (mode=0;mode<4;mode++) {
    jit_config[13]=mode&1;jit_config[18]=mode>>1;
    JitNativeDigest(JitDispatch);
  }
}

JitNativeRun;
