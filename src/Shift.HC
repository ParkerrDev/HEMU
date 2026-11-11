U0 DoShift(I64 op,I64 cnt,I64 size)
{//Group 2 shifts and rotates, including carry as the extra rotate bit.
  U64 mask=SizeMask(size),val=RdRM(size)&mask,res=val;
  I64 bits=size*8,n,last=rfl&F_CF,bit,overflow=0;
  if (size==8) cnt&=63;
  else cnt&=31;
  n=cnt;
  if (op<2) n%=bits;
  else if (op<4 && size<4) n%=bits+1;
  switch (op) {
    case 0:
      if (n) res=(val<<n|val>>(bits-n))&mask;
      if (cnt) last=res&1;
      overflow=res>>(bits-1)^last;
      break;
    case 1:
      if (n) res=(val>>n|val<<(bits-n))&mask;
      if (cnt) last=res>>(bits-1);
      overflow=res>>(bits-1)^res>>(bits-2);
      break;
    case 2:
      while (n--) {
	bit=res>>(bits-1);
	res=(res<<1|last)&mask;
	last=bit;
      }
      overflow=res>>(bits-1)^last;
      break;
    case 3:
      while (n--) {
	bit=res&1;
	res=res>>1|last<<(bits-1);
	last=bit;
      }
      overflow=res>>(bits-1)^res>>(bits-2);
      break;
    case 4: case 6:
      if (cnt) {
	res=val<<cnt&mask;
	last=0;
	if (cnt<=bits) last=val>>(bits-cnt)&1;
      }
      overflow=res>>(bits-1)^last;
      break;
    case 5:
      if (cnt) {
	res=val>>cnt;
	last=val>>(cnt-1)&1;
      }
      overflow=val>>(bits-1);
      break;
    case 7:
      if (cnt) {
	res=SignExtTo64(val,size)>>cnt;
	res&=mask;
	if (cnt>=bits) last=val>>(bits-1);
	else last=val>>(cnt-1)&1;
      }
      break;
  }
  WrRM(size,res); //Even a zero count zero-extends a 32-bit register.
  if (cnt) {
    rfl=rfl&~F_CF|last;
    if (op>=4) SetZSP(res,size);
    if (cnt==1) {
      rfl&=~F_OF;
      if (overflow&1) rfl|=F_OF;
    }
  }
}
