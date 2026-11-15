class CJitSegment
{
  I64 start,at;
  CWasmBuf exit;
};

CJitSegment jit_segments[8];
I64 jit_segment_cnt;
CWasmBuf jit_guard,jit_exit,jit_entry;

Bool JitForwardBranch(CWasmBuf *f,I64 cc,I64 target,I64 fall)
{
  CJitFlags pending;
  CJitSegment *segment;
  if (jit_decode.top_at>=0 || target<=fall || jit_segment_cnt>=8)
    return FALSE;
  jit_decode.side_exit=TRUE;JitPendingCond(f,cc);
  JitCopy(&pending,&jit_flags,sizeof(CJitFlags));
  WasmIf(f);JitMaterialize(f);
  WasmI32(f,jit_rip_addr);WasmI64(f,target);WasmSt64(f);
  JitWriteBack(f);WasmI32(f,jit_decode.n+1);WasmByte(f,W_RETURN);
  WasmByte(f,W_END);JitCopy(&jit_flags,&pending,sizeof(CJitFlags));
  segment=&jit_segments[jit_segment_cnt++];
  segment->start=fall;segment->at=f->cnt;
  segment->exit.cnt=0;segment->exit.overflow=FALSE;
  JitMaterialize(&segment->exit);
  JitCopy(&jit_flags,&pending,sizeof(CJitFlags));
  WasmI32(&segment->exit,jit_rip_addr);WasmI64(&segment->exit,fall);
  WasmSt64(&segment->exit);JitWriteBack(&segment->exit);
  WasmI64(&segment->exit,jit_decode.rip);WasmArg(&segment->exit,W_CALL,2);
  WasmI32(&segment->exit,jit_decode.n+1);WasmByte(&segment->exit,W_RETURN);
  return TRUE;
}

Bool JitTopBranch(CWasmBuf *f,I64 cc,I64 target,I64 fall)
{
  if (jit_decode.no_top_loop || jit_decode.no_loop ||
	jit_decode.top_at>=0 || jit_decode.n!=1 ||
	!jit_decode.compare_head || target<=fall)
    return FALSE;
  JitMaterialize(f);JitCond(f,cc);WasmIf(f);
  jit_decode.top_at=f->cnt;jit_decode.top_target=target;
  jit_decode.top_count=jit_decode.n+1;WasmByte(f,W_END);
  return TRUE;
}

U0 JitCodeGuard(CWasmBuf *f,I64 rip,U8 *bytes,I64 len,CWasmBuf *miss)
{
  I64 i=0;
  WasmArg(f,W_BLOCK,0x40);WasmArg(f,W_BLOCK,0x40);
  while (i+8<=len) {
    WasmI32(f,jit_gbase+rip+i);WasmMem(f,W_I64_LOAD,0,0);
    WasmI64(f,*(bytes+i)(I64 *));WasmByte(f,W_I64_NE);
    WasmArg(f,W_BR_IF,0);i+=8;
  }
  if (i+4<=len) {
    WasmI32(f,jit_gbase+rip+i);WasmMem(f,W_I32_LOAD,0,0);
    WasmI32(f,*(bytes+i)(I32 *));WasmByte(f,W_I32_NE);
    WasmArg(f,W_BR_IF,0);i+=4;
  }
  if (i+2<=len) {
    WasmI32(f,jit_gbase+rip+i);WasmMem(f,W_I32_LOAD16_U,0,0);
    WasmI32(f,*(bytes+i)(U16 *));WasmByte(f,W_I32_NE);
    WasmArg(f,W_BR_IF,0);i+=2;
  }
  if (i<len) {
    WasmI32(f,jit_gbase+rip+i);WasmMem(f,W_I32_LOAD8_U,0,0);
    WasmI32(f,bytes[i]);WasmByte(f,W_I32_NE);WasmArg(f,W_BR_IF,0);
  }
  WasmArg(f,W_BR,1);WasmByte(f,W_END);
  WasmCopy(f,miss->data,miss->cnt);WasmByte(f,W_END);
  if (miss->overflow) f->overflow=TRUE;
}

Bool JitIntegerLoopOp(I64 op,Bool two,I64 ext)
{
  if (two)
    return 0x40<=op<=0x4F || 0x80<=op<=0x9F || op==0xB6 ||
	  op==0xB7 || op==0xBE || op==0xBF;
  if (op<0x40 || 0x70<=op<=0x7F || 0xB0<=op<=0xBF) return TRUE;
  if (op==0xFE || op==0xFF) return ext<=1;
  if (op==0xF6 || op==0xF7) return ext<=5;
  switch (op) {
    case 0x63: case 0x69: case 0x6B: case 0x80: case 0x81:
    case 0x83: case 0x84: case 0x85: case 0x88: case 0x89:
    case 0x8A: case 0x8B: case 0x8D: case 0x90: case 0x98:
    case 0x99: case 0xA8: case 0xA9: case 0xC0: case 0xC1:
    case 0xC6: case 0xC7: case 0xD0: case 0xD1: case 0xE9:
    case 0xEB:
      return TRUE;
  }
  return FALSE;
}

U0 JitCount(CWasmBuf *f,I64 prefix=0)
{
  WasmArg(f,W_LOCAL_GET,4);WasmI64(f,jit_decode.n);
  WasmByte(f,W_I64_MUL);
  if (prefix) {
    WasmI64(f,prefix);WasmByte(f,W_I64_ADD);
  }
  WasmByte(f,W_I32_WRAP_I64);
}

