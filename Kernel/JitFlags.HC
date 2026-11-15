U0 JitAuxCarry(CWasmBuf *f)
{
  WasmArg(f,W_LOCAL_GET,0);
  WasmArg(f,W_LOCAL_GET,1);
  WasmByte(f,W_I64_XOR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmByte(f,W_I64_XOR);
  WasmI64(f,0x10);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_OR);
}

U0 JitFlags(CWasmBuf *f,I64 kind,I64 sz)
{
  I64 high_bit,mask;
  high_bit=sz*8-1;
  if (sz==8) {
    mask=-1;
  } else {
    mask=1<<(sz*8)-1;
  }
  WasmI32(f,jit_rfl);
  WasmI32(f,jit_rfl);
  WasmLd64(f);
  WasmI64(f,~0x8D5);
  WasmByte(f,W_I64_AND);
  WasmArg(f,W_LOCAL_GET,2);
  if (mask!=-1) {
    WasmI64(f,mask);
    WasmByte(f,W_I64_AND);
  }
  WasmByte(f,W_I64_EQZ);
  WasmByte(f,W_I64_EXTEND_I32_U);
  WasmI64(f,0x40);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmI64(f,high_bit);
  WasmByte(f,W_I64_SHR_U);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmI64(f,0x80);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmI64(f,0xFF);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_POPCNT);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_EQZ);
  WasmByte(f,W_I64_EXTEND_I32_U);
  WasmI64(f,4);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  if (kind==0) {
    WasmArg(f,W_LOCAL_GET,2);
    if (mask!=-1) {
      WasmI64(f,mask);
      WasmByte(f,W_I64_AND);
    }
    WasmArg(f,W_LOCAL_GET,0);
    if (mask!=-1) {
      WasmI64(f,mask);
      WasmByte(f,W_I64_AND);
    }
    WasmByte(f,W_I64_LT_U);
    WasmByte(f,W_I64_EXTEND_I32_U);
    WasmByte(f,W_I64_OR);
    WasmArg(f,W_LOCAL_GET,0);
    WasmArg(f,W_LOCAL_GET,2);
    WasmByte(f,W_I64_XOR);
    WasmArg(f,W_LOCAL_GET,1);
    WasmArg(f,W_LOCAL_GET,2);
    WasmByte(f,W_I64_XOR);
    WasmByte(f,W_I64_AND);
    WasmI64(f,high_bit);
    WasmByte(f,W_I64_SHR_U);
    WasmI64(f,1);
    WasmByte(f,W_I64_AND);
    WasmI64(f,0x800);
    WasmByte(f,W_I64_MUL);
    WasmByte(f,W_I64_OR);
  } else {
    if (kind==1) {
      WasmArg(f,W_LOCAL_GET,0);
      if (mask!=-1) {
	WasmI64(f,mask);
	WasmByte(f,W_I64_AND);
      }
      WasmArg(f,W_LOCAL_GET,1);
      if (mask!=-1) {
	WasmI64(f,mask);
	WasmByte(f,W_I64_AND);
      }
      WasmByte(f,W_I64_LT_U);
      WasmByte(f,W_I64_EXTEND_I32_U);
      WasmByte(f,W_I64_OR);
      WasmArg(f,W_LOCAL_GET,0);
      WasmArg(f,W_LOCAL_GET,1);
      WasmByte(f,W_I64_XOR);
      WasmArg(f,W_LOCAL_GET,0);
      WasmArg(f,W_LOCAL_GET,2);
      WasmByte(f,W_I64_XOR);
      WasmByte(f,W_I64_AND);
      WasmI64(f,high_bit);
      WasmByte(f,W_I64_SHR_U);
      WasmI64(f,1);
      WasmByte(f,W_I64_AND);
      WasmI64(f,0x800);
      WasmByte(f,W_I64_MUL);
      WasmByte(f,W_I64_OR);
    }
  }
  if (kind!=2) {
    JitAuxCarry(f);
  }
  WasmSt64(f);
}

