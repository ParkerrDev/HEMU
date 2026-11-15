#define JIT_MEM_SIZE 402653184
#define JIT_RC 19
#define JIT_FSP_LOCAL 35
#define JIT_FPC 37
#define JIT_VALUE 15
#define JIT_FVALUE 36

class CJitOperand
{
  I64 reg_num,rm,j,base,index,scale,disp;
  Bool is_mem,rip_rel,known_ram;
};

I64 jit_reg,jit_rip_addr,jit_gbase,jit_fs,jit_gs,jit_tsc;
I64 jit_fpr,jit_fsp,jit_sw,jit_cw,jit_xmm_lo,jit_xmm_hi,jit_seg;
I64 jit_reg_used,jit_reg_dirty,jit_fstack,jit_fused,jit_fdirty;
Bool jit_fcache,jit_fx,jit_x87;

U0 JitRegRd(CWasmBuf *f,I64 reg_num,I64 size,Bool rex)
{
  if (size==1 && !rex && 4<=reg_num<8) {
    jit_reg_used|=1<<(reg_num-4);
    WasmArg(f,W_LOCAL_GET,JIT_RC+reg_num-4);
    WasmI64(f,8);WasmByte(f,W_I64_SHR_U);
    WasmI64(f,0xFF);WasmByte(f,W_I64_AND);
  } else {
    jit_reg_used|=1<<reg_num;
    WasmArg(f,W_LOCAL_GET,JIT_RC+reg_num);
    if (size<8) {
      WasmI64(f,1<<(size*8)-1);WasmByte(f,W_I64_AND);
    }
  }
}

U0 JitRegWr(CWasmBuf *f,I64 reg_num,I64 size,Bool rex)
{//Consume the new value already on the WASM operand stack.
  I64 mask;
  if (size==1 && !rex && 4<=reg_num<8) {
    reg_num-=4;
    jit_reg_used|=1<<reg_num;jit_reg_dirty|=1<<reg_num;
    WasmI64(f,0xFF);WasmByte(f,W_I64_AND);
    WasmI64(f,8);WasmByte(f,W_I64_SHL);
    WasmArg(f,W_LOCAL_GET,JIT_RC+reg_num);
    WasmI64(f,~0xFF00);WasmByte(f,W_I64_AND);
    WasmByte(f,W_I64_OR);WasmArg(f,W_LOCAL_SET,JIT_RC+reg_num);
  } else {
    jit_reg_used|=1<<reg_num;jit_reg_dirty|=1<<reg_num;
    if (size<8) {
      mask=1<<(size*8)-1;
      WasmI64(f,mask);WasmByte(f,W_I64_AND);
      if (size<4) {
	WasmArg(f,W_LOCAL_GET,JIT_RC+reg_num);
	WasmI64(f,~mask);WasmByte(f,W_I64_AND);
	WasmByte(f,W_I64_OR);
      }
    }
    WasmArg(f,W_LOCAL_SET,JIT_RC+reg_num);
  }
}

U0 JitRspAdd(CWasmBuf *f,I64 delta)
{
  JitRegRd(f,4,8,TRUE);WasmI64(f,delta);WasmByte(f,W_I64_ADD);
  JitRegWr(f,4,8,TRUE);
}

U0 JitSpAddr(CWasmBuf *f)
{
  WasmI64(f,jit_gbase);JitRegRd(f,4,8,TRUE);
  WasmByte(f,W_I64_ADD);WasmByte(f,W_I32_WRAP_I64);
}

