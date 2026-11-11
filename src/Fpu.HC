//The x87 stack uses F64 precision. Extended-real memory operands still use
//the legacy low-64-bit approximation; this is not an 80-bit x87 model.

F64 BitsToF64(U64 bits)
{
  return bits(F64);
}

U64 F64ToBits(F64 value)
{
  return value(U64);
}

F64 IntToF64(I64 value)
{
  return ToF64(value);
}

I64 F64ToInt(F64 value)
{//An invalid signed conversion returns integer indefinite.
  if (!(value>=-0x43E0000000000000(F64) &&
	value<0x43E0000000000000(F64)))
    return -I64_MAX-1;
  return ToI64(value);
}

F64 F32ToF64(U64 bits)
{//Subnormal F32 inputs retain the legacy zero approximation.
  U64 sign=bits>>31&1,exp=bits>>23&0xFF,frac=bits&0x7FFFFF,res;
  if (!exp)
    res=sign<<63;
  else if (exp==0xFF)
    res=sign<<63|0x7FF<<52|frac<<29;
  else
    res=sign<<63|(exp-127+1023)<<52|frac<<29;
  return res(F64);
}

U64 F64ToF32b(F64 value)
{//Legacy truncation to F32, including underflow to signed zero.
  U64 bits=value(U64),sign=bits>>63&1,frac=bits&0xFFFFFFFFFFFFF;
  I64 exp=bits>>52&0x7FF,next;
  if (!exp)
    return sign<<31;
  if (exp==0x7FF)
    return sign<<31|0xFF<<23|frac>>29;
  next=exp-1023+127;
  if (next<=0)
    return sign<<31;
  if (next>=0xFF)
    return sign<<31|0xFF<<23;
  return sign<<31|next<<23|frac>>29;
}

U0 FPush(F64 value)
{
  fsp=(fsp-1)&7;
  fpr[fsp]=value;
}

F64 FPopv()
{
  F64 res=fpr[fsp];
  fsp=(fsp+1)&7;
  return res;
}

F64 FStv(I64 i)
{
  return fpr[(fsp+i)&7];
}

U0 FStset(I64 i,F64 value)
{
  fpr[(fsp+i)&7]=value;
}

F64 FIntRound(F64 value,I64 mode)
{//x87 rounding: nearest even, down, up or truncate.
  I64 i;
  F64 res,part;
  if (value!=value || value>=4503599627370496.0 ||
	value<=-4503599627370496.0 || !value)
    return value;
  i=value;res=i;
  if (!mode) {
    part=value-res;
    if (part>0.5 || part==0.5 && i&1)
      res++;
    else if (part< -0.5 || part== -0.5 && i&1)
      res--;
  } else if (mode==1 && res>value)
    res--;
  else if (mode==2 && res<value)
    res++;
  if (!res)
    return (value(U64)&0x8000000000000000)(F64);
  return res;
}

I64 RoundCW(F64 value)
{
  return F64ToInt(FIntRound(value,x87_cw>>10&3));
}

U0 FIntStore(I64 size,Bool trunc,Bool pop)
{//FIST(P)/FISTTP with the destination's range and masked exception flags.
  I64 mode=x87_cw>>10&3,limit=1<<(size*8-1),res;
  F64 value=FStv(0),rounded,bound=32768.0;
  if (trunc)
    mode=3;
  rounded=FIntRound(value,mode);
  if (size==4)
    bound=2147483648.0;
  else if (size==8)
    bound=0x43E0000000000000(F64);
  x87_sw&=~0x200;
  if (!(rounded>=-bound && rounded<bound)) {
    x87_sw|=1;
    if (!(x87_cw&1)) {
      x87_sw|=0x8080;
      return;
    }
    res=limit;
  } else {
    res=rounded;
    if (rounded!=value) {
      x87_sw|=0x20;
      if (!trunc && Abs(rounded)>Abs(value))
	x87_sw|=0x200;
    }
  }
  WrMem(ea,size,res);
  if (pop)
    FPopv;
}

U0 FCmpSW(F64 arg1,F64 arg2)
{//FCOM condition bits C3/C2/C0.
  x87_sw&=~0x4500;
  if (arg1!=arg1 || arg2!=arg2)
    x87_sw|=0x4500;
  else if (arg1<arg2)
    x87_sw|=0x100;
  else if (arg1==arg2)
    x87_sw|=0x4000;
}

U0 FCmpFL(F64 arg1,F64 arg2)
{//FCOMI/FUCOMI result in ZF/PF/CF.
  rfl&=~(F_ZF|F_PF|F_CF);
  if (arg1!=arg1 || arg2!=arg2)
    rfl|=F_ZF|F_PF|F_CF;
  else if (arg1==arg2)
    rfl|=F_ZF;
  else if (arg1<arg2)
    rfl|=F_CF;
}