U0 JitIncFlags(CWasmBuf *f,I64 sz,I64 ext)
{
  WasmI32(f,jit_rfl);
  WasmI32(f,jit_rfl);
  WasmLd64(f);
  WasmI64(f,~0x8D4);
  WasmByte(f,W_I64_AND);
  WasmArg(f,W_LOCAL_GET,2);
  if (sz!=8) {
    WasmI64(f,1<<(sz*8)-1);
    WasmByte(f,W_I64_AND);
  }
  WasmByte(f,W_I64_EQZ);
  WasmByte(f,W_I64_EXTEND_I32_U);
  WasmI64(f,0x40);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmI64(f,sz*8-1);
  WasmByte(f,W_I64_SHR_U);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmI64(f,0x80);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmI64(f,0xFF);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_POPCNT);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_EQZ);
  WasmByte(f,W_I64_EXTEND_I32_U);
  WasmI64(f,4);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  if (ext==0) {
    WasmArg(f,W_LOCAL_GET,0);
    WasmArg(f,W_LOCAL_GET,2);
    WasmByte(f,W_I64_XOR);
    WasmArg(f,W_LOCAL_GET,1);
    WasmArg(f,W_LOCAL_GET,2);
    WasmByte(f,W_I64_XOR);
    WasmByte(f,W_I64_AND);
  } else {
    WasmArg(f,W_LOCAL_GET,0);
    WasmArg(f,W_LOCAL_GET,1);
    WasmByte(f,W_I64_XOR);
    WasmArg(f,W_LOCAL_GET,0);
    WasmArg(f,W_LOCAL_GET,2);
    WasmByte(f,W_I64_XOR);
    WasmByte(f,W_I64_AND);
  }
  WasmI64(f,sz*8-1);
  WasmByte(f,W_I64_SHR_U);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmI64(f,0x800);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  JitAuxCarry(f);
  WasmSt64(f);
}

U0 JitShiftFlags(CWasmBuf *f,I64 sz,I64 cnt,I64 opn)
{
  I64 high_bit,mask;
  high_bit=sz*8-1;
  if (sz==8) {
    mask=-1;
  } else {
    mask=1<<(sz*8)-1;
  }
  WasmI32(f,jit_rfl);
  WasmI32(f,jit_rfl);
  WasmLd64(f);
  if (cnt==1) {
    WasmI64(f,~0x8C5);
  } else {
    WasmI64(f,~0xC5);
  }
  WasmByte(f,W_I64_AND);
  WasmArg(f,W_LOCAL_GET,1);
  WasmByte(f,W_I64_OR);
  if (cnt==1 && opn!=7) {
    if (opn==4) {
      WasmArg(f,W_LOCAL_GET,2);
    } else {
      WasmArg(f,W_LOCAL_GET,0);
    }
    WasmI64(f,high_bit);
    WasmByte(f,W_I64_SHR_U);
    if (opn==4) {
      WasmArg(f,W_LOCAL_GET,1);
      WasmByte(f,W_I64_XOR);
    }
    WasmI64(f,1);
    WasmByte(f,W_I64_AND);
    WasmI64(f,0x800);
    WasmByte(f,W_I64_MUL);
    WasmByte(f,W_I64_OR);
  }
  WasmArg(f,W_LOCAL_GET,2);
  if (mask!=-1) {
    WasmI64(f,mask);
    WasmByte(f,W_I64_AND);
  }
  WasmByte(f,W_I64_EQZ);
  WasmByte(f,W_I64_EXTEND_I32_U);
  WasmI64(f,0x40);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmI64(f,high_bit);
  WasmByte(f,W_I64_SHR_U);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmI64(f,0x80);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmI64(f,0xFF);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_POPCNT);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_EQZ);
  WasmByte(f,W_I64_EXTEND_I32_U);
  WasmI64(f,4);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmSt64(f);
}

