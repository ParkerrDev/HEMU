U0 WasmF64(CWasmBuf *f,F64 value)
{
  WasmByte(f,W_F64_CONST);WasmCopy(f,&value,8);
}

U0 JitFRound(CWasmBuf *f,Bool trunc)
{//Round as F64 to preserve large finite values and infinities.
  WasmArg(f,W_LOCAL_SET,36);
  if (trunc) {
    WasmArg(f,W_LOCAL_GET,36);WasmByte(f,W_F64_TRUNC);
  } else {
    WasmI32(f,jit_cw);WasmLd64(f);WasmI64(f,10);
    WasmByte(f,W_I64_SHR_U);WasmI64(f,3);WasmByte(f,W_I64_AND);
    WasmArg(f,W_LOCAL_SET,0);
    WasmArg(f,W_LOCAL_GET,0);WasmByte(f,W_I64_EQZ);
    WasmIf(f,0x7C);
      WasmArg(f,W_LOCAL_GET,36);WasmByte(f,W_F64_NEAREST);
    WasmByte(f,W_ELSE);
      WasmArg(f,W_LOCAL_GET,0);WasmI64(f,1);WasmByte(f,W_I64_EQ);
      WasmIf(f,0x7C);
	WasmArg(f,W_LOCAL_GET,36);WasmByte(f,W_F64_FLOOR);
      WasmByte(f,W_ELSE);
	WasmArg(f,W_LOCAL_GET,0);WasmI64(f,2);WasmByte(f,W_I64_EQ);
	WasmIf(f,0x7C);
	  WasmArg(f,W_LOCAL_GET,36);WasmByte(f,W_F64_CEIL);
	WasmByte(f,W_ELSE);
	  WasmArg(f,W_LOCAL_GET,36);WasmByte(f,W_F64_TRUNC);
	WasmByte(f,W_END);
      WasmByte(f,W_END);
    WasmByte(f,W_END);
  }
}

U0 JitFInt(CWasmBuf *f,I64 bits,Bool trunc)
{
  F64 limit=0x43E0000000000000(F64);
  if (bits==16) limit=32768.0;
  else if (bits==32) limit=2147483648.0;
  JitFRound(f,trunc);WasmArg(f,W_LOCAL_SET,5);
  WasmI32(f,jit_sw);WasmI32(f,jit_sw);WasmLd64(f);
  WasmI64(f,~0x200);WasmByte(f,W_I64_AND);WasmSt64(f);
  WasmArg(f,W_LOCAL_GET,5);WasmF64(f,-limit);WasmByte(f,W_F64_GE);
  WasmArg(f,W_LOCAL_GET,5);WasmF64(f,limit);WasmByte(f,W_F64_LT);
  WasmByte(f,W_I32_AND);WasmIf(f,0x7E);
    WasmArg(f,W_LOCAL_GET,5);WasmArg(f,W_LOCAL_GET,36);
    WasmByte(f,W_F64_NE);WasmIf(f);
      WasmI32(f,jit_sw);WasmI32(f,jit_sw);WasmLd64(f);
      WasmI64(f,0x20);WasmByte(f,W_I64_OR);WasmSt64(f);
      if (!trunc) {
	WasmArg(f,W_LOCAL_GET,5);WasmByte(f,W_F64_ABS);
	WasmArg(f,W_LOCAL_GET,36);WasmByte(f,W_F64_ABS);
	WasmByte(f,W_F64_GT);WasmIf(f);
	  WasmI32(f,jit_sw);WasmI32(f,jit_sw);WasmLd64(f);
	  WasmI64(f,0x200);WasmByte(f,W_I64_OR);WasmSt64(f);
	WasmByte(f,W_END);
      }
    WasmByte(f,W_END);
    WasmArg(f,W_LOCAL_GET,5);WasmByte(f,W_I64_TRUNC_F64_S);
  WasmByte(f,W_ELSE);
    WasmI32(f,jit_sw);WasmI32(f,jit_sw);WasmLd64(f);
    WasmI64(f,1);WasmByte(f,W_I64_OR);WasmSt64(f);
    WasmI64(f,-(1<<(bits-1)));
  WasmByte(f,W_END);
}

U0 JitFaultExit(CWasmBuf *f)
{
  jit_decode.side_exit=TRUE;WasmIf(f);JitMaterialize(f);
  WasmI32(f,jit_rip_addr);WasmI64(f,jit_decode.i-jit_gbase);
  WasmSt64(f);JitWriteBack(f);WasmI32(f,jit_decode.n);
  WasmByte(f,W_RETURN);WasmByte(f,W_END);
}

U0 JitFMath(CWasmBuf *f,I64 sub,I64 index,Bool reverse)
{
  I64 op=W_F64_DIV;
  switch (sub) {
    case 0: op=W_F64_ADD;break;
    case 1: op=W_F64_MUL;break;
    case 4: case 5: op=W_F64_SUB;break;
  }
  if (reverse) {
    WasmArg(f,W_LOCAL_GET,5);JitFRd(f,index);
  } else {
    JitFRd(f,index);WasmArg(f,W_LOCAL_GET,5);
  }
  WasmByte(f,op);JitFWr(f,index);
}

