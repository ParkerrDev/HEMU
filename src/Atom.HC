U0 AtomFault()
{//Retain unsupported atomic operands without a partial update.
  g_badop=0xF0;
  halted=2;
}

I64 AtomAddr(I64 size)
{//A split SMP field requires coordinated ownership of all guest RAM.
  U64 addr=ea;
  if (addr>=mem_size) addr&=0xFFFFFFFFFF;
  if (!isMem || addr>=mem_size || size>mem_size-addr) {
    AtomFault;
    return -1;
  }
  if (addr&(size-1) &&
	(addr&7+size>8 || addr&~7+8>mem_size) && g_ncore!=1) {
    if (!(1<g_ncore<=NCORES) || !__bus_lock) {
      AtomFault;
      return -1;
    }
  }
  return addr;
}

U0 AtomEnd(U64 addr,I64 size)
{//Release only after this instruction's register and flag writes retire.
  if (g_ncore>1 && addr&(size-1) &&
	(addr&7+size>8 || addr&~7+8>mem_size))
    __bus_unlock;
}

U64 AtomPart(U64 addr,U64 arg,U64 expected,I64 size,I64 op)
{//Wide fields need a lone CPU or coordinated exclusive RAM ownership.
//Contained fields use masked CAS to preserve neighboring changes.
  I64 shift=(addr&7)*8;
  U64 *ptr=mem+addr&~7,mask=SizeMask(size),field,word,old,res,found;
  Bool single=addr&7+size>8 || addr&~7+8>mem_size;
  if (single) {
    word=RdMem(addr,size);
    shift=0;
  } else
    word=__a_or64(ptr,0);
  field=mask<<shift;
  while (TRUE) {
    old=word>>shift&mask;
    switch (op) {
      case 0:res=old|arg;break;
      case 1:res=old&arg;break;
      case 2:res=old^arg;break;
      case 3:res=old+arg;break;
      case 5:
	if (old!=expected) return old;
      default:res=arg;
    }
    res=word&~field|res<<shift&field;
    if (single) {
      WrMem(addr,size,res);
      return old;
    }
    found=__a_cmpxchg64(ptr,word,res);
    if (found==word) return old;
    word=found;
  }
}

Bool AtomOp(I64 op)
{
  if (op<0x38 && op&7<=1) return TRUE;
  switch (op) {
    case 0x0F:case 0x80:case 0x81:case 0x83:case 0x86:case 0x87:
    case 0xF6:case 0xF7:case 0xFE:case 0xFF:
      return TRUE;
  }
  return FALSE;
}

Bool AtomOp2(I64 op)
{
  switch (op) {
    case 0xAB:case 0xB0:case 0xB1:case 0xB3:case 0xBA:case 0xBB:
    case 0xC0:case 0xC1:case 0xC7:
      return TRUE;
  }
  return FALSE;
}

U64 AtomOr(U64 addr,U64 val,I64 size)
{
  if (addr&(size-1)) return AtomPart(addr,val,0,size,0);
  if (size==1) return __a_or8(mem+addr,val);
  if (size==2) return __a_or16(mem+addr,val);
  if (size==4) return __a_or32(mem+addr,val);
  return __a_or64(mem+addr,val);
}

U64 AtomAnd(U64 addr,U64 val,I64 size)
{
  if (addr&(size-1)) return AtomPart(addr,val,0,size,1);
  if (size==1) return __a_and8(mem+addr,val);
  if (size==2) return __a_and16(mem+addr,val);
  if (size==4) return __a_and32(mem+addr,val);
  return __a_and64(mem+addr,val);
}

U64 AtomXor(U64 addr,U64 val,I64 size)
{
  if (addr&(size-1)) return AtomPart(addr,val,0,size,2);
  if (size==1) return __a_xor8(mem+addr,val);
  if (size==2) return __a_xor16(mem+addr,val);
  if (size==4) return __a_xor32(mem+addr,val);
  return __a_xor64(mem+addr,val);
}

