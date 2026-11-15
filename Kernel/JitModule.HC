CWasmBuf jit_module,jit_section,jit_body;
Bool jit_shared;

U0 WasmStr(CWasmBuf *f,U8 *text)
{
  I64 len=0;
  while (text[len]) len++;
  WasmUleb(f,len);WasmCopy(f,text,len);
}

U0 WasmSection(CWasmBuf *module,CWasmBuf *section,I64 id)
{
  WasmByte(module,id);WasmUleb(module,section->cnt);
  WasmCopy(module,section->data,section->cnt);
  if (section->overflow) module->overflow=TRUE;
  section->cnt=0;section->overflow=FALSE;
}

U0 WasmType(CWasmBuf *f,I64 cnt,I64 param,I64 result=0)
{
  I64 i;
  WasmByte(f,0x60);WasmUleb(f,cnt);
  for (i=0;i<cnt;i++) WasmByte(f,param);
  if (result) {
    WasmByte(f,1);WasmByte(f,result);
  } else WasmByte(f,0);
}

U0 WasmImport(CWasmBuf *f,U8 *name,I64 kind,I64 index)
{
  WasmStr(f,"env");WasmStr(f,name);
  WasmByte(f,kind);WasmUleb(f,index);
}

U0 WasmLocal(CWasmBuf *f,I64 cnt,I64 type)
{
  WasmUleb(f,cnt);WasmByte(f,type);
}

U0 JitModule(CWasmBuf *f,Bool dispatch=FALSE,Bool render=FALSE)
{
  CWasmBuf *m=&jit_module,*s=&jit_section,*b=&jit_body;
  I64 index=3;
  m->cnt=0;m->overflow=FALSE;s->cnt=0;s->overflow=FALSE;
  b->cnt=0;b->overflow=FALSE;
  WasmCopy(m,"\x00asm\x01\x00\x00\x00",8);
  if (dispatch) {
    index=0;
    if (render) index=1;
    WasmUleb(s,2+index);
    if (render) WasmType(s,0,0,0x7E);
    WasmType(s,0,0,0x7F);WasmType(s,1,0x7F,0x7F);
  } else {
    WasmUleb(s,4);
    WasmType(s,2,0x7E,0x7E);WasmType(s,3,0x7E);
    WasmType(s,1,0x7E);WasmType(s,0,0,0x7F);
  }
  WasmSection(m,s,1);
  WasmUleb(s,index+2);
  if (dispatch) {
    if (render) WasmImport(s,"RenderTry",0,0);
  } else {
    WasmImport(s,"RdMem",0,0);WasmImport(s,"WrMem",0,1);
    WasmImport(s,"CodeChanged",0,2);
  }
  WasmStr(s,"env");WasmStr(s,"mem");WasmByte(s,2);
  if (jit_shared) {
    WasmByte(s,3);WasmUleb(s,1);WasmUleb(s,8192);
  } else {
    WasmByte(s,0);WasmUleb(s,1);
  }
  WasmImport(s,"budget",3,0x7E);WasmByte(s,1);
  WasmSection(m,s,2);
  WasmByte(s,1);
  if (dispatch) WasmUleb(s,index+1);
  else WasmUleb(s,3);
  WasmSection(m,s,3);
  if (dispatch) {
    WasmByte(s,1);WasmByte(s,0x70);WasmByte(s,0);
    WasmUleb(s,65536);WasmSection(m,s,4);
    WasmByte(s,2);WasmStr(s,"tbl");WasmByte(s,1);WasmByte(s,0);
    WasmStr(s,"dispatch");
  } else {
    WasmByte(s,1);WasmStr(s,"run");
  }
  WasmByte(s,0);WasmUleb(s,index);WasmSection(m,s,7);
  if (dispatch) {
    WasmByte(b,1);WasmLocal(b,6,0x7F);
  } else {
    WasmByte(b,5);
    WasmLocal(b,5,0x7E);WasmLocal(b,1,0x7C);
    WasmLocal(b,30,0x7E);WasmLocal(b,9,0x7C);
    WasmLocal(b,jit_local_next-45,0x7E);
  }
  WasmCopy(b,f->data,f->cnt);WasmByte(b,W_END);
  WasmByte(s,1);WasmUleb(s,b->cnt);WasmCopy(s,b->data,b->cnt);
  WasmSection(m,s,10);
  if (f->overflow || b->overflow) m->overflow=TRUE;
}
