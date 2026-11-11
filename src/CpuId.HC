//Leaf 1 EDX families. Individual instruction and fault limits remain explicit.
#define CPUIDF_FPU	(1<<0)
#define CPUIDF_TSC	(1<<4)
#define CPUIDF_MSR	(1<<5)
#define CPUIDF_CX8	(1<<8)
#define CPUIDF_APIC	(1<<9)
#define CPUIDF_CMOV	(1<<15)
#define CPUIDF_FXSR	(1<<24)
#define CPUIDF_HTT	(1<<28)
//Leaf 0x80000001 EDX.
#define CPUIDF_LM	(1<<29)

U0 CpuId()
{//The long-mode model is independent of the host's instruction set.
  U64 leaf=reg[0]&0xFFFFFFFF;
  reg[0]=reg[1]=reg[2]=reg[3]=0;
  if (!leaf) {
    reg[0]=1;
    reg[3]=0x756E6547;reg[2]=0x49656E69;reg[1]=0x6C65746E;
  } else if (leaf==1) {
    reg[0]=0x6FB;
    reg[3]=(MyCore&0xFF)<<24|(g_ncore&0xFF)<<16|8<<8;
    reg[2]=CPUIDF_FPU|CPUIDF_TSC|CPUIDF_MSR|CPUIDF_CX8|
	  CPUIDF_APIC|CPUIDF_CMOV|CPUIDF_FXSR;
    if (g_ncore>1) reg[2]|=CPUIDF_HTT;
  } else if (leaf==0x80000000)
    reg[0]=0x80000001;
  else if (leaf==0x80000001)
    reg[2]=CPUIDF_LM;
}