F64 FArith(I64 op,F64 arg1,F64 arg2)
{//The memory and ST0-destination opcode order.
  switch (op) {
    case 0:
      return arg1+arg2;
    case 1:
      return arg1*arg2;
    case 4:
      return arg1-arg2;
    case 5:
      return arg2-arg1;
    case 6:
      return arg1/arg2;
  }
  return arg2/arg1;
}

U0 FpuMem(I64 op,I64 sub)
{
  I64 i,value,digit;
  Bool neg;
  F64 arg;
  switch (op) {
    case 0xD9:
      switch (sub) {
	case 0: //FLD m32.
	  FPush(F32ToF64(RdMem(ea,4)));
	  break;
	case 2...3: //FST(P) m32.
	  WrMem(ea,4,F64ToF32b(FStv(0)));
	  if (sub==3) FPopv;
	  break;
	case 5: //FLDCW.
	  x87_cw=RdMem(ea,2);
	  break;
	case 7: //FNSTCW.
	  WrMem(ea,2,x87_cw);
      }
      break;
    case 0xDB:
      switch (sub) {
	case 0: //FILD m32.
	  FPush(IntToF64(SignExtTo64(RdMem(ea,4),4)));
	  break;
	case 1...3: //FISTTP/FIST/FISTP m32.
	  FIntStore(4,sub==1,sub!=2);
	  break;
	case 5: //FLD m80 approximation.
	  FPush(BitsToF64(RdMem(ea,8)));
	  break;
	case 7: //FSTP m80 approximation.
	  WrMem(ea,8,F64ToBits(FStv(0)));
	  FPopv;
      }
      break;
    case 0xDD:
      switch (sub) {
	case 0: //FLD m64.
	  FPush(BitsToF64(RdMem(ea,8)));
	  break;
	case 1: //FISTTP m64.
	  FIntStore(8,TRUE,TRUE);
	  break;
	case 2...3: //FST(P) m64.
	  WrMem(ea,8,F64ToBits(FStv(0)));
	  if (sub==3) FPopv;
      }
      break;
    case 0xDF:
      switch (sub) {
	case 0: //FILD m16.
	  FPush(IntToF64(SignExtTo64(RdMem(ea,2),2)));
	  break;
	case 1...3: //FISTTP/FIST/FISTP m16.
	  FIntStore(2,sub==1,sub!=2);
	  break;
	case 4: //FBLD: 18 decimal digits, then the sign byte.
	  value=0;
	  for (i=8;i>=0;i--) {
	    digit=RdMem(ea+i,1);
	    value=value*100+digit>>4*10+digit&15;
	  }
	  if (RdMem(ea+9,1)&0x80) value=-value;
	  FPush(IntToF64(value));
	  break;
	case 5: //FILD m64.
	  FPush(IntToF64(RdMem(ea,8)));
	  break;
	case 6: //FBSTP.
	  value=RoundCW(FStv(0));
	  neg=value<0;
	  if (neg) value=-value;
	  for (i=0;i<9;i++) {
	    WrMem(ea+i,1,value%10|(value/10%10)<<4);
	    value/=100;
	  }
	  if (neg) WrMem(ea+9,1,0x80);
	  else WrMem(ea+9,1,0);
	  FPopv;
	  break;
	case 7: //FISTP m64.
	  FIntStore(8,FALSE,TRUE);
      }
      break;
    case 0xD8:
    case 0xDC:
      if (op==0xD8) arg=F32ToF64(RdMem(ea,4));
      else arg=BitsToF64(RdMem(ea,8));
      if (sub==2 || sub==3) {
	FCmpSW(FStv(0),arg);
	if (sub==3) FPopv;
      } else
	FStset(0,FArith(sub,FStv(0),arg));
      break;
    case 0xDA:
    case 0xDE:
      if (op==0xDA) arg=IntToF64(SignExtTo64(RdMem(ea,4),4));
      else arg=IntToF64(SignExtTo64(RdMem(ea,2),2));
      FStset(0,FArith(sub,FStv(0),arg));
  }
}

U0 FpuConst(I64 op)
{
  switch (op) {
    case 0: FPush(1.0); break;
    case 1: FPush(0x400A934F0979A371(F64)); break;
    case 2: FPush(0x3FF71547652B82FE(F64)); break;
    case 3: FPush(0x400921FB54442D18(F64)); break;
    case 4: FPush(0x3FD34413509F79FF(F64)); break;
    case 5: FPush(0x3FE62E42FEFA39EF(F64)); break;
    case 6: FPush(0.0);
  }
}

