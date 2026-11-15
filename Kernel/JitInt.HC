U0 JitSign(CWasmBuf *f,I64 size)
{
  switch (size) {
    case 1: WasmByte(f,W_I64_EXTEND8_S);break;
    case 2: WasmByte(f,W_I64_EXTEND16_S);break;
    case 4: WasmByte(f,W_I64_EXTEND32_S);break;
  }
}

U0 JitMask(CWasmBuf *f,I64 size)
{
  if (size<8) {
    WasmI64(f,1<<(size*8)-1);WasmByte(f,W_I64_AND);
  }
}

U0 JitAluValue(CWasmBuf *f,I64 grp,I64 size)
{//Operands are locals 0 and 1; the result goes to local 2.
  I64 op=W_I64_SUB;
  switch (grp) {
    case 0: case 2: op=W_I64_ADD;break;
    case 1: op=W_I64_OR;break;
    case 4: op=W_I64_AND;break;
    case 6: op=W_I64_XOR;break;
  }
  if (grp==2 || grp==3) {
    WasmI32(f,jit_rfl);WasmLd64(f);WasmI64(f,1);
    WasmByte(f,W_I64_AND);WasmArg(f,W_LOCAL_SET,6);
  }
  WasmArg(f,W_LOCAL_GET,0);WasmArg(f,W_LOCAL_GET,1);WasmByte(f,op);
  if (grp==2 || grp==3) {
    WasmArg(f,W_LOCAL_GET,6);WasmByte(f,op);JitMask(f,size);
  }
  WasmArg(f,W_LOCAL_SET,2);
}

U0 JitAluFlags(CWasmBuf *f,I64 grp,I64 size)
{
  if (grp==2 || grp==3) JitAdcFlags(f,grp==3,size);
  else if (!grp) JitDefer(f,0,size);
  else if (grp==5 || grp==7) JitDefer(f,1,size);
  else JitDefer(f,2,size);
}

U0 JitMulValue(CWasmBuf *f,I64 size,Bool is_signed)
{//Low product in local 2 and upper operand-sized half in local 1.
  I64 i,left,right;
  CWasmBuf *g=&jit_part;
  if (size==8) {
    WasmArg(f,W_LOCAL_GET,0);WasmArg(f,W_LOCAL_GET,1);
    WasmByte(f,W_I64_MUL);WasmArg(f,W_LOCAL_SET,2);
    for (i=0;i<2;i++) {
      WasmArg(f,W_LOCAL_GET,i);WasmI64(f,0xFFFFFFFF);
      WasmByte(f,W_I64_AND);WasmArg(f,W_LOCAL_SET,6+i*2);
      WasmArg(f,W_LOCAL_GET,i);WasmI64(f,32);
      WasmByte(f,W_I64_SHR_U);WasmArg(f,W_LOCAL_SET,7+i*2);
    }
    for (i=0;i<4;i++) {
      left=6+i>>1;right=8+i&1;
      WasmArg(f,W_LOCAL_GET,left);WasmArg(f,W_LOCAL_GET,right);
      WasmByte(f,W_I64_MUL);WasmArg(f,W_LOCAL_SET,10+i);
    }
    WasmArg(f,W_LOCAL_GET,10);WasmI64(f,32);WasmByte(f,W_I64_SHR_U);
    for (i=11;i<=12;i++) {
      WasmArg(f,W_LOCAL_GET,i);WasmI64(f,0xFFFFFFFF);
      WasmByte(f,W_I64_AND);WasmByte(f,W_I64_ADD);
    }
    WasmArg(f,W_LOCAL_SET,14);WasmArg(f,W_LOCAL_GET,13);
    for (i=11;i<=14;i++)
      if (i!=13) {
	WasmArg(f,W_LOCAL_GET,i);WasmI64(f,32);
	WasmByte(f,W_I64_SHR_U);WasmByte(f,W_I64_ADD);
      }
    if (is_signed)
      for (i=0;i<2;i++) {
	WasmArg(f,W_LOCAL_GET,i);WasmI64(f,63);
	WasmByte(f,W_I64_SHR_S);WasmArg(f,W_LOCAL_GET,1-i);
	WasmByte(f,W_I64_AND);WasmByte(f,W_I64_SUB);
      }
    WasmArg(f,W_LOCAL_SET,1);
  } else {
    for (i=0;i<2;i++) {
      WasmArg(f,W_LOCAL_GET,i);
      if (is_signed) JitSign(f,size);
    }
    WasmByte(f,W_I64_MUL);WasmArg(f,W_LOCAL_SET,2);
    WasmArg(f,W_LOCAL_GET,2);WasmI64(f,size*8);
    WasmByte(f,W_I64_SHR_U);JitMask(f,size);WasmArg(f,W_LOCAL_SET,1);
  }
  g->cnt=0;g->overflow=FALSE;
  WasmI32(g,jit_rfl);WasmI32(g,jit_rfl);WasmLd64(g);
  WasmI64(g,~0x801);WasmByte(g,W_I64_AND);
  if (is_signed && size<8) {
    WasmArg(g,W_LOCAL_GET,2);JitSign(g,size);
    WasmArg(g,W_LOCAL_GET,2);WasmByte(g,W_I64_NE);
  } else {
    WasmArg(g,W_LOCAL_GET,1);
    if (is_signed) {
      WasmArg(g,W_LOCAL_GET,2);WasmI64(g,63);WasmByte(g,W_I64_SHR_S);
    } else WasmI64(g,0);
    WasmByte(g,W_I64_NE);
  }
  WasmByte(g,W_I64_EXTEND_I32_U);WasmI64(g,0x801);
  WasmByte(g,W_I64_MUL);WasmByte(g,W_I64_OR);WasmSt64(g);
  JitPartial(f,g);
}

