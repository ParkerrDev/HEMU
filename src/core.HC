//============================================================================
// core.HC - hemu's per-core CPU state plus the shared SMP / guest-call / present scaffolding that every
// entry uses: snapshot.HC (the TempleOS resumer), boot.HC / anim.HC (the demo kernels) and tools/test.HC
// all #include cpu.HC, which includes this first. A single-core build is NCORES slots with MyCore()==0.
//============================================================================
// PER-CORE CPU state for SMP: each vCPU runs in its own Web Worker over SHARED guest RAM, so its
// registers + decode scratch must be per-core, while RAM/devices/JIT-cache stay shared (below).
// g_cpu_st[MyCore()] is THIS worker's slot; MyCore() reads a per-instance WASM global the host sets.
// At single-core MyCore()==0, so this is behaviour-identical to the old flat globals (just relocated).
// f_ prefixes avoid #define self-recursion. f_rip/f_rfl/f_halted stay consecutive: harnesses derive
// halted = &rip + 16 (reg[16]=128B, rip@128, rfl@136, halted@144 = rip+16). ✓
#define NCORES 4
// Guest RAM = the OS's 384 MiB (the snapshot) + a SCRATCH WINDOW above it that TempleOS's page allocator
// never sees (its pools were sized by the boot-time E820 map). hemu ignores paging, so guest code can
// read/write the window (RdMem/WrMem treat anything < mem_size as RAM), which makes it the safe place for
// host<->guest staging (job source text, FileWrite payloads, request mailboxes, the call sentinel) with
// zero risk of colliding with an OS heap block. See guestcall.HC and guestexec.js.
#define RAM_SIZE 402653184
#define SCR_SIZE 0x1000000
// Host-injected guest call states / error codes (guestcall.HC; cpu.HC Run() tests GC_PENDING)
#define GC_IDLE    0
#define GC_PENDING 1
#define GC_RUNNING 2
#define GC_DONE    3
#define GC_FAILED  4
#define GC_ERR_BUDGET 1              // sentinel not reached within the step budget
#define GC_ERR_FAULT  2              // callee faulted (BADOP / #DE) or executed HLT
class CCpuState {
  U64 f_reg[16], f_rip, f_rfl;
  I64 f_halted, f_irq_stall;            // 0 run,1 HLT,2 bad op,3 #DE ; IRQ0-under-IF=0 watchdog
  U64 f_g_seg[8];                       // segment selectors (stored, flat long mode)
  U8  f_fsc[8];                         // U64<->F64 reinterpret scratch
  F64 f_fpr[8]; I64 f_fsp;              // x87 register stack + top
  U64 f_x87_cw, f_x87_sw, f_msr_fsbase, f_msr_gsbase;
  I64 f_hasRex, f_rexW, f_rexR, f_rexX, f_rexB, f_pfx66, f_repf;   // prefix decode
  U64 f_g_segbase;                      // FS/GS base for the current instruction (0 = flat)
  I64 f_md, f_rg, f_rm, f_isMem; U64 f_ea;   // ModRM decode
  I64 f_icount;	//Instructions this core has run.
};
CCpuState g_cpu_st[NCORES];
#define reg        g_cpu_st[MyCore()].f_reg
#define rip        g_cpu_st[MyCore()].f_rip
#define rfl        g_cpu_st[MyCore()].f_rfl
#define halted     g_cpu_st[MyCore()].f_halted
#define irq_stall  g_cpu_st[MyCore()].f_irq_stall
#define g_seg      g_cpu_st[MyCore()].f_g_seg
#define fsc        g_cpu_st[MyCore()].f_fsc
#define fpr        g_cpu_st[MyCore()].f_fpr
#define fsp        g_cpu_st[MyCore()].f_fsp
#define x87_cw     g_cpu_st[MyCore()].f_x87_cw
#define x87_sw     g_cpu_st[MyCore()].f_x87_sw
#define msr_fsbase g_cpu_st[MyCore()].f_msr_fsbase
#define msr_gsbase g_cpu_st[MyCore()].f_msr_gsbase
#define hasRex     g_cpu_st[MyCore()].f_hasRex
#define rexW       g_cpu_st[MyCore()].f_rexW
#define rexR       g_cpu_st[MyCore()].f_rexR
#define rexX       g_cpu_st[MyCore()].f_rexX
#define rexB       g_cpu_st[MyCore()].f_rexB
#define pfx66      g_cpu_st[MyCore()].f_pfx66
#define repf       g_cpu_st[MyCore()].f_repf
#define g_segbase  g_cpu_st[MyCore()].f_g_segbase
#define md         g_cpu_st[MyCore()].f_md
#define rg         g_cpu_st[MyCore()].f_rg
#define rm         g_cpu_st[MyCore()].f_rm
#define isMem      g_cpu_st[MyCore()].f_isMem
#define ea         g_cpu_st[MyCore()].f_ea
#define icount     g_cpu_st[MyCore()].f_icount
#define xmm_lo     g_xmm_lo[MyCore()]   // SSE XMM regs per-core (arrays declared in cpu.HC); like x87, must not be shared across cores
#define xmm_hi     g_xmm_hi[MyCore()]
#define lockf      g_lockf[MyCore()]    // per-core: current instruction had a LOCK prefix (atomic RMW on shared mem)
I64 g_ncore;                            // # of active cores (set by SetSnapRegs; 0/1 = single-core)
U64 g_ipi_pending[NCORES];              // SMP: per-core pending IPI vector (0=none; runtime I_WAKE wakes APs)
U64 g_icr_high[NCORES];                 // SMP: each core's last LAPIC ICR_HIGH write (dest apic_id<<24)