U0 JitAdcFlags(CWasmBuf *f,I64 is_sbb,I64 sz)
{
  I64 bits,high_bit,mask;
  bits=sz*8;
  high_bit=bits-1;
  if (sz==8) {
    mask=-1;
  } else {
    mask=1<<bits-1;
  }
  WasmI32(f,jit_rfl);
  WasmI32(f,jit_rfl);
  WasmLd64(f);
  WasmI64(f,~0x8D5);
  WasmByte(f,W_I64_AND);
  WasmArg(f,W_LOCAL_GET,2);
  WasmByte(f,W_I64_EQZ);
  WasmByte(f,W_I64_EXTEND_I32_U);
  WasmI64(f,0x40);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmI64(f,high_bit);
  WasmByte(f,W_I64_SHR_U);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmI64(f,0x80);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  WasmArg(f,W_LOCAL_GET,2);
  WasmI64(f,0xFF);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_POPCNT);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmByte(f,W_I64_EQZ);
  WasmByte(f,W_I64_EXTEND_I32_U);
  WasmI64(f,4);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  if (!is_sbb) {
    if (sz==8) {
      WasmArg(f,W_LOCAL_GET,0);
      WasmArg(f,W_LOCAL_GET,1);
      WasmByte(f,W_I64_ADD);
      WasmArg(f,W_LOCAL_SET,7);
      WasmArg(f,W_LOCAL_GET,7);
      WasmArg(f,W_LOCAL_GET,0);
      WasmByte(f,W_I64_LT_U);
      WasmArg(f,W_LOCAL_GET,2);
      WasmArg(f,W_LOCAL_GET,7);
      WasmByte(f,W_I64_LT_U);
      WasmByte(f,W_I32_OR);
      WasmByte(f,W_I64_EXTEND_I32_U);
      WasmByte(f,W_I64_OR);
    } else {
      WasmArg(f,W_LOCAL_GET,0);
      if (mask!=-1) {
	WasmI64(f,mask);
	WasmByte(f,W_I64_AND);
      }
      WasmArg(f,W_LOCAL_GET,1);
      if (mask!=-1) {
	WasmI64(f,mask);
	WasmByte(f,W_I64_AND);
      }
      WasmByte(f,W_I64_ADD);
      WasmArg(f,W_LOCAL_GET,6);
      WasmByte(f,W_I64_ADD);
      WasmI64(f,bits);
      WasmByte(f,W_I64_SHR_U);
      WasmI64(f,1);
      WasmByte(f,W_I64_AND);
      WasmByte(f,W_I64_OR);
    }
  } else {
    WasmArg(f,W_LOCAL_GET,0);
    if (mask!=-1) {
      WasmI64(f,mask);
      WasmByte(f,W_I64_AND);
    }
    WasmArg(f,W_LOCAL_GET,1);
    if (mask!=-1) {
      WasmI64(f,mask);
      WasmByte(f,W_I64_AND);
    }
    WasmByte(f,W_I64_LT_U);
    WasmArg(f,W_LOCAL_GET,0);
    if (mask!=-1) {
      WasmI64(f,mask);
      WasmByte(f,W_I64_AND);
    }
    WasmArg(f,W_LOCAL_GET,1);
    if (mask!=-1) {
      WasmI64(f,mask);
      WasmByte(f,W_I64_AND);
    }
    WasmByte(f,W_I64_EQ);
    WasmArg(f,W_LOCAL_GET,6);
    WasmI64(f,0);
    WasmByte(f,W_I64_NE);
    WasmByte(f,W_I32_AND);
    WasmByte(f,W_I32_OR);
    WasmByte(f,W_I64_EXTEND_I32_U);
    WasmByte(f,W_I64_OR);
  }
  if (!is_sbb) {
    WasmArg(f,W_LOCAL_GET,0);
    WasmArg(f,W_LOCAL_GET,2);
    WasmByte(f,W_I64_XOR);
    WasmArg(f,W_LOCAL_GET,1);
    WasmArg(f,W_LOCAL_GET,2);
    WasmByte(f,W_I64_XOR);
    WasmByte(f,W_I64_AND);
  } else {
    WasmArg(f,W_LOCAL_GET,0);
    WasmArg(f,W_LOCAL_GET,1);
    WasmByte(f,W_I64_XOR);
    WasmArg(f,W_LOCAL_GET,0);
    WasmArg(f,W_LOCAL_GET,2);
    WasmByte(f,W_I64_XOR);
    WasmByte(f,W_I64_AND);
  }
  WasmI64(f,high_bit);
  WasmByte(f,W_I64_SHR_U);
  WasmI64(f,1);
  WasmByte(f,W_I64_AND);
  WasmI64(f,0x800);
  WasmByte(f,W_I64_MUL);
  WasmByte(f,W_I64_OR);
  JitAuxCarry(f);
  WasmSt64(f);
}