U64 jit_fconst[7]={0x3FF0000000000000,0x400A934F0979A371,
      0x3FF71547652B82FE,0x400921FB54442D18,0x3FD34413509F79FF,
      0x3FE62E42FEFA39EF,0};

Bool JitFpuOp(CWasmBuf *f)
{
  I64 op=jit_decode.op,byte=JitCodeByte(jit_decode.j),
	sub=byte>>3&7,sti=byte&7,size,store;
  Bool mem=byte>>6!=3,ok,int_store;
  CJitOperand m;
  if (!jit_fpr) return FALSE;
  if (mem) {
    ok=op==0xD9 && jit_cw && (sub==5 || sub==7) ||
	  op==0xDD && (sub==0 || sub==1 || sub==2 || sub==3) ||
	  op==0xDF && (sub==1 || sub==5 || sub==7) ||
	  op==0xDB && (sub==0 || sub==1 || sub==3) ||
	  op==0xDC && sub!=2 && sub!=3;
    if (!ok) return FALSE;
    int_store=sub==1 && op!=0xDC || op==0xDF && sub==7 ||
	  op==0xDB && sub==3;
    if (int_store && (!jit_cw || !jit_sw)) return FALSE;
    if (int_store) {
      JitMaterialize(f);WasmI32(f,jit_cw);WasmLd64(f);
      WasmI64(f,0x21);WasmByte(f,W_I64_AND);WasmI64(f,0x21);
      WasmByte(f,W_I64_NE);JitFaultExit(f);
    }
    JitModRm(&m,jit_decode.j,jit_decode.rex_r,jit_decode.rex_x,
	  jit_decode.rex_b);
    jit_decode.j=m.j;JitEa(f,&m,m.j-jit_gbase);
    if (!m.known_ram) JitRamOperand(f);
    if (op==0xD9 && sub==5) {
      WasmI32(f,jit_cw);JitRmRd(f,&m,2,jit_decode.rex);WasmSt64(f);
    } else if (op==0xD9 && sub==7) {
      WasmI32(f,jit_cw);WasmLd64(f);JitRmWr(f,&m,2,jit_decode.rex);
    } else if (sub==1 && op!=0xDC) {
      size=64;store=W_I64_STORE;
      if (op==0xDB) {
	size=32;store=W_I64_STORE32;
      } else if (op==0xDF) {
	size=16;store=W_I64_STORE16;
      }
      JitMemAddr(f);JitFRd(f,0);JitFInt(f,size,TRUE);
      WasmMem(f,store,0,JitAlign(size/8));JitFInc(f,1);
    } else if (op==0xDD && sub==0) {
      JitMemAddr(f);WasmMem(f,W_F64_LOAD);JitFPush(f);
    } else if (op==0xDD && (sub==2 || sub==3)) {
      JitMemAddr(f);JitFRd(f,0);WasmMem(f,W_F64_STORE);
      if (sub==3) JitFInc(f,1);
    } else if (op==0xDF && sub==5) {
      JitMemAddr(f);WasmLd64(f);WasmByte(f,W_F64_CONVERT_I64_S);
      JitFPush(f);
    } else if (op==0xDF && sub==7) {
      JitMemAddr(f);JitFRd(f,0);JitFInt(f,64,FALSE);
      WasmSt64(f);JitFInc(f,1);
    } else if (op==0xDB && sub==0) {
      JitMemAddr(f);WasmMem(f,W_I64_LOAD32_U,0,2);
      WasmByte(f,W_I64_EXTEND32_S);WasmByte(f,W_F64_CONVERT_I64_S);
      JitFPush(f);
    } else if (op==0xDB && sub==3) {
      JitMemAddr(f);JitFRd(f,0);JitFInt(f,32,FALSE);
      WasmMem(f,W_I64_STORE32,0,2);JitFInc(f,1);
    } else if (op==0xDC) {
      JitMemAddr(f);WasmMem(f,W_F64_LOAD);WasmArg(f,W_LOCAL_SET,5);
      JitFMath(f,sub,0,sub==5 || sub==7);
    }
  } else {
    ok=(op==0xD8 || op==0xDC || op==0xDE) && sub!=2 && sub!=3 ||
	  op==0xD9 && (sub==0 || sub==1 ||
	  sub==4 && (sti<=1 || sti==4) ||
	  sub==6 && (sti==6 || sti==7) || sub==5 && sti<=6 ||
	  sub==7 && (sti==2 || sti==4 && jit_cw)) ||
	  op==0xDD && (sub==0 || sub==2 || sub==3) ||
	  op==0xDF && sub==4 && !sti ||
	  (op==0xDB || op==0xDF) && (sub==5 || sub==6) && jit_sw;
    if (!ok) return FALSE;
    jit_decode.j++;
    if (op==0xD8) {
      JitFRd(f,sti);WasmArg(f,W_LOCAL_SET,5);
      JitFMath(f,sub,0,sub==5 || sub==7);
    } else if (op==0xDC || op==0xDE) {
      JitFRd(f,0);WasmArg(f,W_LOCAL_SET,5);
      JitFMath(f,sub,sti,sub==4 || sub==6);
      if (op==0xDE) JitFInc(f,1);
    } else if (op==0xD9 && sub==0) {
      JitFRd(f,sti);JitFPush(f);
    } else if (op==0xD9 && sub==1) {
      JitFRd(f,0);WasmArg(f,W_LOCAL_SET,5);
      JitFRd(f,sti);JitFWr(f,0);
      WasmArg(f,W_LOCAL_GET,5);JitFWr(f,sti);
    } else if (op==0xD9 && sub==5) {
      WasmByte(f,W_F64_CONST);WasmCopy(f,&jit_fconst[sti],8);JitFPush(f);
    } else if (op==0xD9 && sub==7 && sti==4) {
      JitMaterialize(f);JitFRd(f,0);JitFRound(f,FALSE);JitFWr(f,0);
    } else if (op==0xD9 && sub==4 && sti<=1) {
      JitFRd(f,0);
      if (sti) WasmByte(f,W_F64_ABS);
      else WasmByte(f,W_F64_NEG);
      JitFWr(f,0);
    } else if (op==0xD9 && sub==4 && sti==4) {
      JitFRd(f,0);WasmArg(f,W_LOCAL_SET,5);
      WasmI32(f,jit_sw);WasmI32(f,jit_sw);WasmLd64(f);
      WasmI64(f,~0x4700);WasmByte(f,W_I64_AND);
      WasmI64(f,0x4500);WasmI64(f,0x4000);
      WasmI64(f,0x0100);WasmI64(f,0);
      WasmArg(f,W_LOCAL_GET,5);WasmF64(f,0);
      WasmByte(f,W_F64_LT);WasmByte(f,W_SELECT);
      WasmArg(f,W_LOCAL_GET,5);WasmF64(f,0);
      WasmByte(f,W_F64_EQ);WasmByte(f,W_SELECT);
      WasmArg(f,W_LOCAL_GET,5);WasmArg(f,W_LOCAL_GET,5);
      WasmByte(f,W_F64_NE);WasmByte(f,W_SELECT);
      WasmByte(f,W_I64_OR);WasmSt64(f);
    } else if (op==0xDF && sub==4 && !sti) {
      JitFStatus(f);JitRegWr(f,0,2,TRUE);
    } else if (op==0xD9 && sub==7 && sti==2) {
      JitFRd(f,0);WasmByte(f,W_F64_SQRT);JitFWr(f,0);
    } else if (op==0xD9 && sub==6) {
      if (sti==6) JitFInc(f,-1);
      else JitFInc(f,1);
    } else if (op==0xDD && sub!=0) {
      JitFRd(f,0);JitFWr(f,sti);
      if (sub==3) JitFInc(f,1);
    } else if ((op==0xDB || op==0xDF) && (sub==5 || sub==6)) {
      JitMaterialize(f);
      JitFRd(f,0);WasmArg(f,W_LOCAL_SET,5);
      JitFRd(f,sti);WasmArg(f,W_LOCAL_SET,36);
      WasmArg(f,W_LOCAL_GET,5);WasmArg(f,W_LOCAL_GET,5);
      WasmByte(f,W_F64_NE);
      WasmArg(f,W_LOCAL_GET,36);WasmArg(f,W_LOCAL_GET,36);
      WasmByte(f,W_F64_NE);WasmByte(f,W_I32_OR);JitFaultExit(f);
      WasmI32(f,jit_sw);WasmI32(f,jit_sw);WasmLd64(f);
      WasmI64(f,~0x200);WasmByte(f,W_I64_AND);WasmSt64(f);
      WasmI32(f,jit_rfl);WasmI32(f,jit_rfl);WasmLd64(f);
      WasmI64(f,~0x8D5);WasmByte(f,W_I64_AND);
      WasmI64(f,0x40);WasmI64(f,1);WasmI64(f,0);
      WasmArg(f,W_LOCAL_GET,5);WasmArg(f,W_LOCAL_GET,36);
      WasmByte(f,W_F64_LT);WasmByte(f,W_SELECT);
      WasmArg(f,W_LOCAL_GET,5);WasmArg(f,W_LOCAL_GET,36);
      WasmByte(f,W_F64_EQ);WasmByte(f,W_SELECT);
      WasmByte(f,W_I64_OR);WasmSt64(f);
      if (op==0xDF) JitFInc(f,1);
    }
  }
  return TRUE;
}