U0 JitAnother(CWasmBuf *f)
{
  WasmArg(f,W_LOCAL_GET,4);WasmI64(f,1024);WasmByte(f,W_I64_LT_U);
  WasmArg(f,W_LOCAL_GET,4);WasmI64(f,1);WasmByte(f,W_I64_ADD);
  WasmI64(f,jit_decode.n);WasmByte(f,W_I64_MUL);
  WasmArg(f,W_GLOBAL_GET,0);WasmByte(f,W_I64_LE_U);
  WasmByte(f,W_I32_AND);
}

U0 JitLoopRip(CWasmBuf *f)
{
  WasmI32(f,jit_rip_addr);WasmI64(f,jit_decode.rip);
  if (!jit_decode.top_loop) {
    WasmI64(f,jit_decode.loop_fall);JitCond(f,jit_decode.loop_cc);
    WasmByte(f,W_SELECT);
  }
  WasmSt64(f);
}

U0 JitFinish(CWasmBuf *f)
{
  I64 k,end,span=jit_decode.i-jit_code_start;
  CJitSegment *segment;
  CWasmBuf *g=&jit_guard,*exit=&jit_exit,*entry=&jit_entry;
  for (k=jit_segment_cnt-1;k>0;k--) {
    segment=&jit_segments[k];end=jit_decode.i-jit_gbase;
    if (k+1<jit_segment_cnt) end=jit_segments[k+1].start;
    g->cnt=0;g->overflow=FALSE;
    JitCodeGuard(g,segment->start,jit_code+segment->start-jit_decode.rip,
	  end-segment->start,&segment->exit);
    WasmInsert(f,segment->at,g->data,g->cnt);
  }
  if (jit_decode.top_loop) {
    exit->cnt=0;exit->overflow=FALSE;
    WasmI32(exit,jit_rip_addr);WasmI64(exit,jit_decode.top_target);
    WasmSt64(exit);JitWriteBack(exit);
    JitCount(exit,jit_decode.top_count);WasmByte(exit,W_RETURN);
    WasmInsert(f,jit_decode.top_at,exit->data,exit->cnt);
  }
  if (jit_decode.top_loop || jit_decode.loop_cc>=0) {
    g->cnt=0;WasmArg(g,W_LOOP,0x40);WasmInsert(f,0,g->data,g->cnt);
    WasmArg(f,W_LOCAL_GET,4);WasmI64(f,1);WasmByte(f,W_I64_ADD);
    WasmArg(f,W_LOCAL_SET,4);
    exit->cnt=0;exit->overflow=FALSE;
    JitLoopRip(exit);JitWriteBack(exit);
    WasmI64(exit,jit_decode.rip);WasmArg(exit,W_CALL,2);
    JitCount(exit);WasmByte(exit,W_RETURN);
    JitCodeGuard(f,jit_decode.rip,jit_code,span,exit);
    JitAnother(f);
    if (!jit_decode.top_loop) {
      JitCond(f,jit_decode.loop_cc);WasmByte(f,W_I32_AND);
    }
    WasmArg(f,W_BR_IF,0);WasmByte(f,W_END);
    JitLoopRip(f);JitWriteBack(f);JitCount(f);
  } else {
    if (jit_decode.term) {
      WasmArg(f,W_LOCAL_SET,3);WasmI32(f,jit_rip_addr);
      WasmArg(f,W_LOCAL_GET,3);WasmSt64(f);
    } else {
      JitMaterialize(f);WasmI32(f,jit_rip_addr);
      WasmI64(f,jit_decode.i-jit_gbase);WasmSt64(f);
    }
    JitWriteBack(f);end=jit_decode.n;
    if (jit_decode.if_break) end|=1<<30;
    WasmI32(f,end);
  }
  entry->cnt=0;entry->overflow=FALSE;
  for (k=0;k<16;k++)
    if (jit_reg_used&1<<k) {
      WasmI32(entry,jit_reg+k*8);WasmLd64(entry);
      WasmArg(entry,W_LOCAL_SET,JIT_RC+k);
    }
  if (jit_x87) {
    WasmI32(entry,jit_fsp);WasmLd64(entry);
    WasmArg(entry,W_LOCAL_SET,JIT_FSP_LOCAL);
    if (jit_fcache)
      for (k=0;k<8;k++)
	if (jit_fused&1<<k) {
	  JitFAddr(entry,k);WasmMem(entry,W_F64_LOAD);
	  WasmArg(entry,W_LOCAL_SET,JIT_FPC+k);
	}
  }
  WasmInsert(f,0,entry->data,entry->cnt);
  g->cnt=0;exit->cnt=0;
  WasmI64(exit,jit_decode.rip);WasmArg(exit,W_CALL,2);
  WasmI32(exit,0);WasmByte(exit,W_RETURN);
  if (jit_segment_cnt>1) span=jit_segments[1].start-jit_decode.rip;
  JitCodeGuard(g,jit_decode.rip,jit_code,span,exit);
  WasmInsert(f,0,g->data,g->cnt);
  if (g->overflow || exit->overflow || entry->overflow ||
	jit_part_buf.overflow) f->overflow=TRUE;
}