U0 JitDivExit(CWasmBuf *f)
{//The condition on the stack asks the interpreter to handle this instruction.
  jit_decode.side_exit=TRUE;WasmIf(f);JitMaterialize(f);
  WasmI32(f,jit_rip_addr);WasmI64(f,jit_decode.i-jit_gbase);
  WasmSt64(f);JitWriteBack(f);WasmI32(f,jit_decode.n);
  WasmByte(f,W_RETURN);WasmByte(f,W_END);
}

U0 JitAdvance(CWasmBuf *f,I64 reg_num)
{
  JitRegRd(f,reg_num,8,TRUE);WasmArg(f,W_LOCAL_GET,6);
  WasmByte(f,W_I64_ADD);JitRegWr(f,reg_num,8,TRUE);
}

U0 JitStringBody(CWasmBuf *f,I64 op,I64 size,Bool rex,Bool eager)
{
  CJitOperand mem;
  mem.is_mem=TRUE;mem.known_ram=FALSE;
  if (op==0xAC || op==0xAD) {
    JitRegRd(f,6,8,TRUE);WasmArg(f,W_LOCAL_SET,3);
    JitRmRd(f,&mem,size,rex);JitRegWr(f,0,size,rex);JitAdvance(f,6);
  } else if (op==0xAA || op==0xAB) {
    JitRegRd(f,7,8,TRUE);WasmArg(f,W_LOCAL_SET,3);
    JitRegRd(f,0,size,rex);JitRmWr(f,&mem,size,rex);JitAdvance(f,7);
  } else if (op==0xA4 || op==0xA5) {
    JitRegRd(f,6,8,TRUE);WasmArg(f,W_LOCAL_SET,3);
    JitRmRd(f,&mem,size,rex);WasmArg(f,W_LOCAL_SET,0);
    JitRegRd(f,7,8,TRUE);WasmArg(f,W_LOCAL_SET,3);
    WasmArg(f,W_LOCAL_GET,0);JitRmWr(f,&mem,size,rex);
    JitAdvance(f,6);JitAdvance(f,7);
  } else {
    if (op==0xAE || op==0xAF) JitRegRd(f,0,size,rex);
    else {
      JitRegRd(f,6,8,TRUE);WasmArg(f,W_LOCAL_SET,3);
      JitRmRd(f,&mem,size,rex);
    }
    WasmArg(f,W_LOCAL_SET,0);
    JitRegRd(f,7,8,TRUE);WasmArg(f,W_LOCAL_SET,3);
    JitRmRd(f,&mem,size,rex);WasmArg(f,W_LOCAL_SET,1);
    WasmArg(f,W_LOCAL_GET,0);WasmArg(f,W_LOCAL_GET,1);
    WasmByte(f,W_I64_SUB);WasmArg(f,W_LOCAL_SET,2);
    if (eager) JitFlags(f,1,size);
    else JitDefer(f,1,size);
    if (op==0xA6 || op==0xA7) JitAdvance(f,6);
    JitAdvance(f,7);
  }
}

