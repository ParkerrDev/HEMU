U0 ExceptDiv(U64 fault_rip)
{//Measured ring-zero long-mode divide fault, without a stack switch.
  U64 gate=idtr_base,sel,code,off,sp=reg[4]&~15,attr,desc,cs_idx;
  rip=fault_rip;
  halted=3;
  //Unsupported delivery stays stopped, before changing registers or RAM.
  if (!(msr_efer&0x400) || !(cr0&1) || g_cs&3 || g_ss&3 ||
	idtr_limit<15 || gate>=mem_size || mem_size-gate<16)
    return;
  attr=RdMem(gate+5,1);
  if (attr&0x9F!=0x8E && attr&0x9F!=0x8F ||
	RdMem(gate+4,1) || RdMem(gate+12,4))
    return;
  sel=RdMem(gate+2,2);
  cs_idx=sel&~7;
  if (!cs_idx || sel&4 || sel&~3!=g_cs&~3 ||
	gdtr_limit<7 || cs_idx>gdtr_limit-7 ||
	gdtr_base>=mem_size || cs_idx+8>mem_size-gdtr_base)
    return;
  desc=RdMem(gdtr_base+cs_idx,8);
  code=desc>>40&0xFF;
  if (code&0xF8!=0x98 || desc>>52&6!=2)
    return;
  off=RdMem(gate,2)|RdMem(gate+6,2)<<16|RdMem(gate+8,4)<<32;
  if (off>=mem_size || reg[4]>mem_size || sp<40)
    return;
  WrMem(gdtr_base+cs_idx+5,1,code|1); //Loading CS sets accessed.
  WrMem(sp-8,8,g_ss);
  WrMem(sp-16,8,reg[4]);
  WrMem(sp-24,8,rfl|0x10000); //Faults save RF, with no error-code word.
  WrMem(sp-32,8,g_cs);
  WrMem(sp-40,8,fault_rip);
  reg[4]=sp-40;
  rfl&=~0x34100; //TF,NT,RF,VM clear in either gate type.
  if (attr&15==14) rfl&=~F_IF;
  g_cs=sel&~3;
  rip=off;
  irq_stall=halted=0;
}
