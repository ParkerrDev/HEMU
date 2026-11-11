//Each worker owns one CPU slot. RAM and devices are shared.
#define NCORES 4
//Scratch above the boot-time RAM map cannot overlap a guest heap block.
#define RAM_SIZE 402653184
#define SCR_SIZE 0x1000000
//Host-injected calls, completed or failed at the guest-call sentinel.
#define GC_IDLE    0
#define GC_PENDING 1
#define GC_RUNNING 2
#define GC_DONE    3
#define GC_FAILED  4
#define GC_ERR_BUDGET 1 //The call exhausted its instruction budget.
#define GC_ERR_FAULT  2 //The call faulted or halted.
class CCpuState
{//The f_ prefix keeps register macros from expanding member names.
  U64 f_reg[16],f_rip,f_rfl; //rip,rfl,halted keep their ABI order.
  I64 f_halted,f_irq_stall; //0 run,1 HLT,2 bad opcode,3 divide error.
  U64 f_g_seg[8];			//Flat long-mode selectors.
  U8  f_reserved[8]; //Keeps the existing CPU state layout.
  F64 f_fpr[8];
  I64 f_fsp;		  //x87 stack and top.
  U64 f_x87_cw,f_x87_sw,f_msr_fsbase,f_msr_gsbase;
  I64 f_has_rex,f_rex_w,f_rex_r,f_rex_x,f_rex_b,f_pfx66,f_repf;
  U64 f_g_segbase;			//FS/GS base of the current instruction.
  I64 f_md,f_rg,f_rm,f_is_mem;
  U64 f_ea; //ModRM operand.
  I64 f_icount;	//Instructions this core has run.
};
CCpuState g_cpu_st[NCORES];
#define reg	   g_cpu_st[MyCore()].f_reg
#define rip	   g_cpu_st[MyCore()].f_rip
#define rfl	   g_cpu_st[MyCore()].f_rfl
#define halted	   g_cpu_st[MyCore()].f_halted
#define irq_stall  g_cpu_st[MyCore()].f_irq_stall
#define g_seg	   g_cpu_st[MyCore()].f_g_seg
#define fpr	   g_cpu_st[MyCore()].f_fpr
#define fsp	   g_cpu_st[MyCore()].f_fsp
#define x87_cw	   g_cpu_st[MyCore()].f_x87_cw
#define x87_sw	   g_cpu_st[MyCore()].f_x87_sw
#define msr_fsbase g_cpu_st[MyCore()].f_msr_fsbase
#define msr_gsbase g_cpu_st[MyCore()].f_msr_gsbase
#define hasRex	   g_cpu_st[MyCore()].f_has_rex
#define rexW	   g_cpu_st[MyCore()].f_rex_w
#define rexR	   g_cpu_st[MyCore()].f_rex_r
#define rexX	   g_cpu_st[MyCore()].f_rex_x
#define rexB	   g_cpu_st[MyCore()].f_rex_b
#define pfx66	   g_cpu_st[MyCore()].f_pfx66
#define repf	   g_cpu_st[MyCore()].f_repf
#define g_segbase  g_cpu_st[MyCore()].f_g_segbase
#define md	   g_cpu_st[MyCore()].f_md
#define rg	   g_cpu_st[MyCore()].f_rg
#define rm	   g_cpu_st[MyCore()].f_rm
#define isMem	   g_cpu_st[MyCore()].f_is_mem
#define ea	   g_cpu_st[MyCore()].f_ea
#define icount	   g_cpu_st[MyCore()].f_icount
#define xmm_lo	   g_xmm_lo[MyCore()]	//XMM halves are per core.
#define xmm_hi	   g_xmm_hi[MyCore()]
#define lockf	   g_lockf[MyCore()]	//The current instruction has LOCK.
I64 g_ncore=1;				//Active cores.
U64 g_ipi_pending[NCORES];		//IPI vector,zero when none.
U64 g_icr_high[NCORES]; 		//Destination of the next IPI.
