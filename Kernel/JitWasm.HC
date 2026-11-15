#include "JitWasm.HH"

#define WASM_BUF_SIZE 262144

class CWasmBuf
{
  I64 cnt;
  Bool overflow;
  U8 data[WASM_BUF_SIZE];
};

U0 WasmByte(CWasmBuf *buf,I64 value)
{
  if (buf->cnt<WASM_BUF_SIZE)
    buf->data[buf->cnt++]=value;
  else
    buf->overflow=TRUE;
}

U0 WasmUleb(CWasmBuf *buf,U64 value)
{
  I64 byte;
  do {
    byte=value&0x7F;
    value>>=7;
    if (value) byte|=0x80;
    WasmByte(buf,byte);
  } while (value);
}

U0 WasmSleb(CWasmBuf *buf,I64 value)
{
  I64 byte;
  Bool more;
  do {
    byte=value&0x7F;
    value>>=7;
    more=!(value==0 && !(byte&0x40) || value==-1 && byte&0x40);
    if (more) byte|=0x80;
    WasmByte(buf,byte);
  } while (more);
}

U0 WasmI32(CWasmBuf *buf,I64 value)
{
  WasmByte(buf,W_I32_CONST);WasmSleb(buf,value<<32>>32);
}

U0 WasmI64(CWasmBuf *buf,I64 value)
{
  WasmByte(buf,W_I64_CONST);WasmSleb(buf,value);
}

U0 WasmArg(CWasmBuf *buf,I64 op,I64 value)
{
  WasmByte(buf,op);WasmUleb(buf,value);
}

U0 WasmMem(CWasmBuf *buf,I64 op,I64 offset=0,I64 align=3)
{
  WasmByte(buf,op);WasmUleb(buf,align);WasmUleb(buf,offset);
}

U0 WasmLd64(CWasmBuf *buf)
{
  WasmMem(buf,W_I64_LOAD);
}

U0 WasmSt64(CWasmBuf *buf)
{
  WasmMem(buf,W_I64_STORE);
}

U0 WasmIf(CWasmBuf *buf,I64 type=0x40)
{
  WasmByte(buf,W_IF);WasmByte(buf,type);
}

U0 WasmCopy(CWasmBuf *buf,U8 *data,I64 cnt)
{
  I64 i;
  for (i=0;i<cnt;i++)
    WasmByte(buf,data[i]);
}

U0 WasmInsert(CWasmBuf *buf,I64 at,U8 *data,I64 cnt)
{
  I64 i;
  if (at<0 || at>buf->cnt || cnt<0 || cnt>WASM_BUF_SIZE-buf->cnt) {
    buf->overflow=TRUE;
    return;
  }
  for (i=buf->cnt-1;i>=at;i--)
    buf->data[i+cnt]=buf->data[i];
  for (i=0;i<cnt;i++)
    buf->data[at+i]=data[i];
  buf->cnt+=cnt;
}

U0 JitCopy(U8 *dst,U8 *src,I64 cnt)
{
  I64 i;
  for (i=0;i<cnt;i++)
    dst[i]=src[i];
}