U0 JitEa(CWasmBuf *f,CJitOperand *m,I64 end_rip)
{
  if (m->rip_rel)
    WasmI64(f,end_rip+m->disp);
  else {
    WasmI64(f,m->disp);
    if (m->base>=0) {
      JitRegRd(f,m->base,8,TRUE);WasmByte(f,W_I64_ADD);
    }
    if (m->index>=0) {
      JitRegRd(f,m->index,8,TRUE);
      if (m->scale>1) {
	WasmI64(f,m->scale);WasmByte(f,W_I64_MUL);
      }
      WasmByte(f,W_I64_ADD);
    }
  }
  if (jit_seg==1 && jit_fs || jit_seg==2 && jit_gs) {
    if (jit_seg==1) WasmI32(f,jit_fs);
    else WasmI32(f,jit_gs);
    WasmLd64(f);WasmByte(f,W_I64_ADD);
  }
  WasmArg(f,W_LOCAL_SET,3);
  m->known_ram=!jit_seg && m->rip_rel &&
	0<=end_rip+m->disp<JIT_MEM_SIZE;
}

U0 JitMemAddr(CWasmBuf *f)
{
  WasmI64(f,jit_gbase);WasmArg(f,W_LOCAL_GET,3);
  WasmByte(f,W_I64_ADD);WasmByte(f,W_I32_WRAP_I64);
}

I64 JitAlign(I64 size)
{
  I64 res=0;
  while (size>1) {
    size>>=1;res++;
  }
  return res;
}

U0 JitMemRd(CWasmBuf *f,I64 size)
{
  I64 op=W_I64_LOAD;
  switch (size) {
    case 1: op=W_I64_LOAD8_U;break;
    case 2: op=W_I64_LOAD16_U;break;
    case 4: op=W_I64_LOAD32_U;break;
  }
  WasmMem(f,op,0,JitAlign(size));
}

U0 JitMemWr(CWasmBuf *f,I64 size)
{
  I64 op=W_I64_STORE;
  switch (size) {
    case 1: op=W_I64_STORE8;break;
    case 2: op=W_I64_STORE16;break;
    case 4: op=W_I64_STORE32;break;
  }
  WasmMem(f,op,0,JitAlign(size));
}

U0 JitRmRd(CWasmBuf *f,CJitOperand *m,I64 size,Bool rex)
{
  if (!m->is_mem)
    JitRegRd(f,m->rm,size,rex);
  else if (m->known_ram) {
    JitMemAddr(f);JitMemRd(f,size);
  } else {
    WasmArg(f,W_LOCAL_GET,3);WasmI64(f,JIT_MEM_SIZE);
    WasmByte(f,W_I64_LT_U);WasmIf(f,0x7E);
    JitMemAddr(f);JitMemRd(f,size);
    WasmByte(f,W_ELSE);
    WasmArg(f,W_LOCAL_GET,3);WasmI64(f,size);WasmArg(f,W_CALL,0);
    WasmByte(f,W_END);
  }
}

U0 JitRmWr(CWasmBuf *f,CJitOperand *m,I64 size,Bool rex)
{
  if (!m->is_mem)
    JitRegWr(f,m->rm,size,rex);
  else {
    WasmArg(f,W_LOCAL_SET,JIT_VALUE);
    if (!m->known_ram) {
      WasmArg(f,W_LOCAL_GET,3);WasmI64(f,JIT_MEM_SIZE);
      WasmByte(f,W_I64_LT_U);WasmIf(f);
    }
    JitMemAddr(f);WasmArg(f,W_LOCAL_GET,JIT_VALUE);JitMemWr(f,size);
    if (!m->known_ram) {
      WasmByte(f,W_ELSE);WasmArg(f,W_LOCAL_GET,3);WasmI64(f,size);
      WasmArg(f,W_LOCAL_GET,JIT_VALUE);WasmArg(f,W_CALL,1);
      WasmByte(f,W_END);
    }
  }
}

U0 JitFAddr(CWasmBuf *f,I64 index)
{
  jit_x87=TRUE;
  WasmArg(f,W_LOCAL_GET,JIT_FSP_LOCAL);
  if (index) {
    WasmI64(f,index);WasmByte(f,W_I64_ADD);
  }
  WasmI64(f,7);WasmByte(f,W_I64_AND);
  WasmI64(f,8);WasmByte(f,W_I64_MUL);
  WasmI64(f,jit_fpr);WasmByte(f,W_I64_ADD);
  WasmByte(f,W_I32_WRAP_I64);
}