U64 AtomAdd(U64 addr,U64 val,I64 size)
{
  if (addr&(size-1)) return AtomPart(addr,val,0,size,3);
  if (size==1) return __a_add8(mem+addr,val);
  if (size==2) return __a_add16(mem+addr,val);
  if (size==4) return __a_add32(mem+addr,val);
  return __a_add64(mem+addr,val);
}

U64 AtomXchg(U64 addr,U64 val,I64 size)
{
  if (addr&(size-1)) return AtomPart(addr,val,0,size,4);
  if (size==1) return __a_xchg8(mem+addr,val);
  if (size==2) return __a_xchg16(mem+addr,val);
  if (size==4) return __a_xchg32(mem+addr,val);
  return __a_xchg64(mem+addr,val);
}

U64 AtomCas(U64 addr,U64 expected,U64 val,I64 size)
{
  if (addr&(size-1)) return AtomPart(addr,val,expected,size,5);
  if (size==1) return __a_cmpxchg8(mem+addr,expected,val);
  if (size==2) return __a_cmpxchg16(mem+addr,expected,val);
  if (size==4) return __a_cmpxchg32(mem+addr,expected,val);
  return __a_cmpxchg64(mem+addr,expected,val);
}

U0 RmArith(I64 op,U64 arg,I64 size)
{//The atomic primitive returns the old operand used to set flags.
  I64 addr;
  U64 old,res,carry=rfl&F_CF;
  if (lockf) {
    if (op==7) {AtomFault;return;}
    addr=AtomAddr(size);
    if (addr<0) return;
    switch (op) {
      case 0:old=AtomAdd(addr,arg,size);break;
      case 1:old=AtomOr(addr,arg,size);break;
      case 2:old=AtomAdd(addr,arg+carry,size);break;
      case 3:old=AtomAdd(addr,-arg-carry,size);break;
      case 4:old=AtomAnd(addr,arg,size);break;
      case 5:old=AtomAdd(addr,-arg,size);break;
      default:old=AtomXor(addr,arg,size);
    }
  } else
    old=RdRM(size);
  res=Arith(op,old,arg,size);
  if (!lockf && op!=7) WrRM(size,res);
  if (lockf) AtomEnd(addr,size);
}

U0 RmUnary(I64 op,I64 size)
{//INC/DEC preserve carry; NOT preserves all flags.
  I64 addr;
  U64 old,res,found,carry=rfl&F_CF;
  if (lockf) {
    addr=AtomAddr(size);
    if (addr<0) return;
    switch (op) {
      case 0:old=AtomAdd(addr,1,size);break;
      case 1:old=AtomAdd(addr,-1,size);break;
      case 2:old=AtomXor(addr,-1,size);break;
      default:
	old=AtomOr(addr,0,size);
	while (TRUE) {
	  found=AtomCas(addr,old,-old,size);
	  if (found==old) break;
	  old=found;
	}
    }
  } else
    old=RdRM(size);
  switch (op) {
    case 0:
      res=old+1;
      SetAdd(old,1,res,size);
      rfl=rfl&~F_CF|carry;
      break;
    case 1:
      res=old-1;
      SetSub(old,1,res,size);
      rfl=rfl&~F_CF|carry;
      break;
    case 2:res=~old;break;
    default:
      res=-old;
      SetSub(0,old,res,size);
  }
  if (!lockf) WrRM(size,res);
  if (lockf) AtomEnd(addr,size);
}

U0 RmXchg(I64 size)
{//Every memory XCHG is atomic, even without a LOCK prefix.
  I64 addr;
  U64 old,arg=RdReg(rg,size);
  if (isMem || lockf) {
    addr=AtomAddr(size);
    if (addr<0) return;
    old=AtomXchg(addr,arg,size);
  } else {
    old=RdRM(size);
    WrRM(size,arg);
  }
  WrReg(rg,size,old);
  if (isMem || lockf) AtomEnd(addr,size);
}

