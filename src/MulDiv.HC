U64 MulHigh(U64 arg1,U64 arg2)
{//Upper word of an unsigned 64 by 64 product.
  U64 lo1=arg1&0xFFFFFFFF,hi1=arg1>>32,
	lo2=arg2&0xFFFFFFFF,hi2=arg2>>32,
	lo=lo1*lo2,mid1=lo1*hi2,mid2=hi1*lo2,carry=lo>>32;
  carry+=mid1&0xFFFFFFFF;
  carry+=mid2&0xFFFFFFFF;
  return hi1*hi2+mid1>>32+mid2>>32+carry>>32;
}

U64 MulRes(U64 arg1,U64 arg2,I64 size,Bool sign,U64 *_high=NULL)
{//Only CF and OF are defined; retain the other flags.
  U64 res,high,mask=SizeMask(size),expected=0;
  Bool overflow;
  arg1&=mask;arg2&=mask;
  if (size==8) {
    res=arg1*arg2;
    high=MulHigh(arg1,arg2);
    if (sign) {
      if (arg1>>63) high-=arg2;
      if (arg2>>63) high-=arg1;
      if (res>>63) expected=0xFFFFFFFFFFFFFFFF;
      overflow=high!=expected;
    } else
      overflow=high!=0;
  } else {
    if (sign)
      res=SignExtTo64(arg1,size)*SignExtTo64(arg2,size);
    else
      res=arg1*arg2;
    high=res>>(size*8)&mask;
    if (sign)
      overflow=SignExtTo64(res,size)!=res;
    else
      overflow=high!=0;
  }
  rfl&=~(F_CF|F_OF);
  if (overflow) rfl|=F_CF|F_OF;
  if (_high) *_high=high;
  return res&mask;
}

Bool DivFull(U64 high,U64 low,U64 divisor,U64 *_quot,U64 *_rem)
{//A quotient wider than 64 bits is rejected before any CPU writes.
  I64 i;
  U64 quot=0,rem=high,carry;
  if (!divisor || high>=divisor) return FALSE;
  if (!high) {
    *_quot=low/divisor;
    *_rem=low%divisor;
    return TRUE;
  }
  for (i=63;i>=0;i--) {
    carry=rem>>63;
    rem=rem<<1|low>>i&1;
    if (carry || rem>=divisor) {
      rem-=divisor;
      quot|=1(U64)<<i;
    }
  }
  *_quot=quot;*_rem=rem;
  return TRUE;
}

U0 DivRes(U64 divisor,I64 size,Bool sign)
{//Keep all destination registers intact on a retained divide fault.
  U64 high=0,low,quot,rem,limit=SizeMask(size);
  Bool neg_num=FALSE,neg_div=FALSE,neg_quot=FALSE;
  if (size==1)
    low=RdReg(0,2);
  else if (size==8) {
    low=reg[0];high=reg[2];
  } else
    low=RdReg(2,size)<<(size*8)|RdReg(0,size);
  divisor&=limit;
  if (sign) {
    if (size<8) {
      low=SignExtTo64(low,size*2);
      if (low>>63) high=0xFFFFFFFFFFFFFFFF;
    }
    neg_num=high>>63;
    divisor=SignExtTo64(divisor,size);
    neg_div=divisor>>63;
    neg_quot=neg_num ^^ neg_div;
    if (neg_num) {
      low=-low;high=~high;
      if (!low) high++;
    }
    if (neg_div) divisor=-divisor;
    limit=1(U64)<<(size*8-1);
    if (!neg_quot) limit--;
  }
  if (!DivFull(high,low,divisor,&quot,&rem) || quot>limit) {
    halted=3;
    return;
  }
  if (neg_quot) quot=-quot;
  if (neg_num) rem=-rem;
  if (size==1)
    WrReg(0,2,quot&0xFF|rem<<8&0xFF00);
  else {
    WrReg(0,size,quot);WrReg(2,size,rem);
  }
}

U0 Grp3(I64 size)
{//F6/F7 share TEST, unary arithmetic, full products and dividends.
  I64 op=rg&7;
  U64 arg,res,high,imm;
  if (op==2 || op==3) {
    RmUnary(op,size);
    return;
  }
  if (lockf) {
    AtomFault;
    return;
  }
  arg=RdRM(size);
  if (op<=1) {
    imm=FetchImm(size);
    SetLogic(arg&imm,size);
  } else if (op<=5) {
    res=MulRes(arg,RdReg(0,size),size,op==5,&high);
    if (size==1)
      WrReg(0,2,res|high<<8);
    else {
      WrReg(0,size,res);WrReg(2,size,high);
    }
  } else
    DivRes(arg,size,op==7);
}