U0 JitFRd(CWasmBuf *f,I64 index)
{
  I64 slot;
  if (!jit_fcache) {
    JitFAddr(f,index);WasmMem(f,W_F64_LOAD);
  } else {
    slot=(jit_fstack+index)&7;
    jit_x87=TRUE;
    if (!(jit_fdirty&1<<slot)) jit_fused|=1<<slot;
    WasmArg(f,W_LOCAL_GET,JIT_FPC+slot);
  }
}

U0 JitFWr(CWasmBuf *f,I64 index)
{
  I64 slot;
  if (!jit_fcache) {
    WasmArg(f,W_LOCAL_SET,JIT_FVALUE);JitFAddr(f,index);
    WasmArg(f,W_LOCAL_GET,JIT_FVALUE);WasmMem(f,W_F64_STORE);
  } else {
    slot=(jit_fstack+index)&7;
    jit_x87=TRUE;jit_fdirty|=1<<slot;
    WasmArg(f,W_LOCAL_SET,JIT_FPC+slot);
  }
}

U0 JitFInc(CWasmBuf *f,I64 delta)
{
  jit_x87=TRUE;
  if (jit_fcache)
    jit_fstack=(jit_fstack+delta)&7;
  else {
    WasmArg(f,W_LOCAL_GET,JIT_FSP_LOCAL);
    WasmI64(f,delta);WasmByte(f,W_I64_ADD);
    WasmI64(f,7);WasmByte(f,W_I64_AND);
    WasmArg(f,W_LOCAL_SET,JIT_FSP_LOCAL);
  }
}

U0 JitFPush(CWasmBuf *f)
{
  WasmArg(f,W_LOCAL_SET,5);JitFInc(f,-1);
  WasmArg(f,W_LOCAL_GET,5);JitFWr(f,0);
}

U0 JitFStatus(CWasmBuf *f)
{
  jit_x87=TRUE;
  WasmI32(f,jit_sw);WasmLd64(f);
  WasmI64(f,~0x3800);WasmByte(f,W_I64_AND);
  WasmArg(f,W_LOCAL_GET,JIT_FSP_LOCAL);
  if (jit_fcache && jit_fstack) {
    WasmI64(f,jit_fstack);WasmByte(f,W_I64_ADD);
  }
  WasmI64(f,7);WasmByte(f,W_I64_AND);
  WasmI64(f,11);WasmByte(f,W_I64_SHL);WasmByte(f,W_I64_OR);
}

U0 JitWriteBack(CWasmBuf *f)
{//Every observable exit exposes only its completed instruction prefix.
  I64 reg_num;
  for (reg_num=0;reg_num<16;reg_num++)
    if (jit_reg_dirty&1<<reg_num) {
      WasmI32(f,jit_reg+reg_num*8);WasmArg(f,W_LOCAL_GET,JIT_RC+reg_num);
      WasmSt64(f);
    }
  if (jit_x87) {
    if (jit_fcache)
      for (reg_num=0;reg_num<8;reg_num++)
	if (jit_fdirty&1<<reg_num) {
	  JitFAddr(f,reg_num);WasmArg(f,W_LOCAL_GET,JIT_FPC+reg_num);
	  WasmMem(f,W_F64_STORE);
	}
    WasmI32(f,jit_fsp);WasmArg(f,W_LOCAL_GET,JIT_FSP_LOCAL);
    if (jit_fcache && jit_fstack) {
      WasmI64(f,jit_fstack);WasmByte(f,W_I64_ADD);
      WasmI64(f,7);WasmByte(f,W_I64_AND);
    }
    WasmSt64(f);
  }
}