U0 FpuMath(I64 sub,I64 op)
{
  I64 exp;
  F64 arg1,arg2,res,log2e=0x3FF71547652B82FE(F64);
  if (sub==6) {
    switch (op) {
      case 0: //F2XM1.
	FStset(0,Pow(2.0,FStv(0))-1.0);
	break;
      case 1: //FYL2X.
	res=FStv(1)*Ln(FStv(0))*log2e;
	FPopv;FStset(0,res);
	break;
      case 2: //FPTAN.
	FStset(0,Tan(FStv(0)));FPush(1.0);
	break;
      case 3: //FPATAN.
	res=Arg(FStv(0),FStv(1));
	FPopv;FStset(0,res);
	break;
      case 4: //FXTRACT.
	arg1=FStv(0);
	if (!arg1) {
	  FStset(0,0.0);FPush(0.0);
	} else {
	  arg2=arg1;
	  if (arg2<0) arg2=-arg2;
	  exp=F64ToInt(Ln(arg2)*log2e);
	  if (IntToF64(exp)>Ln(arg2)*log2e) exp--;
	  FStset(0,IntToF64(exp));
	  FPush(arg1/Pow(2.0,IntToF64(exp)));
	}
	break;
      case 6: //FDECSTP.
	fsp=(fsp-1)&7;
	break;
      case 7: //FINCSTP.
	fsp=(fsp+1)&7;
    }
  } else {
    switch (op) {
      case 0: //FPREM.
	arg1=FStv(0);arg2=FStv(1);
	FStset(0,arg1-IntToF64(F64ToInt(arg1/arg2))*arg2);
	break;
      case 1: //FYL2XP1.
	res=FStv(1)*Ln(FStv(0)+1.0)*log2e;
	FPopv;FStset(0,res);
	break;
      case 2: //FSQRT.
	FStset(0,Sqrt(FStv(0)));
	break;
      case 3: //FSINCOS.
	arg1=FStv(0);FStset(0,Sin(arg1));FPush(Cos(arg1));
	break;
      case 4: //FRNDINT.
	FStset(0,FIntRound(FStv(0),x87_cw>>10&3));
	break;
      case 5: //FSCALE.
	FStset(0,FStv(0)*Pow(2.0,IntToF64(F64ToInt(FStv(1)))));
	break;
      case 6: //FSIN.
	FStset(0,Sin(FStv(0)));
	break;
      case 7: //FCOS.
	FStset(0,Cos(FStv(0)));
    }
  }
}

U0 OpX87(U64 op)
{
  I64 sub,sti;
  F64 value;
  DecodeModRM;
  sub=rg&7;sti=rm&7;
  if (isMem) {
    FpuMem(op,sub);
    return;
  }
  switch (op) {
    case 0xD9:
      switch (sub) {
	case 0: //FLD ST(i).
	  FPush(FStv(sti));
	  break;
	case 1: //FXCH.
	  value=FStv(0);
	  FStset(0,FStv(sti));FStset(sti,value);
	  break;
	case 4:
	  if (!sti) FStset(0,-FStv(0));
	  else if (sti==1)
	    FStset(0,(FStv(0)(U64)&0x7FFFFFFFFFFFFFFF)(F64));
	  else if (sti==4) {
	    x87_sw&=~0x200;FCmpSW(FStv(0),0.0);
	  }
	  break;
	case 5:
	  FpuConst(sti);
	  break;
	case 6...7:
	  FpuMath(sub,sti);
      }
      break;
    case 0xD8:
      if (sub==2 || sub==3) {
	FCmpSW(FStv(0),FStv(sti));
	if (sub==3) FPopv;
      } else
	FStset(0,FArith(sub,FStv(0),FStv(sti)));
      break;
    case 0xDC:
      if (sub==0 || sub==1 || sub>=4) {
	if (sub>=4) sub^=1;
	FStset(sti,FArith(sub,FStv(sti),FStv(0)));
      }
      break;
    case 0xDD:
      if (sub==2 || sub==3) {
	FStset(sti,FStv(0));
	if (sub==3) FPopv;
      } else if (sub==4 || sub==5) {
	FCmpSW(FStv(0),FStv(sti));
	if (sub==5) FPopv;
      }
      break;
    case 0xDE:
      if (sub==3) {
	FCmpSW(FStv(0),FStv(1));FPopv;FPopv;
      } else {
	if (sub==2) sub=6;
	else if (sub>=4) sub^=1;
	FStset(sti,FArith(sub,FStv(sti),FStv(0)));
	FPopv;
      }
      break;
    case 0xDB:
      if (sub==4 && sti==3) { //FNINIT.
	fsp=0;x87_cw=0x37F;x87_sw=0;
      } else if (sub==6 || sub==7)
	FCmpFL(FStv(0),FStv(sti));
      break;
    case 0xDF:
      if (sub==4 && !sti)
	reg[0]=reg[0]&~0xFFFF|x87_sw&0xFFFF;
      else if (sub==6 || sub==7) {
	FCmpFL(FStv(0),FStv(sti));FPopv;
      }
  }
}