U0 JitRotateFlags(CWasmBuf *g,I64 bits,I64 cnt,I64 opn)
{
  WasmI32(g,jit_rfl);WasmI32(g,jit_rfl);WasmLd64(g);
  if (cnt==1) WasmI64(g,~0x801);
  else WasmI64(g,~1);
  WasmByte(g,W_I64_AND);WasmArg(g,W_LOCAL_GET,1);WasmByte(g,W_I64_OR);
  if (cnt==1) {
    WasmArg(g,W_LOCAL_GET,2);WasmI64(g,bits-1);WasmByte(g,W_I64_SHR_U);
    if (opn) {
      WasmArg(g,W_LOCAL_GET,2);WasmI64(g,bits-2);
      WasmByte(g,W_I64_SHR_U);
    } else WasmArg(g,W_LOCAL_GET,1);
    WasmByte(g,W_I64_XOR);WasmI64(g,1);WasmByte(g,W_I64_AND);
    WasmI64(g,0x800);WasmByte(g,W_I64_MUL);WasmByte(g,W_I64_OR);
  }
  WasmSt64(g);
}

Bool JitIntOp(CWasmBuf *f)
{
  CJitDecode *d=&jit_decode;
  CJitOperand m;
  CWasmBuf *g=&jit_part;
  I64 op=d->op,j=d->j,szv=d->size,rex=d->rex,lo=op&7,grp=op>>3,
    size,width,value,ext=d->ext,reg_num,target,cnt,bits,rotate,shift,opn;
  Bool dst_rm,is_signed,compare;
  if (op==0x88 || op==0x89 || op==0x8A || op==0x8B) {
    size=1;if (op&1) size=szv;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    if (op&2) {
      JitRmRd(f,&m,size,rex);JitRegWr(f,m.reg_num,size,rex);
    } else {
      JitRegRd(f,m.reg_num,size,rex);JitRmWr(f,&m,size,rex);
    }
  } else if (op==0xD7) {
    m.is_mem=TRUE;m.disp=0;m.base=3;m.index=-1;m.scale=1;
    m.rip_rel=FALSE;m.known_ram=FALSE;
    JitEa(f,&m,j-jit_gbase);WasmArg(f,W_LOCAL_GET,3);
    JitRegRd(f,0,1,TRUE);WasmByte(f,W_I64_ADD);WasmArg(f,W_LOCAL_SET,3);
    JitRmRd(f,&m,1,TRUE);JitRegWr(f,0,1,TRUE);
  } else if (op==0xC6 || op==0xC7) {
    size=szv;if (op==0xC6) size=1;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    value=JitImm(j,size);j+=JitImmLen(size);
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    WasmI64(f,value);JitRmWr(f,&m,size,rex);
  } else if (0xB0<=op<=0xBF) {
    size=szv;if (op<0xB8) size=1;
    reg_num=op&7|d->rex_b<<3;
    if (size==8) value=JitImm64(j);
    else value=JitImm(j,size);
    j+=size;WasmI64(f,value);JitRegWr(f,reg_num,size,rex);
  } else if (op<0x40 && lo<=3) {
    size=1;if (op&1) size=szv;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    dst_rm=lo<=1;
    if (grp==2 || grp==3) JitMaterialize(f);
    if (dst_rm) JitRmRd(f,&m,size,rex);
    else JitRegRd(f,m.reg_num,size,rex);
    WasmArg(f,W_LOCAL_SET,0);
    if (dst_rm) JitRegRd(f,m.reg_num,size,rex);
    else JitRmRd(f,&m,size,rex);
    WasmArg(f,W_LOCAL_SET,1);JitAluValue(f,grp,size);
    if (grp!=7) {
      WasmArg(f,W_LOCAL_GET,2);
      if (dst_rm) JitRmWr(f,&m,size,rex);
      else JitRegWr(f,m.reg_num,size,rex);
    }
    JitAluFlags(f,grp,size);
  } else if (op<0x40 && (lo==4 || lo==5)) {
    size=szv;if (lo==4) size=1;
    value=JitImm(j,size);j+=JitImmLen(size);
    if (grp==2 || grp==3) JitMaterialize(f);
    JitRegRd(f,0,size,rex);WasmArg(f,W_LOCAL_SET,0);
    WasmI64(f,value);WasmArg(f,W_LOCAL_SET,1);JitAluValue(f,grp,size);
    if (grp!=7) {
      WasmArg(f,W_LOCAL_GET,2);JitRegWr(f,0,size,rex);
    }
    JitAluFlags(f,grp,size);
  } else if (op==0x80 || op==0x81 || op==0x83) {
    size=szv;if (op==0x80) size=1;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (op==0x81) {value=JitImm(j,size);j+=JitImmLen(size);}
    else {value=JitImm(j,1);j++;}
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    if (ext==2 || ext==3) JitMaterialize(f);
    JitRmRd(f,&m,size,rex);WasmArg(f,W_LOCAL_SET,0);
    WasmI64(f,value);WasmArg(f,W_LOCAL_SET,1);JitAluValue(f,ext,size);
    if (ext!=7) {WasmArg(f,W_LOCAL_GET,2);JitRmWr(f,&m,size,rex);}
    JitAluFlags(f,ext,size);
  } else if (op==0x84 || op==0x85 || op==0xA8 || op==0xA9) {
    size=1;if (op&1) size=szv;
    if (op<0xA0) {
      JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
      if (m.is_mem) JitEa(f,&m,j-jit_gbase);
      JitRmRd(f,&m,size,rex);WasmArg(f,W_LOCAL_SET,0);
      JitRegRd(f,m.reg_num,size,rex);
    } else {
      value=JitImm(j,size);j+=JitImmLen(size);
      JitRegRd(f,0,size,rex);WasmArg(f,W_LOCAL_SET,0);WasmI64(f,value);
    }
    WasmArg(f,W_LOCAL_SET,1);JitAluValue(f,4,size);JitDefer(f,2,size);
  } else if (op==0x8D) {
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (!m.is_mem) return FALSE;
    JitEa(f,&m,j-jit_gbase);WasmArg(f,W_LOCAL_GET,3);
    JitRegWr(f,m.reg_num,szv,rex);
  } else if (op==0xFE || op==0xFF) {
    size=szv;if (op==0xFE) size=1;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (ext<=1) {
      if (m.is_mem) JitEa(f,&m,j-jit_gbase);
      JitRmRd(f,&m,size,rex);WasmArg(f,W_LOCAL_SET,0);
      WasmI64(f,1);WasmArg(f,W_LOCAL_SET,1);
      WasmArg(f,W_LOCAL_GET,0);WasmArg(f,W_LOCAL_GET,1);
      if (!ext) WasmByte(f,W_I64_ADD);
      else WasmByte(f,W_I64_SUB);
      WasmArg(f,W_LOCAL_SET,2);WasmArg(f,W_LOCAL_GET,2);
      JitRmWr(f,&m,size,rex);g->cnt=0;g->overflow=FALSE;
      JitIncFlags(g,size,ext);JitPartial(f,g);
    } else if (op==0xFF && (ext==2 || ext==4)) {
      JitMaterialize(f);
      if (ext==2) JitStackOperand(f,-8);
      if (m.is_mem) JitEa(f,&m,j-jit_gbase);
      JitRmRd(f,&m,8,TRUE);WasmArg(f,W_LOCAL_SET,0);
      if (ext==2) {
	JitRspAdd(f,-8);JitSpAddr(f);WasmI64(f,j-jit_gbase);WasmSt64(f);
      }
      WasmArg(f,W_LOCAL_GET,0);d->term=TRUE;
    } else if (op==0xFF && ext==6) {
      width=8;if (szv==2) width=2;
      JitStackOperand(f,-width);
      if (m.is_mem) JitEa(f,&m,j-jit_gbase);
      JitRmRd(f,&m,width,TRUE);WasmArg(f,W_LOCAL_SET,0);
      JitRspAdd(f,-width);JitSpAddr(f);WasmArg(f,W_LOCAL_GET,0);
      JitMemWr(f,width);
    } else return FALSE;
  } else if (0x50<=op<=0x5F) {
    reg_num=op&7|d->rex_b<<3;width=8;if (szv==2) width=2;
    if (op<0x58) {
      JitStackOperand(f,-width);JitRegRd(f,reg_num,width,TRUE);
      WasmArg(f,W_LOCAL_SET,0);JitRspAdd(f,-width);JitSpAddr(f);
      WasmArg(f,W_LOCAL_GET,0);JitMemWr(f,width);
    } else {
      JitStackOperand(f);JitSpAddr(f);JitMemRd(f,width);
      WasmArg(f,W_LOCAL_SET,0);JitRspAdd(f,width);
      WasmArg(f,W_LOCAL_GET,0);JitRegWr(f,reg_num,width,TRUE);
    }
  } else if (op==0x63) {
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    JitRmRd(f,&m,4,rex);JitSign(f,4);JitRegWr(f,m.reg_num,8,rex);
  } else if (0x70<=op<=0x7F) {
    target=j+1-jit_gbase+JitImm(j,1);j++;
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
  } else if (op==0xEB || op==0xE9 || op==0xE8) {
    width=4;if (op==0xEB) width=1;
    target=j+width-jit_gbase+JitImm(j,width);j+=width;
    if (op==0xE8) {
      JitMaterialize(f);JitStackOperand(f,-8);JitRspAdd(f,-8);
      JitSpAddr(f);WasmI64(f,j-jit_gbase);WasmSt64(f);WasmI64(f,target);
    } else {
      d->top_loop=d->top_at>=0 && target==d->rip &&
	    d->top_target>=j-jit_gbase;
      JitMaterialize(f);
      if (!d->top_loop) WasmI64(f,target);
    }
    d->term=TRUE;
  } else if (op==0xC3 || op==0xC2) {
    value=0;
    if (op==0xC2) {value=JitImm(j,2)&0xFFFF;j+=2;}
    JitMaterialize(f);JitStackOperand(f);JitSpAddr(f);WasmLd64(f);
    JitRspAdd(f,8+value);d->term=TRUE;
  } else if (op==0xC9) {
    width=8;if (szv==2) width=2;
    JitStackOperand(f,0,5);JitRegRd(f,5,8,TRUE);JitRegWr(f,4,8,TRUE);
    JitSpAddr(f);JitMemRd(f,width);WasmArg(f,W_LOCAL_SET,0);
    JitRspAdd(f,width);WasmArg(f,W_LOCAL_GET,0);JitRegWr(f,5,width,TRUE);
  } else if (op==0x68 || op==0x6A) {
    width=8;if (szv==2) width=2;
    if (op==0x6A) {value=JitImm(j,1);j++;}
    else {value=JitImm(j,width);j+=JitImmLen(width);}
    JitStackOperand(f,-width);JitRspAdd(f,-width);JitSpAddr(f);
    WasmI64(f,value);JitMemWr(f,width);
  } else if (op==0x9C) {
    JitMaterialize(f);JitStackOperand(f,-8);JitRspAdd(f,-8);
    JitSpAddr(f);WasmI32(f,jit_rfl);WasmLd64(f);WasmSt64(f);
  } else if (op==0x9D) {
    JitStackOperand(f);jit_flags.kind=-1;jit_flags.cnt=0;
    jit_flags.first=jit_part_next;
    WasmI32(f,jit_rfl);JitSpAddr(f);WasmLd64(f);
    WasmI64(f,~0x10000);WasmByte(f,W_I64_AND);
    WasmI64(f,2);WasmByte(f,W_I64_OR);WasmSt64(f);JitRspAdd(f,8);
    WasmI64(f,j-jit_gbase);d->if_break=d->term=TRUE;
  } else if (op==0xCF) {
    JitStackOperand(f,0,4,40);jit_flags.kind=-1;jit_flags.cnt=0;
    jit_flags.first=jit_part_next;
    WasmI32(f,jit_rfl);JitSpAddr(f);WasmMem(f,W_I64_LOAD,16);WasmSt64(f);
    JitSpAddr(f);WasmLd64(f);WasmArg(f,W_LOCAL_SET,0);
    JitSpAddr(f);WasmMem(f,W_I64_LOAD,24);WasmArg(f,W_LOCAL_SET,1);
    WasmArg(f,W_LOCAL_GET,1);JitRegWr(f,4,8,TRUE);
    WasmArg(f,W_LOCAL_GET,0);d->if_break=d->term=TRUE;
  } else if (op==0x8F) {
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (m.reg_num&7) return FALSE;
    width=8;if (szv==2) width=2;
    JitStackOperand(f);JitSpAddr(f);JitMemRd(f,width);
    WasmArg(f,W_LOCAL_SET,0);JitRspAdd(f,width);
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    WasmArg(f,W_LOCAL_GET,0);JitRmWr(f,&m,width,TRUE);
  } else if (op==0x69 || op==0x6B) {
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (op==0x6B) {value=JitImm(j,1);j++;}
    else {value=JitImm(j,szv);j+=JitImmLen(szv);}
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    JitRmRd(f,&m,szv,rex);WasmArg(f,W_LOCAL_SET,0);
    WasmI64(f,value);WasmArg(f,W_LOCAL_SET,1);JitMulValue(f,szv,TRUE);
    WasmArg(f,W_LOCAL_GET,2);JitRegWr(f,m.reg_num,szv,rex);
  } else if (0xA4<=op<=0xA7 || 0xAA<=op<=0xAF) {
    size=1;if (op&1) size=szv;
    WasmI64(f,size);WasmI64(f,-size);WasmI32(f,jit_rfl);
    WasmMem(f,W_I32_LOAD,0,2);WasmI32(f,0x400);
    WasmByte(f,W_I32_AND);WasmByte(f,W_I32_EQZ);WasmByte(f,W_SELECT);
    WasmArg(f,W_LOCAL_SET,6);
    if (!d->rep) JitStringBody(f,op,size,rex,FALSE);
    else {
      compare=op==0xA6 || op==0xA7 || op==0xAE || op==0xAF;
      JitMaterialize(f);WasmByte(f,W_BLOCK);WasmByte(f,0x40);
      WasmByte(f,W_LOOP);WasmByte(f,0x40);
      JitRegRd(f,1,8,TRUE);WasmByte(f,W_I64_EQZ);WasmArg(f,W_BR_IF,1);
      JitStringBody(f,op,size,rex,TRUE);
      JitRegRd(f,1,8,TRUE);WasmI64(f,1);WasmByte(f,W_I64_SUB);
      JitRegWr(f,1,8,TRUE);
      if (compare) {
	if (d->rep==1) JitCond(f,4);
	else JitCond(f,5);
	WasmByte(f,W_I32_EQZ);WasmArg(f,W_BR_IF,1);
      }
      WasmArg(f,W_BR,0);WasmByte(f,W_END);WasmByte(f,W_END);
      WasmI64(f,j-jit_gbase);d->term=TRUE;
    }
  } else if (0xFA<=op<=0xFD) {
    value=0x400;if (op<=0xFB) value=0x200;
    JitMaterialize(f);WasmI32(f,jit_rfl);WasmI32(f,jit_rfl);WasmLd64(f);
    if (op&1) {WasmI64(f,value);WasmByte(f,W_I64_OR);}
    else {WasmI64(f,~value);WasmByte(f,W_I64_AND);}
    WasmSt64(f);
    if (op==0xFB) {
      WasmI64(f,j-jit_gbase);d->if_break=d->term=TRUE;
    }
  } else if (op==0xC0 || op==0xC1 || op==0xD0 || op==0xD1) {
    size=1;if (op&1) size=szv;
    opn=ext;JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    cnt=1;
    if (op<0xD0) {
      cnt=JitCodeByte(j++);
      if (size==8) cnt&=63;
      else cnt&=31;
    }
    if (m.is_mem) JitEa(f,&m,j-jit_gbase);
    bits=size*8;
    if (opn<2) {
      rotate=cnt%bits;JitRmRd(f,&m,size,rex);JitMask(f,size);
      WasmArg(f,W_LOCAL_SET,0);WasmArg(f,W_LOCAL_GET,0);
      if (size==8) {
	WasmI64(f,rotate);
	if (opn) WasmByte(f,W_I64_ROTR);
	else WasmByte(f,W_I64_ROTL);
      } else if (rotate) {
	WasmI64(f,rotate);
	if (opn) WasmByte(f,W_I64_SHR_U);
	else WasmByte(f,W_I64_SHL);
	WasmArg(f,W_LOCAL_GET,0);WasmI64(f,bits-rotate);
	if (opn) WasmByte(f,W_I64_SHL);
	else WasmByte(f,W_I64_SHR_U);
	WasmByte(f,W_I64_OR);JitMask(f,size);
      }
      WasmArg(f,W_LOCAL_SET,2);WasmArg(f,W_LOCAL_GET,2);
      JitRmWr(f,&m,size,rex);
      if (cnt) {
	WasmArg(f,W_LOCAL_GET,2);
	if (opn) WasmI64(f,bits-1);
	else WasmI64(f,0);
	WasmByte(f,W_I64_SHR_U);WasmI64(f,1);WasmByte(f,W_I64_AND);
	WasmArg(f,W_LOCAL_SET,1);g->cnt=0;g->overflow=FALSE;
	JitRotateFlags(g,bits,cnt,opn);JitPartial(f,g);
      }
    } else if (opn==4 || opn==5 || opn==7) {
      JitRmRd(f,&m,size,rex);WasmArg(f,W_LOCAL_SET,0);
      if (cnt) {
	WasmArg(f,W_LOCAL_GET,0);
	if (opn==7) JitSign(f,size);
	WasmI64(f,cnt);
	if (opn==4) WasmByte(f,W_I64_SHL);
	else if (opn==5) WasmByte(f,W_I64_SHR_U);
	else WasmByte(f,W_I64_SHR_S);
	if (opn!=5) JitMask(f,size);
	WasmArg(f,W_LOCAL_SET,2);WasmArg(f,W_LOCAL_GET,0);
	shift=cnt-1;
	if (opn==4) shift=bits-cnt;
	else if (opn==7 && cnt>bits) shift=bits-1;
	WasmI64(f,shift);WasmByte(f,W_I64_SHR_U);
	WasmI64(f,1);WasmByte(f,W_I64_AND);WasmArg(f,W_LOCAL_SET,1);
	WasmArg(f,W_LOCAL_GET,2);JitRmWr(f,&m,size,rex);
	g->cnt=0;g->overflow=FALSE;JitShiftFlags(g,size,cnt,opn);
	JitPartial(f,g);
      } else {WasmArg(f,W_LOCAL_GET,0);JitRmWr(f,&m,size,rex);}
    } else return FALSE;
  } else if (op==0xF6 || op==0xF7) {
    size=szv;if (op==0xF6) size=1;
    JitModRm(&m,j,d->rex_r,d->rex_x,d->rex_b);j=m.j;
    if (ext<=1) {
      value=JitImm(j,size);
      if (size==2) value&=0xFFFF;
      j+=JitImmLen(size);
      if (m.is_mem) JitEa(f,&m,j-jit_gbase);
      JitRmRd(f,&m,size,rex);WasmArg(f,W_LOCAL_SET,0);
      WasmI64(f,value);WasmArg(f,W_LOCAL_SET,1);
      JitAluValue(f,4,size);JitDefer(f,2,size);
    } else if (ext==2) {
      if (m.is_mem) JitEa(f,&m,j-jit_gbase);
      JitRmRd(f,&m,size,rex);WasmI64(f,-1);WasmByte(f,W_I64_XOR);
      JitRmWr(f,&m,size,rex);
    } else if (ext==3) {
      if (m.is_mem) JitEa(f,&m,j-jit_gbase);
      JitRmRd(f,&m,size,rex);WasmArg(f,W_LOCAL_SET,1);
      WasmI64(f,0);WasmArg(f,W_LOCAL_SET,0);JitAluValue(f,5,size);
      WasmArg(f,W_LOCAL_GET,2);JitRmWr(f,&m,size,rex);JitDefer(f,1,size);
    } else {
      if (ext>=6) JitMaterialize(f);
      if (m.is_mem) {
	JitEa(f,&m,j-jit_gbase);
	if (ext>=6 && !m.known_ram) {
	  WasmArg(f,W_LOCAL_GET,3);WasmI64(f,JIT_MEM_SIZE);
	  WasmByte(f,W_I64_GE_U);JitDivExit(f);
	}
      }
      JitRmRd(f,&m,size,rex);WasmArg(f,W_LOCAL_SET,0);
      if (ext<=5) {
	JitRegRd(f,0,size,rex);WasmArg(f,W_LOCAL_SET,1);
	JitMulValue(f,size,ext==5);WasmArg(f,W_LOCAL_GET,2);
	if (size==1) JitRegWr(f,0,2,TRUE);
	else {
	  JitRegWr(f,0,size,rex);WasmArg(f,W_LOCAL_GET,1);
	  JitRegWr(f,2,size,rex);
	}
      } else {
	is_signed=ext==7;
	if (is_signed && size<8) {
	  WasmArg(f,W_LOCAL_GET,0);JitSign(f,size);WasmArg(f,W_LOCAL_SET,0);
	}
	WasmArg(f,W_LOCAL_GET,0);WasmByte(f,W_I64_EQZ);JitDivExit(f);
	if (size==1) {
	  JitRegRd(f,0,2,TRUE);
	  if (is_signed) JitSign(f,2);
	  WasmArg(f,W_LOCAL_SET,1);
	} else if (size==8) {
	  JitRegRd(f,0,8,TRUE);WasmArg(f,W_LOCAL_SET,1);
	  JitRegRd(f,2,8,TRUE);
	  if (is_signed) {
	    WasmArg(f,W_LOCAL_GET,1);WasmI64(f,63);WasmByte(f,W_I64_SHR_S);
	  } else WasmI64(f,0);
	  WasmByte(f,W_I64_NE);JitDivExit(f);
	} else {
	  JitRegRd(f,2,size,rex);WasmI64(f,size*8);WasmByte(f,W_I64_SHL);
	  JitRegRd(f,0,size,rex);WasmByte(f,W_I64_OR);
	  if (is_signed && size==2) JitSign(f,4);
	  WasmArg(f,W_LOCAL_SET,1);
	}
	if (is_signed) {
	  WasmArg(f,W_LOCAL_GET,0);WasmI64(f,-1);WasmByte(f,W_I64_EQ);
	  WasmArg(f,W_LOCAL_GET,1);WasmI64(f,1<<63);WasmByte(f,W_I64_EQ);
	  WasmByte(f,W_I32_AND);JitDivExit(f);
	}
	WasmArg(f,W_LOCAL_GET,1);WasmArg(f,W_LOCAL_GET,0);
	if (is_signed) WasmByte(f,W_I64_DIV_S);
	else WasmByte(f,W_I64_DIV_U);
	WasmArg(f,W_LOCAL_SET,2);
	if (size<8) {
	  bits=size*8;
	  if (is_signed) bits--;
	  WasmArg(f,W_LOCAL_GET,2);WasmI64(f,1<<bits-1);
	  if (is_signed) WasmByte(f,W_I64_GT_S);
	  else WasmByte(f,W_I64_GT_U);
	  if (is_signed) {
	    WasmArg(f,W_LOCAL_GET,2);WasmI64(f,-(1<<(size*8-1)));
	    WasmByte(f,W_I64_LT_S);WasmByte(f,W_I32_OR);
	  }
	  JitDivExit(f);
	}
	WasmArg(f,W_LOCAL_GET,1);WasmArg(f,W_LOCAL_GET,0);
	if (is_signed) WasmByte(f,W_I64_REM_S);
	else WasmByte(f,W_I64_REM_U);
	WasmArg(f,W_LOCAL_SET,1);WasmArg(f,W_LOCAL_GET,2);
	if (size==1) {
	  WasmI64(f,255);WasmByte(f,W_I64_AND);WasmArg(f,W_LOCAL_GET,1);
	  WasmI64(f,255);WasmByte(f,W_I64_AND);WasmI64(f,8);
	  WasmByte(f,W_I64_SHL);WasmByte(f,W_I64_OR);JitRegWr(f,0,2,TRUE);
	} else {
	  JitRegWr(f,0,size,rex);WasmArg(f,W_LOCAL_GET,1);
	  JitRegWr(f,2,size,rex);
	}
      }
    }
  } else if (op==0x98) {
    if (d->rex_w) {size=8;width=4;}
    else if (szv==2) {size=2;width=1;}
    else {size=4;width=2;}
    JitRegRd(f,0,width,rex);JitSign(f,width);JitRegWr(f,0,size,rex);
  } else if (op==0x99) {
    size=4;if (d->rex_w) size=8;
    JitRegRd(f,0,size,rex);
    if (size==4) JitSign(f,4);
    WasmI64(f,63);WasmByte(f,W_I64_SHR_S);JitRegWr(f,2,size,rex);
  } else if (op!=0x90 || rex) return FALSE;
  d->j=j;
  return TRUE;
}