U0 RmXadd(I64 size)
{
  I64 addr;
  U64 old,arg=RdReg(rg,size);
  if (lockf) {
    addr=AtomAddr(size);
    if (addr<0) return;
    old=AtomAdd(addr,arg,size);
    WrReg(rg,size,old);
  } else {
    old=RdRM(size);
    WrReg(rg,size,old);
    WrRM(size,arg+old);
  }
  SetAdd(old,arg,old+arg,size);
  if (lockf) AtomEnd(addr,size);
}

U0 RmCmpXchg(I64 size)
{
  I64 addr;
  U64 old,expected=RdReg(0,size),arg=RdReg(rg,size);
  if (lockf) {
    addr=AtomAddr(size);
    if (addr<0) return;
    old=AtomCas(addr,expected,arg,size);
  } else {
    old=RdRM(size);
    if (expected==old) WrRM(size,arg);
    else if (isMem) WrRM(size,old);
  }
  SetSub(expected,old,expected-old,size);
  if (expected!=old) WrReg(0,size,old);
  if (lockf) AtomEnd(addr,size);
}

U0 RmCmpXchg8B()
{
  I64 addr;
  U64 old,expected=reg[2]<<32|reg[0]&0xFFFFFFFF,
	arg=reg[1]<<32|reg[3]&0xFFFFFFFF;
  if (!isMem || rg&7!=1 || rexW) {AtomFault;return;}
  if (lockf) {
    addr=AtomAddr(8);
    if (addr<0) return;
    old=AtomCas(addr,expected,arg,8);
  } else {
    old=RdRM(8);
    if (old==expected) WrRM(8,arg);
    else WrRM(8,old);
  }
  rfl&=~F_ZF;
  if (old==expected) rfl|=F_ZF;
  else {
    reg[0]=old&0xFFFFFFFF;
    reg[2]=old>>32;
  }
  if (lockf) AtomEnd(addr,8);
}

U0 RmCmpXchg16B()
{//An aligned pair still needs exclusive ownership when LOCK is used.
  I64 addr;
  U64 lo,hi;
  Bool owner=lockf && g_ncore>1;
  if (!isMem || rg&7!=1 || ea&15) {AtomFault;return;}
  addr=AtomAddr(16);
  if (addr<0) return;
  if (owner && (!(1<g_ncore<=NCORES) || !__bus_lock)) {
    AtomFault;
    return;
  }
  lo=RdMem(addr,8);hi=RdMem(addr+8,8);
  rfl&=~F_ZF;
  if (lo==reg[0] && hi==reg[2]) {
    lo=reg[3];hi=reg[1];
    rfl|=F_ZF;
  } else {
    reg[0]=lo;reg[2]=hi;
  }
  WrMem(addr,8,lo);WrMem(addr+8,8,hi);
  if (owner) __bus_unlock;
}

U0 DoBit(I64 op,U64 bit,I64 size)
{//Memory bit strings may extend beyond the instruction's operand width.
  I64 addr,offset;
  U64 old,mask;
  if (op<0 || op>3 || lockf && (!op || !isMem)) {
    AtomFault;
    return;
  }
  if (isMem) {
    offset=SignExtTo64(bit,size);
    ea+=offset>>3;
    bit&=7;
    size=1;
  } else
    bit&=size*8-1;
  mask=1<<bit;
  if (lockf) {
    addr=AtomAddr(size);
    if (addr<0) return;
    if (op==1) old=AtomOr(addr,mask,size);
    else if (op==2) old=AtomAnd(addr,~mask,size);
    else old=AtomXor(addr,mask,size);
  } else {
    old=RdRM(size);
    if (op==1) WrRM(size,old|mask);
    else if (op==2) WrRM(size,old&~mask);
    else if (op==3) WrRM(size,old^mask);
  }
  if (old&mask) rfl|=F_CF;
  else rfl&=~F_CF;
}
