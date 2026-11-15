Bool JitTwoOp(CWasmBuf *f)
{
  CJitDecode *d=&jit_decode;
  CJitOperand m;
  I64 op=d->op,j=d->j,size=d->size,rex=d->rex,
	width,target,ext,which,bit,offset,mask,k;
  if (op==0x31 && jit_tsc) {
    WasmI32(f,jit_tsc);WasmLd64(f);JitRegWr(f,0,4,rex);
    WasmI32(f,jit_tsc);WasmLd64(f);WasmI64(f,32);
    WasmByte(f,W_I64_SHR_U);JitRegWr(f,2,4,rex);
  } else if (op==0xAF) {
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    JitRegRd(f,m.reg_num,size,rex);WasmArg(f,W_LOCAL_SET,0);
    JitRmRd(f,&m,size,rex);WasmArg(f,W_LOCAL_SET,1);
    JitMulValue(f,size,TRUE);WasmArg(f,W_LOCAL_GET,2);
    JitRegWr(f,m.reg_num,size,rex);
  } else if (0x40<=op<=0x4F) {
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    JitMaterialize(f);
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    JitRmRd(f,&m,size,rex);JitRegRd(f,m.reg_num,size,rex);
    JitCond(f,op&15);WasmByte(f,W_SELECT);
    JitRegWr(f,m.reg_num,size,rex);
  } else if (0x90<=op<=0x9F) {
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    JitMaterialize(f);
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    JitCond(f,op&15);WasmByte(f,W_I64_EXTEND_I32_U);
    JitRmWr(f,&m,1,rex);
  } else if (op==0xB6 || op==0xB7 || op==0xBE || op==0xBF) {
    width=1;if (op&1) width=2;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    JitRmRd(f,&m,width,rex);
    if (op&8) JitSign(f,width);
    else JitMask(f,width);
    JitRegWr(f,m.reg_num,size,rex);
  } else if (0x80<=op<=0x8F) {
    target=j+4-jit_gbase+JitImm(j,4);j+=4;
    if (!JitTopBranch(f,op&15,target,j-jit_gbase) &&
	!JitForwardBranch(f,op&15,target,j-jit_gbase)) {
      JitMaterialize(f);
      if (target==d->rip && !d->no_loop) {
	d->loop_cc=op&15;d->loop_fall=j-jit_gbase;
      } else {
	WasmI64(f,target);WasmI64(f,j-jit_gbase);
	JitCond(f,op&15);WasmByte(f,W_SELECT);
      }
      d->term=TRUE;
    }
  } else if (op==0xBA) {
    which=d->ext-4;
    if (which<0) return FALSE;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    bit=JitCodeByte(j++)&(size*8-1);width=size;
    JitMaterialize(f);
    if (m.is_mem) {
      JitEa(f,&m,j-jit_gbase);offset=bit>>3;bit&=7;width=1;
      if (offset) {
	WasmArg(f,W_LOCAL_GET,3);WasmI64(f,offset);
	WasmByte(f,W_I64_ADD);WasmArg(f,W_LOCAL_SET,3);
      }
    }
    mask=1<<bit;JitRmRd(f,&m,width,rex);WasmArg(f,W_LOCAL_SET,0);
    WasmI32(f,jit_rfl);WasmI32(f,jit_rfl);WasmLd64(f);
    WasmI64(f,-2);WasmByte(f,W_I64_AND);
    WasmArg(f,W_LOCAL_GET,0);WasmI64(f,bit);WasmByte(f,W_I64_SHR_U);
    WasmI64(f,1);WasmByte(f,W_I64_AND);WasmByte(f,W_I64_OR);
    WasmSt64(f);
    if (which) {
      WasmArg(f,W_LOCAL_GET,0);
      if (which==1) {WasmI64(f,mask);WasmByte(f,W_I64_OR);}
      else if (which==2) {WasmI64(f,~mask);WasmByte(f,W_I64_AND);}
      else {WasmI64(f,mask);WasmByte(f,W_I64_XOR);}
      JitRmWr(f,&m,width,rex);
    }
  } else if (op==0x1F) {
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
  } else if (op==0xAE && jit_cw && jit_sw && jit_fpr &&
	jit_xmm_lo && jit_xmm_hi) {
    ext=d->ext;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);
    if (ext!=0 && ext!=1 || !m.is_mem) return FALSE;
    if (jit_fcache && jit_x87) {d->retry_fpr=TRUE;return FALSE;}
    jit_fx=TRUE;j=m.j;JitEa(f,&m,j-jit_gbase);JitRamOperand(f,512);
    if (!ext) {
      JitMemAddr(f);WasmI32(f,jit_cw);WasmLd64(f);
      WasmMem(f,W_I64_STORE16,0,1);
      JitMemAddr(f);WasmI32(f,jit_sw);WasmLd64(f);
      WasmMem(f,W_I64_STORE16,2,1);
      JitMemAddr(f);WasmI64(f,0x1F80);WasmMem(f,W_I64_STORE32,24,2);
      for (k=0;k<8;k++) {
	JitMemAddr(f);WasmI32(f,jit_fpr+k*8);WasmLd64(f);
	WasmMem(f,W_I64_STORE,32+k*16);
      }
      for (k=0;k<16;k++) {
	JitMemAddr(f);WasmI32(f,jit_xmm_lo+k*8);WasmLd64(f);
	WasmMem(f,W_I64_STORE,160+k*16);
	JitMemAddr(f);WasmI32(f,jit_xmm_hi+k*8);WasmLd64(f);
	WasmMem(f,W_I64_STORE,168+k*16);
      }
    } else {
      WasmI32(f,jit_cw);JitMemAddr(f);WasmMem(f,W_I64_LOAD16_U,0,1);
      WasmSt64(f);
      WasmI32(f,jit_sw);JitMemAddr(f);WasmMem(f,W_I64_LOAD16_U,2,1);
      WasmSt64(f);
      for (k=0;k<8;k++) {
	WasmI32(f,jit_fpr+k*8);JitMemAddr(f);
	WasmMem(f,W_I64_LOAD,32+k*16);WasmSt64(f);
      }
      for (k=0;k<16;k++) {
	WasmI32(f,jit_xmm_lo+k*8);JitMemAddr(f);
	WasmMem(f,W_I64_LOAD,160+k*16);WasmSt64(f);
	WasmI32(f,jit_xmm_hi+k*8);JitMemAddr(f);
	WasmMem(f,W_I64_LOAD,168+k*16);WasmSt64(f);
      }
    }
  } else if (op==0x30 && jit_fs && jit_gs) {
    JitMaterialize(f);
    JitRegRd(f,2,4,TRUE);WasmI64(f,32);WasmByte(f,W_I64_SHL);
    JitRegRd(f,0,4,TRUE);WasmByte(f,W_I64_OR);WasmArg(f,W_LOCAL_SET,0);
    JitRegRd(f,1,4,TRUE);WasmArg(f,W_LOCAL_SET,1);
    for (k=0;k<2;k++) {
      WasmArg(f,W_LOCAL_GET,1);WasmI64(f,0xC0000100+k);
      WasmByte(f,W_I64_EQ);WasmIf(f);
      if (k) WasmI32(f,jit_gs);
      else WasmI32(f,jit_fs);
      WasmArg(f,W_LOCAL_GET,0);WasmSt64(f);WasmByte(f,W_END);
    }
    WasmI64(f,j-jit_gbase);WasmI64(f,d->i-jit_gbase);
    WasmArg(f,W_LOCAL_GET,1);WasmI64(f,0xC0000100);
    WasmByte(f,W_I64_EQ);WasmArg(f,W_LOCAL_GET,1);
    WasmI64(f,0xC0000101);WasmByte(f,W_I64_EQ);
    WasmByte(f,W_I32_OR);WasmByte(f,W_SELECT);d->term=TRUE;
  } else return FALSE;
  d->j=j;
  return TRUE;
}
