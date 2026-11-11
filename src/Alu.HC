U0 SetZSP(U64 val,I64 size)
{//Zero, sign and even parity from the operand width and low byte.
  I64 i,cnt=0;
  val&=SizeMask(size);
  rfl&=~(F_ZF|F_SF|F_PF);
  if (!val) rfl|=F_ZF;
  if (val>>(size*8-1)&1) rfl|=F_SF;
  for (i=0;i<8;i++)
    cnt+=val>>i&1;
  if (!(cnt&1)) rfl|=F_PF;
}

U0 SetAdd(U64 arg1,U64 arg2,U64 res,I64 size)
{
  U64 mask=SizeMask(size),sign=1<<(size*8-1);
  SetZSP(res,size);
  rfl&=~(F_CF|F_OF);
  if (res&mask<arg1&mask) rfl|=F_CF;
  if ((arg1^res)&(arg2^res)&sign) rfl|=F_OF;
}

U0 SetSub(U64 arg1,U64 arg2,U64 res,I64 size)
{
  U64 mask=SizeMask(size),sign=1<<(size*8-1);
  SetZSP(res,size);
  rfl&=~(F_CF|F_OF);
  if (arg1&mask<arg2&mask) rfl|=F_CF;
  if ((arg1^arg2)&(arg1^res)&sign) rfl|=F_OF;
}

U0 SetLogic(U64 res,I64 size)
{
  SetZSP(res,size);
  rfl&=~(F_CF|F_OF);
}

U64 Arith(I64 op,U64 arg1,U64 arg2,I64 size)
{//The eight ALU opcodes share operand and flag rules.
  U64 res,mask=SizeMask(size),sign=1<<(size*8-1),carry=rfl&F_CF,
	sum,tmp;
  switch (op) {
    case 0:
      res=arg1+arg2;
      SetAdd(arg1,arg2,res,size);
      break;
    case 1:
      res=arg1|arg2;
      SetLogic(res,size);
      break;
    case 2:
      res=(arg1+arg2+carry)&mask;
      SetZSP(res,size);
      rfl&=~(F_CF|F_OF);
      if (size==8) {
	sum=arg1+arg2;
	tmp=sum+carry;
	if (sum<arg1 || tmp<sum) rfl|=F_CF;
      } else {
	sum=arg1&mask+arg2&mask+carry;
	if (sum>>(size*8)&1) rfl|=F_CF;
      }
      if ((arg1^res)&(arg2^res)&sign) rfl|=F_OF;
      break;
    case 3:
      res=(arg1-arg2-carry)&mask;
      SetZSP(res,size);
      rfl&=~(F_CF|F_OF);
      if (arg1&mask<arg2&mask || arg1&mask==arg2&mask && carry)
	rfl|=F_CF;
      if ((arg1^arg2)&(arg1^res)&sign) rfl|=F_OF;
      break;
    case 4:
      res=arg1&arg2;
      SetLogic(res,size);
      break;
    case 6:
      res=arg1^arg2;
      SetLogic(res,size);
      break;
    default:
      res=arg1-arg2;
      SetSub(arg1,arg2,res,size);
  }
  return res;
}

I64 Cond(I64 code)
{//Each odd condition code negates the preceding even condition.
  Bool res=FALSE,sign=rfl&F_SF!=0,overflow=rfl&F_OF!=0;
  switch (code>>1) {
    case 0:res=overflow;break;
    case 1:res=rfl&F_CF!=0;break;
    case 2:res=rfl&F_ZF!=0;break;
    case 3:res=rfl&(F_CF|F_ZF)!=0;break;
    case 4:res=sign;break;
    case 5:res=rfl&F_PF!=0;break;
    case 6:res=sign!=overflow;break;
    case 7:res=rfl&F_ZF || sign!=overflow;break;
  }
  if (code&1) return !res;
  return res;
}