U0 JitCond(CWasmBuf *f,I64 cc)
{
  I64 base;
  base=cc>>1;
  if (base==0) {
    WasmI32(f,jit_rfl);
    WasmMem(f,W_I32_LOAD,0,2);
    WasmI32(f,11);
    WasmByte(f,W_I32_SHR_U);
    WasmI32(f,1);
    WasmByte(f,W_I32_AND);
  } else {
    if (base==1) {
      WasmI32(f,jit_rfl);
      WasmMem(f,W_I32_LOAD,0,2);
      WasmI32(f,0);
      WasmByte(f,W_I32_SHR_U);
      WasmI32(f,1);
      WasmByte(f,W_I32_AND);
    } else {
      if (base==2) {
	WasmI32(f,jit_rfl);
	WasmMem(f,W_I32_LOAD,0,2);
	WasmI32(f,6);
	WasmByte(f,W_I32_SHR_U);
	WasmI32(f,1);
	WasmByte(f,W_I32_AND);
      } else {
	if (base==3) {
	  WasmI32(f,jit_rfl);
	  WasmMem(f,W_I32_LOAD,0,2);
	  WasmI32(f,0);
	  WasmByte(f,W_I32_SHR_U);
	  WasmI32(f,1);
	  WasmByte(f,W_I32_AND);
	  WasmI32(f,jit_rfl);
	  WasmMem(f,W_I32_LOAD,0,2);
	  WasmI32(f,6);
	  WasmByte(f,W_I32_SHR_U);
	  WasmI32(f,1);
	  WasmByte(f,W_I32_AND);
	  WasmByte(f,W_I32_OR);
	} else {
	  if (base==4) {
	    WasmI32(f,jit_rfl);
	    WasmMem(f,W_I32_LOAD,0,2);
	    WasmI32(f,7);
	    WasmByte(f,W_I32_SHR_U);
	    WasmI32(f,1);
	    WasmByte(f,W_I32_AND);
	  } else {
	    if (base==5) {
	      WasmI32(f,jit_rfl);
	      WasmMem(f,W_I32_LOAD,0,2);
	      WasmI32(f,2);
	      WasmByte(f,W_I32_SHR_U);
	      WasmI32(f,1);
	      WasmByte(f,W_I32_AND);
	    } else {
	      if (base==6) {
		WasmI32(f,jit_rfl);
		WasmMem(f,W_I32_LOAD,0,2);
		WasmI32(f,7);
		WasmByte(f,W_I32_SHR_U);
		WasmI32(f,1);
		WasmByte(f,W_I32_AND);
		WasmI32(f,jit_rfl);
		WasmMem(f,W_I32_LOAD,0,2);
		WasmI32(f,11);
		WasmByte(f,W_I32_SHR_U);
		WasmI32(f,1);
		WasmByte(f,W_I32_AND);
		WasmByte(f,W_I32_XOR);
	      } else {
		WasmI32(f,jit_rfl);
		WasmMem(f,W_I32_LOAD,0,2);
		WasmI32(f,6);
		WasmByte(f,W_I32_SHR_U);
		WasmI32(f,1);
		WasmByte(f,W_I32_AND);
		WasmI32(f,jit_rfl);
		WasmMem(f,W_I32_LOAD,0,2);
		WasmI32(f,7);
		WasmByte(f,W_I32_SHR_U);
		WasmI32(f,1);
		WasmByte(f,W_I32_AND);
		WasmI32(f,jit_rfl);
		WasmMem(f,W_I32_LOAD,0,2);
		WasmI32(f,11);
		WasmByte(f,W_I32_SHR_U);
		WasmI32(f,1);
		WasmByte(f,W_I32_AND);
		WasmByte(f,W_I32_XOR);
		WasmByte(f,W_I32_OR);
	      }
	    }
	  }
	}
      }
    }
  }
  if (cc&1) {
    WasmI32(f,1);
    WasmByte(f,W_I32_XOR);
  }
}
